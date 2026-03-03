// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import "../src/core/OCPVault.sol";
import "../src/factory/OCPVaultFactory.sol";
import "../src/interfaces/IOCPVault.sol";

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
        factory = new OCPVaultFactory(
            address(0x1),   // mock vrfCoordinator
            0,              // subscriptionId
            bytes32(0),     // keyHash
            200000,         // callbackGasLimit
            3               // requestConfirmations
        );
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
        // 仅推金库版本：工厂不再创建预测市场
        assertEq(marketAddr, address(0));
        OCPVault vault = OCPVault(vaultAddr);
        assertEq(vault.linkedMarket(), address(0));
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
            0,
            "Test Event",
            "Description"
        );
        vm.stopPrank();

        assertEq(marketAddr, address(0));
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

        assertGt(vault.totalPrincipal(), 0);

        // 快进到冷静期结束并终局：alice 500 > bob 400，是方胜
        vm.warp(resolutionTime + 1 days + 1);
        vault.finalize();
        assertTrue(vault.resolved());
        assertEq(uint256(vault.outcome()), uint256(IOCPVault.Outcome.YES));

        // 提款：赢家 alice 领本金，输家 bob 无本金返还（无 donate 时应为 0）
        uint256 aliceBalBefore = token.balanceOf(alice);
        vm.prank(alice);
        vault.withdraw();
        assertGt(token.balanceOf(alice), aliceBalBefore);

        uint256 bobBalBefore = token.balanceOf(bob);
        vm.prank(bob);
        vault.withdraw();
        assertEq(token.balanceOf(bob), bobBalBefore);
    }
}
