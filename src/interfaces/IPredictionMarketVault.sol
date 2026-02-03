// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title IPredictionMarketVault
 * @dev 预测市场专用金库的最小接口
 * - 存款、投票（是/否）、捐赠、锁定至结算后提款
 * - 投票占比决定预测市场解析结果
 */
interface IPredictionMarketVault {
    function depositToken() external view returns (IERC20);
    function resolutionTime() external view returns (uint256);
    function totalPrincipal() external view returns (uint256);
    function totalVoteWeight() external view returns (uint256);  // 赞成（是）方权重
    function hasVoted(address user) external view returns (bool);
    function principalOf(address user) external view returns (uint256);
    /// @return outcome true=是方胜(>50%), false=否方胜
    function getOutcome() external view returns (bool outcome);
    /// @return 是否已过结算时间（可解析）
    function canResolve() external view returns (bool);
    /// @notice 捐赠（任何人可调用，按本金占比分配）
    function donate(uint256 amount) external;
    /// @notice 由预测市场调用，标记已解析
    function markResolved(bool _outcome) external;
}
