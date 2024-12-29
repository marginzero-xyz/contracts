// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Script.sol";
import {OptionPricingLinearV2} from "../src/apps/options/pricing/OptionPricingLinearV2.sol";
import {OptionMarketOTMFE} from "../src/apps/options/OptionMarketOTMFE.sol";

contract AddNewTTL is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address owner = vm.envAddress("OWNER");
        address primePool = 0x25f746bB206041Ed8dA6F08Ed1D32454A5856D37;
        
        vm.startBroadcast(deployerPrivateKey);

        OptionPricingLinearV2 optionPricingLinearV2 = OptionPricingLinearV2(0x4ec7FB89865D40f3de3A7A72546c316B7d7445D0);
        OptionMarketOTMFE optionMarket = OptionMarketOTMFE(0x2bE4413949868F3211652068069c374A58c9c1A0);

        uint256[] memory ttls = new uint256[](2);
        uint256[] memory ttlIV = new uint256[](2);

        ttls[0] = 900;
        ttlIV[0] = 10;

        optionPricingLinearV2.updateIVs(ttls, ttlIV);

        optionMarket.updatePoolApporvals(owner, true, address(primePool), true, 900, true, 2 minutes);
    
        vm.stopBroadcast();
    }
}
