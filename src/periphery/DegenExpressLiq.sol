// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.0 <0.9.0;

import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

import {IERC6909} from "../interfaces/IERC6909.sol";
import {IPositionManager} from "../interfaces/IPositionManager.sol";
import {IHandler} from "../interfaces/IHandler.sol";
import {Multicall} from "openzeppelin-contracts/contracts/utils/Multicall.sol";

interface IShadowLPHandler {
    function shadowlp_claim(address token) external;
}

/// @title DegenExpressLiq
/// @author 0xcarrot
/// @notice Facilitates liquidity management and token operations for Degen Express protocol
/// @dev Implements whitelisted admin controls and multicall functionality
contract DegenExpressLiq is Ownable, Multicall {
    // errors
    error NotWhitelistedAdmin();

    // events
    event ShadowLiquidityReceived(address token0, address token1, uint256 amount0, uint256 amount1, uint128 liqToRemove);

    // state
    address public immutable positionManager;
    mapping(address => bool) public whitelistedAdmins;

    /// @notice Ensures the caller is a whitelisted admin
    modifier onlyWhitelistedAdmin() {
        if (!whitelistedAdmins[msg.sender]) revert NotWhitelistedAdmin();
        _;
    }

    /// @notice Constructs the DegenExpressLiq contract
    /// @param _owner The address that will own the contract
    /// @param _positionManager The address of the position manager contract
    constructor(address _owner, address _positionManager) Ownable(_owner) {
        positionManager = _positionManager;
    }

    /// @notice Claims shadow LP tokens
    /// @param shadowLPHandler The address of the shadow LP handler contract
    /// @param token The token address to claim
    function claimShadowLP(address shadowLPHandler, address token) external onlyWhitelistedAdmin {
        IShadowLPHandler(shadowLPHandler).shadowlp_claim(token);
    }

    /// @notice Callback function for receiving shadow liquidity
    /// @param token0 The address of the first token
    /// @param token1 The address of the second token
    /// @param amount0 The amount of the first token
    /// @param amount1 The amount of the second token
    /// @param liqToRemove The amount of liquidity to remove
    function shadow_liquidity_received(
        address token0,
        address token1,
        uint256 amount0,
        uint256 amount1,
        uint128 liqToRemove
    ) external {
        emit ShadowLiquidityReceived(token0, token1, amount0, amount1, liqToRemove);
    }

    /// @notice Adds liquidity to a position
    /// @param handler The handler contract to use
    /// @param data The encoded data for minting the position
    /// @return The shares minted
    function addLiquidity(IHandler handler, bytes calldata data) external onlyWhitelistedAdmin returns (uint256) {
        return IPositionManager(positionManager).mintPosition(handler, data);
    }

    /// @notice Removes liquidity from a position
    /// @param handler The handler contract to use
    /// @param data The encoded data for burning the position
    /// @return The shares burned
    function removeLiquidity(IHandler handler, bytes calldata data) external onlyWhitelistedAdmin returns (uint256) {
        return IPositionManager(positionManager).burnPosition(handler, data);
    }

    /// @notice Sweeps ERC20 tokens from the contract
    /// @param token The token address to sweep
    /// @param to The recipient address
    /// @param amount The amount to sweep
    function sweepTokens(address token, address to, uint256 amount) external onlyOwner {
        IERC20(token).transfer(to, amount);
    }

    /// @notice Sweeps MZLP tokens from the contract
    /// @param handler The handler contract address
    /// @param to The recipient address
    /// @param tokenId The ID of the MZLP token
    /// @param amount The amount to sweep
    function sweepMZLP(address handler, address to, uint256 tokenId, uint256 amount) external onlyOwner {
        IERC6909(address(handler)).transfer(to, tokenId, amount);
    }

    /// @notice Sets ERC20 token approvals
    /// @param token The token address to approve
    /// @param spender The address to approve spending for
    /// @param amount The amount to approve
    function setApprovals(address token, address spender, uint256 amount) external onlyOwner {
        IERC20(token).approve(spender, amount);
    }

    /// @notice Sets MZLP token approvals
    /// @param handler The handler contract address
    /// @param spender The address to approve spending for
    /// @param tokenId The ID of the MZLP token
    /// @param amount The amount to approve
    function setMZLPApprovals(address handler, address spender, uint256 tokenId, uint256 amount) external onlyOwner {
        IERC6909(address(handler)).approve(spender, tokenId, amount);
    }

    /// @notice Updates the whitelist status of an admin
    /// @param admin The admin address to update
    /// @param isWhitelisted The new whitelist status
    function updateWhitelistedAdmin(address admin, bool isWhitelisted) external onlyOwner {
        whitelistedAdmins[admin] = isWhitelisted;
    }
}
