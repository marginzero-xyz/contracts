// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.0 <0.9.0;

import {Script} from "forge-std/Script.sol";
import {OpenSettlement} from "../src/periphery/OpenSettlement.sol";
import {OptionMarketOTMFE} from "../src/apps/options/OptionMarketOTMFE.sol";
contract Update_OpenSettlement_Perm is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address openSettlementAddress = 0x7Da345f6c8746d1E3818410846f480De4f17A722;
        address optionsMarket = 0x2bE4413949868F3211652068069c374A58c9c1A0;
        address pool = 0x25f746bB206041Ed8dA6F08Ed1D32454A5856D37;

        vm.startBroadcast(deployerPrivateKey);

        OptionMarketOTMFE(optionsMarket).updatePoolApporvals(
            openSettlementAddress, true, pool, true, 86400, true, 10 minutes
        );
        
        vm.stopBroadcast();
    }
}
