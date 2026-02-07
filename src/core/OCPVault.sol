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

    uint256 private constant REWARD_PRECISION = 1e18;

    IERC20 public immutable override stakeToken;
    uint256 public immutable override resolutionTime; // t0
    uint256 public immutable override challengeWindowEnd; // t0 + Δ
    uint256 public immutable override minStake; // b
    address public immutable factory;
    address public linkedMarket;

    uint256 private _totalPrincipal;
    uint256 private _totalStakeYes;
    uint256 private _totalStakeNo;
    uint256 private _totalStakeInvalid;

    /// @dev 每单位本金的累积分红（与 ClassicsConsensusVault 一致，每笔 donate 按当时质押占比记入，防最后一秒冲进来领分红）
    uint256 private _accRewardPerShare;
    mapping(address => uint256) private _rewardDebt;

    struct StakeInfo {
        uint256 yes;
        uint256 no;
        uint256 invalid;
        bool hasStaked;
    }
    mapping(address => StakeInfo) private _stakeOf;
    mapping(address => bool) private _claimed;

    bool public override resolved;
    Outcome public override outcome;

    bool public challenged;
    uint256 public override reStakePeriodEnd;
    address public challenger;
    enum ChallengeType {
        NONE,
        YES_NO,
        INVALID
    }
    ChallengeType public challengeType;

    event Staked(address indexed user, Side side, uint256 amount);
    event StakeMoved(
        address indexed user,
        Side fromSide,
        Side toSide,
        uint256 amount
    );
    event Challenged(
        address indexed user,
        ChallengeType challengeType,
        Side side
    );
    event Donated(address indexed from, uint256 amount);
    event Finalized(Outcome outcome);
    event Withdrawn(address indexed user, uint256 payout);

    constructor(
        address _factory,
        address _stakeToken,
        uint256 _resolutionTime,
        uint256 challengeWindowSeconds,
        uint256 _minStake
    ) {
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
        require(msg.sender == factory, "Only factory");
        require(linkedMarket == address(0), "Already set");
        require(_market != address(0), "Invalid market");
        linkedMarket = _market;
    }

    function totalPrincipal() external view override returns (uint256) {
        return _totalPrincipal;
    }

    function totalStakeYes() external view override returns (uint256) {
        return _totalStakeYes;
    }

    function totalStakeNo() external view override returns (uint256) {
        return _totalStakeNo;
    }

    function totalStakeInvalid() external view override returns (uint256) {
        return _totalStakeInvalid;
    }

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

    function canResolve() public view override returns (bool) {
        if (resolved) return true;
        if (challenged) return block.timestamp >= reStakePeriodEnd;
        return block.timestamp >= challengeWindowEnd;
    }

    /// @notice 统一质押入口：质押期可押 YES/NO；冷静期仅可押 b 于劣势方或 INVALID（即发起挑战）；挑战期可押 YES/NO/INVALID 或移仓
    function stake(Side side, uint256 amount) external override nonReentrant {
        bool inStakePeriod = block.timestamp < resolutionTime;
        bool inCoolingOff = block.timestamp >= resolutionTime &&
            block.timestamp < challengeWindowEnd &&
            !challenged;
        bool inChallengePeriod = challenged &&
            block.timestamp < reStakePeriodEnd;

        if (inCoolingOff) {
            require(amount == minStake, "Cooling-off: amount must equal b");
            if (side == Side.YES || side == Side.NO) {
                uint256 yesStake = _totalStakeYes;
                uint256 noStake = _totalStakeNo;
                require(yesStake != noStake, "No disadvantaged side");
                bool yesDisadvantaged = yesStake < noStake;
                require(
                    (side == Side.YES && yesDisadvantaged) ||
                        (side == Side.NO && !yesDisadvantaged),
                    "Not disadvantaged"
                );
            }
        } else {
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

        StakeInfo storage info = _stakeOf[msg.sender];
        uint256 prevPrincipal = info.yes + info.no + info.invalid;
        uint256 pendingReward = 0;
        if (prevPrincipal > 0) {
            pendingReward =
                (prevPrincipal * _accRewardPerShare) /
                REWARD_PRECISION -
                _rewardDebt[msg.sender];
        }
        if (!inCoolingOff) {
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

        _rewardDebt[msg.sender] =
            (newPrincipal * _accRewardPerShare) /
            REWARD_PRECISION -
            pendingReward;

        if (inCoolingOff) {
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

    /// @notice 挑战期内将某侧质押整体移至另一侧；不允许部分移动，以保持「每人至多一侧」的共识严肃性。
    function moveStake(
        Side fromSide,
        Side toSide,
        uint256 amount
    ) external override nonReentrant {
        require(
            challenged && block.timestamp < reStakePeriodEnd,
            "Not in challenge period"
        );
        require(fromSide != toSide, "Same side");

        StakeInfo storage info = _stakeOf[msg.sender];
        uint256 userTotal = info.yes + info.no + info.invalid;
        _rewardDebt[msg.sender] =
            (userTotal * _accRewardPerShare) /
            REWARD_PRECISION;
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
        require(amount > 0, "Amount must be > 0");
        require(_totalPrincipal > 0, "No principal");
        stakeToken.safeTransferFrom(msg.sender, address(this), amount);
        _accRewardPerShare += (amount * REWARD_PRECISION) / _totalPrincipal;
        emit Donated(msg.sender, amount);
    }

    function finalize() external override nonReentrant {
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

    function withdraw() external override nonReentrant {
        require(resolved, "Not finalized");
        require(!_claimed[msg.sender], "Already claimed");
        _claimed[msg.sender] = true;

        StakeInfo storage info = _stakeOf[msg.sender];
        uint256 userTotal = info.yes + info.no + info.invalid;
        require(userTotal > 0, "No stake");

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

        if (payout > 0) {
            stakeToken.safeTransfer(msg.sender, payout);
        }
        emit Withdrawn(msg.sender, payout);
    }

    /// @notice 某地址当前未结算的累计分红（按 accRewardPerShare 与 rewardDebt 计算）
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
