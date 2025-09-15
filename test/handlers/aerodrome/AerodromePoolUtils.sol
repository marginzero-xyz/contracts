// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";

import {ICLFactory} from "../../../src/handlers/aerodrome/ICLFactory.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {LiquidityAmounts} from "v3-periphery/libraries/LiquidityAmounts.sol";
import {AerodromeLiquidityManagement} from "./AerodromeLiquidityManagement.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";
import {ICLPool} from "../../../src/handlers/aerodrome/ICLPool.sol";

contract AerodromePoolUtils is Test {
    ICLFactory public factory;

    constructor(address _factory) {
        factory = ICLFactory(_factory);
    }

    function deployAndInitializePool(MockERC20 tokenA, MockERC20 tokenB, int24 tickSpacing, uint160 sqrtPriceX96)
        external
        returns (address pool)
    {
        // Create a Uniswap V3 pool for the tokenA/tokenB pair with the specified fee
        pool = factory.createPool(address(tokenA), address(tokenB), tickSpacing, sqrtPriceX96);
    }

    struct AddLiquidityStruct {
        address liquidityManager;
        address user;
        address pool;
        int24 desiredTickLower;
        int24 desiredTickUpper;
        uint256 desiredAmount0;
        uint256 desiredAmount1;
        bool requireMint;
    }

    function addLiquidity(AddLiquidityStruct memory _params) public returns (uint256 liquidity) {
        if (_params.requireMint) {
            if (_params.desiredAmount0 > 0) {
                MockERC20(ICLPool(_params.pool).token0()).mint(_params.user, _params.desiredAmount0);
            }
            if (_params.desiredAmount1 > 0) {
                MockERC20(ICLPool(_params.pool).token1()).mint(_params.user, _params.desiredAmount1);
            }
        }

        vm.startPrank(_params.user);

        MockERC20(ICLPool(_params.pool).token0()).approve(address(_params.liquidityManager), type(uint256).max);
        MockERC20(ICLPool(_params.pool).token1()).approve(address(_params.liquidityManager), type(uint256).max);

        (liquidity,,,) = AerodromeLiquidityManagement(_params.liquidityManager).addLiquidity(
            AerodromeLiquidityManagement.AddLiquidityParams({
                token0: ICLPool(_params.pool).token0(),
                token1: ICLPool(_params.pool).token1(),
                tickSpacing: ICLPool(_params.pool).tickSpacing(),
                recipient: _params.user,
                tickLower: _params.desiredTickLower,
                tickUpper: _params.desiredTickUpper,
                amount0Desired: _params.desiredAmount0,
                amount1Desired: _params.desiredAmount1,
                amount0Min: 0,
                amount1Min: 0
            })
        );

        vm.stopPrank();
    }
}
