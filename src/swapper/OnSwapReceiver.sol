// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";

/// @title OnSwapReceiver
/// @author 0xcarrot
/// @notice A contract that implements the ISwapper interface to receive and process token swaps
/// @dev This contract is Ownable and uses SafeERC20 for token transfers
contract OnSwapReceiver is Ownable {
    using SafeERC20 for IERC20;

    /// @notice Mapping to track whitelisted swappers
    /// @dev The key is the address of the swapper, and the value is a boolean indicating if it is whitelisted
    /// @dev Only whitelisted swappers can call the onSwapReceived function
    /// @dev This mapping is used to restrict access to the onSwapReceived function
    mapping(address => bool) public whitelistedSwappers;

    /// @notice Thrown when the swap operation fails
    /// @param data The error data returned by the failed swap
    error OnSwapReceiver__onSwapReceivedFail(bytes data);

    /// @notice Thrown when the amount of tokens received is less than the minimum expected
    error OnSwapReceiver__InsufficientAmountOut();

    /// @notice Thrown when the expected amount of input tokens is not received
    error OnSwapReceiver__AmountInNotReceived();

    /// @notice Thrown when a zero address is provided for a token or recipient
    error OnSwapReceiver__ZeroAddress();

    /// @notice Thrown when the swapper is not whitelisted
    error OnSwapReceiver__InvalidSwapper();

    /// @notice Emitted when a swap is successfully received and processed
    /// @param _amountIn The amount of input tokens
    /// @param _amountOut The amount of output tokens
    /// @param _tokenIn The address of the input token
    /// @param _tokenOut The address of the output token
    /// @param _swapper The address of the swapper contract used
    event OnSwapReceived(uint256 _amountIn, uint256 _amountOut, address _tokenIn, address _tokenOut, address _swapper);

    /// @notice Emitted when a swapper is whitelisted or de-whitelisted
    /// @param _address The address of the swapper
    /// @param _isWhitelisted The new whitelist status
    event SwapperWhitelisted(address _address, bool _isWhitelisted);

    /// @notice Constructs the OnSwapReceiver contract
    constructor(address _owner) Ownable(_owner) {}

    /// @notice Receives and processes a token swap
    /// @dev This function is called to execute a swap using the provided swap data
    /// @param _tokenIn The address of the input token
    /// @param _tokenOut The address of the output token
    /// @param _amountIn The amount of input tokens to swap
    /// @param _swapData The encoded swap data
    /// @return amountOut The amount of output tokens received
    function onSwapReceived(address _tokenIn, address _tokenOut, uint256 _amountIn, bytes memory _swapData)
        external
        returns (uint256 amountOut)
    {
        IERC20 tokenIn = IERC20(_tokenIn);
        IERC20 tokenOut = IERC20(_tokenOut);

        bytes memory swapData;
        address to;
        uint256 minAmountout;

        (minAmountout, to, swapData) = abi.decode(_swapData, (uint256, address, bytes));

        if (!whitelistedSwappers[to]) {
            revert OnSwapReceiver__InvalidSwapper();
        }

        if (_tokenIn == address(0) || _tokenOut == address(0) || to == address(0)) {
            revert OnSwapReceiver__ZeroAddress();
        }

        if (_amountIn > tokenIn.balanceOf((address(this)))) {
            revert OnSwapReceiver__AmountInNotReceived();
        }

        tokenIn.safeIncreaseAllowance(to, _amountIn);

        /**
         * @dev
         * receiver: address(this)
         * sender: address(this)
         */
        (bool success, bytes memory data) = to.call(swapData);

        if (!success) {
            revert OnSwapReceiver__onSwapReceivedFail(data);
        }

        amountOut = tokenOut.balanceOf(address(this));

        if (amountOut < minAmountout) {
            revert OnSwapReceiver__InsufficientAmountOut();
        }

        tokenOut.transfer(msg.sender, amountOut);

        emit OnSwapReceived(_amountIn, amountOut, _tokenIn, _tokenOut, to);
    }

    /// @notice Updates the whitelist status of a swapper
    /// @dev Can only be called by the owner of the contract
    /// @param _address The address of the swapper to update
    /// @param _isWhitelisted The new whitelist status (true for whitelisted, false for de-whitelisted)
    function updateSwapperWhitelist(address _address, bool _isWhitelisted) external onlyOwner {
        whitelistedSwappers[_address] = _isWhitelisted;
        emit SwapperWhitelisted(_address, _isWhitelisted);
    }
}
