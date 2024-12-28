// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.0 <0.9.0;

import {Script} from "forge-std/Script.sol";
import {OpenSettlement} from "../src/periphery/OpenSettlement.sol";

contract Deploy_OpenSettlement is Script {
    function run() external returns (OpenSettlement) {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        
        // Configuration parameters
        address initialWhitelistedSettler = vm.envAddress("OWNER");
        address feeRecipient = vm.envAddress("FEE_RECEIVER");
        uint256 protocolFee = 0;
        uint256 publicFee = 0;

        vm.startBroadcast(deployerPrivateKey);

        OpenSettlement settlement = new OpenSettlement(
            initialWhitelistedSettler,
            feeRecipient,
            protocolFee,
            publicFee
        );



        vm.stopBroadcast();

        return settlement;
    }
}
