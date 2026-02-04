// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Script.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "../src/factory/PredictionMarketVaultFactory.sol";

contract MockERC20 is ERC20 {
    constructor() ERC20("OCP Test Token", "OCPT") {}
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract DeployScript is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envOr("PRIVATE_KEY", uint256(0));
        require(deployerPrivateKey != 0, "Set PRIVATE_KEY in env");
        vm.startBroadcast(deployerPrivateKey);

        MockERC20 token = new MockERC20();
        token.mint(msg.sender, 1_000_000 * 1e18);

        PredictionMarketVaultFactory factory = new PredictionMarketVaultFactory();

        vm.stopBroadcast();

        console.log("MockERC20 (deposit token):", address(token));
        console.log("PredictionMarketVaultFactory:", address(factory));
    }
}
