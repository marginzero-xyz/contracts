// // SPDX-License-Identifier: MIT
// pragma solidity ^0.8.0;

// import "forge-std/Script.sol";
// import "../src/PositionManager.sol";
// import "../src/apps/options/OptionMarketOTMFE.sol";
// import "../src/apps/options/pricing/PoolSpotPrice.sol";
// import "../src/apps/options/pricing/OptionPricingLinearv2.sol";
// import "../src/apps/options/pricing/fees/ClammFeeStrategyV2.sol";
// import "../src/periphery/firewalls/ExerciseOptionFirewall.sol";
// import "../src/periphery/firewalls/MintOptionFirewall.sol";
// import "../src/periphery/OpenSettlement.sol";
// import "../src/periphery/routers/AddLiquidityRouter.sol";
// import {UniswapV3Handler} from "../src/handlers/uniswap-v3/UniswapV3Handler.sol";
// import {ShadowV3Handler} from "../src/handlers/shadow-v3/ShadowV3Handler.sol";
// import {V3BaseHandler} from "../src/handlers/V3BaseHandler.sol";

// uint256 salt;

// contract Deploy is Script {
//     address owner;
//     PositionManager positionManager;

//     function run() public {
//         // if (owner == address(0)) {
//         //     revert("owner not set");
//         // }

//         vm.startBroadcast();

//         // deployPositionManager();
//         vm.stopBroadcast();
//     }

//     // function deployPositionManager() internal returns (PositionManager) {
//     //     return new PositionManager{salt: salt}(owner);
//     // }

//     // function positionManager__whitelistHandler(
//     //     address _handler,
//     //     bool _as
//     // ) internal {
//     //     if (address(positionManager) == address(0)) {
//     //         revert("Position manager not set");
//     //     }

//     //     positionManager.updateWhitelistHandler(_handler, _as);
//     // }

//     // function handler__updateSettings(V3BaseHandler handler, ) internal {

//     // }
// }
