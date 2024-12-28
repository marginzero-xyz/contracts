// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Script.sol";
import "../src/handlers/hooks/BoundedTTLHook_0Day.sol";
import "../src/handlers/hooks/BoundedTTLHook_1Week.sol";

contract DeployHooks is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address wagmiV3HandlerAddress = 0xE7E225194e81729b27e8FA5c1ebD801D502c016b;
        address optionsMarketAddress = 0x2bE4413949868F3211652068069c374A58c9c1A0;

        vm.startBroadcast(deployerPrivateKey);

        // Deploy 0day hook
        BoundedTTLHook_0Day boundedTTLHook_0Day = new BoundedTTLHook_0Day();
        console.log("BoundedTTLHook_0Day deployed at:", address(boundedTTLHook_0Day));

        // Deploy 1week hook
        BoundedTTLHook_1Week boundedTTLHook_1Week = new BoundedTTLHook_1Week();
        console.log("BoundedTTLHook_1Week deployed at:", address(boundedTTLHook_1Week));

        vm.stopBroadcast();
    }
}