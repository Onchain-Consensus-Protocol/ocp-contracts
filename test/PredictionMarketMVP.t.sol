// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import "../src/core/OCPVault.sol";
import "../src/market/PredictionMarket.sol";
import "../src/factory/OCPVaultFactory.sol";
import "../src/interfaces/IOCPVault.sol";
import "../src/interfaces/IPredictionMarket.sol";

contract MockERC20 is ERC20 {
    constructor() ERC20("Mock", "MOCK") {}
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract PredictionMarketMVPTest is Test {
    MockERC20 internal token;
    OCPVaultFactory internal factory;
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);

    function setUp() public {
        token = new MockERC20();
        token.mint(alice, 10_000 ether);
        token.mint(bob, 10_000 ether);
        factory = new OCPVaultFactory();
    }

    function test_createMarket_and_addLiquidity() public {
        uint256 resolutionTime = block.timestamp + 7 days;

        vm.startPrank(alice);
        token.approve(address(factory), type(uint256).max);
        (address vaultAddr, address marketAddr) = factory.createMarket(
            address(token),
            resolutionTime,
            1 days,
            100 ether,
            1000 ether,
            "Test Event",
            "Description"
        );
        vm.stopPrank();

        assertTrue(vaultAddr != address(0));
        assertTrue(marketAddr != address(0));

        PredictionMarket pm = PredictionMarket(marketAddr);
        OCPVault vault = OCPVault(vaultAddr);

        assertEq(pm.yesReserve(), 500 ether);
        assertEq(pm.noReserve(), 500 ether);
        assertEq(pm.poolCollateral(), 1000 ether);
    }

    function test_fullFlow() public {
        uint256 resolutionTime = block.timestamp + 7 days;

        vm.startPrank(alice);
        token.approve(address(factory), type(uint256).max);
        (address vaultAddr, address marketAddr) = factory.createMarket(
            address(token),
            resolutionTime,
            1 days,
            100 ether,
            1000 ether,
            "Test Event",
            "Description"
        );
        vm.stopPrank();

        PredictionMarket pm = PredictionMarket(marketAddr);
        OCPVault vault = OCPVault(vaultAddr);

        // alice 质押并选是方
        vm.startPrank(alice);
        token.approve(address(vault), type(uint256).max);
        vault.stake(IOCPVault.Side.YES, 500 ether);
        vm.stopPrank();

        // bob 质押并选否方
        vm.startPrank(bob);
        token.approve(address(vault), type(uint256).max);
        vault.stake(IOCPVault.Side.NO, 400 ether);
        vm.stopPrank();

        // alice 买 YES
        vm.startPrank(alice);
        token.approve(address(pm), type(uint256).max);
        pm.buyYes(100 ether, 0);
        vm.stopPrank();

        assertGt(pm.yesShares(alice), 0);
        assertGt(vault.totalPrincipal(), 0);

        // 快进到结算时间
        vm.warp(resolutionTime + 1 days + 1);

        // 解析：alice 500 > bob 400，是方胜
        pm.resolve();
        assertTrue(pm.resolved());
        assertEq(uint256(pm.outcome()), uint256(IPredictionMarket.Outcome.YES));

        // 赎回
        uint256 aliceYes = pm.yesShares(alice);
        vm.prank(alice);
        pm.redeem(aliceYes, 0);

        // 提款：赢家 alice 领本金+分红，输家 bob 可领其累计分红（预测市场 fee 按当时在池占比记入，本金已输给赢家）
        uint256 aliceBalBefore = token.balanceOf(alice);
        vm.prank(alice);
        vault.withdraw();
        assertGt(token.balanceOf(alice), aliceBalBefore);

        uint256 bobBalBefore = token.balanceOf(bob);
        vm.prank(bob);
        vault.withdraw();
        assertGe(token.balanceOf(bob), bobBalBefore);
    }
}
