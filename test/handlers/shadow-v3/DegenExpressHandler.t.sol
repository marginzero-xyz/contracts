// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {ShadowV3Handler} from "../../../src/handlers/shadow-v3/ShadowV3Handler.sol";
import {PositionManager} from "../../../src/PositionManager.sol";

import {ShadowV3PoolUtils} from "./shadow-v3-utils/ShadowV3PoolUtils.sol";
import {ShadowV3LiquidityManagement} from "./shadow-v3-utils/ShadowV3LiquidityManagement.sol";

import {IRamsesV3Factory} from "./shadow-v3-utils/IRamsesV3Factory.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";
import {IV3Pool} from "../../../src/interfaces/handlers/V3/IV3Pool.sol";
import {V3BaseHandler} from "../../../src/handlers/V3BaseHandler.sol";
import {IHandler} from "../../../src/interfaces/IHandler.sol";
import {TickMath} from "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import {LiquidityAmounts} from "v3-periphery/libraries/LiquidityAmounts.sol";
import {Tick} from "@uniswap/v3-core/contracts/libraries/Tick.sol";
import {IRamsesV3Pool} from "../../../src/handlers/shadow-v3/IRamsesV3Pool.sol";
import {MockDegenExpressHandler} from "../../mocks/MockDegenExpressHandler.sol";
import {DegenExpressLiq} from "../../../src/periphery/DegenExpressLiq.sol";

