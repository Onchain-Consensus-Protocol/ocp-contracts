// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import "../src/core/PredictionMarketVault.sol";
import "../src/market/PredictionMarket.sol";
import "../src/factory/PredictionMarketVaultFactory.sol";

contract MockERC20 is ERC20 {
    constructor() ERC20("Mock", "MOCK") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

contract PredictionMarketMVPTest is Test {
    MockERC20 internal token;
    PredictionMarketVaultFactory internal factory;
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);

    function setUp() public {
        token = new MockERC20();
        token.mint(alice, 10_000 ether);
        token.mint(bob, 10_000 ether);
        factory = new PredictionMarketVaultFactory();
    }

    function test_createMarket_and_addLiquidity() public {
        uint256 resolutionTime = block.timestamp + 7 days;

        vm.startPrank(alice);
        token.approve(address(factory), type(uint256).max);
        (address vaultAddr, address marketAddr) = factory.createMarket(
            address(token),
            resolutionTime,
            1000 ether  // initial liquidity
        );
        vm.stopPrank();

        assertTrue(vaultAddr != address(0));
        assertTrue(marketAddr != address(0));

        PredictionMarket pm = PredictionMarket(marketAddr);
        PredictionMarketVault vault = PredictionMarketVault(vaultAddr);

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
            1000 ether
        );
        vm.stopPrank();

        PredictionMarket pm = PredictionMarket(marketAddr);
        PredictionMarketVault vault = PredictionMarketVault(vaultAddr);

        // alice 存款金库并投票（是方）
        vm.startPrank(alice);
        token.approve(address(vault), type(uint256).max);
        vault.deposit(500 ether);
        vault.vote();
        vm.stopPrank();

        // bob 存款金库不投票（否方）
        vm.startPrank(bob);
        token.approve(address(vault), type(uint256).max);
        vault.deposit(400 ether);
        vm.stopPrank();

        // alice 买 YES
        vm.prank(alice);
        token.approve(address(pm), type(uint256).max);
        pm.buyYes(100 ether, 0);

        assertGt(pm.yesShares(alice), 0);
        assertGt(vault.totalPrincipal(), 0);

        // 快进到结算时间
        vm.warp(resolutionTime + 1);

        // 解析：alice 500 > bob 400，是方胜
        pm.resolve();
        assertTrue(pm.resolved());
        assertTrue(pm.outcome());  // 是方胜

        // 赎回
        uint256 aliceYes = pm.yesShares(alice);
        vm.prank(alice);
        pm.redeem(aliceYes, 0);

        // 提款
        vm.prank(alice);
        vault.withdraw();
        vm.prank(bob);
        vault.withdraw();
    }
}
