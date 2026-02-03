// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../core/PredictionMarketVault.sol";
import "../market/PredictionMarket.sol";

/**
 * @title PredictionMarketVaultFactory
 * @dev MVP：一次性创建金库 + 预测市场
 */
contract PredictionMarketVaultFactory {
    using SafeERC20 for IERC20;
    address[] public vaults;
    address[] public markets;

    event MarketCreated(
        address indexed market,
        address indexed vault,
        address indexed creator
    );

    /**
     * @param depositToken 存款/抵押代币
     * @param resolutionTime 结算时间戳
     * @param initialLiquidity 初始流动性（0 则需后续 addLiquidity）
     */
    function createMarket(
        address depositToken,
        uint256 resolutionTime,
        uint256 initialLiquidity
    ) external returns (address vaultAddr, address marketAddr) {
        require(depositToken != address(0), "Invalid token");
        require(resolutionTime > block.timestamp, "Invalid resolutionTime");

        PredictionMarketVault v = new PredictionMarketVault(
            address(this),
            depositToken,
            resolutionTime
        );
        vaultAddr = address(v);

        PredictionMarket m = new PredictionMarket(
            vaultAddr,
            address(0),  // treasury 预留
            0,           // conditionType
            "",          // conditionParams
            resolutionTime
        );
        marketAddr = address(m);

        v.setLinkedMarket(marketAddr);

        vaults.push(vaultAddr);
        markets.push(marketAddr);

        if (initialLiquidity > 0) {
            IERC20(depositToken).safeTransferFrom(msg.sender, address(this), initialLiquidity);
            IERC20(depositToken).safeApprove(marketAddr, initialLiquidity);
            PredictionMarket(marketAddr).addLiquidity(initialLiquidity);
        }

        emit MarketCreated(marketAddr, vaultAddr, msg.sender);
    }

    function getMarkets() external view returns (address[] memory) {
        return markets;
    }

    function getVaults() external view returns (address[] memory) {
        return vaults;
    }
}
