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
        uint256 parentEventId; // 0 表示根事件
        bytes32 parentConsensusSnapshot; // 父终局共识快照，创建时固化
        uint256 totalStakeA;
        uint256 totalStakeB;
        uint256 totalWeightA; // 按声誉加成的有效权重
        uint256 totalWeightB;
        uint256 challengeBond; // 按父链调整并设上限后的保证金
        uint256 stakeWindowEnd; // 质押窗口结束时间
        uint256 challengeWindowEnd; // 挑战窗口结束时间
        uint256 epochAtCreation; // 创建时所在纪元
        bool finalized; // 是否已终局
        bool outcome; // true = A 方胜
        uint256 depth; // 根=0，子=父 depth+1
        bool challenged; // 是否已被挑战
        uint256 reStakePeriodEnd; // 再质押期结束时间
        bool leadingSideAAtChallenge; // 挑战发生时领先方是否为 A
    }

    /// @notice 用户声誉：累计赢方质押、参与事件数等（disputeSuccessCount 预留）
    struct UserReputation {
        uint256 cumulativeWinningStake; // 赢方累计质押（声誉基础）
        uint256 disputeSuccessCount; // 挑战成功次数（预留）
        uint256 totalParticipatedEvents; // 参与事件次数
    }

    /// @notice 下一个事件 ID
    function nextEventId() external view returns (uint256);
    /// @notice 已终局事件数量
    function totalFinalizedEvents() external view returns (uint256);
    /// @notice 当前纪元（与终局事件数相关）
    function currentEpoch() external view returns (uint256);

    /// @notice 读取事件记录（完整结构体）
    function getEvent(
        uint256 eventId
    ) external view returns (EventRecord memory);
    /// @notice 读取用户声誉信息
    function getUserReputation(
        address user
    ) external view returns (UserReputation memory);

    /// @notice 创建事件（可选父事件），返回新事件 ID
    function createEvent(
        uint256 parentEventId,
        uint256 baseChallengeBond,
        uint256 stakeWindowSeconds,
        uint256 challengeWindowSeconds
    ) external returns (uint256 eventId);

    /// @notice 对事件进行质押，选择立场与金额
    function stake(uint256 eventId, bool sideA, uint256 amount) external;

    /// @notice 劣势方支付不低于 challengeBond 的 ETH 发起挑战，触发再质押期
    function challenge(uint256 eventId) external payable;

    /// @notice 在窗口结束后终局事件，写入 outcome（true=A 方胜）
    function finalizeEvent(uint256 eventId, bool outcome) external;

    /// @notice 给定用户与基础质押量，返回有效权重（声誉加成）
    function effectiveStakeWeight(
        address user,
        uint256 baseStake
    ) external view returns (uint256);
}
