// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import "../src/core/JobGuaranteeVault.sol";
import "../src/factory/JobGuaranteeVaultFactory.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev 最简单的 MockUSDC，方便 mint
contract MockUSDC is ERC20 {
    constructor() ERC20("Mock USDC", "USDC") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

contract JobGuaranteeVaultTest is Test {
    MockUSDC usdc;
    JobGuaranteeVaultFactory factory;

    address buyer     = address(0xBBBB);
    address seller    = address(0x5555);
    address evaluator = address(0xEEEE);
    address anyone    = address(0xAAAA);

    uint256 constant GUARANTEE = 100e6;     // 100 USDC
    uint256 deadline;
    uint256 evalWindow = 3600;              // 1 hour

    string constant JOB_ID = "acp-job-42";

    function setUp() public {
        usdc    = new MockUSDC();
        factory = new JobGuaranteeVaultFactory();

        // 设置 deadline = now + 1 day
        deadline = block.timestamp + 1 days;

        // 给 buyer / seller / evaluator 各 1000 USDC
        // approve 在各测试的 _approveVault() helper 里按需设置
        usdc.mint(buyer,     1000e6);
        usdc.mint(seller,    1000e6);
        usdc.mint(evaluator, 1000e6);
    }

    // ─── Helper ──────────────────────────────────────────────

    function _deployVault() internal returns (JobGuaranteeVault v) {
        address addr = factory.create(
            buyer,
            seller,
            evaluator,
            address(usdc),
            GUARANTEE,
            deadline,
            evalWindow,
            JOB_ID
        );
        v = JobGuaranteeVault(addr);
    }

    function _approveVault(address user, address vault) internal {
        vm.prank(user);
        usdc.approve(vault, type(uint256).max);
    }

    function _bothStake(JobGuaranteeVault v) internal {
        _approveVault(buyer,  address(v));
        _approveVault(seller, address(v));
        vm.prank(buyer);  v.stakeAsBuyer();
        vm.prank(seller); v.stakeAsSeller();
    }

    // ─── Factory tests ───────────────────────────────────────

    function test_factory_create() public {
        address addr = factory.create(
            buyer, seller, evaluator,
            address(usdc), GUARANTEE, deadline, evalWindow, JOB_ID
        );
        assertEq(factory.vaultCount(), 1);
        assertEq(factory.vaultByJobId(JOB_ID), addr);
        assertTrue(factory.isVault(addr));
    }

    function test_factory_duplicate_jobId_reverts() public {
        factory.create(buyer, seller, evaluator, address(usdc), GUARANTEE, deadline, evalWindow, JOB_ID);
        vm.expectRevert("Job already has a vault");
        factory.create(buyer, seller, evaluator, address(usdc), GUARANTEE, deadline, evalWindow, JOB_ID);
    }

    // ─── Staking tests ───────────────────────────────────────

    function test_stakeAsBuyer_transitions_to_active_when_both_staked() public {
        JobGuaranteeVault v = _deployVault();
        _approveVault(buyer,  address(v));
        _approveVault(seller, address(v));

        vm.prank(buyer);
        v.stakeAsBuyer();
        assertEq(uint256(v.phase()), uint256(JobGuaranteeVault.Phase.INIT)); // seller not yet

        vm.prank(seller);
        v.stakeAsSeller();
        assertEq(uint256(v.phase()), uint256(JobGuaranteeVault.Phase.ACTIVE)); // both done
    }

    function test_stake_after_deadline_reverts() public {
        JobGuaranteeVault v = _deployVault();
        _approveVault(buyer, address(v));

        vm.warp(deadline + 1);
        vm.expectRevert("Stake period over");
        vm.prank(buyer);
        v.stakeAsBuyer();
    }

    function test_buyer_cannot_stake_twice() public {
        JobGuaranteeVault v = _deployVault();
        _approveVault(buyer, address(v));

        vm.prank(buyer);
        v.stakeAsBuyer();

        vm.prank(buyer);
        vm.expectRevert("Buyer already staked");
        v.stakeAsBuyer();
    }

    function test_wrong_role_reverts() public {
        JobGuaranteeVault v = _deployVault();
        _approveVault(anyone, address(v));

        vm.prank(anyone);
        vm.expectRevert("Not buyer");
        v.stakeAsBuyer();
    }

    // ─── Adjudicate tests ────────────────────────────────────

    function test_adjudicate_service_completed() public {
        JobGuaranteeVault v = _deployVault();
        _bothStake(v);

        // Warp to after deadline (eval window opens)
        vm.warp(deadline + 1);

        vm.prank(evaluator);
        v.adjudicate(true); // service completed

        assertEq(uint256(v.phase()), uint256(JobGuaranteeVault.Phase.JUDGED));
        assertTrue(v.judged());
        assertTrue(v.evalVotedYes());
    }

    function test_adjudicate_seller_defaulted() public {
        JobGuaranteeVault v = _deployVault();
        _bothStake(v);

        vm.warp(deadline + 1);
        vm.prank(evaluator);
        v.adjudicate(false); // seller defaulted

        assertFalse(v.evalVotedYes());
    }

    function test_adjudicate_before_deadline_reverts() public {
        JobGuaranteeVault v = _deployVault();
        _bothStake(v);

        vm.prank(evaluator);
        vm.expectRevert("Job deadline not reached");
        v.adjudicate(true);
    }

    function test_adjudicate_after_eval_window_reverts() public {
        JobGuaranteeVault v = _deployVault();
        _bothStake(v);

        vm.warp(deadline + evalWindow + 1);
        vm.prank(evaluator);
        vm.expectRevert("Eval window ended");
        v.adjudicate(true);
    }

    function test_adjudicate_on_init_vault_reverts() public {
        JobGuaranteeVault v = _deployVault();
        // Only buyer staked → still INIT
        _approveVault(buyer, address(v));
        vm.prank(buyer); v.stakeAsBuyer();

        vm.warp(deadline + 1);
        vm.prank(evaluator);
        vm.expectRevert("Vault not ACTIVE");
        v.adjudicate(true);
    }

    // ─── stakeAsEvaluator tests ──────────────────────────────

    function test_stakeAsEvaluator_economic_model() public {
        JobGuaranteeVault v = _deployVault();
        _bothStake(v);
        _approveVault(evaluator, address(v));

        vm.warp(deadline + 1);
        vm.prank(evaluator);
        v.stakeAsEvaluator(true);

        uint256 expectedEvalStake = GUARANTEE / 100; // 1%
        assertEq(v.evalStake(), expectedEvalStake);
        assertTrue(v.judged());
        assertEq(uint256(v.phase()), uint256(JobGuaranteeVault.Phase.JUDGED));
    }

    // ─── Finalize tests ──────────────────────────────────────

    function test_finalize_after_adjudicate() public {
        JobGuaranteeVault v = _deployVault();
        _bothStake(v);

        vm.warp(deadline + 1);
        vm.prank(evaluator); v.adjudicate(true);

        vm.prank(anyone);
        v.finalize();

        assertEq(uint256(v.outcome()), uint256(JobGuaranteeVault.Outcome.SERVICE_COMPLETED));
        assertEq(uint256(v.phase()),   uint256(JobGuaranteeVault.Phase.FINALIZED));
    }

    function test_finalize_timeout_refund() public {
        JobGuaranteeVault v = _deployVault();
        _bothStake(v);

        // Warp past evalWindow without any adjudication
        vm.warp(deadline + evalWindow + 1);

        vm.prank(anyone);
        v.finalize();

        assertEq(uint256(v.outcome()), uint256(JobGuaranteeVault.Outcome.REFUND));
    }

    function test_finalize_before_conditions_reverts() public {
        JobGuaranteeVault v = _deployVault();
        _bothStake(v);

        // Right in the middle of eval window — not yet timed out, not yet judged
        vm.warp(deadline + evalWindow / 2);

        vm.expectRevert("Cannot finalize yet");
        vm.prank(anyone);
        v.finalize();
    }

    function test_finalize_not_active_timeout_refund() public {
        // Only buyer staked, seller never showed up → timeout → REFUND
        JobGuaranteeVault v = _deployVault();
        _approveVault(buyer, address(v));
        vm.prank(buyer); v.stakeAsBuyer();

        vm.warp(deadline + evalWindow + 1);
        vm.prank(anyone);
        v.finalize();

        assertEq(uint256(v.outcome()), uint256(JobGuaranteeVault.Outcome.REFUND));
    }

    // ─── Withdraw tests ──────────────────────────────────────

    function test_withdraw_service_completed_seller_wins() public {
        // B=100, evalStake=1, evalVotedYes=true
        // YES pool = 100 + 1 = 101, total = 201
        // Seller payout = 100/101 * 201 ≈ 199.01 (integer: 100*201/101 = 199)
        // Evaluator payout = 1/101 * 201 = 1 (integer truncation: 1*201/101 = 1... remainder)
        // Buyer payout = 0

        JobGuaranteeVault v = _deployVault();
        _bothStake(v);
        _approveVault(evaluator, address(v));

        vm.warp(deadline + 1);
        vm.prank(evaluator); v.stakeAsEvaluator(true); // voted YES

        vm.prank(anyone); v.finalize();

        uint256 evalStakeAmount = GUARANTEE / 100; // 1e6
        uint256 totalPool  = GUARANTEE * 2 + evalStakeAmount;
        uint256 yesPool    = GUARANTEE + evalStakeAmount;

        // seller withdraw
        uint256 sellerBefore = usdc.balanceOf(seller);
        vm.prank(seller); v.withdraw();
        uint256 sellerGain = usdc.balanceOf(seller) - sellerBefore;
        assertEq(sellerGain, GUARANTEE * totalPool / yesPool, "Seller payout mismatch");

        // evaluator withdraw
        uint256 evalBefore = usdc.balanceOf(evaluator);
        vm.prank(evaluator); v.withdraw();
        uint256 evalGain = usdc.balanceOf(evaluator) - evalBefore;
        assertEq(evalGain, evalStakeAmount * totalPool / yesPool, "Evaluator payout mismatch");

        // buyer gets 0
        assertEq(v.previewPayout(buyer), 0, "Buyer should get 0");
    }

    function test_withdraw_seller_defaulted_buyer_wins() public {
        // Evaluator votes NO → NO wins
        // Buyer payout = 100/101 * 201 USDC (≈199)
        JobGuaranteeVault v = _deployVault();
        _bothStake(v);
        _approveVault(evaluator, address(v));

        vm.warp(deadline + 1);
        vm.prank(evaluator); v.stakeAsEvaluator(false); // voted NO

        vm.prank(anyone); v.finalize();

        uint256 evalStakeAmount = GUARANTEE / 100;
        uint256 totalPool = GUARANTEE * 2 + evalStakeAmount;
        uint256 noPool    = GUARANTEE + evalStakeAmount;

        uint256 buyerBefore = usdc.balanceOf(buyer);
        vm.prank(buyer); v.withdraw();
        uint256 buyerGain = usdc.balanceOf(buyer) - buyerBefore;
        assertEq(buyerGain, GUARANTEE * totalPool / noPool, "Buyer payout mismatch");

        // seller gets 0 (slashed)
        assertEq(v.previewPayout(seller), 0, "Seller should get 0");
    }

    function test_withdraw_adjudicate_no_eval_stake() public {
        // adjudicate (no evalStake) → SERVICE_COMPLETED
        // Seller gets all 200 USDC, buyer gets 0
        JobGuaranteeVault v = _deployVault();
        _bothStake(v);

        vm.warp(deadline + 1);
        vm.prank(evaluator); v.adjudicate(true);
        vm.prank(anyone); v.finalize();

        // totalPool=200, yesPool=100 (only sellerStake, evalStake=0)
        // seller gets 100/100 * 200 = 200
        uint256 totalPool = GUARANTEE * 2;

        uint256 sellerBefore = usdc.balanceOf(seller);
        vm.prank(seller); v.withdraw();
        assertEq(usdc.balanceOf(seller) - sellerBefore, totalPool, "Seller should take all");
    }

    function test_withdraw_refund_both_get_back_stake() public {
        JobGuaranteeVault v = _deployVault();
        _bothStake(v);

        vm.warp(deadline + evalWindow + 1);
        vm.prank(anyone); v.finalize();

        uint256 buyerBefore  = usdc.balanceOf(buyer);
        uint256 sellerBefore = usdc.balanceOf(seller);

        vm.prank(buyer);  v.withdraw();
        vm.prank(seller); v.withdraw();

        assertEq(usdc.balanceOf(buyer)  - buyerBefore,  GUARANTEE, "Buyer refund wrong");
        assertEq(usdc.balanceOf(seller) - sellerBefore, GUARANTEE, "Seller refund wrong");
    }

    function test_withdraw_twice_reverts() public {
        JobGuaranteeVault v = _deployVault();
        _bothStake(v);

        vm.warp(deadline + evalWindow + 1);
        vm.prank(anyone); v.finalize();

        vm.prank(buyer); v.withdraw();
        vm.expectRevert("Nothing to withdraw");
        vm.prank(buyer); v.withdraw();
    }

    function test_withdraw_before_finalize_reverts() public {
        JobGuaranteeVault v = _deployVault();
        _bothStake(v);

        vm.expectRevert("Not finalized");
        vm.prank(buyer); v.withdraw();
    }

    // ─── No dust left in contract after full withdrawal ──────

    function test_no_dust_after_full_withdrawal() public {
        // With evalStake, integer division may leave 1-2 wei dust — that's expected
        // and the last withdrawer gets it via the `balance` fallback capping.
        // This test verifies the contract balance is 0 (or 1 wei dust) after all withdraw.
        JobGuaranteeVault v = _deployVault();
        _bothStake(v);
        _approveVault(evaluator, address(v));

        vm.warp(deadline + 1);
        vm.prank(evaluator); v.stakeAsEvaluator(true);
        vm.prank(anyone); v.finalize();

        vm.prank(seller);    v.withdraw();
        vm.prank(evaluator); v.withdraw();

        uint256 afterAll = usdc.balanceOf(address(v));
        assertLe(afterAll, 2, "Contract should have at most 2 wei dust");
    }
}
