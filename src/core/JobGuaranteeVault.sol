// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title JobGuaranteeVault
 * @dev ACP Job 三方担保金库（专为单笔 ACP Job 设计，与通用 OCPVault 完全独立）
 *
 * 角色与质押方向：
 *   Buyer    → 押 NO  ("我赌服务不会完成"，买保险)
 *   Seller   → 押 YES ("我担保服务会完成"，交保证金)
 *   Evaluator→ 押 YES 或 NO 1% 担保额（裁决费），或由 gateway 直接调用 adjudicate()（无需质押）
 *
 * 终局规则：
 *   SERVICE_COMPLETED  — evaluator 判定服务完成（evalVotedYes=true）
 *   SELLER_DEFAULTED   — evaluator 判定服务违约（evalVotedYes=false）
 *   REFUND             — 超时无裁决 / 双边未完成质押（客观失败，各自退款）
 *
 * 阶段流转（Phase）：
 *   INIT  →  ACTIVE（buyer+seller 双边锁仓完成）
 *         →  JUDGED（evaluator 裁决）
 *         →  FINALIZED（结算完成）
 *
 * 时间线：
 *   [0, jobDeadline)            : 质押期 — buyer/seller 可各自 stakeAs*(）
 *   [jobDeadline, +evalWindow)  : 裁决期 — evaluator 可 adjudicate() / stakeAsEvaluator()
 *   [jobDeadline + evalWindow, ∞): 超时期 — 任何人可调 finalize()，结果为 REFUND
 */
contract JobGuaranteeVault is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ─── Enums ──────────────────────────────────────────────

    /// @notice 金库最终结算结果
    enum Outcome {
        PENDING,             // 未结算
        SERVICE_COMPLETED,   // 服务完成（Seller 赢，保证金归 Seller）
        SELLER_DEFAULTED,    // Seller 违约（Buyer 赢，保证金赔付给 Buyer）
        REFUND               // 退款（超时 / 双边未完成质押 / 客观失败）
    }

    /// @notice 金库阶段
    enum Phase {
        INIT,       // 创建后，等待双边质押
        ACTIVE,     // Buyer + Seller 双边锁仓完成，等待裁决
        JUDGED,     // 裁决完成，等待 finalize
        FINALIZED   // 终局，可提现
    }

    // ─── 不可变配置（构造时写死）────────────────────────────────

    /// @notice Buyer 地址（押 NO）
    address public immutable buyer;
    /// @notice Seller 地址（押 YES）
    address public immutable seller;
    /// @notice Evaluator 地址；address(0) = 仅超时结算，不支持裁决
    address public immutable evaluator;
    /// @notice 质押 / 结算使用的代币（通常为 USDC）
    IERC20 public immutable usdc;
    /// @notice Buyer 和 Seller 各自需质押的金额（= 担保金额 B）
    uint256 public immutable guaranteeAmount;
    /// @notice ACP Job 截止时间（= 质押截止时间）
    uint256 public immutable jobDeadline;
    /// @notice 裁决窗口（jobDeadline 后 Evaluator 的裁决期，单位：秒）
    uint256 public immutable evalWindowSeconds;
    /// @notice 关联的 ACP Job ID（链外追踪用）
    string public jobId;
    /// @notice 本金库的创建者（通常为 OCP gateway 地址）
    address public immutable creator;

    // ─── 可变状态 ─────────────────────────────────────────────

    Phase public phase;
    Outcome public outcome;

    uint256 public buyerStake;    // Buyer 已质押金额
    uint256 public sellerStake;   // Seller 已质押金额
    uint256 public evalStake;     // Evaluator 经济质押金额（stakeAsEvaluator 时才 >0）

    bool public judged;         // 是否已裁决（adjudicate 或 stakeAsEvaluator 后置 true）
    bool public evalVotedYes;   // 裁决方向：true = 服务完成，false = Seller 违约

    bool public buyerWithdrawn;
    bool public sellerWithdrawn;
    bool public evaluatorWithdrawn;

    // ─── Events ──────────────────────────────────────────────

    event BuyerStaked(address indexed buyer, uint256 amount);
    event SellerStaked(address indexed seller, uint256 amount);
    event VaultActivated(string jobId);
    event EvaluatorJudged(address indexed evaluator, bool serviceCompleted, uint256 evalStake);
    event Finalized(Outcome outcome);
    event Withdrawn(address indexed user, uint256 amount);

    // ─── Constructor ─────────────────────────────────────────

    constructor(
        address _buyer,
        address _seller,
        address _evaluator,        // address(0) = 仅超时结算；实际使用时填 OCP gateway
        address _usdc,
        uint256 _guaranteeAmount,
        uint256 _jobDeadline,
        uint256 _evalWindowSeconds,
        string memory _jobId
    ) {
        require(_buyer != address(0) && _seller != address(0), "Invalid buyer/seller");
        require(_buyer != _seller, "Buyer must differ from seller");
        require(_usdc != address(0), "Invalid token");
        require(_guaranteeAmount > 0, "Amount must be > 0");
        require(_jobDeadline > block.timestamp, "Deadline must be in future");
        require(_evalWindowSeconds >= 60, "Eval window must be >= 60s");

        buyer             = _buyer;
        seller            = _seller;
        evaluator         = _evaluator;
        usdc              = IERC20(_usdc);
        guaranteeAmount   = _guaranteeAmount;
        jobDeadline       = _jobDeadline;
        evalWindowSeconds = _evalWindowSeconds;
        jobId             = _jobId;
        creator           = msg.sender;

        phase   = Phase.INIT;
        outcome = Outcome.PENDING;
    }

    // ─── 质押期 ───────────────────────────────────────────────

    /// @notice Buyer 押 NO（服务不会完成）；必须在 jobDeadline 前调用
    function stakeAsBuyer() external nonReentrant {
        require(msg.sender == buyer, "Not buyer");
        require(block.timestamp < jobDeadline, "Stake period over");
        require(buyerStake == 0, "Buyer already staked");

        usdc.safeTransferFrom(msg.sender, address(this), guaranteeAmount);
        buyerStake = guaranteeAmount;
        emit BuyerStaked(msg.sender, guaranteeAmount);

        _tryActivate();
    }

    /// @notice Seller 押 YES（服务会完成）；必须在 jobDeadline 前调用
    function stakeAsSeller() external nonReentrant {
        require(msg.sender == seller, "Not seller");
        require(block.timestamp < jobDeadline, "Stake period over");
        require(sellerStake == 0, "Seller already staked");

        usdc.safeTransferFrom(msg.sender, address(this), guaranteeAmount);
        sellerStake = guaranteeAmount;
        emit SellerStaked(msg.sender, guaranteeAmount);

        _tryActivate();
    }

    /// @dev 双边锁仓完成 → 推进至 ACTIVE
    function _tryActivate() internal {
        if (buyerStake >= guaranteeAmount && sellerStake >= guaranteeAmount) {
            phase = Phase.ACTIVE;
            emit VaultActivated(jobId);
        }
    }

    // ─── 裁决期 ───────────────────────────────────────────────

    /**
     * @notice MVP 裁决入口：gateway 在收到 ACP 评估结果后调用，无需提交 USDC
     * @dev    适用于 "OCP 自己当 Evaluator" 的场景，不需要经济质押
     * @param  serviceCompleted true = 服务完成（Seller 赢）；false = Seller 违约（Buyer 赢）
     */
    function adjudicate(bool serviceCompleted) external nonReentrant {
        require(evaluator != address(0), "No evaluator configured");
        require(msg.sender == evaluator, "Not evaluator");
        require(phase == Phase.ACTIVE, "Vault not ACTIVE");
        require(block.timestamp >= jobDeadline, "Job deadline not reached");
        require(block.timestamp < jobDeadline + evalWindowSeconds, "Eval window ended");
        require(!judged, "Already judged");

        judged        = true;
        evalVotedYes  = serviceCompleted;
        phase         = Phase.JUDGED;

        emit EvaluatorJudged(msg.sender, serviceCompleted, 0);
    }

    /**
     * @notice 完整经济模型裁决：Evaluator 质押 1% 担保额到裁决侧（赚仲裁费）
     * @dev    适用于第三方 Evaluator agent 参与的场景
     * @param  voteYes true = 服务完成（押 YES）；false = Seller 违约（押 NO）
     */
    function stakeAsEvaluator(bool voteYes) external nonReentrant {
        require(evaluator != address(0), "No evaluator configured");
        require(msg.sender == evaluator, "Not evaluator");
        require(phase == Phase.ACTIVE, "Vault not ACTIVE");
        require(block.timestamp >= jobDeadline, "Job deadline not reached");
        require(block.timestamp < jobDeadline + evalWindowSeconds, "Eval window ended");
        require(!judged, "Already judged");

        // 仲裁保证金 = 1%，最小 1 wei
        uint256 amount = guaranteeAmount / 100;
        if (amount == 0) amount = 1;

        usdc.safeTransferFrom(msg.sender, address(this), amount);
        evalStake     = amount;
        judged        = true;
        evalVotedYes  = voteYes;
        phase         = Phase.JUDGED;

        emit EvaluatorJudged(msg.sender, voteYes, amount);
    }

    // ─── 终局结算 ─────────────────────────────────────────────

    /// @notice 结算金库。满足条件后任何人可调用。
    function finalize() external nonReentrant {
        require(phase != Phase.FINALIZED, "Already finalized");
        require(_canFinalize(), "Cannot finalize yet");

        Outcome resolved;
        if (phase == Phase.JUDGED) {
            // 已有裁决：按裁决方向结算
            resolved = evalVotedYes
                ? Outcome.SERVICE_COMPLETED
                : Outcome.SELLER_DEFAULTED;
        } else {
            // 超时无裁决（INIT 或 ACTIVE 但 evalWindow 已过）→ 退款
            resolved = Outcome.REFUND;
        }

        outcome = resolved;
        phase   = Phase.FINALIZED;
        emit Finalized(resolved);
    }

    /// @notice 是否满足结算条件（view，供链外轮询）
    function canFinalize() external view returns (bool) {
        return _canFinalize();
    }

    function _canFinalize() internal view returns (bool) {
        if (phase == Phase.FINALIZED) return false;
        if (phase == Phase.JUDGED)    return true;
        // 超时：评估窗口结束后任何人可触发退款
        return block.timestamp >= jobDeadline + evalWindowSeconds;
    }

    // ─── 提现 ─────────────────────────────────────────────────

    /// @notice 终局后按角色领取；每地址仅一次
    function withdraw() external nonReentrant {
        require(phase == Phase.FINALIZED, "Not finalized");

        uint256 amount = _calculatePayout(msg.sender);
        require(amount > 0, "Nothing to withdraw");

        // Effects first (CEI)
        _markWithdrawn(msg.sender);

        // 防精度损失导致 revert：最后提款者可提尽剩余 dust
        uint256 balance  = usdc.balanceOf(address(this));
        uint256 toSend   = amount > balance ? balance : amount;
        require(toSend > 0, "Zero transfer");

        usdc.safeTransfer(msg.sender, toSend);
        emit Withdrawn(msg.sender, toSend);
    }

    /// @dev 按结算结果计算各角色应领金额
    function _calculatePayout(address user) internal view returns (uint256) {
        // 防止重复提现
        if (user == buyer    && buyerWithdrawn)     return 0;
        if (user == seller   && sellerWithdrawn)    return 0;
        if (user == evaluator && evaluatorWithdrawn) return 0;

        uint256 totalPool = buyerStake + sellerStake + evalStake;

        if (outcome == Outcome.REFUND) {
            // 各方拿回自己质押的金额
            if (user == buyer)     return buyerStake;
            if (user == seller)    return sellerStake;
            if (user == evaluator) return evalStake;
            return 0;
        }

        if (outcome == Outcome.SERVICE_COMPLETED) {
            // YES 赢：YES 池（Seller + Evaluator(if YES)）按比例瓜分总池
            //   Seller payout = sellerStake / yesPool * totalPool
            //   Evaluator（押 YES）payout = evalStake / yesPool * totalPool
            //   Buyer = 0
            uint256 yesPool = sellerStake + (evalVotedYes ? evalStake : 0);
            if (yesPool == 0) return 0; // 无人押 YES（不应发生）
            if (user == seller) {
                return sellerStake * totalPool / yesPool;
            }
            if (user == evaluator && evalVotedYes && evalStake > 0) {
                return evalStake * totalPool / yesPool;
            }
            return 0; // buyer gets 0 (insurance not triggered, they got the service)
        }

        if (outcome == Outcome.SELLER_DEFAULTED) {
            // NO 赢：NO 池（Buyer + Evaluator(if NO)）按比例瓜分总池
            //   Buyer payout = buyerStake / noPool * totalPool
            //   Evaluator（押 NO）payout = evalStake / noPool * totalPool
            //   Seller = 0 (质押被没收)
            uint256 noPool = buyerStake + (evalVotedYes ? 0 : evalStake);
            if (noPool == 0) return 0; // 无人押 NO（不应发生）
            if (user == buyer) {
                return buyerStake * totalPool / noPool;
            }
            if (user == evaluator && !evalVotedYes && evalStake > 0) {
                return evalStake * totalPool / noPool;
            }
            return 0; // seller gets 0 (defaulted, stake slashed)
        }

        return 0;
    }

    function _markWithdrawn(address user) internal {
        if (user == buyer)     buyerWithdrawn     = true;
        if (user == seller)    sellerWithdrawn    = true;
        if (user == evaluator) evaluatorWithdrawn = true;
    }

    // ─── View helpers ─────────────────────────────────────────

    /// @notice 完整状态快照（供 gateway 轮询）
    function status()
        external
        view
        returns (
            Phase    phase_,
            Outcome  outcome_,
            uint256  buyerStake_,
            uint256  sellerStake_,
            uint256  evalStake_,
            bool     judged_,
            bool     evalVotedYes_,
            bool     canFinalize_
        )
    {
        return (
            phase,
            outcome,
            buyerStake,
            sellerStake,
            evalStake,
            judged,
            evalVotedYes,
            _canFinalize()
        );
    }

    /// @notice 不变配置快照
    function config()
        external
        view
        returns (
            address buyer_,
            address seller_,
            address evaluator_,
            address usdc_,
            uint256 guaranteeAmount_,
            uint256 jobDeadline_,
            uint256 evalWindowSeconds_,
            string memory jobId_
        )
    {
        return (
            buyer,
            seller,
            evaluator,
            address(usdc),
            guaranteeAmount,
            jobDeadline,
            evalWindowSeconds,
            jobId
        );
    }

    /// @notice 预览某地址当前可领金额（finalize 前返回 0）
    function previewPayout(address user) external view returns (uint256) {
        if (phase != Phase.FINALIZED) return 0;
        return _calculatePayout(user);
    }
}
