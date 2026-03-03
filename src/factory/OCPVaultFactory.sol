// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "../core/OCPVault.sol";

/// @dev Chainlink VRF V2+ Coordinator 精简接口
interface IVRFCoordinatorV2Plus {
    function requestRandomWords(
        bytes32 keyHash,
        uint256 subId,
        uint16 requestConfirmations,
        uint32 callbackGasLimit,
        uint32 numWords
    ) external returns (uint256 requestId);
}

/**
 * @title OCPVaultFactory
 * @dev OCP 金库工厂 — TEE + VRF commitment 方案
 *
 * VRF 回调只 emit keccak256(offset)，不暴露明文 offset。
 * TEE Keeper 从 Chainlink VRF proof 链下推导 offset，外部观察者无法得知结算时间。
 */
contract OCPVaultFactory {
    // ──────────── 基础数据 ────────────
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

    // ──────────── VRF 配置 ────────────
    IVRFCoordinatorV2Plus public immutable vrfCoordinator;
    uint256 public vrfSubscriptionId;
    bytes32 public vrfKeyHash;
    uint32 public vrfCallbackGasLimit;
    uint16 public vrfRequestConfirmations;
    address public owner;

    /// @dev requestId → vault 地址
    mapping(uint256 => address) private _requestToVault;
    /// @dev requestId → 随机偏移窗口长度（秒）
    mapping(uint256 => uint32) private _requestToWindowLength;
    /// @dev vault → 是否已请求过 VRF
    mapping(address => bool) public vrfRequested;

    // ──────────── Events ────────────
    event MarketCreated(
        address indexed market,
        address indexed vault,
        address indexed creator,
        string title,
        string description
    );

    /// @notice VRF 请求已发出
    event RandomEndRequested(
        address indexed vault,
        uint256 indexed requestId,
        uint32 windowLength
    );

    /// @notice VRF 回调后发出：只包含 vault 地址和 offset 的 keccak256 承诺值
    /// @dev TEE 不依赖此事件获取 offset，而是从 VRF proof 链下推导
    event RandomOffsetCommitted(
        address indexed vault,
        bytes32 offsetCommitment,
        uint256 indexed requestId
    );

    // ──────────── Constructor ────────────
    constructor(
        address _vrfCoordinator,
        uint256 _subscriptionId,
        bytes32 _keyHash,
        uint32 _callbackGasLimit,
        uint16 _requestConfirmations
    ) {
        owner = msg.sender;
        vrfCoordinator = IVRFCoordinatorV2Plus(_vrfCoordinator);
        vrfSubscriptionId = _subscriptionId;
        vrfKeyHash = _keyHash;
        vrfCallbackGasLimit = _callbackGasLimit;
        vrfRequestConfirmations = _requestConfirmations;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner");
        _;
    }

    /// @notice 更新 VRF 配置参数
    function setVRFConfig(
        uint256 _subscriptionId,
        bytes32 _keyHash,
        uint32 _callbackGasLimit,
        uint16 _requestConfirmations
    ) external onlyOwner {
        vrfSubscriptionId = _subscriptionId;
        vrfKeyHash = _keyHash;
        vrfCallbackGasLimit = _callbackGasLimit;
        vrfRequestConfirmations = _requestConfirmations;
    }

    // ──────────── 金库创建 ────────────

    /**
     * @param stakeToken 质押代币
     * @param resolutionTime 质押截止时间戳（t0）
     * @param challengeWindowSeconds 冷静期与挑战期时长（秒）
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
        marketAddr = address(0);

        vaults.push(vaultAddr);
        _metaByMarket[vaultAddr] = MarketMeta({ title: title, description: description });
        _metaByVault[vaultAddr] = MarketMeta({ title: title, description: description });
        _creatorByVault[vaultAddr] = msg.sender;
        initialLiquidity; // reserved

        emit MarketCreated(marketAddr, vaultAddr, msg.sender, title, description);
    }

    // ──────────── VRF 随机结束 ────────────

    /// @notice vault 创建者发起 VRF 请求，为 vault 启用随机结束
    /// @param vault 金库地址
    /// @param windowLength 随机偏移窗口长度（秒），offset ∈ [0, windowLength]
    function requestRandomEnd(address vault, uint32 windowLength) external {
        require(_creatorByVault[vault] == msg.sender, "Not creator");
        require(!vrfRequested[vault], "Already requested");
        require(windowLength > 0, "Invalid window length");

        // 在 vault 上启用随机结束模式
        OCPVault(vault).enableRandomizedEnd();

        uint256 requestId = vrfCoordinator.requestRandomWords(
            vrfKeyHash,
            vrfSubscriptionId,
            vrfRequestConfirmations,
            vrfCallbackGasLimit,
            1 // numWords
        );

        _requestToVault[requestId] = vault;
        _requestToWindowLength[requestId] = windowLength;
        vrfRequested[vault] = true;

        emit RandomEndRequested(vault, requestId, windowLength);
    }

    /// @notice Chainlink VRF 回调 — 只 emit keccak256(offset)，不暴露明文 offset
    /// @dev TEE 从 Chainlink 节点的 VRF proof 链下推导 offset，无需读链上事件
    function rawFulfillRandomWords(uint256 requestId, uint256[] memory randomWords) external {
        require(msg.sender == address(vrfCoordinator), "Only coordinator");

        address vaultAddr = _requestToVault[requestId];
        require(vaultAddr != address(0), "Unknown request");

        uint32 windowLength = _requestToWindowLength[requestId];
        uint32 offset = uint32(randomWords[0] % (uint256(windowLength) + 1));

        // 只 emit offset 的 keccak256 承诺值 — 外部无法从哈希反推 offset
        bytes32 commitment = keccak256(abi.encodePacked(offset));
        emit RandomOffsetCommitted(vaultAddr, commitment, requestId);

        // 用完即删，不留在 storage
        delete _requestToVault[requestId];
        delete _requestToWindowLength[requestId];
    }

    /// @notice TEE Keeper 通过此入口触发 vault 结算
    /// @dev 任何人可调用，但只有 TEE 在正确时间调用才有意义
    function finalizeVault(address vault) external {
        OCPVault(vault).finalizeByFactory();
    }

    // ──────────── 查询 ────────────

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

    function getVaultMeta(
        address vault
    ) external view returns (string memory title, string memory description) {
        MarketMeta storage meta = _metaByVault[vault];
        return (meta.title, meta.description);
    }

    function getVaultCreator(address vault) external view returns (address) {
        return _creatorByVault[vault];
    }
}
