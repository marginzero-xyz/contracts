// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Script.sol";
import "../src/handlers/hooks/BoundedTTLHook_0Day.sol";
import "../src/handlers/hooks/BoundedTTLHook_1Week.sol";
import "../src/handlers/wagmi-v3/WagmiV3Handler.sol";
import "../src/interfaces/IHandler.sol";

contract RegisterHooks is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address wagmiV3HandlerAddress = 0xE7E225194e81729b27e8FA5c1ebD801D502c016b;
        address optionsMarketAddress = 0x2bE4413949868F3211652068069c374A58c9c1A0;
        

        vm.startBroadcast(deployerPrivateKey);

        // Deploy 0day hook
        BoundedTTLHook_0Day boundedTTLHook_0Day = BoundedTTLHook_0Day(0x654118756a8A94c79aeA82104C7EC90659d77613);

        // Create HookPermInfo struct
        V3BaseHandler.HookPermInfo memory hookPermInfo = IHandler.HookPermInfo({
            onMint: false,
            onBurn: false,
            onUse: true,
            onUnuse: false,
            onDonate: false,
            allowSplit: true
        });

        // Register the BoundedTTLHook_0Day with UniswapV3Handler
        WagmiV3Handler(wagmiV3HandlerAddress).registerHook(address(boundedTTLHook_0Day), hookPermInfo);

        boundedTTLHook_0Day.updateWhitelistedAppsStatus(optionsMarketAddress, true);

        // Deploy 1week hook
        BoundedTTLHook_1Week boundedTTLHook_1Week = BoundedTTLHook_1Week(0xDb0Da9A929aC30E123695EEa8E44B1e167213dCb);

        // Register the BoundedTTLHook_1Week with UniswapV3Handler
        WagmiV3Handler(wagmiV3HandlerAddress).registerHook(address(boundedTTLHook_1Week), hookPermInfo);

        boundedTTLHook_1Week.updateWhitelistedAppsStatus(optionsMarketAddress, true);

        vm.stopBroadcast();
    }
}