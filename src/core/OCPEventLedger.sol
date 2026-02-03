// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "../interfaces/IOCPEventLedger.sol";

/**
 * @title OCPEventLedger
 * @notice OCP 历史事件账本：链上事件创建、质押（声誉加权）、挑战（再质押期）、终局（纪元减半 + 深度声誉溢价）。
 *         保证金按「父链/路径」的挑战成功率调整并设上限，避免全局历史包袱。
 * @dev    无管理员，代码即法律。惰性更新，仅在与用户/事件交互时写状态。
 */
contract OCPEventLedger is IOCPEventLedger {
    // ---------- 纪元与链深度 ----------
    /// @notice 每纪元包含的终局事件数（用于 currentEpoch、声誉减半）
    uint256 public constant EPOCH_SIZE = 210_000;
    /// @notice 事件链最大深度（根 depth=0，子事件 depth = parent.depth + 1）
    uint256 public constant MAX_DEPTH = 64;
    /// @notice 单事件最多父引用数量（当前仅支持单父）
    uint256 public constant MAX_PARENT_COUNT = 1;
    /// @notice 精度基数（1e18），用于比例与声誉上限
    uint256 public constant PRECISION = 1e18;
    /// @notice 纪元减半上限（E > HALVING_CAP 时仍按 HALVING_CAP 算因子）
    uint256 public constant HALVING_CAP = 64;
    /// @notice 声誉参与有效权重计算的上限基数，随纪元右移减半
    uint256 public constant BASE_REPUTATION_CAP = 100e18;

    // ---------- 挑战与再质押 ----------
    /// @notice 挑战发生后，再开放质押的时长
    uint256 public constant RE_STAKE_PERIOD_SECONDS = 1 days;
    /// @notice 保证金按父链计算时，向上追溯的祖先层数（避免长链 gas 无界）
    uint256 public constant MAX_BOND_ANCESTORS = 5;
    /// @notice 保证金相对 base 的最大倍数（防止历史路径把 bond 推得过高）
    uint256 public constant MAX_CHALLENGE_BOND_MULTIPLIER = 3e18; // 3 * PRECISION

    // ---------- 声誉溢价 ----------
    /// @notice 深度声誉溢价：每多一层深度，赢方声誉增量乘以 (1 + DEPTH_REPUTATION_BONUS/PRECISION)
    uint256 public constant DEPTH_REPUTATION_BONUS = 1e17; // 0.1 per depth

    uint256 private _nextEventId = 1;
    uint256 private _totalFinalizedEvents;
    uint256 private _totalDisputeSuccess;

    mapping(uint256 => EventRecord) private _events;
    mapping(uint256 => address[]) private _participants;
    mapping(uint256 => mapping(address => uint256)) private _stakeAmount;
    mapping(uint256 => mapping(address => bool)) private _stakeSideA;
    mapping(address => UserReputation) private _userReputation;
    mapping(uint256 => uint256) private _challengeBondPaid;

    event EventCreated(
        uint256 indexed eventId,
        uint256 indexed parentEventId,
        bytes32 parentConsensusSnapshot,
        uint256 challengeBond,
        uint256 stakeWindowEnd,
        uint256 challengeWindowEnd,
        uint256 epochAtCreation,
        uint256 depth
    );
    event Staked(uint256 indexed eventId, address indexed user, bool sideA, uint256 amount);
    event Challenged(uint256 indexed eventId, address indexed challenger, bool leadingSideA, uint256 bondPaid);
    event EventFinalized(uint256 indexed eventId, bool outcome, uint256 epochAtCreation);

    // -------------------------------------------------------------------------
    // 只读视图
    // -------------------------------------------------------------------------

    /// @notice 下一个可用的全局事件 ID（创建后自增）
    function nextEventId() external view override returns (uint256) {
        return _nextEventId;
    }

    /// @notice 已终局事件总数（用于纪元、统计；不参与保证金计算）
    function totalFinalizedEvents() external view override returns (uint256) {
        return _totalFinalizedEvents;
    }

    /// @notice 当前纪元 E = totalFinalizedEvents / EPOCH_SIZE，用于声誉减半与 cap
    function currentEpoch() public view override returns (uint256) {
        return _totalFinalizedEvents / EPOCH_SIZE;
    }

    /// @notice 按 ID 返回事件记录（含父引用、权重、挑战状态等）
    function getEvent(uint256 eventId) external view override returns (EventRecord memory) {
        return _events[eventId];
    }

    /// @notice 返回用户的声誉（累计赢方质押、参与事件数等）
    function getUserReputation(address user) external view override returns (UserReputation memory) {
        return _userReputation[user];
    }

    // -------------------------------------------------------------------------
    // 事件创建
    // -------------------------------------------------------------------------

    /// @notice 创建新事件。parentEventId=0 为根事件；否则必须为已终局的父事件，并写入父共识快照与深度。
    /// @param parentEventId 父事件 ID，0 表示根事件
    /// @param baseChallengeBond 基础保证金（将按父链挑战成功率调整并设上限）
    /// @param stakeWindowSeconds 质押窗口时长（秒）
    /// @param challengeWindowSeconds 挑战窗口时长（秒），紧接在质押窗口之后
    /// @return eventId 新事件 ID
    function createEvent(
        uint256 parentEventId,
        uint256 baseChallengeBond,
        uint256 stakeWindowSeconds,
        uint256 challengeWindowSeconds
    ) external override returns (uint256 eventId) {
        uint256 depth = 0;
        bytes32 parentSnapshot = bytes32(0);

        if (parentEventId != 0) {
            EventRecord storage parent = _events[parentEventId];
            require(parent.eventId != 0, "OCP: invalid parent");
            require(parent.finalized, "OCP: parent not finalized");
            depth = parent.depth + 1;
            require(depth <= MAX_DEPTH, "OCP: max depth");
            parentSnapshot = _snapshotParentConsensus(parentEventId);
        }

        eventId = _nextEventId++;
        uint256 epoch = _totalFinalizedEvents / EPOCH_SIZE;
        uint256 b = _adjustedChallengeBond(baseChallengeBond, parentEventId);
        uint256 stakeWindowEnd = block.timestamp + stakeWindowSeconds;
        uint256 challengeWindowEnd = stakeWindowEnd + challengeWindowSeconds;

        _events[eventId] = EventRecord({
            eventId: eventId,
            parentEventId: parentEventId,
            parentConsensusSnapshot: parentSnapshot,
            totalStakeA: 0,
            totalStakeB: 0,
            totalWeightA: 0,
            totalWeightB: 0,
            challengeBond: b,
            stakeWindowEnd: stakeWindowEnd,
            challengeWindowEnd: challengeWindowEnd,
            epochAtCreation: epoch,
            finalized: false,
            outcome: false,
            depth: depth,
            challenged: false,
            reStakePeriodEnd: 0,
            leadingSideAAtChallenge: false
        });

        emit EventCreated(
            eventId,
            parentEventId,
            parentSnapshot,
            b,
            stakeWindowEnd,
            challengeWindowEnd,
            epoch,
            depth
        );
        return eventId;
    }

    // -------------------------------------------------------------------------
    // 质押
    // -------------------------------------------------------------------------

    /// @notice 对指定事件质押：绑定立场（sideA=true 为 A 方，false 为 B 方）与金额；有效权重按声誉加成累加到 totalWeightA/B。
    /// @dev 允许质押的时段：初始质押窗口内，或已被挑战且处于再质押期内。
    function stake(uint256 eventId, bool sideA, uint256 amount) external override {
        EventRecord storage e = _events[eventId];
        require(e.eventId != 0, "OCP: invalid event");
        require(!e.finalized, "OCP: event finalized");
        bool inStakeWindow = block.timestamp < e.stakeWindowEnd;
        bool inReStakeWindow = e.challenged && block.timestamp < e.reStakePeriodEnd;
        require(inStakeWindow || inReStakeWindow, "OCP: stake window closed");
        require(amount > 0, "OCP: zero stake");

        if (_stakeAmount[eventId][msg.sender] == 0) {
            _participants[eventId].push(msg.sender);
            _userReputation[msg.sender].totalParticipatedEvents += 1;
            _stakeSideA[eventId][msg.sender] = sideA;
        } else {
            require(_stakeSideA[eventId][msg.sender] == sideA, "OCP: same side only");
        }

        _stakeAmount[eventId][msg.sender] += amount;
        uint256 weight = _effectiveStakeWeightInternal(msg.sender, amount);

        if (sideA) {
            e.totalStakeA += amount;
            e.totalWeightA += weight;
        } else {
            e.totalStakeB += amount;
            e.totalWeightB += weight;
        }

        emit Staked(eventId, msg.sender, sideA, amount);
    }

    // -------------------------------------------------------------------------
    // 挑战
    // -------------------------------------------------------------------------

    /// @notice 劣势方支付不低于 event.challengeBond 的 ETH 发起挑战，开启再质押期；仅挑战窗口内、且该事件尚未被挑战时可调用。
    function challenge(uint256 eventId) external payable override {
        EventRecord storage e = _events[eventId];
        require(e.eventId != 0, "OCP: invalid event");
        require(!e.finalized, "OCP: event finalized");
        require(!e.challenged, "OCP: already challenged");
        require(block.timestamp >= e.stakeWindowEnd && block.timestamp < e.challengeWindowEnd, "OCP: not in challenge window");
        require(msg.value >= e.challengeBond, "OCP: bond too low");

        bool leadingA = e.totalWeightA >= e.totalWeightB;
        bool callerSideA = _stakeSideA[eventId][msg.sender];
        require(callerSideA != leadingA, "OCP: only disadvantage can challenge");

        e.challenged = true;
        e.reStakePeriodEnd = block.timestamp + RE_STAKE_PERIOD_SECONDS;
        e.leadingSideAAtChallenge = leadingA;
        _challengeBondPaid[eventId] = msg.value;

        emit Challenged(eventId, msg.sender, leadingA, msg.value);
    }

    // -------------------------------------------------------------------------
    // 终局
    // -------------------------------------------------------------------------

    /// @notice 在挑战窗口结束（未挑战）或再质押期结束（已挑战）后，任何人可调用以终局并写入 outcome。
    /// @dev 终局时：若有挑战保证金则按赢方有效权重比例分配；赢方获得声誉增量（纪元减半 × 深度溢价）。
    function finalizeEvent(uint256 eventId, bool outcome) external override {
        EventRecord storage e = _events[eventId];
        require(e.eventId != 0, "OCP: invalid event");
        require(!e.finalized, "OCP: already finalized");
        if (e.challenged) {
            require(block.timestamp >= e.reStakePeriodEnd, "OCP: re-stake period not ended");
        } else {
            require(block.timestamp >= e.challengeWindowEnd, "OCP: window not ended");
        }

        e.finalized = true;
        e.outcome = outcome;
        _totalFinalizedEvents += 1;

        if (e.outcome != e.leadingSideAAtChallenge && e.challenged) {
            _totalDisputeSuccess += 1;
        }

        uint256 bond = _challengeBondPaid[eventId];
        if (bond > 0) {
            _distributeBondToWinners(eventId, outcome, bond);
            _challengeBondPaid[eventId] = 0;
        }

        uint256 E = e.epochAtCreation;
        if (E > HALVING_CAP) E = HALVING_CAP;
        uint256 reputationFactor = PRECISION >> E;
        uint256 depthBonus = PRECISION + (e.depth * DEPTH_REPUTATION_BONUS);

        address[] storage participants = _participants[eventId];
        for (uint256 i = 0; i < participants.length; i++) {
            address user = participants[i];
            uint256 amt = _stakeAmount[eventId][user];
            bool sideA = _stakeSideA[eventId][user];
            bool winner = (outcome && sideA) || (!outcome && !sideA);
            if (winner && amt > 0) {
                uint256 credit = (amt * reputationFactor * depthBonus) / PRECISION / PRECISION;
                _userReputation[user].cumulativeWinningStake += credit;
            }
        }

        emit EventFinalized(eventId, outcome, e.epochAtCreation);
    }

    // -------------------------------------------------------------------------
    // 有效权重与内部逻辑
    // -------------------------------------------------------------------------

    /// @notice 给定用户与基础质押量，返回有效权重（用于比较双方强弱、分配保证金）。声誉越高权重越高，受纪元 cap 限制。
    function effectiveStakeWeight(address user, uint256 baseStake) external view override returns (uint256) {
        return _effectiveStakeWeightInternal(user, baseStake);
    }

    /// @dev 有效权重 = baseStake * (1 + min(声誉, 纪元上限))；声誉与 cap 均以 PRECISION 为基。
    function _effectiveStakeWeightInternal(address user, uint256 baseStake) internal view returns (uint256) {
        uint256 epoch = _totalFinalizedEvents / EPOCH_SIZE;
        uint256 E = epoch;
        if (E > HALVING_CAP) E = HALVING_CAP;
        uint256 cap = BASE_REPUTATION_CAP >> E;
        uint256 rep = _userReputation[user].cumulativeWinningStake;
        uint256 effectiveRep = rep > cap ? cap : rep;
        return (baseStake * (PRECISION + effectiveRep)) / PRECISION;
    }

    /// @dev 对父事件做共识快照：keccak256(eventId, outcome, totalStakeA, totalStakeB)，子事件创建后不可篡改。
    function _snapshotParentConsensus(uint256 parentEventId) internal view returns (bytes32) {
        EventRecord storage p = _events[parentEventId];
        return keccak256(abi.encode(p.eventId, p.outcome, p.totalStakeA, p.totalStakeB));
    }

    /// @dev 按父链/路径的挑战成功率调整保证金，并设上限，避免全局历史包袱。
    ///      rate = 路径上「挑战成功次数」/ (路径上「被挑战次数」+ 1)，路径最多 MAX_BOND_ANCESTORS 层。
    ///      低成功率 → 高保证金（恶意骚扰抑制）；高成功率 → 接近 base。最终 bond <= base * MAX_CHALLENGE_BOND_MULTIPLIER/PRECISION。
    /// @param baseBond 应用层传入的基础保证金
    /// @param parentEventId 父事件 ID，0 表示根事件（无父链，按 rate=0 处理）
    function _adjustedChallengeBond(uint256 baseBond, uint256 parentEventId) internal view returns (uint256) {
        uint256 rate = _pathDisputeRate(parentEventId);
        uint256 rawBond = (baseBond * (2 * PRECISION - rate)) / PRECISION;
        uint256 cap = (baseBond * MAX_CHALLENGE_BOND_MULTIPLIER) / PRECISION;
        return rawBond > cap ? cap : rawBond;
    }

    /// @dev 沿父链向上统计「被挑战次数」与「挑战方获胜次数」，返回成功率（PRECISION 为 1）。
    ///      仅追溯 MAX_BOND_ANCESTORS 层，避免长链 gas 无界。
    function _pathDisputeRate(uint256 parentEventId) internal view returns (uint256) {
        if (parentEventId == 0) return 0;
        uint256 pathChallenged = 0;
        uint256 pathDisputeSuccess = 0;
        uint256 cur = parentEventId;
        for (uint256 i = 0; i < MAX_BOND_ANCESTORS && cur != 0; i++) {
            EventRecord storage p = _events[cur];
            if (p.eventId == 0) break;
            if (p.challenged) {
                pathChallenged += 1;
                if (p.outcome != p.leadingSideAAtChallenge) pathDisputeSuccess += 1;
            }
            cur = p.parentEventId;
        }
        if (pathChallenged == 0) return 0;
        return (pathDisputeSuccess * PRECISION) / pathChallenged;
    }

    /// @dev 接收挑战方支付的 ETH，供终局时分配给赢方
    receive() external payable {}

    /// @dev 将挑战保证金按赢方的有效权重比例分配给赢方（同事件内）；若无赢方则不分配。
    function _distributeBondToWinners(uint256 eventId, bool outcome, uint256 bond) internal {
        address[] storage participants = _participants[eventId];
        uint256 totalWinnerWeight = 0;
        for (uint256 i = 0; i < participants.length; i++) {
            address user = participants[i];
            bool sideA = _stakeSideA[eventId][user];
            bool winner = (outcome && sideA) || (!outcome && !sideA);
            if (winner) {
                uint256 w = _effectiveStakeWeightInternal(user, _stakeAmount[eventId][user]);
                totalWinnerWeight += w;
            }
        }
        if (totalWinnerWeight == 0) return;
        for (uint256 i = 0; i < participants.length; i++) {
            address user = participants[i];
            bool sideA = _stakeSideA[eventId][user];
            bool winner = (outcome && sideA) || (!outcome && !sideA);
            if (winner) {
                uint256 w = _effectiveStakeWeightInternal(user, _stakeAmount[eventId][user]);
                uint256 share = (bond * w) / totalWinnerWeight;
                if (share > 0) {
                    (bool ok,) = user.call{value: share}("");
                    require(ok, "OCP: bond transfer failed");
                }
            }
        }
    }
}
