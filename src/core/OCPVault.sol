// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import "../interfaces/IOCPVault.sol";

/**
 * @title OCPVault
 * @dev OCP 金库（三态：YES/NO/INVALID）
 *
 * 规则（与白皮书一致，去除声誉/父子事件）：
 * - 质押期：至 t0 止，可质押；每人至多一侧
 * - 冷静期：t0 后时长 Δ，可发起一次挑战（YES/NO 劣势方或 INVALID）
 * - 挑战期：有人挑战后开放、时长 Δ，可重新投票/新质押（整边移动）；结束即终局
 * - 终局规则：YES>50% 或 NO>50% 则该方通吃，否则 INVALID 全员退款
 */
contract OCPVault is ReentrancyGuard, IOCPVault {
    using SafeERC20 for IERC20;

    /// @notice 分红精度（用于 accRewardPerShare）
    uint256 private constant REWARD_PRECISION = 1e18;

    /// @notice 质押/计价使用的 ERC20
    IERC20 public immutable override stakeToken;
    /// @notice 质押截止时间（t0）
    uint256 public immutable override resolutionTime; // t0
    /// @notice 冷静期/挑战期结束时间（t0 + Δ）
    uint256 public immutable override challengeWindowEnd; // t0 + Δ
    /// @notice 最小质押额（挑战保证金 b）
    uint256 public immutable override minStake; // b
    /// @notice 工厂地址
    address public immutable factory;
    /// @notice 关联的预测市场地址（由工厂绑定）
    address public linkedMarket;

    /// @dev 质押本金与各侧总量
    uint256 private _totalPrincipal;
    uint256 private _totalStakeYes;
    uint256 private _totalStakeNo;
    uint256 private _totalStakeInvalid;
    /// @notice 累积手续费（donate 总额）
    uint256 public totalFees;

    /// @dev 每单位本金的累积分红（与 ClassicsConsensusVault 一致，每笔 donate 按当时质押占比记入，防最后一秒冲进来领分红）
    uint256 private _accRewardPerShare;
    /// @dev 用户奖励负债：记录上次交互时已计入的分红份额，用于避免重复领取
    mapping(address => uint256) private _rewardDebt;

    struct StakeInfo {
        /// @notice YES 侧质押
        uint256 yes;
        /// @notice NO 侧质押
        uint256 no;
        /// @notice INVALID 侧质押
        uint256 invalid;
        /// @notice 是否已有质押（用于限制多侧下注）
        bool hasStaked;
    }
    mapping(address => StakeInfo) private _stakeOf;
    mapping(address => bool) private _claimed;

    /// @notice 是否已终局
    bool public override resolved;
    /// @notice 终局结果
    Outcome public override outcome;

    /// @notice 是否已触发挑战
    bool public challenged;
    /// @notice 再质押期结束时间（挑战后生效）
    uint256 public override reStakePeriodEnd;
    /// @notice 挑战发起人
    address public challenger;
    enum ChallengeType {
        NONE,
        YES_NO,
        INVALID
    }
    /// @notice 当前挑战类型（NONE/YES_NO/INVALID）
    ChallengeType public challengeType;

    /// @notice 用户质押事件
    event Staked(address indexed user, Side side, uint256 amount);
    /// @notice 用户移仓事件
    event StakeMoved(
        address indexed user,
        Side fromSide,
        Side toSide,
        uint256 amount
    );
    /// @notice 挑战触发事件
    event Challenged(
        address indexed user,
        ChallengeType challengeType,
        Side side
    );
    /// @notice 手续费/捐赠进入金库事件
    event Donated(address indexed from, uint256 amount);
    /// @notice 金库终局事件
    event Finalized(Outcome outcome);
    /// @notice 终局后提现事件
    event Withdrawn(address indexed user, uint256 payout);

    constructor(
        address _factory,
        address _stakeToken,
        uint256 _resolutionTime,
        uint256 challengeWindowSeconds,
        uint256 _minStake
    ) {
        // 参数校验
        require(_factory != address(0), "Invalid factory");
        require(_stakeToken != address(0), "Invalid token");
        require(_resolutionTime > block.timestamp, "Invalid resolutionTime");
        require(challengeWindowSeconds > 0, "Invalid challenge window");
        require(_minStake > 0, "Invalid min stake");

        factory = _factory;
        stakeToken = IERC20(_stakeToken);
        resolutionTime = _resolutionTime;
        challengeWindowEnd = _resolutionTime + challengeWindowSeconds;
        minStake = _minStake;
        outcome = Outcome.PENDING;
    }

    /// @notice 由工厂在创建 PM 后调用，绑定预测市场
    function setLinkedMarket(address _market) external {
        // 仅允许工厂绑定一次
        require(msg.sender == factory, "Only factory");
        require(linkedMarket == address(0), "Already set");
        require(_market != address(0), "Invalid market");
        linkedMarket = _market;
    }

    /// @notice 读取金库总本金
    function totalPrincipal() external view override returns (uint256) {
        return _totalPrincipal;
    }

    /// @notice 读取 YES 侧总质押
    function totalStakeYes() external view override returns (uint256) {
        return _totalStakeYes;
    }

    /// @notice 读取 NO 侧总质押
    function totalStakeNo() external view override returns (uint256) {
        return _totalStakeNo;
    }

    /// @notice 读取 INVALID 侧总质押
    function totalStakeInvalid() external view override returns (uint256) {
        return _totalStakeInvalid;
    }

    /// @notice 读取某用户在各侧的质押额
    function stakeOf(
        address user
    )
        external
        view
        override
        returns (uint256 yesAmount, uint256 noAmount, uint256 invalidAmount)
    {
        StakeInfo storage info = _stakeOf[user];
        return (info.yes, info.no, info.invalid);
    }

    /// @notice 是否满足终局条件（不改变状态）
    function canResolve() public view override returns (bool) {
        // 已终局直接返回 true；否则依据是否挑战与时间判断
        if (resolved) return true;
        if (challenged) return block.timestamp >= reStakePeriodEnd;
        return block.timestamp >= challengeWindowEnd;
    }

    /// @notice 统一质押入口：质押期可押 YES/NO；冷静期仅可押 b 于劣势方或 INVALID（即发起挑战）；挑战期可押 YES/NO/INVALID 或移仓
    function stake(Side side, uint256 amount) external override nonReentrant {
        // 三个阶段判断
        bool inStakePeriod = block.timestamp < resolutionTime;
        bool inCoolingOff = block.timestamp >= resolutionTime &&
            block.timestamp < challengeWindowEnd &&
            !challenged;
        bool inChallengePeriod = challenged &&
            block.timestamp < reStakePeriodEnd;

        StakeInfo storage info = _stakeOf[msg.sender];

        if (inCoolingOff) {
            // 冷静期：仅允许劣势方/INVALID 以 b 发起挑战
            require(amount == minStake, "Cooling-off: amount must equal b");
            uint256 yesStake = _totalStakeYes;
            uint256 noStake = _totalStakeNo;
            bool hasAdvantaged = yesStake != noStake;
            bool yesDisadvantaged = hasAdvantaged && yesStake < noStake;
            if (side == Side.YES || side == Side.NO) {
                require(hasAdvantaged, "No disadvantaged side");
                require(
                    (side == Side.YES && yesDisadvantaged) ||
                        (side == Side.NO && !yesDisadvantaged),
                    "Not disadvantaged"
                );
                // 优势方持仓者不得在冷静期转押劣势方
                if (yesDisadvantaged) {
                    require(
                        !(info.no > 0 && side == Side.YES),
                        "Advantaged side cannot switch"
                    );
                } else {
                    require(
                        !(info.yes > 0 && side == Side.NO),
                        "Advantaged side cannot switch"
                    );
                }
            } else {
                // 优势方持仓者不得在冷静期通过 INVALID 发起挑战
                if (hasAdvantaged) {
                    if (yesDisadvantaged) {
                        require(info.no == 0, "Advantaged side cannot switch");
                    } else {
                        require(info.yes == 0, "Advantaged side cannot switch");
                    }
                }
            }
        } else {
            // 质押期或挑战期：金额需 >= b，且质押期不能押 INVALID
            require(
                inStakePeriod || inChallengePeriod,
                "Not in stake or challenge period"
            );
            require(amount >= minStake, "Amount below min stake");
            require(
                !(inStakePeriod && side == Side.INVALID),
                "INVALID only in cooling-off or challenge period"
            );
        }

        // 结算该用户的未分配分红（pendingReward）
        uint256 prevPrincipal = info.yes + info.no + info.invalid;
        // 计算该用户在此次质押前应计的分红（pendingReward）
        uint256 pendingReward = 0;
        if (prevPrincipal > 0) {
            pendingReward =
                (prevPrincipal * _accRewardPerShare) /
                REWARD_PRECISION -
                _rewardDebt[msg.sender];
        }
        if (!inCoolingOff) {
            // 非冷静期：每人只能押单侧（禁止跨侧下注）
            if (info.hasStaked) {
                if (side == Side.YES)
                    require(
                        info.no == 0 && info.invalid == 0,
                        "Same side only"
                    );
                if (side == Side.NO)
                    require(
                        info.yes == 0 && info.invalid == 0,
                        "Same side only"
                    );
                if (side == Side.INVALID)
                    require(info.yes == 0 && info.no == 0, "Same side only");
            }
        }

        // 转入质押本金
        stakeToken.safeTransferFrom(msg.sender, address(this), amount);
        info.hasStaked = true;
        _totalPrincipal += amount;
        uint256 newPrincipal = prevPrincipal + amount;
        if (side == Side.YES) {
            info.yes += amount;
            _totalStakeYes += amount;
        } else if (side == Side.NO) {
            info.no += amount;
            _totalStakeNo += amount;
        } else {
            info.invalid += amount;
            _totalStakeInvalid += amount;
        }

        // 更新奖励负债，保证分红不被重复领取
        // 将 pendingReward 留在 rewardDebt 中，避免被冲掉
        _rewardDebt[msg.sender] =
            (newPrincipal * _accRewardPerShare) /
            REWARD_PRECISION -
            pendingReward;

        if (inCoolingOff) {
            // 冷静期押注即触发挑战与再质押期
            challenged = true;
            challenger = msg.sender;
            reStakePeriodEnd =
                block.timestamp +
                (challengeWindowEnd - resolutionTime);
            if (side == Side.INVALID) {
                challengeType = ChallengeType.INVALID;
                emit Challenged(
                    msg.sender,
                    ChallengeType.INVALID,
                    Side.INVALID
                );
            } else {
                challengeType = ChallengeType.YES_NO;
                emit Challenged(msg.sender, ChallengeType.YES_NO, side);
            }
        } else {
            emit Staked(msg.sender, side, amount);
        }
    }

    /// @notice 挑战期内将某侧质押整体移至另一侧；不允许部分移动，以保持「每人至多一侧」的共识严肃性。仅本金换边，分红继续跟着（不提取），终局 withdraw 时一并结算。
    function moveStake(
        Side fromSide,
        Side toSide,
        uint256 amount
    ) external override nonReentrant {
        // 仅挑战期允许移仓
        require(
            challenged && block.timestamp < reStakePeriodEnd,
            "Not in challenge period"
        );
        require(fromSide != toSide, "Same side");

        StakeInfo storage info = _stakeOf[msg.sender];
        uint256 userTotal = info.yes + info.no + info.invalid;
        require(userTotal > 0, "No stake");

        // 移仓前结算分红记账：保留 pending 到 rewardDebt（与 stake 一致），本金换边后分红继续跟着，withdraw 时一并发放
        uint256 pendingReward = (userTotal * _accRewardPerShare) /
            REWARD_PRECISION -
            _rewardDebt[msg.sender];
        _rewardDebt[msg.sender] =
            (userTotal * _accRewardPerShare) /
            REWARD_PRECISION -
            pendingReward;

        uint256 amountToMove;
        if (fromSide == Side.YES) {
            amountToMove = info.yes;
            require(amountToMove > 0, "No YES stake");
            require(amount == amountToMove, "Must move full side");
            info.yes = 0;
            _totalStakeYes -= amountToMove;
        } else if (fromSide == Side.NO) {
            amountToMove = info.no;
            require(amountToMove > 0, "No NO stake");
            require(amount == amountToMove, "Must move full side");
            info.no = 0;
            _totalStakeNo -= amountToMove;
        } else {
            amountToMove = info.invalid;
            require(amountToMove > 0, "No INVALID stake");
            require(amount == amountToMove, "Must move full side");
            info.invalid = 0;
            _totalStakeInvalid -= amountToMove;
        }

        // 将整侧质押移动到新侧
        if (toSide == Side.YES) {
            info.yes += amountToMove;
            _totalStakeYes += amountToMove;
        } else if (toSide == Side.NO) {
            info.no += amountToMove;
            _totalStakeNo += amountToMove;
        } else {
            info.invalid += amountToMove;
            _totalStakeInvalid += amountToMove;
        }

        emit StakeMoved(msg.sender, fromSide, toSide, amountToMove);
    }

    /// @notice 捐赠入金库；该笔按当前质押占比即时记入当时在池内的质押人（accRewardPerShare），提款时一并结算
    function donate(uint256 amount) external override nonReentrant {
        // donate 允许任何人向金库贡献手续费
        require(amount > 0, "Amount must be > 0");
        require(_totalPrincipal > 0, "No principal");
        stakeToken.safeTransferFrom(msg.sender, address(this), amount);
        totalFees += amount;
        _accRewardPerShare += (amount * REWARD_PRECISION) / _totalPrincipal;
        emit Donated(msg.sender, amount);
    }

    /// @notice 终局结算（任何人可调用）
    function finalize() external override nonReentrant {
        // 挑战结束或冷静期结束后可终局
        require(!resolved, "Already finalized");
        if (challenged) {
            require(
                block.timestamp >= reStakePeriodEnd,
                "Challenge period not ended"
            );
        } else {
            require(
                block.timestamp >= challengeWindowEnd,
                "Cooling-off period not ended"
            );
        }

        // 终局规则：YES/NO 超过 50% 则胜，否则 INVALID
        uint256 total = _totalPrincipal;
        if (total == 0) {
            outcome = Outcome.INVALID;
        } else if (_totalStakeYes * 2 > total) {
            outcome = Outcome.YES;
        } else if (_totalStakeNo * 2 > total) {
            outcome = Outcome.NO;
        } else {
            outcome = Outcome.INVALID;
        }
        resolved = true;

        emit Finalized(outcome);
    }

    /// @notice 终局后提取本金与分红（每地址仅一次）。严格遵守 CEI：先更新状态再转账；转账额不超过合约余额，最后一笔提款可提尽剩余 dust。
    function withdraw() external override nonReentrant {
        require(resolved, "Not finalized");
        require(!_claimed[msg.sender], "Already claimed");

        StakeInfo storage info = _stakeOf[msg.sender];
        uint256 userTotal = info.yes + info.no + info.invalid;
        require(userTotal > 0, "No stake");

        // 计算应得分红与应付总额（只读）
        uint256 userPendingFees = (userTotal * _accRewardPerShare) /
            REWARD_PRECISION -
            _rewardDebt[msg.sender];

        uint256 payout = 0;
        if (outcome == Outcome.INVALID) {
            payout = userTotal + userPendingFees;
        } else if (outcome == Outcome.YES) {
            if (info.yes > 0) {
                payout =
                    (_totalPrincipal * info.yes) /
                    _totalStakeYes +
                    userPendingFees;
            } else {
                payout = userPendingFees;
            }
        } else if (outcome == Outcome.NO) {
            if (info.no > 0) {
                payout =
                    (_totalPrincipal * info.no) /
                    _totalStakeNo +
                    userPendingFees;
            } else {
                payout = userPendingFees;
            }
        }

        // Effects：先更新状态，再执行外部调用（防重入）
        _claimed[msg.sender] = true;
        info.yes = 0;
        info.no = 0;
        info.invalid = 0;
        _rewardDebt[msg.sender] = 0;

        // Interaction：转账额不超过合约余额，避免精度损失导致 revert，并让最后提款者可提尽剩余 dust
        uint256 balance = stakeToken.balanceOf(address(this));
        uint256 amountToSend = payout > balance ? balance : payout;
        if (amountToSend > 0) {
            stakeToken.safeTransfer(msg.sender, amountToSend);
        }
        emit Withdrawn(msg.sender, amountToSend);
    }

    /// @notice 某地址当前未结算的累计分红（按 accRewardPerShare 与 rewardDebt 计算）
    /// @notice 计算未结算分红（不改变状态）
    function pendingFees(address user) external view returns (uint256) {
        StakeInfo storage info = _stakeOf[user];
        uint256 principal = info.yes + info.no + info.invalid;
        if (principal == 0) return 0;
        return
            (principal * _accRewardPerShare) /
            REWARD_PRECISION -
            _rewardDebt[user];
    }
}
