// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/**
 * @dev 共识金库只读接口（占位，供 PredictionMarketFactory 编译通过）
 *
 * 说明：
 * - 这里不声明任何函数，仅作为编译期类型占位
 * - 实际的金库校验逻辑在 PredictionMarketFactory 中通过 IConsensusVaultFactory 完成
 * - 若后续需要在工厂内读取金库状态，可在此接口中新增只读函数
 */
interface IConsensusVaultView {
    // 占位接口：保持为空即可
}
