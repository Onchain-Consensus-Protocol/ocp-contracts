// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/**
 * @title IPredictionMarket
 * @dev 预测市场标准接口，方便外部协议集成
 *
 * 设计目标：
 * - 让外部协议不依赖具体实现，只依赖接口
 * - 提供最核心的市场参数和解析结果
 */
interface IPredictionMarket {
    /// @notice 市场解析结果（PENDING=未解析；YES/NO=单边胜；INVALID=无效/退款）
    enum Outcome {
        PENDING,
        YES,
        NO,
        INVALID
    }

    // ======= 基本只读信息 =======
    /// @notice 关联的 OCP 金库地址（市场解析依赖该金库的终局结果）
    function vault() external view returns (address);
    /// @notice 抵押品（交易币种）地址
    function collateral() external view returns (address);

    /// @notice 交易手续费（bps）
    function feeBps() external view returns (uint256);

    /// @notice 条件类型（由上层协议定义）
    function conditionType() external view returns (uint8);
    /// @notice 条件参数（ABI 编码，便于链上存证）
    function conditionParams() external view returns (bytes memory);
    /// @notice 解析时间戳（到期后可解析/赎回）
    function resolutionTime() external view returns (uint256);

    /// @notice 是否已解析
    function resolved() external view returns (bool);
    /// @notice 解析结果
    function outcome() external view returns (Outcome);

    // ======= 可选：隐含价格/概率 =======
    /// @notice 读取 YES/NO 价格（以 1e18 为基准的比例，yesPrice+noPrice≈1e18）
    function getYesNoPrice()
        external
        view
        returns (uint256 yesPrice, uint256 noPrice);

    // ======= 事件 =======
    /// @notice 市场解析事件（由金库终局驱动）
    event Resolved(address indexed market, Outcome outcome);
}
