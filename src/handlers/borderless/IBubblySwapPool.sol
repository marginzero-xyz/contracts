// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {IUniswapV3Pool} from "../kodiak-v3/IUniswapV3Pool.sol";

/// @title The interface for a PancakeSwap V3 Pool
/// @notice A PancakeSwap pool facilitates swapping and automated market making between any two assets that strictly conform
/// to the ERC20 specification
/// @dev The pool interface is broken up into many smaller pieces
interface IBubblySwapPool is IUniswapV3Pool {}
