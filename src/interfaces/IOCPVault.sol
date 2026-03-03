// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title IOCPVault
 * @dev OCP 金库接口（三态：YES/NO/INVALID）
 */
interface IOCPVault {
    /// @notice 质押侧别（与 Outcome 区分：Side 表示下注/立场，Outcome 表示终局结果）
    enum Side {
        YES,
        NO,
        INVALID
    }

    /// @notice 终局结果（PENDING=未终局）
    enum Outcome {
        PENDING,
        YES,
        NO,
        INVALID
    }

    /// @notice 质押/交易使用的 ERC20 代币
    function stakeToken() external view returns (IERC20);
    /// @notice 质押截止时间（t0）
    function resolutionTime() external view returns (uint256);
    /// @notice 冷静期/挑战期结束时间（t0 + Δ）
    function challengeWindowEnd() external view returns (uint256);
    /// @notice 再质押期结束时间（仅在挑战后有效）
    function reStakePeriodEnd() external view returns (uint256);
    /// @notice 最小质押额（挑战保证金 b）
    function minStake() external view returns (uint256);

    /// @notice 总本金（全部质押额）
    function totalPrincipal() external view returns (uint256);
    /// @notice 累积手续费（donate 总额）
    function totalFees() external view returns (uint256);
    /// @notice YES 侧总质押
    function totalStakeYes() external view returns (uint256);
    /// @notice NO 侧总质押
    function totalStakeNo() external view returns (uint256);
    /// @notice INVALID 侧总质押
    function totalStakeInvalid() external view returns (uint256);

    /// @notice 读取某用户在三侧的质押额
    function stakeOf(
        address user
    )
        external
        view
        returns (uint256 yesAmount, uint256 noAmount, uint256 invalidAmount);

    /// @notice 是否已终局
    function resolved() external view returns (bool);
    /// @notice 终局结果
    function outcome() external view returns (Outcome);
    /// @notice 是否满足终局条件（不改变状态）
    function canResolve() external view returns (bool);
    /// @notice 是否启用了随机结束（TEE + VRF 模式）
    function randomizedEndEnabled() external view returns (bool);

    /// @notice 进行质押（按 Side，质押期/挑战期/冷静期规则由实现约束）
    function stake(Side side, uint256 amount) external;
    /// @notice 挑战期内将质押从一侧整体移动到另一侧（通常要求整侧移动）
    function moveStake(Side fromSide, Side toSide, uint256 amount) external;
    /// @notice 终局结算（任何人可调用）
    function finalize() external;
    /// @notice 向金库捐赠手续费（按当前质押占比计入分红）
    function donate(uint256 amount) external;
    /// @notice 终局后提现（含本金与分红，每地址仅一次）
    function withdraw() external;
}
