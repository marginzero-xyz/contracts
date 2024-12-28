// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Script.sol";
import "../src/PositionManager.sol";

contract DeployPositionManager is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address owner = vm.envAddress("OWNER");

        vm.startBroadcast(deployerPrivateKey);

        PositionManager positionManager = new PositionManager(owner);

        console.log("PositionManager deployed at:", address(positionManager));

        vm.stopBroadcast();
    }
}