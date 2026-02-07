// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title IOCPVault
 * @dev OCP 金库接口（三态：YES/NO/INVALID）
 */
interface IOCPVault {
    enum Side {
        YES,
        NO,
        INVALID
    }

    enum Outcome {
        PENDING,
        YES,
        NO,
        INVALID
    }

    function stakeToken() external view returns (IERC20);
    function resolutionTime() external view returns (uint256);
    function challengeWindowEnd() external view returns (uint256);
    function reStakePeriodEnd() external view returns (uint256);
    function minStake() external view returns (uint256);

    function totalPrincipal() external view returns (uint256);
    function totalStakeYes() external view returns (uint256);
    function totalStakeNo() external view returns (uint256);
    function totalStakeInvalid() external view returns (uint256);

    function stakeOf(address user) external view returns (uint256 yesAmount, uint256 noAmount, uint256 invalidAmount);

    function resolved() external view returns (bool);
    function outcome() external view returns (Outcome);
    function canResolve() external view returns (bool);

    function stake(Side side, uint256 amount) external;
    function moveStake(Side fromSide, Side toSide, uint256 amount) external;
    function finalize() external;
    function donate(uint256 amount) external;
    function withdraw() external;
}
