// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "../core/OCPVault.sol";

/**
 * @title OCPVaultFactory
 * @dev 当前仅创建 OCP 金库（预测市场创建逻辑暂停）
 */
contract OCPVaultFactory {
    /// @notice 已创建金库列表
    address[] public vaults;
    /// @notice 已创建市场列表
    address[] public markets;

    /// @notice 市场元信息（标题/说明），供前端展示
    struct MarketMeta {
        string title;
        string description;
    }

    /// @dev 以市场地址索引元信息（历史兼容）
    mapping(address => MarketMeta) private _metaByMarket;
    /// @dev 以金库地址索引元信息（当前仅推金库）
    mapping(address => MarketMeta) private _metaByVault;
    /// @dev 记录每个金库的创建者（用于后续权限操作）
    mapping(address => address) private _creatorByVault;

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
     * @param initialLiquidity 预留参数（当前不使用，传入会被忽略）
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

        // 2) 预测市场创建逻辑暂停：仅推金库
        marketAddr = address(0);

        vaults.push(vaultAddr);
        _metaByMarket[vaultAddr] = MarketMeta({
            title: title,
            description: description
        });
        _metaByVault[vaultAddr] = MarketMeta({
            title: title,
            description: description
        });
        _creatorByVault[vaultAddr] = msg.sender;
        initialLiquidity; // reserved

        emit MarketCreated(
            marketAddr,
            vaultAddr,
            msg.sender,
            title,
            description
        );
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

    /// @notice 返回金库元信息（标题/说明）
    function getVaultMeta(
        address vault
    ) external view returns (string memory title, string memory description) {
        MarketMeta storage meta = _metaByVault[vault];
        return (meta.title, meta.description);
    }

    /// @notice 读取某金库创建者
    function getVaultCreator(address vault) external view returns (address) {
        return _creatorByVault[vault];
    }

    /**
     * @notice 为指定金库配置“随机结束窗口”参数（由该金库创建者调用）
     * @param vault 金库地址
     * @param keeper 负责 reveal 的 keeper 地址
     * @param commit seed 承诺值（keccak256）
     * @param windowStart 随机窗口起点（unix 秒）
     * @param windowLength 随机窗口长度（秒）
     */
    function configureRandomizedEnd(
        address vault,
        address keeper,
        bytes32 commit,
        uint64 windowStart,
        uint32 windowLength
    ) external {
        require(vault != address(0), "Invalid vault");
        OCPVault(vault).configureRandomizedEnd(
            keeper,
            commit,
            windowStart,
            windowLength
        );
    }
}
