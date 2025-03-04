// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";


interface IShadowLiquidityClaimer {
    function shadow_liquidity_received(
        address token0,
        address token1,
        uint256 amount0,
        uint256 amount1,
        uint128 liqToRemove
    ) external;
}

contract MockDegenExpressHandler {

    address public token0;
    address public token1;

    constructor(address _token0, address _token1) {
        token0 = _token0;
        token1 = _token1;
    }

    function shadowlp_claim(address token) external {
        IERC20(token0).transfer(msg.sender, IERC20(token0).balanceOf(address(this)));
        IERC20(token1).transfer(msg.sender, IERC20(token1).balanceOf(address(this)));

        IShadowLiquidityClaimer(msg.sender).shadow_liquidity_received(token0, token1, IERC20(token0).balanceOf(address(this)), IERC20(token1).balanceOf(address(this)), 0);
    }
}