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
    /// @notice 已创建金库列表
    address[] public vaults;
    /// @notice 已创建市场列表
    address[] public markets;

    /// @notice 市场元信息（标题/说明），供前端展示
    struct MarketMeta {
        string title;
        string description;
    }

    /// @dev 以市场地址索引元信息
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
        // 参数校验
        require(stakeToken != address(0), "Invalid token");
        require(resolutionTime > block.timestamp, "Invalid resolutionTime");
        require(challengeWindowSeconds > 0, "Invalid challenge window");
        require(minStake > 0, "Invalid min stake");

        // 1) 创建金库（负责共识/终局）
        OCPVault v = new OCPVault(
            address(this),
            stakeToken,
            resolutionTime,
            challengeWindowSeconds,
            minStake
        );
        vaultAddr = address(v);

        // 2) 创建预测市场（AMM + 手续费捐赠）
        PredictionMarket m = new PredictionMarket(
            vaultAddr,
            address(0), // treasury 预留
            0, // conditionType
            "", // conditionParams
            resolutionTime
        );
        marketAddr = address(m);

        // 3) 绑定市场到金库，便于外部查询与协作
        v.setLinkedMarket(marketAddr);

        vaults.push(vaultAddr);
        markets.push(marketAddr);
        _metaByMarket[marketAddr] = MarketMeta({
            title: title,
            description: description
        });

        // 4) 可选：创建者注入初始流动性
        // 注意：调用方需提前对工厂地址进行 ERC20 授权
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

    /// @dev 内部注入初始流动性：先转入工厂，再授权给市场完成注入
    function _addInitialLiquidity(
        address token,
        address market,
        uint256 amount
    ) internal {
        // 将代币转入工厂，再授权给市场合约
        IERC20 t = IERC20(token);
        t.safeTransferFrom(msg.sender, address(this), amount);
        t.safeIncreaseAllowance(market, amount);
        PredictionMarket(market).addLiquidity(amount);
    }

    /// @notice 返回已创建市场列表
    function getMarkets() external view returns (address[] memory) {
        return markets;
    }

    /// @notice 返回已创建金库列表
    function getVaults() external view returns (address[] memory) {
        return vaults;
    }

    /// @notice 返回市场元信息（标题/说明）
    function getMarketMeta(
        address market
    ) external view returns (string memory title, string memory description) {
        MarketMeta storage meta = _metaByMarket[market];
        return (meta.title, meta.description);
    }
}
