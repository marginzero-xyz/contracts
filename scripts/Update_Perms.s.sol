// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Script.sol";
import "../src/handlers/wagmi-v3/WagmiV3Handler.sol";
import "../src/PositionManager.sol";
import "../src/apps/options/OptionMarketOTMFE.sol";

contract UpdatePerms is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address owner = vm.envAddress("OWNER");
        
        WagmiV3Handler handler = WagmiV3Handler(0xE7E225194e81729b27e8FA5c1ebD801D502c016b);
        PositionManager positionManager = PositionManager(0xC87520C85c56Eb83122ABA145912A5F7a7f927c5);
        OptionMarketOTMFE optionMarketOTMFE = OptionMarketOTMFE(0x2bE4413949868F3211652068069c374A58c9c1A0);

        vm.startBroadcast(deployerPrivateKey);
        positionManager.updateWhitelistHandler(address(handler), true);

        handler.updateHandlerSettings(address(positionManager), true, address(0), 6 hours, address(0));

        positionManager.updateWhitelistHandlerWithApp(address(handler), address(optionMarketOTMFE), true);
        vm.stopBroadcast();
    }
}