// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import "../src/core/OCPEventLedger.sol";
import "../src/interfaces/IOCPEventLedger.sol";

contract OCPEventLedgerTest is Test {
    OCPEventLedger public ledger;

    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);

    function setUp() public {
        ledger = new OCPEventLedger();
    }

    function test_createEvent_root() public {
        uint256 eid = ledger.createEvent(0, 1 ether, 1 days, 0);
        assertEq(eid, 1);
        assertEq(ledger.nextEventId(), 2);

        IOCPEventLedger.EventRecord memory e = ledger.getEvent(1);
        assertEq(e.eventId, 1);
        assertEq(e.parentEventId, 0);
        assertEq(e.parentConsensusSnapshot, bytes32(0));
        assertEq(e.challengeBond, 2 ether);
        assertEq(e.depth, 0);
        assertFalse(e.finalized);
        assertEq(e.stakeWindowEnd, block.timestamp + 1 days);
        assertEq(e.challengeWindowEnd, block.timestamp + 1 days);
    }

    function test_stake_and_finalize_halving() public {
        uint256 eid = ledger.createEvent(0, 1 ether, 1 days, 0);
        vm.prank(alice);
        ledger.stake(eid, true, 100 ether);

        vm.warp(block.timestamp + 1 days + 1);
        ledger.finalizeEvent(eid, true);

        IOCPEventLedger.UserReputation memory rep = ledger.getUserReputation(alice);
        assertEq(rep.cumulativeWinningStake, 100 ether);
        assertEq(rep.totalParticipatedEvents, 1);
        assertEq(ledger.totalFinalizedEvents(), 1);
        assertEq(ledger.currentEpoch(), 0);
    }

    function test_effectiveStakeWeight_reputationLedger() public {
        uint256 eid = ledger.createEvent(0, 1 ether, 1 days, 0);
        vm.prank(alice);
        ledger.stake(eid, true, 100 ether);
        vm.warp(block.timestamp + 1 days + 1);
        ledger.finalizeEvent(eid, true);

        uint256 weightAlice = ledger.effectiveStakeWeight(alice, 10 ether);
        uint256 weightBob = ledger.effectiveStakeWeight(bob, 10 ether);

        assertGt(weightAlice, 10 ether);
        assertEq(weightBob, 10 ether);
        assertGt(weightAlice, weightBob);
    }

    /// @dev 同额质押下总权重按声誉加成：Alice 有声誉，Bob 无，totalWeightA > totalStakeA
    function test_stakeWeight_accumulates() public {
        uint256 eid = ledger.createEvent(0, 1 ether, 1 days, 0);
        vm.prank(alice);
        ledger.stake(eid, true, 100 ether);
        vm.warp(block.timestamp + 1 days + 1);
        ledger.finalizeEvent(eid, true);

        uint256 eid2 = ledger.createEvent(0, 1 ether, 1 days, 0);
        vm.prank(alice);
        ledger.stake(eid2, true, 10 ether);
        vm.prank(bob);
        ledger.stake(eid2, false, 10 ether);

        IOCPEventLedger.EventRecord memory e = ledger.getEvent(eid2);
        assertEq(e.totalStakeA, 10 ether);
        assertEq(e.totalStakeB, 10 ether);
        assertGt(e.totalWeightA, 10 ether);
        assertEq(e.totalWeightB, 10 ether);
        assertGt(e.totalWeightA, e.totalWeightB);
    }

    function test_childEvent_parentSnapshot() public {
        uint256 e1 = ledger.createEvent(0, 1 ether, 1 days, 0);
        vm.prank(alice);
        ledger.stake(e1, true, 50 ether);
        vm.prank(bob);
        ledger.stake(e1, false, 50 ether);
        vm.warp(block.timestamp + 1 days + 1);
        ledger.finalizeEvent(e1, true);

        bytes32 expectedSnapshot = keccak256(
            abi.encode(uint256(1), true, 50 ether, 50 ether)
        );
        assertEq(ledger.getEvent(1).totalStakeA, 50 ether);
        assertEq(ledger.getEvent(1).totalStakeB, 50 ether);

        uint256 e2 = ledger.createEvent(1, 2 ether, 2 days, 0);
        IOCPEventLedger.EventRecord memory child = ledger.getEvent(e2);
        assertEq(child.parentEventId, 1);
        assertEq(child.parentConsensusSnapshot, expectedSnapshot);
        assertEq(child.depth, 1);
    }

    /// @dev 深度约束：子事件 depth = parent.depth + 1，超过 MAX_DEPTH(64) 则 revert。65 层链需 65 次 create+finalize，Gas 高故仅做浅层校验。
    function test_depthIncrements() public {
        uint256 e1 = ledger.createEvent(0, 1 ether, 1 days, 0);
        vm.prank(alice);
        ledger.stake(e1, true, 1 ether);
        vm.warp(block.timestamp + 1 days + 1);
        ledger.finalizeEvent(e1, true);

        uint256 e2 = ledger.createEvent(e1, 1 ether, 1 days, 0);
        assertEq(ledger.getEvent(e2).depth, 1);
        assertEq(ledger.getEvent(e2).parentEventId, e1);
    }

    function test_parentMustBeFinalized() public {
        uint256 e1 = ledger.createEvent(0, 1 ether, 1 days, 0);
        vm.expectRevert("OCP: parent not finalized");
        ledger.createEvent(e1, 1 ether, 1 days, 0);
    }

    function test_sameSide_only() public {
        uint256 eid = ledger.createEvent(0, 1 ether, 1 days, 0);
        vm.startPrank(alice);
        ledger.stake(eid, true, 10 ether);
        vm.expectRevert("OCP: same side only");
        ledger.stake(eid, false, 5 ether);
        vm.stopPrank();
    }

    /// @dev 仅劣势方可挑战；支付 bond 后进入再质押期，终局后赢方分得保证金（首事件 rate=0 故 bond=2*base）
    function test_challenge_reStake_finalize_bondToWinners() public {
        vm.deal(bob, 2 ether);
        uint256 eid = ledger.createEvent(0, 1 ether, 1 days, 2 days);
        vm.prank(alice);
        ledger.stake(eid, true, 100 ether);
        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(bob);
        ledger.challenge{value: 2 ether}(eid);
        assertTrue(ledger.getEvent(eid).challenged);
        assertEq(ledger.getEvent(eid).leadingSideAAtChallenge, true);

        vm.prank(alice);
        ledger.stake(eid, true, 20 ether);
        vm.warp(block.timestamp + 1 days + 1);
        ledger.finalizeEvent(eid, true);

        assertTrue(ledger.getEvent(eid).finalized);
        assertTrue(ledger.getEvent(eid).outcome);
        assertEq(bob.balance, 0);
        assertEq(alice.balance, 2 ether);
    }

    function test_challenge_onlyDisadvantage() public {
        vm.deal(alice, 2 ether);
        uint256 eid = ledger.createEvent(0, 1 ether, 1 days, 2 days);
        vm.prank(alice);
        ledger.stake(eid, true, 100 ether);
        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(alice);
        vm.expectRevert("OCP: only disadvantage can challenge");
        ledger.challenge{value: 2 ether}(eid);
    }

    function test_finalize_afterReStakePeriodIfChallenged() public {
        vm.deal(bob, 2 ether);
        uint256 eid = ledger.createEvent(0, 1 ether, 1 days, 2 days);
        vm.prank(alice);
        ledger.stake(eid, true, 100 ether);
        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(bob);
        ledger.challenge{value: 2 ether}(eid);
        uint256 reStakeEnd = ledger.getEvent(eid).reStakePeriodEnd;
        vm.warp(reStakeEnd - 1);
        vm.expectRevert("OCP: re-stake period not ended");
        ledger.finalizeEvent(eid, true);
        vm.warp(reStakeEnd);
        ledger.finalizeEvent(eid, true);
        assertTrue(ledger.getEvent(eid).finalized);
    }

    /// @dev 深度子事件赢家获得难度溢价声誉（depthBonus）
    function test_depthReputationBonus() public {
        uint256 e1 = ledger.createEvent(0, 1 ether, 1 days, 0);
        vm.prank(alice);
        ledger.stake(e1, true, 100 ether);
        vm.warp(block.timestamp + 1 days + 1);
        ledger.finalizeEvent(e1, true);
        uint256 repAfterRoot = ledger.getUserReputation(alice).cumulativeWinningStake;

        uint256 e2 = ledger.createEvent(e1, 1 ether, 1 days, 0);
        vm.prank(alice);
        ledger.stake(e2, true, 100 ether);
        vm.warp(block.timestamp + 1 days + 1);
        ledger.finalizeEvent(e2, true);
        uint256 repAfterDepth1 = ledger.getUserReputation(alice).cumulativeWinningStake;
        assertGt(repAfterDepth1 - repAfterRoot, 100 ether / 4);
    }
}
