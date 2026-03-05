// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "../core/JobGuaranteeVault.sol";

/**
 * @title JobGuaranteeVaultFactory
 * @dev OCP、ACP Job 担保金库工厂
 *
 * OCP gateway 为每笔需要担保的 ACP Job 调用 create() 部署一个 JobGuaranteeVault。
 * 工厂记录所有已部署金库，供链外查询。
 */
contract JobGuaranteeVaultFactory {
    // ─── State ───────────────────────────────────────────────

    /// @notice 所有已部署金库地址（按创建顺序）
    address[] public vaults;
    /// @notice jobId → vault 地址（一个 ACP Job 只对应一个金库）
    mapping(string => address) public vaultByJobId;
    /// @notice vault 地址 → 是否由本工厂创建
    mapping(address => bool) public isVault;

    // ─── Events ──────────────────────────────────────────────

    event GuaranteeVaultCreated(
        address indexed vault,
        string  jobId,
        address indexed buyer,
        address indexed seller,
        address evaluator,
        uint256 guaranteeAmount,
        uint256 jobDeadline
    );

    // ─── Factory function ────────────────────────────────────

    /**
     * @notice 为一笔 ACP Job 部署担保金库
     * @param  buyer              Buyer 地址（押 NO）
     * @param  seller             Seller 地址（押 YES）
     * @param  evaluator          Evaluator 地址；填 OCP gateway 地址时由 gateway 调 adjudicate()；
     *                            填 address(0) 时仅超时结算
     * @param  usdc               USDC 合约地址
     * @param  guaranteeAmount    Buyer / Seller 各需质押的金额（wei 单位）
     * @param  jobDeadline        ACP Job 截止时间（Unix timestamp，单位：秒）
     * @param  evalWindowSeconds  裁决窗口时长（建议 3600 = 1 小时）
     * @param  jobId              ACP Job ID（字符串，供链外追踪）
     * @return vault              新部署的 JobGuaranteeVault 地址
     */
    function create(
        address buyer,
        address seller,
        address evaluator,
        address usdc,
        uint256 guaranteeAmount,
        uint256 jobDeadline,
        uint256 evalWindowSeconds,
        string calldata jobId
    ) external returns (address vault) {
        require(bytes(jobId).length > 0, "jobId required");
        require(vaultByJobId[jobId] == address(0), "Job already has a vault");

        JobGuaranteeVault v = new JobGuaranteeVault(
            buyer,
            seller,
            evaluator,
            usdc,
            guaranteeAmount,
            jobDeadline,
            evalWindowSeconds,
            jobId
        );

        vault = address(v);
        vaults.push(vault);
        vaultByJobId[jobId] = vault;
        isVault[vault]      = true;

        emit GuaranteeVaultCreated(
            vault,
            jobId,
            buyer,
            seller,
            evaluator,
            guaranteeAmount,
            jobDeadline
        );
    }

    // ─── View helpers ─────────────────────────────────────────

    /// @notice 返回已部署金库总数
    function vaultCount() external view returns (uint256) {
        return vaults.length;
    }

    /// @notice 批量读取金库地址（分页）
    function getVaults(uint256 start, uint256 count)
        external
        view
        returns (address[] memory result)
    {
        uint256 total = vaults.length;
        if (start >= total) return new address[](0);
        uint256 end = start + count;
        if (end > total) end = total;
        result = new address[](end - start);
        for (uint256 i = start; i < end; i++) {
            result[i - start] = vaults[i];
        }
    }
}
