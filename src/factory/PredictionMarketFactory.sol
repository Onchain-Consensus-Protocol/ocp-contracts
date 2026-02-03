// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "../interfaces/IConsensusVaultView.sol";
import "../market/PredictionMarket.sol";

/**
 * @title PredictionMarketFactory
 * @dev 预测市场工厂（框架版本）
 *
 * 说明：
 * - 仅允许针对已存在的金库开盘
 * - 统一绑定 Treasury 作为费用兜底接收方
 */
contract PredictionMarketFactory {
    address public immutable vaultFactory;
    address public immutable treasury;

    address[] public markets;

    event MarketCreated(
        address indexed market,
        address indexed vault,
        address indexed creator
    );

    /**
     * @param _vaultFactory ConsensusVaultFactory 地址
     * @param _treasury Treasury 合约地址
     */
    constructor(address _vaultFactory, address _treasury) {
        require(_vaultFactory != address(0), "Invalid vaultFactory");
        require(_treasury != address(0), "Invalid treasury");
        vaultFactory = _vaultFactory;
        treasury = _treasury;
    }

    /**
     * @dev 创建预测市场（框架）
     * @param vault 目标金库地址（必须来自 vaultFactory）
     * @param conditionType 条件类型（由协议约定）
     * @param conditionParams 条件参数（ABI 编码）
     * @param resolutionTime 解析时间
     * @param initialLiquidity 可选初始流动性（框架中暂不执行）
     */
    function createMarket(
        address vault,
        uint8 conditionType,
        bytes calldata conditionParams,
        uint256 resolutionTime,
        uint256 initialLiquidity
    ) external returns (address market) {
        require(vault != address(0), "Invalid vault");
        require(resolutionTime > block.timestamp, "Invalid resolutionTime");

        require(_isVaultFromFactory(vault), "Vault not from factory");

        PredictionMarket pm = new PredictionMarket(
            vault,
            treasury,
            conditionType,
            conditionParams,
            resolutionTime
        );
        market = address(pm);

        markets.push(market);
        emit MarketCreated(market, vault, msg.sender);

        // TODO: 若 initialLiquidity > 0，执行首笔 addLiquidity（原子完成）
        // 这里仅保留参数与注释，具体逻辑待实现
        initialLiquidity;

        return market;
    }

    function getMarkets() external view returns (address[] memory) {
        return markets;
    }

    function getMarketsCount() external view returns (uint256) {
        return markets.length;
    }

    // ======= 内部工具 =======
    function _isVaultFromFactory(address vault) internal view returns (bool) {
        address[] memory vaults = IConsensusVaultFactory(vaultFactory).getVaults();
        for (uint256 i = 0; i < vaults.length; i++) {
            if (vaults[i] == vault) {
                return true;
            }
        }
        return false;
    }
}

/**
 * @dev 仅用于读取金库列表的最小接口
 */
interface IConsensusVaultFactory {
    function getVaults() external view returns (address[] memory);
}
