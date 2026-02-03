// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

import "../interfaces/IPredictionMarketVault.sol";

/**
 * @title PredictionMarketVault
 * @dev 预测市场专用金库（MVP 最小版）
 *
 * 规则：
 * - 存款即获得投票权，投票=赞成（是），不投票=反对（否）
 * - 捐赠按本金占比分配
 * - 锁定至 resolutionTime 之后才可提款
 * - 解析：totalVoteWeight > totalPrincipal/2 则 outcome=true（是方胜）
 */
contract PredictionMarketVault is ReentrancyGuard, IPredictionMarketVault {
    using SafeERC20 for IERC20;

    IERC20 public immutable override depositToken;
    uint256 public immutable override resolutionTime;
    address public immutable factory;
    address public linkedMarket;  // 绑定的预测市场，仅其可调用 markResolved

    uint256 private _totalPrincipal;
    uint256 private _totalVoteWeight;
    uint256 private constant PRECISION = 1e12;

    mapping(address => uint256) private _principalOf;
    mapping(address => bool) private _hasVoted;
    uint256 public accRewardPerShare;
    mapping(address => uint256) public rewardDebt;

    bool public resolved;
    bool public outcome;  // true=是方胜

    event Deposited(address indexed user, uint256 amount);
    event Voted(address indexed user, uint256 weight);
    event Donated(address indexed from, uint256 amount);
    event Withdrawn(address indexed user, uint256 principal, uint256 reward);
    event Resolved(bool outcome);

    constructor(
        address _factory,
        address _depositToken,
        uint256 _resolutionTime
    ) {
        require(_factory != address(0), "Invalid factory");
        require(_depositToken != address(0), "Invalid token");
        require(_resolutionTime > block.timestamp, "Invalid resolutionTime");

        factory = _factory;
        depositToken = IERC20(_depositToken);
        resolutionTime = _resolutionTime;
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

    function totalVoteWeight() external view override returns (uint256) {
        return _totalVoteWeight;
    }

    function hasVoted(address user) external view override returns (bool) {
        return _hasVoted[user];
    }

    function principalOf(address user) external view override returns (uint256) {
        return _principalOf[user];
    }

    function canResolve() external view override returns (bool) {
        return block.timestamp >= resolutionTime;
    }

    /// @return outcome true=是方胜, false=否方胜
    function getOutcome() external view override returns (bool) {
        if (_totalPrincipal == 0) return false;
        return _totalVoteWeight * 2 > _totalPrincipal;
    }

    /// @notice 存款
    function deposit(uint256 amount) external nonReentrant {
        require(block.timestamp < resolutionTime, "Deposit closed");
        require(amount > 0, "Amount must be > 0");
        require(!_hasVoted[msg.sender], "Already voted");

        uint256 oldPrincipal = _principalOf[msg.sender];
        uint256 newPrincipal = oldPrincipal + amount;

        depositToken.safeTransferFrom(msg.sender, address(this), amount);
        _principalOf[msg.sender] = newPrincipal;
        _totalPrincipal += amount;

        _updateRewardDebt(msg.sender, oldPrincipal, newPrincipal);

        emit Deposited(msg.sender, amount);
    }

    /// @notice 投票（赞成/是方）
    function vote() external nonReentrant {
        require(block.timestamp < resolutionTime, "Vote closed");
        uint256 principal = _principalOf[msg.sender];
        require(principal > 0, "No stake");
        require(!_hasVoted[msg.sender], "Already voted");

        _hasVoted[msg.sender] = true;
        _totalVoteWeight += principal;

        emit Voted(msg.sender, principal);
    }

    /// @notice 捐赠（任何人可捐，按本金占比分配）
    function donate(uint256 amount) external nonReentrant {
        require(amount > 0, "Amount must be > 0");
        require(_totalPrincipal > 0, "No principal");

        depositToken.safeTransferFrom(msg.sender, address(this), amount);
        accRewardPerShare += (amount * PRECISION) / _totalPrincipal;

        emit Donated(msg.sender, amount);
    }

    /// @notice 提款（仅 resolutionTime 之后）
    function withdraw() external nonReentrant {
        require(block.timestamp >= resolutionTime, "Not yet unlock");

        uint256 principal = _principalOf[msg.sender];
        require(principal > 0, "Nothing to withdraw");

        uint256 reward = (principal * accRewardPerShare) / PRECISION - rewardDebt[msg.sender];

        _principalOf[msg.sender] = 0;
        _totalPrincipal -= principal;
        rewardDebt[msg.sender] = 0;

        uint256 total = principal + reward;
        if (_totalPrincipal == 0) {
            uint256 bal = depositToken.balanceOf(address(this));
            if (bal > total) total = bal;
        }

        depositToken.safeTransfer(msg.sender, total);
        emit Withdrawn(msg.sender, principal, reward);
    }

    /// @notice 由预测市场调用，标记已解析（便于金库后续逻辑扩展）
    function markResolved(bool _outcome) external {
        require(msg.sender == linkedMarket, "Only linked market");
        require(block.timestamp >= resolutionTime, "Too early");
        require(!resolved, "Already resolved");

        resolved = true;
        outcome = _outcome;
        emit Resolved(_outcome);
    }

    function _updateRewardDebt(address user, uint256 oldPrincipal, uint256 newPrincipal) private {
        uint256 pending = oldPrincipal > 0
            ? (oldPrincipal * accRewardPerShare) / PRECISION - rewardDebt[user]
            : 0;
        rewardDebt[user] = (newPrincipal * accRewardPerShare) / PRECISION - pending;
    }

    function pendingReward(address user) external view returns (uint256) {
        uint256 principal = _principalOf[user];
        if (principal == 0) return 0;
        return (principal * accRewardPerShare) / PRECISION - rewardDebt[user];
    }
}
