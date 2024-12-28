// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
import "../src/apps/options/OptionMarketOTMFE.sol";
import "../src/apps/options/pricing/OptionPricingLinearV2.sol";
import "../src/apps/options/pricing/fees/ClammFeeStrategyV2.sol";

contract DeployOMOTMFE is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address owner = vm.envAddress("OWNER");
        address feeReceiver = vm.envAddress("FEE_RECEIVER");

        address positionManager = 0xC87520C85c56Eb83122ABA145912A5F7a7f927c5;
        address callAsset = 0x039e2fB66102314Ce7b64Ce5Ce3E5183bc94aD38;
        address putAsset = 0x29219dd400f2Bf60E5a23d13Be72B486D4038894;
        address primePool = 0x25f746bB206041Ed8dA6F08Ed1D32454A5856D37;
        uint256 startTime = 1729152000;
        address poolSpotPrice = 0x1A2010e66E65adA65ACcf8c2B60C7b40A155089b;

        vm.startBroadcast(deployerPrivateKey);

        // Deploy OptionPricingLinearV2
        OptionPricingLinearV2 optionPricingLinearV2 = new OptionPricingLinearV2(10_000, 1_000, 10_000_000);

        console.log("OptionPricingLinearV2 deployed at:", address(optionPricingLinearV2));

        uint256[] memory ttls = new uint256[](2);
        uint256[] memory ttlIV = new uint256[](2);
        

        ttls[0] = 86400;
        ttlIV[0] = 75;

        ttls[1] = 86400 * 7;
        ttlIV[1] = 125;

        optionPricingLinearV2.updateIVs(ttls, ttlIV);

        ClammFeeStrategyV2 clammFeeStrategyV2 = new ClammFeeStrategyV2();

        console.log("ClammFeeStrategyV2 deployed at:", address(clammFeeStrategyV2));
        
        // Deploy OptionMarketOTMFE
        OptionMarketOTMFE optionMarket = new OptionMarketOTMFE(
            address(positionManager),
            address(optionPricingLinearV2),
            address(clammFeeStrategyV2),
            address(callAsset),
            address(putAsset),
            address(primePool),
            address(poolSpotPrice),
            startTime
        );

        clammFeeStrategyV2.registerOptionMarket(address(optionMarket), 100000);

        optionMarket.updatePoolApporvals(owner, true, address(primePool), true, 86400, true, 10 minutes);
        optionMarket.updatePoolApporvals(owner, true, address(primePool), true, 86400 * 7, true, 10 minutes);
        
        optionMarket.updatePoolSettings(
            address(feeReceiver),
            address(0),
            address(clammFeeStrategyV2),
            address(optionPricingLinearV2),
            address(poolSpotPrice)
        );

        console.log("OptionMarketOTMFE deployed at:", address(optionMarket));

        vm.stopBroadcast();
    }
}