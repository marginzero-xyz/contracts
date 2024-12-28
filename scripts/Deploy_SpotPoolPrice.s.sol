// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Script.sol";
import "../src/apps/options/pricing/PoolSpotPrice.sol";

contract DeploySpotPoolPrice is Script {
    function run() external {
        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));

        PoolSpotPrice poolSpotPrice = new PoolSpotPrice();

        console.log("PoolSpotPrice deployed at:", address(poolSpotPrice));

        vm.stopBroadcast();
    }
}
