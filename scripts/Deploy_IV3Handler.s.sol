// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Script.sol";
import "../src/handlers/wagmi-v3/WagmiV3Handler.sol";

contract DeployWagmiV3Handler is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address feeReceiver = vm.envAddress("FEE_RECEIVER");
        address factory = 0x56CFC796bC88C9c7e1b38C2b0aF9B7120B079aef;
        bytes32 poolInitCodeHash = 0x30146866f3a846fe3c636beb2756dbd24cf321bc52c9113c837c21f47470dfeb;

        vm.startBroadcast(deployerPrivateKey);

        WagmiV3Handler wagmiV3Handler = new WagmiV3Handler(feeReceiver, factory, poolInitCodeHash);

        console.log("WagmiV3Handler deployed at:", address(wagmiV3Handler));

        vm.stopBroadcast();
    }
}