contract ShadowV3HandlerTest is Test {
    using TickMath for int24;

    PositionManager public positionManager;
    ShadowV3Handler public handler;

    ShadowV3PoolUtils public shadowV3PoolUtils;
    ShadowV3LiquidityManagement public shadowV3LiquidityManagement;

    MockERC20 public USDC; // token0
    MockERC20 public ETH; // token1

    MockERC20 public token0;
    MockERC20 public token1;

    address public feeReceiver = makeAddr("feeReceiver");

    address public owner = makeAddr("owner");

    IRamsesV3Pool public pool;

    DegenExpressLiq public liqHandler;
    MockDegenExpressHandler public mockDegenExpressHandler;

    function setUp() public {
        vm.createSelectFork(vm.envString("SONIC_RPC_URL"), 1905910);

        address deployer = 0x8BBDc15759a8eCf99A92E004E0C64ea9A5142d59;
        bytes32 PAIR_INIT_CODE_HASH = 0xc701ee63862761c31d620a4a083c61bdc1e81761e6b9c9267fd19afd22e0821d;

        // factory
        shadowV3PoolUtils = new ShadowV3PoolUtils(0xcD2d0637c94fe77C2896BbCBB174cefFb08DE6d7, PAIR_INIT_CODE_HASH);

        shadowV3LiquidityManagement = new ShadowV3LiquidityManagement(deployer, PAIR_INIT_CODE_HASH);

        // Deploy mock tokens for testing
        ETH = new MockERC20("Ethereum", "ETH", 18);
        USDC = new MockERC20("USD Coin", "USDC", 6);

        vm.startPrank(owner);

        positionManager = new PositionManager(owner);

        // Deploy the Uniswap V3 handler with additional arguments
        handler = new ShadowV3Handler(
            feeReceiver, // _feeReceiver
            address(deployer), // _deployer
            PAIR_INIT_CODE_HASH
        );
        // Whitelist the handler
        positionManager.updateWhitelistHandler(address(handler), true);

        handler.updateHandlerSettings(address(positionManager), true, address(0), 6 hours, feeReceiver);

        positionManager.updateWhitelistHandlerWithApp(address(handler), address(this), true);

        vm.stopPrank();

        // Initialize the pool with sqrtPriceX96 representing 1 ETH = 2000 USDC
        uint160 sqrtPriceX96 = 1771595571142957166518320255467520;
        pool = IRamsesV3Pool(shadowV3PoolUtils.deployAndInitializePool(ETH, USDC, 10, sqrtPriceX96));

        shadowV3PoolUtils.addLiquidity(
            ShadowV3PoolUtils.AddLiquidityStruct({
                liquidityManager: address(shadowV3LiquidityManagement),
                pool: address(pool),
                user: owner,
                desiredAmount0: 100000000e6,
                desiredAmount1: 100 ether,
                desiredTickLower: 200010,
                desiredTickUpper: 201010,
                requireMint: true
            })
        );

        liqHandler = new DegenExpressLiq(owner, address(positionManager));
        
        vm.startPrank(owner);
        liqHandler.updateWhitelistedAdmin(owner, true);
        vm.stopPrank();

        mockDegenExpressHandler = new MockDegenExpressHandler(address(USDC), address(ETH));
    }

    function testPoolDeployment() public {
        assertTrue(address(pool) != address(0), "Pool was not deployed");

        (address _token0, address _token1) =
            (ETH < USDC) ? (address(ETH), address(USDC)) : (address(USDC), address(ETH));
        token0 = MockERC20(_token0);
        token1 = MockERC20(_token1);

        assertEq(pool.token0(), address(USDC), "Token0 is not USDC");
        assertEq(pool.token1(), address(ETH), "Token1 is not ETH");
    }

    struct TestVars {
        uint160 sqrtPriceX96;
        int24 currentTick;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint256 tokenId;
        uint256 sharesMinted;
        BalanceCheckVars balanceBefore;
        BalanceCheckVars balanceAfter;
    }

    struct TokenIdInfo {
        uint128 totalLiquidity;
        uint128 liquidityUsed;
        uint256 feeGrowthInside0LastX128;
        uint256 feeGrowthInside1LastX128;
        uint128 tokensOwed0;
        uint128 tokensOwed1;
        uint128 reservedLiquidity;
    }

    struct BalanceCheckVars {
        uint256 balance0;
        uint256 balance1;
    }

    struct LiquidityCheckVars {
        uint128 liquidity0;
        uint128 liquidity1;
    }

    function testShadowLiquidityClaimWithOnlyETH() public {
        ETH.mint(address(mockDegenExpressHandler), 1 ether);

        vm.startPrank(owner);
        liqHandler.claimShadowLP(address(mockDegenExpressHandler), address(0));
        uint256 ethBalance = ETH.balanceOf(address(liqHandler));
        assertTrue(ethBalance > 0, "ETH balance should have increased after claiming");

        liqHandler.setApprovals(address(ETH), address(positionManager), 1 ether);

        TestVars memory vars;
        uint256 amount1Desired = 1 ether; // 1 ETH
        uint256 amount0Desired = 0; // No USDC

        // Get current price and tick
        (vars.sqrtPriceX96, vars.currentTick,,,,,) = pool.slot0();

        // Calculate tick range
        int24 tickSpacing = pool.tickSpacing();
        vars.tickUpper = ((vars.currentTick / tickSpacing) * tickSpacing) - tickSpacing;
        vars.tickLower = vars.tickUpper - 1 * tickSpacing; // 1 tick spaces wide

        vars.liquidity = LiquidityAmounts.getLiquidityForAmounts(
            vars.sqrtPriceX96,
            TickMath.getSqrtRatioAtTick(vars.tickLower),
            TickMath.getSqrtRatioAtTick(vars.tickUpper),
            amount0Desired,
            amount1Desired
        );

        V3BaseHandler.MintPositionParams memory params = V3BaseHandler.MintPositionParams({
            pool: IV3Pool(address(pool)),
            hook: address(0),
            tickLower: vars.tickLower,
            tickUpper: vars.tickUpper,
            liquidity: vars.liquidity
        });

        vars.sharesMinted = liqHandler.addLiquidity(IHandler(address(handler)), abi.encode(params, ""));
        assertTrue(vars.sharesMinted > 0, "Shares minted should be greater than 0");

        vars.tokenId =
            handler.getHandlerIdentifier(abi.encode(address(pool), address(0), vars.tickLower, vars.tickUpper));

        TokenIdInfo memory info;
        (
            info.totalLiquidity,
            info.liquidityUsed,
            info.feeGrowthInside0LastX128,
            info.feeGrowthInside1LastX128,
            info.tokensOwed0,
            info.tokensOwed1,
            ,
            ,
            ,
            info.reservedLiquidity
        ) = handler.tokenIds(vars.tokenId);

        assertTrue(info.totalLiquidity > 0, "Total liquidity should be greater than 0");
        assertEq(info.liquidityUsed, 0, "Liquidity used should be 0");
        assertEq(info.feeGrowthInside0LastX128, 0, "Initial feeGrowthInside0LastX128 should be 0");
        assertEq(info.feeGrowthInside1LastX128, 0, "Initial feeGrowthInside1LastX128 should be 0");
        assertEq(info.tokensOwed0, 0, "Initial tokensOwed0 should be 0");
        assertEq(info.tokensOwed1, 0, "Initial tokensOwed1 should be 0");
        assertEq(info.reservedLiquidity, 0, "Initial reserved liquidity should be 0");

        assertEq(
            handler.balanceOf(address(liqHandler), vars.tokenId), vars.sharesMinted, "Owner's balance should equal shares minted"
        );

        (uint128 poolLiquidity,,,,) =
            pool.positions(keccak256(abi.encodePacked(address(handler), uint256(0), vars.tickLower, vars.tickUpper)));
        assertEq(poolLiquidity, info.totalLiquidity, "Pool liquidity should match total liquidity in handler");

        assertLt(vars.tickUpper, vars.currentTick, "Upper tick should be below current tick for ETH-only position");
        assertLt(vars.tickLower, vars.tickUpper, "Lower tick should be below upper tick");

        vm.stopPrank();
    }

    function testShadowLiquidityClaimWithOnlyUSDC() public {
        USDC.mint(address(mockDegenExpressHandler), 1000e6);

        vm.startPrank(owner);
        liqHandler.claimShadowLP(address(mockDegenExpressHandler), address(0));
        uint256 usdcBalance = USDC.balanceOf(address(liqHandler));
        assertTrue(usdcBalance > 0, "USDC balance should have increased after claiming");

        liqHandler.setApprovals(address(USDC), address(positionManager), 1000e6);

        TestVars memory vars;
        uint256 amount0Desired = 1000e6; // 1000 USDC
        uint256 amount1Desired = 0; // No ETH

        // Get current price and tick
        (vars.sqrtPriceX96, vars.currentTick,,,,,) = pool.slot0();

        // Calculate tick range
        int24 tickSpacing = pool.tickSpacing();
        vars.tickLower = ((vars.currentTick / tickSpacing) * tickSpacing) + tickSpacing;
        vars.tickUpper = vars.tickLower + 1 * tickSpacing; // 1 tick spaces wide

        vars.liquidity = LiquidityAmounts.getLiquidityForAmounts(
            vars.sqrtPriceX96,
            TickMath.getSqrtRatioAtTick(vars.tickLower),
            TickMath.getSqrtRatioAtTick(vars.tickUpper),
            amount0Desired,
            amount1Desired
        );

        V3BaseHandler.MintPositionParams memory params = V3BaseHandler.MintPositionParams({
            pool: IV3Pool(address(pool)),
            hook: address(0),
            tickLower: vars.tickLower,
            tickUpper: vars.tickUpper,
            liquidity: vars.liquidity
        });

        vars.sharesMinted = liqHandler.addLiquidity(IHandler(address(handler)), abi.encode(params, ""));
        assertTrue(vars.sharesMinted > 0, "Shares minted should be greater than 0");

        vars.tokenId = handler.getHandlerIdentifier(abi.encode(address(pool), address(0), vars.tickLower, vars.tickUpper));

        TokenIdInfo memory info;
        (
            info.totalLiquidity,
            info.liquidityUsed,
            info.feeGrowthInside0LastX128,
            info.feeGrowthInside1LastX128,
            info.tokensOwed0,
            info.tokensOwed1,
            ,
            ,
            ,
            info.reservedLiquidity
        ) = handler.tokenIds(vars.tokenId);

        assertTrue(info.totalLiquidity > 0, "Total liquidity should be greater than 0");
        assertEq(info.liquidityUsed, 0, "Liquidity used should be 0");
        assertEq(info.feeGrowthInside0LastX128, 0, "Initial feeGrowthInside0LastX128 should be 0");
        assertEq(info.feeGrowthInside1LastX128, 0, "Initial feeGrowthInside1LastX128 should be 0");
        assertEq(info.tokensOwed0, 0, "Initial tokensOwed0 should be 0");
        assertEq(info.tokensOwed1, 0, "Initial tokensOwed1 should be 0");
        assertEq(info.reservedLiquidity, 0, "Initial reserved liquidity should be 0");

        assertEq(
            handler.balanceOf(address(liqHandler), vars.tokenId), 
            vars.sharesMinted, 
            "Owner's balance should equal shares minted"
        );

        (uint128 poolLiquidity,,,,) = pool.positions(
            keccak256(abi.encodePacked(address(handler), uint256(0), vars.tickLower, vars.tickUpper))
        );
        assertEq(poolLiquidity, info.totalLiquidity, "Pool liquidity should match total liquidity in handler");

        assertGt(vars.tickLower, vars.currentTick, "Lower tick should be above current tick for USDC-only position");
        assertGt(vars.tickUpper, vars.tickLower, "Upper tick should be above lower tick");

        vm.stopPrank();
    }

    function testShadowLiquidityClaimInRange() public {
        USDC.mint(address(mockDegenExpressHandler), 10000e6);
        ETH.mint(address(mockDegenExpressHandler), 5 ether);

        vm.startPrank(owner);
        liqHandler.claimShadowLP(address(mockDegenExpressHandler), address(0));
        uint256 usdcBalance = USDC.balanceOf(address(liqHandler));
        uint256 ethBalance = ETH.balanceOf(address(liqHandler));
        assertTrue(usdcBalance > 0, "USDC balance should have increased after claiming");
        assertTrue(ethBalance > 0, "ETH balance should have increased after claiming");

        liqHandler.setApprovals(address(USDC), address(positionManager), 10000e6);
        liqHandler.setApprovals(address(ETH), address(positionManager), 5 ether);

        TestVars memory vars;
        // Get current price and tick
        (vars.sqrtPriceX96, vars.currentTick,,,,,) = pool.slot0();

        int24 tickSpacing = pool.tickSpacing();

        // Calculate tick range that spans the current tick
        vars.tickLower = ((vars.currentTick / tickSpacing) * tickSpacing) - 10 * tickSpacing;
        vars.tickUpper = ((vars.currentTick / tickSpacing) * tickSpacing) + 10 * tickSpacing;

        // Calculate liquidity for both amounts
        uint128 liquidity0 = LiquidityAmounts.getLiquidityForAmount0(
            TickMath.getSqrtRatioAtTick(vars.tickLower),
            TickMath.getSqrtRatioAtTick(vars.tickUpper),
            10000e6
        );

        uint128 liquidity1 = LiquidityAmounts.getLiquidityForAmount1(
            TickMath.getSqrtRatioAtTick(vars.tickLower),
            TickMath.getSqrtRatioAtTick(vars.tickUpper),
            5 ether
        );

        // Use the lesser of the two liquidities
        vars.liquidity = liquidity0 < liquidity1 ? liquidity0 : liquidity1;

        V3BaseHandler.MintPositionParams memory params = V3BaseHandler.MintPositionParams({
            pool: IV3Pool(address(pool)),
            hook: address(0),
            tickLower: vars.tickLower,
            tickUpper: vars.tickUpper,
            liquidity: vars.liquidity
        });

        vars.sharesMinted = liqHandler.addLiquidity(IHandler(address(handler)), abi.encode(params, ""));
        assertTrue(vars.sharesMinted > 0, "Shares minted should be greater than 0");

        vars.tokenId = handler.getHandlerIdentifier(abi.encode(address(pool), address(0), vars.tickLower, vars.tickUpper));

        TokenIdInfo memory info;
        (
            info.totalLiquidity,
            info.liquidityUsed,
            info.feeGrowthInside0LastX128,
            info.feeGrowthInside1LastX128,
            info.tokensOwed0,
            info.tokensOwed1,
            ,
            ,
            ,
            info.reservedLiquidity
        ) = handler.tokenIds(vars.tokenId);

        assertTrue(info.totalLiquidity > 0, "Total liquidity should be greater than 0");
        assertEq(info.liquidityUsed, 0, "Liquidity used should be 0");
        assertEq(info.feeGrowthInside0LastX128, 0, "Initial feeGrowthInside0LastX128 should be 0");
        assertEq(info.feeGrowthInside1LastX128, 0, "Initial feeGrowthInside1LastX128 should be 0");
        assertEq(info.tokensOwed0, 0, "Initial tokensOwed0 should be 0");
        assertEq(info.tokensOwed1, 0, "Initial tokensOwed1 should be 0");
        assertEq(info.reservedLiquidity, 0, "Initial reserved liquidity should be 0");

        assertEq(
            handler.balanceOf(address(liqHandler), vars.tokenId),
            vars.sharesMinted,
            "Owner's balance should equal shares minted"
        );

        (uint128 poolLiquidity,,,,) = pool.positions(
            keccak256(abi.encodePacked(address(handler), uint256(0), vars.tickLower, vars.tickUpper))
        );
        assertEq(poolLiquidity, info.totalLiquidity, "Pool liquidity should match total liquidity in handler");

        vm.stopPrank();
    }

    function testShadowLiquidityRemoveWithOnlyUSDC() public {
        // First mint a position using existing test
        testShadowLiquidityClaimWithOnlyUSDC();

        vm.startPrank(owner);
        TestVars memory vars;
        // Get current price and tick
        (vars.sqrtPriceX96, vars.currentTick,,,,,) = pool.slot0();

        // Calculate tick range (same as in mint)
        int24 tickSpacing = pool.tickSpacing();
        vars.tickLower = ((vars.currentTick / tickSpacing) * tickSpacing) + tickSpacing;
        vars.tickUpper = vars.tickLower + 1 * tickSpacing;

        vars.tokenId = handler.getHandlerIdentifier(abi.encode(address(pool), address(0), vars.tickLower, vars.tickUpper));
        uint256 sharesMinted = handler.balanceOf(address(liqHandler), vars.tokenId);

        // Remove half of the liquidity
        uint256 sharesBurned = sharesMinted / 2;
        uint256 balanceBefore = USDC.balanceOf(address(liqHandler));

        V3BaseHandler.BurnPositionParams memory burnParams = V3BaseHandler.BurnPositionParams({
            pool: IV3Pool(address(pool)),
            hook: address(0),
            tickLower: vars.tickLower,
            tickUpper: vars.tickUpper,
            liquidity: uint128(sharesBurned)
        });

        liqHandler.removeLiquidity(IHandler(address(handler)), abi.encode(burnParams, ""));

        uint256 balanceAfter = USDC.balanceOf(address(liqHandler));
        assertTrue(balanceAfter > balanceBefore, "USDC balance should have increased after burning");

        vm.stopPrank();
    }

    function testShadowLiquidityRemoveWithOnlyETH() public {
        // First mint a position using existing test
        testShadowLiquidityClaimWithOnlyETH();

        vm.startPrank(owner);
        TestVars memory vars;
        // Get current price and tick
        (vars.sqrtPriceX96, vars.currentTick,,,,,) = pool.slot0();

        // Calculate tick range (same as in mint)
        int24 tickSpacing = pool.tickSpacing();
        vars.tickUpper = ((vars.currentTick / tickSpacing) * tickSpacing) - tickSpacing;
        vars.tickLower = vars.tickUpper - 1 * tickSpacing;

        vars.tokenId = handler.getHandlerIdentifier(abi.encode(address(pool), address(0), vars.tickLower, vars.tickUpper));
        uint256 sharesMinted = handler.balanceOf(address(liqHandler), vars.tokenId);

        // Remove half of the liquidity
        uint256 sharesBurned = sharesMinted / 2;
        uint256 balanceBefore = ETH.balanceOf(address(liqHandler));

        V3BaseHandler.BurnPositionParams memory burnParams = V3BaseHandler.BurnPositionParams({
            pool: IV3Pool(address(pool)),
            hook: address(0),
            tickLower: vars.tickLower,
            tickUpper: vars.tickUpper,
            liquidity: uint128(sharesBurned)
        });

        liqHandler.removeLiquidity(IHandler(address(handler)), abi.encode(burnParams, ""));

        uint256 balanceAfter = ETH.balanceOf(address(liqHandler));
        assertTrue(balanceAfter > balanceBefore, "ETH balance should have increased after burning");

        vm.stopPrank();
    }

    function testShadowLiquidityRemoveInRange() public {
        // First mint a position using existing test
        testShadowLiquidityClaimInRange();

        vm.startPrank(owner);
        TestVars memory vars;
        // Get current price and tick
        (vars.sqrtPriceX96, vars.currentTick,,,,,) = pool.slot0();

        // Calculate tick range (same as in mint)
        int24 tickSpacing = pool.tickSpacing();
        vars.tickLower = ((vars.currentTick / tickSpacing) * tickSpacing) - 10 * tickSpacing;
        vars.tickUpper = ((vars.currentTick / tickSpacing) * tickSpacing) + 10 * tickSpacing;

        vars.tokenId = handler.getHandlerIdentifier(abi.encode(address(pool), address(0), vars.tickLower, vars.tickUpper));
        uint256 sharesMinted = handler.balanceOf(address(liqHandler), vars.tokenId);

        // Remove half of the liquidity
        uint256 sharesBurned = sharesMinted / 2;
        uint256 balanceBefore0 = USDC.balanceOf(address(liqHandler));
        uint256 balanceBefore1 = ETH.balanceOf(address(liqHandler));

        V3BaseHandler.BurnPositionParams memory burnParams = V3BaseHandler.BurnPositionParams({
            pool: IV3Pool(address(pool)),
            hook: address(0),
            tickLower: vars.tickLower,
            tickUpper: vars.tickUpper,
            liquidity: uint128(sharesBurned)
        });

        liqHandler.removeLiquidity(IHandler(address(handler)), abi.encode(burnParams, ""));

        uint256 balanceAfter0 = USDC.balanceOf(address(liqHandler));
        uint256 balanceAfter1 = ETH.balanceOf(address(liqHandler));
        assertTrue(balanceAfter0 > balanceBefore0, "USDC balance should have increased after burning");
        assertTrue(balanceAfter1 > balanceBefore1, "ETH balance should have increased after burning");

        vm.stopPrank();
    }

    function testSweepTokens() public {
        // First mint tokens to the liqHandler
        USDC.mint(address(liqHandler), 1000e6);
        ETH.mint(address(liqHandler), 1 ether);

        address recipient = makeAddr("recipient");
        uint256 usdcAmount = 500e6;
        uint256 ethAmount = 0.5 ether;

        vm.startPrank(owner);
        
        // Get initial balances
        uint256 initialUSDCBalance = USDC.balanceOf(recipient);
        uint256 initialETHBalance = ETH.balanceOf(recipient);

        // Sweep USDC
        liqHandler.sweepTokens(address(USDC), recipient, usdcAmount);
        
        // Sweep ETH
        liqHandler.sweepTokens(address(ETH), recipient, ethAmount);

        // Verify balances after sweep
        assertEq(
            USDC.balanceOf(recipient) - initialUSDCBalance,
            usdcAmount,
            "Recipient should have received correct USDC amount"
        );
        assertEq(
            ETH.balanceOf(recipient) - initialETHBalance,
            ethAmount,
            "Recipient should have received correct ETH amount"
        );

        vm.stopPrank();

        // Test that non-owner cannot sweep tokens
        address nonOwner = makeAddr("nonOwner");
        vm.startPrank(nonOwner);
        vm.expectRevert();
        liqHandler.sweepTokens(address(USDC), recipient, usdcAmount);
        vm.stopPrank();
    }

    function testSweepMZLP() public {
        // First create a position to get some MZLP tokens
        testShadowLiquidityClaimWithOnlyUSDC();

        address recipient = makeAddr("recipient");
        
        vm.startPrank(owner);
        
        TestVars memory vars;
        // Get current price and tick
        (vars.sqrtPriceX96, vars.currentTick,,,,,) = pool.slot0();

        // Calculate tick range
        int24 tickSpacing = pool.tickSpacing();
        vars.tickLower = ((vars.currentTick / tickSpacing) * tickSpacing) + tickSpacing;
        vars.tickUpper = vars.tickLower + 1 * tickSpacing;

        vars.tokenId = handler.getHandlerIdentifier(abi.encode(address(pool), address(0), vars.tickLower, vars.tickUpper));
        uint256 sharesMinted = handler.balanceOf(address(liqHandler), vars.tokenId);
        uint256 sharesToSweep = sharesMinted / 2; // Sweep half of the shares

        // Get initial balance
        uint256 initialBalance = handler.balanceOf(recipient, vars.tokenId);

        // Sweep MZLP tokens
        liqHandler.sweepMZLP(address(handler), recipient, vars.tokenId, sharesToSweep);

        // Verify balance after sweep
        assertEq(
            handler.balanceOf(recipient, vars.tokenId) - initialBalance,
            sharesToSweep,
            "Recipient should have received correct amount of MZLP tokens"
        );

        vm.stopPrank();

        // Test that non-owner cannot sweep MZLP
        address nonOwner = makeAddr("nonOwner");
        vm.startPrank(nonOwner);
        vm.expectRevert();
        liqHandler.sweepMZLP(address(handler), recipient, vars.tokenId, sharesToSweep);
        vm.stopPrank();
    }

    function testAccessControl() public {
        address nonAdmin = makeAddr("nonAdmin");
        address nonOwner = makeAddr("nonOwner");
        address whitelistedAdmin = makeAddr("whitelistedAdmin");

        // Setup test tokens and position
        USDC.mint(address(mockDegenExpressHandler), 1000e6);
        ETH.mint(address(mockDegenExpressHandler), 1 ether);
        USDC.mint(address(liqHandler), 1000e6);
        ETH.mint(address(liqHandler), 1 ether);

        vm.startPrank(owner);
        // Whitelist an admin
        liqHandler.updateWhitelistedAdmin(whitelistedAdmin, true);

        // Set approvals for tokens
        liqHandler.setApprovals(address(USDC), address(positionManager), 1000e6);
        liqHandler.setApprovals(address(ETH), address(positionManager), 1 ether);

        // Setup mint params for testing addLiquidity
        TestVars memory vars;
        (vars.sqrtPriceX96, vars.currentTick,,,,,) = pool.slot0();
        int24 tickSpacing = pool.tickSpacing();
        vars.tickLower = ((vars.currentTick / tickSpacing) * tickSpacing) + tickSpacing;
        vars.tickUpper = vars.tickLower + 1 * tickSpacing;

        vars.liquidity = LiquidityAmounts.getLiquidityForAmounts(
            vars.sqrtPriceX96,
            TickMath.getSqrtRatioAtTick(vars.tickLower),
            TickMath.getSqrtRatioAtTick(vars.tickUpper),
            1000e6,
            0
        );

        V3BaseHandler.MintPositionParams memory mintParams = V3BaseHandler.MintPositionParams({
            pool: IV3Pool(address(pool)),
            hook: address(0),
            tickLower: vars.tickLower,
            tickUpper: vars.tickUpper,
            liquidity: vars.liquidity
        });

        // Setup burn params for testing removeLiquidity with 1/4th of the liquidity
        V3BaseHandler.BurnPositionParams memory burnParams = V3BaseHandler.BurnPositionParams({
            pool: IV3Pool(address(pool)),
            hook: address(0),
            tickLower: vars.tickLower,
            tickUpper: vars.tickUpper,
            liquidity: vars.liquidity / 2  // Use 1/4th of the liquidity for burning
        });
        vm.stopPrank();

        // Test onlyWhitelistedAdmin functions
        vm.startPrank(nonAdmin);
        vm.expectRevert(DegenExpressLiq.NotWhitelistedAdmin.selector);
        liqHandler.claimShadowLP(address(mockDegenExpressHandler), address(0));

        vm.expectRevert(DegenExpressLiq.NotWhitelistedAdmin.selector);
        liqHandler.addLiquidity(IHandler(address(handler)), abi.encode(mintParams, ""));

        vm.expectRevert(DegenExpressLiq.NotWhitelistedAdmin.selector);
        liqHandler.removeLiquidity(IHandler(address(handler)), abi.encode(burnParams, ""));
        vm.stopPrank();

        // Test that whitelisted admin can access restricted functions
        vm.startPrank(whitelistedAdmin);
        liqHandler.claimShadowLP(address(mockDegenExpressHandler), address(0));
        liqHandler.addLiquidity(IHandler(address(handler)), abi.encode(mintParams, ""));
        liqHandler.removeLiquidity(IHandler(address(handler)), abi.encode(burnParams, ""));
        vm.stopPrank();

        vars.tokenId =
            handler.getHandlerIdentifier(abi.encode(address(pool), address(0), vars.tickLower, vars.tickUpper));


        // Test onlyOwner functions
        vm.startPrank(nonOwner);
        vm.expectRevert();
        liqHandler.sweepTokens(address(USDC), nonOwner, 100e6);

        vm.expectRevert();
        liqHandler.sweepMZLP(address(handler), nonOwner, vars.tokenId, 100);

        vm.expectRevert();
        liqHandler.setApprovals(address(USDC), address(handler), 100e6);

        vm.expectRevert();
        liqHandler.setMZLPApprovals(address(handler), address(handler), 1, 100);

        vm.expectRevert();
        liqHandler.updateWhitelistedAdmin(whitelistedAdmin, false);
        vm.stopPrank();

        // Test that owner can access owner-only functions
        vm.startPrank(owner);
        liqHandler.sweepTokens(address(USDC), owner, 100e6);
        liqHandler.sweepMZLP(address(handler), owner, vars.tokenId, 100);
        liqHandler.setApprovals(address(USDC), address(handler), 100e6);
        liqHandler.setMZLPApprovals(address(handler), address(handler), vars.tokenId, 100);
        liqHandler.updateWhitelistedAdmin(whitelistedAdmin, false);

        // Verify admin was removed
        vm.stopPrank();
        vm.startPrank(whitelistedAdmin);
        vm.expectRevert(DegenExpressLiq.NotWhitelistedAdmin.selector);
        liqHandler.claimShadowLP(address(mockDegenExpressHandler), address(0));
        vm.stopPrank();
    }
    
    // Add this function to handle the swap callback
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external {
        if (amount0Delta > 0) {
            USDC.transfer(msg.sender, uint256(amount0Delta));
        } else if (amount1Delta > 0) {
            ETH.transfer(msg.sender, uint256(amount1Delta));
        }
    }
}
