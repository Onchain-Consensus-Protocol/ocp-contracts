// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../core/OCPVault.sol";
import "../market/PredictionMarket.sol";

/**
 * @title OCPVaultFactory
 * @dev 一次性创建 OCP 金库 + 预测市场
 */
contract OCPVaultFactory {
    using SafeERC20 for IERC20;
    address[] public vaults;
    address[] public markets;

    struct MarketMeta {
        string title;
        string description;
    }

    mapping(address => MarketMeta) private _metaByMarket;

    event MarketCreated(
        address indexed market,
        address indexed vault,
        address indexed creator,
        string title,
        string description
    );

    /**
     * @param stakeToken 质押代币
     * @param resolutionTime 质押截止时间戳（t0）
     * @param challengeWindowSeconds 冷静期与挑战期时长（秒）；建议默认 24 小时（86400）
     * @param minStake 最小质押额 b（挑战保证金）
     * @param initialLiquidity 可选。0 则不注入，创建后由他人 addLiquidity；>0 则创建者注入，按 50-50 进入 AMM 池。当前无 LP 分红、无退出路径，纯属创建者策略。
     * @param title 事件标题
     * @param description 事件说明
     */
    function createMarket(
        address stakeToken,
        uint256 resolutionTime,
        uint256 challengeWindowSeconds,
        uint256 minStake,
        uint256 initialLiquidity,
        string calldata title,
        string calldata description
    ) external returns (address vaultAddr, address marketAddr) {
        require(stakeToken != address(0), "Invalid token");
        require(resolutionTime > block.timestamp, "Invalid resolutionTime");
        require(challengeWindowSeconds > 0, "Invalid challenge window");
        require(minStake > 0, "Invalid min stake");

        OCPVault v = new OCPVault(
            address(this),
            stakeToken,
            resolutionTime,
            challengeWindowSeconds,
            minStake
        );
        vaultAddr = address(v);

        PredictionMarket m = new PredictionMarket(
            vaultAddr,
            address(0), // treasury 预留
            0, // conditionType
            "", // conditionParams
            resolutionTime
        );
        marketAddr = address(m);

        v.setLinkedMarket(marketAddr);

        vaults.push(vaultAddr);
        markets.push(marketAddr);
        _metaByMarket[marketAddr] = MarketMeta({
            title: title,
            description: description
        });

        if (initialLiquidity > 0) {
            _addInitialLiquidity(stakeToken, marketAddr, initialLiquidity);
        }

        emit MarketCreated(
            marketAddr,
            vaultAddr,
            msg.sender,
            title,
            description
        );
    }

    function _addInitialLiquidity(
        address token,
        address market,
        uint256 amount
    ) internal {
        IERC20 t = IERC20(token);
        t.safeTransferFrom(msg.sender, address(this), amount);
        t.safeIncreaseAllowance(market, amount);
        PredictionMarket(market).addLiquidity(amount);
    }

    function getMarkets() external view returns (address[] memory) {
        return markets;
    }

    function getVaults() external view returns (address[] memory) {
        return vaults;
    }

    function getMarketMeta(
        address market
    ) external view returns (string memory title, string memory description) {
        MarketMeta storage meta = _metaByMarket[market];
        return (meta.title, meta.description);
    }
}
