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
    enum Outcome {
        PENDING,
        YES,
        NO,
        INVALID
    }

    // ======= 基本只读信息 =======
    function vault() external view returns (address);
    function collateral() external view returns (address);

    function conditionType() external view returns (uint8);
    function conditionParams() external view returns (bytes memory);
    function resolutionTime() external view returns (uint256);

    function resolved() external view returns (bool);
    function outcome() external view returns (Outcome);

    // ======= 可选：隐含价格/概率 =======
    function getYesNoPrice()
        external
        view
        returns (uint256 yesPrice, uint256 noPrice);

    // ======= 事件 =======
    event Resolved(address indexed market, Outcome outcome);
}

