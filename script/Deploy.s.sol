// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Script.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "../src/factory/OCPVaultFactory.sol";

contract MockERC20 is ERC20 {
    constructor() ERC20("OCP Test Token", "OCPT") {}
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract DeployScript is Script {
    function run() external {
        string memory pkStr = vm.envString("PRIVATE_KEY");
        require(bytes(pkStr).length > 0, "Set PRIVATE_KEY in env");
        require(
            keccak256(bytes(pkStr)) !=
                keccak256(bytes("0x_your_base_sepolia_wallet_private_key")),
            "Replace PRIVATE_KEY in solidity/.env with your real wallet private key (64 hex chars, with or without 0x)"
        );
        uint256 deployerPrivateKey;
        if (
            bytes(pkStr).length >= 2 &&
            bytes(pkStr)[0] == "0" &&
            bytes(pkStr)[1] == "x"
        ) {
            deployerPrivateKey = vm.parseUint(pkStr);
        } else {
            deployerPrivateKey = vm.parseUint(
                string(abi.encodePacked("0x", pkStr))
            );
        }
        require(deployerPrivateKey != 0, "Invalid PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        MockERC20 token = new MockERC20();
        address deployer = vm.addr(deployerPrivateKey);
        token.mint(deployer, 1_000_000 * 1e18);

        OCPVaultFactory factory = new OCPVaultFactory();

        vm.stopBroadcast();

        console.log("MockERC20 (deposit token):", address(token));
        console.log("OCPVaultFactory:", address(factory));
    }
}
