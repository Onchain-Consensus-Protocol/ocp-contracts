// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/**
 * @title IOCPEventLedger
 * @notice OCP 历史事件账本：事件结构、用户声誉、创建/终局/质押/挑战接口。
 * @dev    无管理员，代码即法律。保证金按父链/路径调整并设上限。
 */
interface IOCPEventLedger {
    /// @notice 单条事件记录：父引用、质押与权重、挑战状态、终局结果等
    struct EventRecord {
        uint256 eventId;
        uint256 parentEventId;           // 0 表示根事件
        bytes32 parentConsensusSnapshot; // 父终局共识快照，创建时固化
        uint256 totalStakeA;
        uint256 totalStakeB;
        uint256 totalWeightA;            // 按声誉加成的有效权重
        uint256 totalWeightB;
        uint256 challengeBond;            // 按父链调整并设上限后的保证金
        uint256 stakeWindowEnd;
        uint256 challengeWindowEnd;
        uint256 epochAtCreation;
        bool finalized;
        bool outcome;                    // true = A 方胜
        uint256 depth;                   // 根=0，子=父 depth+1
        bool challenged;
        uint256 reStakePeriodEnd;
        bool leadingSideAAtChallenge;    // 挑战发生时领先方是否为 A
    }

    /// @notice 用户声誉：累计赢方质押、参与事件数等（disputeSuccessCount 预留）
    struct UserReputation {
        uint256 cumulativeWinningStake;
        uint256 disputeSuccessCount;
        uint256 totalParticipatedEvents;
    }

    function nextEventId() external view returns (uint256);
    function totalFinalizedEvents() external view returns (uint256);
    function currentEpoch() external view returns (uint256);

    function getEvent(uint256 eventId) external view returns (EventRecord memory);
    function getUserReputation(address user) external view returns (UserReputation memory);

    function createEvent(
        uint256 parentEventId,
        uint256 baseChallengeBond,
        uint256 stakeWindowSeconds,
        uint256 challengeWindowSeconds
    ) external returns (uint256 eventId);

    function stake(uint256 eventId, bool sideA, uint256 amount) external;

    /// @notice 劣势方支付不低于 challengeBond 的 ETH 发起挑战，触发再质押期
    function challenge(uint256 eventId) external payable;

    function finalizeEvent(uint256 eventId, bool outcome) external;

    /// @notice 给定用户与基础质押量，返回有效权重（声誉加成）
    function effectiveStakeWeight(address user, uint256 baseStake) external view returns (uint256);
}
