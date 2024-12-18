// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";

import {UniswapV3Handler} from "../../src/handlers/uniswap-v3/UniswapV3Handler.sol";
import {PositionManager} from "../../src/PositionManager.sol";
import {PerpOTM} from "../../src/apps/perpetuals/PerpOTM.sol";
import {PerpOTMPricing} from "../../src/apps/perpetuals/pricing/PerpOTMPricing.sol";
import {UniswapV3FactoryDeployer} from "../../test/uniswap-v3-utils/UniswapV3FactoryDeployer.sol";

import {UniswapV3PoolUtils} from "../../test/uniswap-v3-utils/UniswapV3PoolUtils.sol";
import {UniswapV3LiquidityManagement} from "../../test/uniswap-v3-utils/UniswapV3LiquidityManagement.sol";

import {IUniswapV3Factory} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";

import {ISwapper} from "../../src/interfaces/ISwapper.sol";

import {MockERC20} from "../../test/mocks/MockERC20.sol";
import {MockHook} from "../../test/mocks/MockHook.sol";
import {IV3Pool} from "../../src/interfaces/handlers/V3/IV3Pool.sol";
import {V3BaseHandler} from "../../src/handlers/V3BaseHandler.sol";
import {IHandler} from "../../src/interfaces/IHandler.sol";
import {TickMath} from "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import {LiquidityAmounts} from "v3-periphery/libraries/LiquidityAmounts.sol";
import {Tick} from "@uniswap/v3-core/contracts/libraries/Tick.sol";

contract PerpOTMTest is Test, UniswapV3FactoryDeployer {
    using TickMath for int24;

    PositionManager public positionManager;
    UniswapV3Handler public handler;

    PerpOTM public perpOTM;
    PerpOTMPricing public perpOTMPricing;

    UniswapV3FactoryDeployer public factoryDeployer;
    IUniswapV3Factory public factory;

    UniswapV3PoolUtils public uniswapV3PoolUtils;
    UniswapV3LiquidityManagement public uniswapV3LiquidityManagement;

    MockERC20 public USDC; // token0
    MockERC20 public ETH; // token1

    MockERC20 public token0;
    MockERC20 public token1;

    address public feeReceiver = makeAddr("feeReceiver");

    address public owner = makeAddr("owner");

    address public user = makeAddr("user");

    address public trader = makeAddr("trader");

    IUniswapV3Pool public pool;

    MockHook public mockHook;

    function setUp() public {
        // Deploy the Uniswap V3 Factory
        factory = IUniswapV3Factory(deployUniswapV3Factory());

        // Deploy mock tokens for testing
        USDC = new MockERC20("USD Coin", "USDC", 6);
        ETH = new MockERC20("Ethereum", "ETH", 18);

        uniswapV3PoolUtils = new UniswapV3PoolUtils();

        uniswapV3LiquidityManagement = new UniswapV3LiquidityManagement(address(factory));

        uint160 sqrtPriceX96 = 1771595571142957166518320255467520;
        pool = IUniswapV3Pool(uniswapV3PoolUtils.deployAndInitializePool(factory, ETH, USDC, 500, sqrtPriceX96));

        uniswapV3PoolUtils.addLiquidity(
            UniswapV3PoolUtils.AddLiquidityStruct({
                liquidityManager: address(uniswapV3LiquidityManagement),
                pool: pool,
                user: owner,
                desiredAmount0: 10_000_000e6,
                desiredAmount1: 10 ether,
                desiredTickLower: 200010,
                desiredTickUpper: 201010,
                requireMint: true
            })
        );

        vm.startPrank(owner);

        positionManager = new PositionManager(owner);

        // Deploy the Uniswap V3 handler with additional arguments
        handler = new UniswapV3Handler(
            feeReceiver, // _feeReceiver
            address(factory), // _factory
            0xa598dd2fba360510c5a8f02f44423a4468e902df5857dbce3ca162a43a3a31ff
        );
        // Whitelist the handler
        positionManager.updateWhitelistHandler(address(handler), true);

        handler.updateHandlerSettings(address(positionManager), true, address(0), 6 hours, feeReceiver);

        mockHook = new MockHook();

        handler.registerHook(
            address(mockHook),
            IHandler.HookPermInfo({
                onMint: false,
                onBurn: false,
                onUse: false,
                onUnuse: false,
                onDonate: false,
                allowSplit: false
            })
        );

        perpOTMPricing = new PerpOTMPricing();

        perpOTM =
            new PerpOTM(address(positionManager), address(pool), address(perpOTMPricing), address(ETH), address(USDC));

        positionManager.updateWhitelistHandlerWithApp(address(handler), address(perpOTM), true);

        vm.stopPrank();

        // Initialize the pool with sqrtPriceX96 representing 1 ETH = 2000 USDC
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

    struct PerpPositionDataVars {
        uint128 perpTickArrayLen;
        int24 positionTickLower;
        int24 positionTickUpper;
        bool isLong;
        uint128 remainingFees;
        uint64 lastFeeAccrued;
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

    function addLiquidityForLong() public returns (uint256) {
        TestVars memory vars;
        uint256 amount1Desired = 1 ether; // 1 ETH
        uint256 amount0Desired = 0; // No USDC

        // Get current price and tick
        (vars.sqrtPriceX96, vars.currentTick,,,,,) = pool.slot0();

        // Calculate tick range
        int24 tickSpacing = pool.tickSpacing();
        vars.tickUpper = ((vars.currentTick / tickSpacing) * tickSpacing) - tickSpacing;
        vars.tickLower = vars.tickUpper - 1 * tickSpacing; // 1 tick spaces wide

        vm.startPrank(user);
        ETH.mint(user, amount1Desired);
        ETH.approve(address(positionManager), amount1Desired);
        vars.balanceBefore.balance1 = ETH.balanceOf(user);

        vars.liquidity = LiquidityAmounts.getLiquidityForAmounts(
            vars.sqrtPriceX96,
            TickMath.getSqrtRatioAtTick(vars.tickLower),
            TickMath.getSqrtRatioAtTick(vars.tickUpper),
            amount0Desired,
            amount1Desired
        );

        V3BaseHandler.MintPositionParams memory params = V3BaseHandler.MintPositionParams({
            pool: IV3Pool(address(pool)),
            hook: address(mockHook),
            tickLower: vars.tickLower,
            tickUpper: vars.tickUpper,
            liquidity: vars.liquidity
        });

        vars.sharesMinted = positionManager.mintPosition(IHandler(address(handler)), abi.encode(params, ""));
        assertTrue(vars.sharesMinted > 0, "Shares minted should be greater than 0");

        vars.tokenId =
            handler.getHandlerIdentifier(abi.encode(address(pool), address(mockHook), vars.tickLower, vars.tickUpper));

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

        assertEq(handler.balanceOf(user, vars.tokenId), vars.sharesMinted, "user's balance should equal shares minted");

        vars.balanceAfter.balance1 = ETH.balanceOf(user);
        assertTrue(vars.balanceAfter.balance1 < vars.balanceBefore.balance1, "ETH balance should have decreased");
        assertTrue(
            vars.balanceBefore.balance1 - vars.balanceAfter.balance1 <= amount1Desired,
            "ETH spent should not exceed desired amount"
        );

        (uint128 poolLiquidity,,,,) =
            pool.positions(keccak256(abi.encodePacked(address(handler), vars.tickLower, vars.tickUpper)));
        assertEq(poolLiquidity, info.totalLiquidity, "Pool liquidity should match total liquidity in handler");

        assertLt(vars.tickUpper, vars.currentTick, "Upper tick should be below current tick for ETH-only position");
        assertLt(vars.tickLower, vars.tickUpper, "Lower tick should be below upper tick");

        vm.stopPrank();

        return vars.sharesMinted;
    }

    function addLiquidityForShort() public returns (uint256) {
        TestVars memory vars;
        uint256 amount0Desired = 1000e6; // 1000 USDC
        uint256 amount1Desired = 0; // No ETH

        // Get current price and tick
        (vars.sqrtPriceX96, vars.currentTick,,,,,) = pool.slot0();

        // Calculate tick range
        int24 tickSpacing = pool.tickSpacing();
        vars.tickLower = ((vars.currentTick / tickSpacing) * tickSpacing) + tickSpacing;
        vars.tickUpper = vars.tickLower + 1 * tickSpacing; // 1 tick spaces wide

        vm.startPrank(user);
        USDC.mint(user, amount0Desired);
        USDC.approve(address(positionManager), amount0Desired);
        vars.balanceBefore.balance0 = USDC.balanceOf(user);

        vars.liquidity = LiquidityAmounts.getLiquidityForAmounts(
            vars.sqrtPriceX96,
            TickMath.getSqrtRatioAtTick(vars.tickLower),
            TickMath.getSqrtRatioAtTick(vars.tickUpper),
            amount0Desired,
            amount1Desired
        );

        V3BaseHandler.MintPositionParams memory params = V3BaseHandler.MintPositionParams({
            pool: IV3Pool(address(pool)),
            hook: address(mockHook),
            tickLower: vars.tickLower,
            tickUpper: vars.tickUpper,
            liquidity: vars.liquidity
        });

        vars.sharesMinted = positionManager.mintPosition(IHandler(address(handler)), abi.encode(params, ""));
        assertTrue(vars.sharesMinted > 0, "Shares minted should be greater than 0");

        vars.tokenId =
            handler.getHandlerIdentifier(abi.encode(address(pool), address(mockHook), vars.tickLower, vars.tickUpper));

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

        assertEq(handler.balanceOf(user, vars.tokenId), vars.sharesMinted, "user's balance should equal shares minted");

        vars.balanceAfter.balance0 = USDC.balanceOf(user);
        assertTrue(vars.balanceAfter.balance0 < vars.balanceBefore.balance0, "USDC balance should have decreased");
        assertTrue(
            vars.balanceBefore.balance0 - vars.balanceAfter.balance0 <= amount0Desired,
            "USDC spent should not exceed desired amount"
        );

        (uint128 poolLiquidity,,,,) =
            pool.positions(keccak256(abi.encodePacked(address(handler), vars.tickLower, vars.tickUpper)));
        assertEq(poolLiquidity, info.totalLiquidity, "Pool liquidity should match total liquidity in handler");

        vm.stopPrank();

        return vars.sharesMinted;
    }

    function testOpenLongPosition() public {
        // Setup
        uint256 sharesMinted = addLiquidityForLong();

        // Get current price and tick
        (uint160 sqrtPriceX96, int24 currentTick,,,,,) = pool.slot0();

        // Calculate tick range for the long position
        int24 tickSpacing = pool.tickSpacing();
        int24 tickUpper = ((currentTick / tickSpacing) * tickSpacing) - tickSpacing;
        int24 tickLower = tickUpper - 1 * tickSpacing;

        // Prepare PerpTicks array
        PerpOTM.PerpTicks[] memory perpTicks = new PerpOTM.PerpTicks[](1);
        perpTicks[0] = PerpOTM.PerpTicks({
            _handler: IHandler(address(handler)),
            pool: IUniswapV3Pool(address(pool)),
            hook: address(mockHook),
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidityToUse: sharesMinted
        });

        // Prepare mint parameters
        PerpOTM.MintParams memory params = PerpOTM.MintParams({
            perpTicks: perpTicks,
            tickLower: tickLower,
            tickUpper: tickUpper,
            isLong: true,
            initialFee: 20e6, // Example initial fee in USDC (20 USDC)
            maxCostAllowance: 400e6 // Example max cost allowance in USDC (400 USDC)
        });

        // Mint USDC to trader and approve PerpOTM contract
        vm.startPrank(trader);
        USDC.mint(trader, 400e6);
        USDC.approve(address(perpOTM), 400e6);

        // Record balances before minting
        uint256 traderUsdcBalanceBefore = USDC.balanceOf(trader);
        uint256 contractUsdcBalanceBefore = USDC.balanceOf(address(perpOTM));
        uint256 feeReceiverUsdcBalanceBefore = USDC.balanceOf(feeReceiver);

        // Mint the position
        perpOTM.mint(params);

        // Record balances after minting
        uint256 traderUsdcBalanceAfter = USDC.balanceOf(trader);
        uint256 contractUsdcBalanceAfter = USDC.balanceOf(address(perpOTM));
        uint256 feeReceiverUsdcBalanceAfter = USDC.balanceOf(feeReceiver);

        // Verify the position was created
        uint256 tokenId = perpOTM.positionIds();
        assertTrue(tokenId > 0, "Position should be created");

        // Verify USDC transfer (note: actual amount will depend on pricing logic)
        assertTrue(traderUsdcBalanceBefore > traderUsdcBalanceAfter, "Trader should spend some USDC");
        assertTrue(contractUsdcBalanceAfter > contractUsdcBalanceBefore, "Contract should receive some USDC");

        PerpPositionDataVars memory positionData;

        // Verify position data
        (
            positionData.perpTickArrayLen,
            positionData.positionTickLower,
            positionData.positionTickUpper,
            positionData.isLong,
            positionData.remainingFees,
            positionData.lastFeeAccrued
        ) = perpOTM.perpData(tokenId);

        assertEq(positionData.perpTickArrayLen, 1, "Incorrect number of perp ticks");
        assertEq(positionData.positionTickLower, tickLower, "Incorrect lower tick");
        assertEq(positionData.positionTickUpper, tickUpper, "Incorrect upper tick");
        assertTrue(positionData.isLong, "Position should be long");
        assertTrue(positionData.remainingFees > 0, "Remaining fees should be greater than 0");
        assertTrue(positionData.lastFeeAccrued > 0, "Last fee accrued timestamp should be set");

        // Verify ERC721 ownership
        assertEq(perpOTM.ownerOf(tokenId), trader, "Trader should own the NFT");

        // Verify fee receiver got the donation
        assertTrue(feeReceiverUsdcBalanceAfter > feeReceiverUsdcBalanceBefore, "Fee receiver should receive a donation");

        vm.stopPrank();
    }

    function testOpenShortPosition() public {
        // Setup
        uint256 sharesMinted = addLiquidityForShort();

        // Get current price and tick
        (uint160 sqrtPriceX96, int24 currentTick,,,,,) = pool.slot0();

        // Calculate tick range for the short position
        int24 tickSpacing = pool.tickSpacing();
        int24 tickLower = ((currentTick / tickSpacing) * tickSpacing) + tickSpacing;
        int24 tickUpper = tickLower + 1 * tickSpacing;

        // Prepare PerpTicks array
        PerpOTM.PerpTicks[] memory perpTicks = new PerpOTM.PerpTicks[](1);
        perpTicks[0] = PerpOTM.PerpTicks({
            _handler: IHandler(address(handler)),
            pool: IUniswapV3Pool(address(pool)),
            hook: address(mockHook),
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidityToUse: sharesMinted
        });

        // Prepare mint parameters
        PerpOTM.MintParams memory params = PerpOTM.MintParams({
            perpTicks: perpTicks,
            tickLower: tickLower,
            tickUpper: tickUpper,
            isLong: false,
            initialFee: 10e6, // Example initial fee in USDC (10 USDC)
            maxCostAllowance: 200e6 // Example max cost allowance in USDC (200 USDC)
        });

        // Mint USDC to trader and approve PerpOTM contract
        vm.startPrank(trader);
        USDC.mint(trader, 200e6);
        USDC.approve(address(perpOTM), 200e6);

        // Record balances before minting
        uint256 traderUsdcBalanceBefore = USDC.balanceOf(trader);
        uint256 contractUsdcBalanceBefore = USDC.balanceOf(address(perpOTM));
        uint256 feeReceiverUsdcBalanceBefore = USDC.balanceOf(feeReceiver);

        // Mint the position
        perpOTM.mint(params);

        // Record balances after minting
        uint256 traderUsdcBalanceAfter = USDC.balanceOf(trader);
        uint256 contractUsdcBalanceAfter = USDC.balanceOf(address(perpOTM));
        uint256 feeReceiverUsdcBalanceAfter = USDC.balanceOf(feeReceiver);

        // Verify the position was created
        uint256 tokenId = perpOTM.positionIds();
        assertTrue(tokenId > 0, "Position should be created");

        // Verify USDC transfer (note: actual amount will depend on pricing logic)
        assertTrue(traderUsdcBalanceBefore > traderUsdcBalanceAfter, "Trader should spend some USDC");
        assertTrue(contractUsdcBalanceAfter > contractUsdcBalanceBefore, "Contract should receive some USDC");

        PerpPositionDataVars memory positionData;

        // Verify position data
        (
            positionData.perpTickArrayLen,
            positionData.positionTickLower,
            positionData.positionTickUpper,
            positionData.isLong,
            positionData.remainingFees,
            positionData.lastFeeAccrued
        ) = perpOTM.perpData(tokenId);

        assertEq(positionData.perpTickArrayLen, 1, "Incorrect number of perp ticks");
        assertEq(positionData.positionTickLower, tickLower, "Incorrect lower tick");
        assertEq(positionData.positionTickUpper, tickUpper, "Incorrect upper tick");
        assertFalse(positionData.isLong, "Position should be short");
        assertTrue(positionData.remainingFees > 0, "Remaining fees should be greater than 0");
        assertTrue(positionData.lastFeeAccrued > 0, "Last fee accrued timestamp should be set");

        // Verify ERC721 ownership
        assertEq(perpOTM.ownerOf(tokenId), trader, "Trader should own the NFT");

        // Verify fee receiver got the donation
        assertTrue(feeReceiverUsdcBalanceAfter > feeReceiverUsdcBalanceBefore, "Fee receiver should receive a donation");

        vm.stopPrank();
    }

    function testAccrueFeesLong() public {
        testOpenLongPosition();

        vm.warp(block.timestamp + 1 days);

        uint256 tokenId = perpOTM.positionIds();

        // Get the initial position data
        PerpPositionDataVars memory initialPositionData;
        (
            initialPositionData.perpTickArrayLen,
            initialPositionData.positionTickLower,
            initialPositionData.positionTickUpper,
            initialPositionData.isLong,
            initialPositionData.remainingFees,
            initialPositionData.lastFeeAccrued
        ) = perpOTM.perpData(tokenId);

        (uint256 feesAccrued, uint256 remainingFees) = perpOTM.accrueFees(tokenId);

        // Get the updated position data
        PerpPositionDataVars memory updatedPositionData;
        (
            updatedPositionData.perpTickArrayLen,
            updatedPositionData.positionTickLower,
            updatedPositionData.positionTickUpper,
            updatedPositionData.isLong,
            updatedPositionData.remainingFees,
            updatedPositionData.lastFeeAccrued
        ) = perpOTM.perpData(tokenId);

        // Ensure fees were accrued
        assertTrue(feesAccrued > 0, "Fees should have accrued");

        // Check that remaining fees have decreased
        assertTrue(remainingFees < initialPositionData.remainingFees, "Remaining fees should have decreased");

        // Verify the exact decrement
        assertEq(
            remainingFees, initialPositionData.remainingFees - feesAccrued, "Remaining fees not decremented correctly"
        );

        // Verify that the position data was updated correctly
        assertEq(updatedPositionData.remainingFees, remainingFees, "Position data not updated correctly");
        assertTrue(
            updatedPositionData.lastFeeAccrued > initialPositionData.lastFeeAccrued,
            "Last fee accrued timestamp should be updated"
        );
    }

    function testAccrueFeesShort() public {
        testOpenShortPosition();

        vm.warp(block.timestamp + 1 days);

        uint256 tokenId = perpOTM.positionIds();

        // Get the initial position data
        PerpPositionDataVars memory initialPositionData;
        (
            initialPositionData.perpTickArrayLen,
            initialPositionData.positionTickLower,
            initialPositionData.positionTickUpper,
            initialPositionData.isLong,
            initialPositionData.remainingFees,
            initialPositionData.lastFeeAccrued
        ) = perpOTM.perpData(tokenId);

        (uint256 feesAccrued, uint256 remainingFees) = perpOTM.accrueFees(tokenId);

        // Get the updated position data
        PerpPositionDataVars memory updatedPositionData;
        (
            updatedPositionData.perpTickArrayLen,
            updatedPositionData.positionTickLower,
            updatedPositionData.positionTickUpper,
            updatedPositionData.isLong,
            updatedPositionData.remainingFees,
            updatedPositionData.lastFeeAccrued
        ) = perpOTM.perpData(tokenId);

        // Ensure fees were accrued
        assertTrue(feesAccrued > 0, "Fees should have accrued");

        // Check that remaining fees have decreased
        assertTrue(remainingFees < initialPositionData.remainingFees, "Remaining fees should have decreased");

        // Verify the exact decrement
        assertEq(
            remainingFees, initialPositionData.remainingFees - feesAccrued, "Remaining fees not decremented correctly"
        );

        // Verify that the position data was updated correctly
        assertEq(updatedPositionData.remainingFees, remainingFees, "Position data not updated correctly");
        assertTrue(
            updatedPositionData.lastFeeAccrued > initialPositionData.lastFeeAccrued,
            "Last fee accrued timestamp should be updated"
        );
    }

    function testExerciseLong() public {
        testOpenLongPosition();

        uint256 tokenId = perpOTM.positionIds();

        // Simulate time passing
        vm.warp(block.timestamp + 1 days);

        // Perform a swap to increase the price
        uint256 swapAmount = 50000e6; // 50,000 USDC
        vm.startPrank(address(this));
        USDC.mint(address(this), swapAmount);
        USDC.approve(address(pool), swapAmount);

        pool.swap(
            address(0xD3AD),
            true,
            int256(swapAmount),
            TickMath.MIN_SQRT_RATIO + 1, // Swap to the upper tick
            abi.encode(address(this))
        );

        vm.stopPrank();

        // Record balances before exercise
        uint256 traderUsdcBalanceBefore = USDC.balanceOf(trader);
        uint256 contractUsdcBalanceBefore = USDC.balanceOf(address(perpOTM));
        uint256 totalAmountWithdrawnInQuoteBefore = perpOTM.totalAmountWithdrawnInQuoteMap(tokenId);
        uint256 amountsInQuotePerPerpTickBefore = perpOTM.amountsInQuotePerPerpTickMap(tokenId, 0);

        // Exercise the position
        PerpOTM.ExerciseOptionParams memory params = PerpOTM.ExerciseOptionParams({
            positionId: tokenId,
            swapper: new ISwapper[](1),
            swapData: new bytes[](1),
            liquidityToExercise: new uint256[](1)
        });

        // Get the liquidity amount to exercise
        (,,,,, uint256 liquidityToUse) = perpOTM.perpTickMap(tokenId, 0);
        params.liquidityToExercise[0] = liquidityToUse;
        params.swapper[0] = ISwapper(address(this));
        params.swapData[0] = abi.encode("");

        vm.prank(trader);
        perpOTM.exercise(params);

        // Record balances after exercise
        uint256 traderUsdcBalanceAfter = USDC.balanceOf(trader);
        uint256 contractUsdcBalanceAfter = USDC.balanceOf(address(perpOTM));

        // Verify that the trader received USDC (profit)
        assertTrue(traderUsdcBalanceAfter > traderUsdcBalanceBefore, "Trader should receive USDC as profit");

        // Verify that the contract's USDC balance decreased
        assertTrue(contractUsdcBalanceAfter < contractUsdcBalanceBefore, "Contract should pay out USDC");

        // Verify that the totalAmountWithdrawnInQuote reduced
        uint256 totalAmountWithdrawnInQuoteAfter = perpOTM.totalAmountWithdrawnInQuoteMap(tokenId);
        assertTrue(
            totalAmountWithdrawnInQuoteAfter < totalAmountWithdrawnInQuoteBefore,
            "totalAmountWithdrawnInQuote should decrease after exercise"
        );

        // Verify that amountsInQuotePerPerpTickMap got reduced
        uint256 amountsInQuotePerPerpTickAfter = perpOTM.amountsInQuotePerPerpTickMap(tokenId, 0);
        assertTrue(
            amountsInQuotePerPerpTickAfter < amountsInQuotePerPerpTickBefore,
            "amountsInQuotePerPerpTickMap should decrease after exercise"
        );

        console.log("Profit:", traderUsdcBalanceAfter - traderUsdcBalanceBefore);
    }

    function testExerciseShort() public {
        testOpenShortPosition();

        uint256 tokenId = perpOTM.positionIds();

        // Simulate time passing
        vm.warp(block.timestamp + 1 days);

        // Perform a swap to increase the price
        uint256 swapAmount = 25 ether; // 50,000 USDC
        vm.startPrank(address(this));
        ETH.mint(address(this), swapAmount);
        ETH.approve(address(pool), swapAmount);

        pool.swap(
            address(0xD3AD),
            false,
            int256(swapAmount),
            TickMath.MAX_SQRT_RATIO - 1, // Swap to the upper tick
            abi.encode(address(this))
        );

        vm.stopPrank();

        // Record balances before exercise
        uint256 traderEthBalanceBefore = ETH.balanceOf(trader);
        uint256 contractUSDCBalanceBefore = USDC.balanceOf(address(perpOTM));
        uint256 totalAmountWithdrawnInQuoteBefore = perpOTM.totalAmountWithdrawnInQuoteMap(tokenId);
        uint256 amountsInQuotePerPerpTickBefore = perpOTM.amountsInQuotePerPerpTickMap(tokenId, 0);

        // Exercise the position
        PerpOTM.ExerciseOptionParams memory params = PerpOTM.ExerciseOptionParams({
            positionId: tokenId,
            swapper: new ISwapper[](1),
            swapData: new bytes[](1),
            liquidityToExercise: new uint256[](1)
        });

        // Get the liquidity amount to exercise
        (,,,,, uint256 liquidityToUse) = perpOTM.perpTickMap(tokenId, 0);
        params.liquidityToExercise[0] = liquidityToUse;
        params.swapper[0] = ISwapper(address(this));
        params.swapData[0] = abi.encode("");

        vm.prank(trader);
        perpOTM.exercise(params);

        // Record balances after exercise
        uint256 traderEthBalanceAfter = ETH.balanceOf(trader);
        uint256 contractUSDCBalanceAfter = USDC.balanceOf(address(perpOTM));

        // Verify that the trader received ETH (profit)
        assertTrue(traderEthBalanceAfter > traderEthBalanceBefore, "Trader should receive ETH as profit");

        // Verify that the contract's USDC balance decreased
        assertTrue(contractUSDCBalanceAfter < contractUSDCBalanceBefore, "Contract should pay out USDC");

        // Verify that the totalAmountWithdrawnInQuote reduced
        uint256 totalAmountWithdrawnInQuoteAfter = perpOTM.totalAmountWithdrawnInQuoteMap(tokenId);
        assertTrue(
            totalAmountWithdrawnInQuoteAfter < totalAmountWithdrawnInQuoteBefore,
            "totalAmountWithdrawnInQuote should decrease after exercise"
        );

        // Verify that amountsInQuotePerPerpTickMap got reduced
        uint256 amountsInQuotePerPerpTickAfter = perpOTM.amountsInQuotePerPerpTickMap(tokenId, 0);
        assertTrue(
            amountsInQuotePerPerpTickAfter < amountsInQuotePerPerpTickBefore,
            "amountsInQuotePerPerpTickMap should decrease after exercise"
        );

        console.log("Profit:", traderEthBalanceAfter - traderEthBalanceBefore);
    }

    function testLiquidateLongWithProfit() public {
        testOpenLongPosition();

        uint256 tokenId = perpOTM.positionIds();
        address trader = perpOTM.ownerOf(tokenId);

        // Record trader's USDC balance before liquidation
        uint256 traderUSDCBalanceBefore = USDC.balanceOf(trader);

        // Simulate time passing
        vm.warp(block.timestamp + 100 days);

        // Perform a swap to increase the price
        uint256 swapAmount = 50000e6; // 50,000 USDC
        vm.startPrank(address(this));
        USDC.mint(address(this), swapAmount);
        USDC.approve(address(pool), swapAmount);

        pool.swap(
            address(0xD3AD),
            true,
            int256(swapAmount),
            TickMath.MIN_SQRT_RATIO + 1, // Swap to the upper tick
            abi.encode(address(this))
        );

        vm.stopPrank();

        // Liquidate the position
        PerpOTM.LiquidateParams memory params = PerpOTM.LiquidateParams({
            positionId: tokenId,
            swapper: new ISwapper[](1),
            swapData: new bytes[](1),
            liquidityToExercise: new uint256[](1)
        });

        // Get the liquidity amount to liquidate
        (,,,,, uint256 liquidityToUse) = perpOTM.perpTickMap(tokenId, 0);
        params.liquidityToExercise[0] = liquidityToUse;
        params.swapper[0] = ISwapper(address(this));
        params.swapData[0] = abi.encode("");

        perpOTM.liquidate(params);

        // Record trader's USDC balance after liquidation
        uint256 traderUSDCBalanceAfter = USDC.balanceOf(trader);

        // Verify that the trader received USDC (profit)
        uint256 profit = traderUSDCBalanceAfter - traderUSDCBalanceBefore;
        assertTrue(profit > 0, "Trader should receive USDC as profit");
        console.log("Profit sent to trader:", profit);

        // Verify that the position has been liquidated
        (uint128 perpTickArrayLen,,,,,) = perpOTM.perpData(tokenId);
        assertEq(perpTickArrayLen, 1, "Position should still exist after liquidation");

        // Verify that all liquidity has been removed
        (,,,,, uint256 remainingLiquidity) = perpOTM.perpTickMap(tokenId, 0);
        assertEq(remainingLiquidity, 0, "All liquidity should be removed after liquidation");

        // Verify that totalAmountWithdrawnInQuote is zero
        uint256 totalAmountWithdrawnInQuote = perpOTM.totalAmountWithdrawnInQuoteMap(tokenId);
        assertEq(totalAmountWithdrawnInQuote, 0, "totalAmountWithdrawnInQuote should be zero after liquidation");

        // Verify that amountsInQuotePerPerpTickMap is zero
        uint256 amountsInQuotePerPerpTick = perpOTM.amountsInQuotePerPerpTickMap(tokenId, 0);
        assertEq(amountsInQuotePerPerpTick, 0, "amountsInQuotePerPerpTickMap should be zero after liquidation");
    }

    function testLiquidateLong() public {
        testOpenLongPosition();

        uint256 tokenId = perpOTM.positionIds();

        // Simulate time passing
        vm.warp(block.timestamp + 100 days);

        // Liquidate the position
        PerpOTM.LiquidateParams memory params = PerpOTM.LiquidateParams({
            positionId: tokenId,
            swapper: new ISwapper[](1),
            swapData: new bytes[](1),
            liquidityToExercise: new uint256[](1)
        });

        // Get the liquidity amount to liquidate
        (,,,,, uint256 liquidityToUse) = perpOTM.perpTickMap(tokenId, 0);
        params.liquidityToExercise[0] = liquidityToUse;
        params.swapper[0] = ISwapper(address(this));
        params.swapData[0] = abi.encode("");

        perpOTM.liquidate(params);

        // Verify that the position has been liquidated
        (uint128 perpTickArrayLen,,,,,) = perpOTM.perpData(tokenId);
        assertEq(perpTickArrayLen, 1, "Position should still exist after liquidation");

        // Verify that all liquidity has been removed
        (,,,,, uint256 remainingLiquidity) = perpOTM.perpTickMap(tokenId, 0);
        assertEq(remainingLiquidity, 0, "All liquidity should be removed after liquidation");

        // Verify that totalAmountWithdrawnInQuote is zero
        uint256 totalAmountWithdrawnInQuote = perpOTM.totalAmountWithdrawnInQuoteMap(tokenId);
        assertEq(totalAmountWithdrawnInQuote, 0, "totalAmountWithdrawnInQuote should be zero after liquidation");

        // Verify that amountsInQuotePerPerpTickMap is zero
        uint256 amountsInQuotePerPerpTick = perpOTM.amountsInQuotePerPerpTickMap(tokenId, 0);
        assertEq(amountsInQuotePerPerpTick, 0, "amountsInQuotePerPerpTickMap should be zero after liquidation");
    }

    function testLiquidateShortWithProfit() public {
        testOpenShortPosition();

        uint256 tokenId = perpOTM.positionIds();
        address trader = perpOTM.ownerOf(tokenId);

        // Record trader's ETH balance before liquidation
        uint256 traderETHBalanceBefore = ETH.balanceOf(trader);

        // Simulate time passing
        vm.warp(block.timestamp + 100 days);

        // Perform a swap to increase the price
        uint256 swapAmount = 25 ether; // 50,000 ETH
        vm.startPrank(address(this));
        ETH.mint(address(this), swapAmount);
        ETH.approve(address(pool), swapAmount);

        pool.swap(
            address(0xD3AD),
            false,
            int256(swapAmount),
            TickMath.MAX_SQRT_RATIO - 1, // Swap to the upper tick
            abi.encode(address(this))
        );

        vm.stopPrank();

        // Liquidate the position
        PerpOTM.LiquidateParams memory params = PerpOTM.LiquidateParams({
            positionId: tokenId,
            swapper: new ISwapper[](1),
            swapData: new bytes[](1),
            liquidityToExercise: new uint256[](1)
        });

        // Get the liquidity amount to liquidate
        (,,,,, uint256 liquidityToUse) = perpOTM.perpTickMap(tokenId, 0);
        params.liquidityToExercise[0] = liquidityToUse;
        params.swapper[0] = ISwapper(address(this));
        params.swapData[0] = abi.encode("");

        perpOTM.liquidate(params);

        // Record trader's ETH balance after liquidation
        uint256 traderETHBalanceAfter = ETH.balanceOf(trader);

        // Verify that the trader received ETH (profit)
        uint256 profit = traderETHBalanceAfter - traderETHBalanceBefore;
        assertTrue(profit > 0, "Trader should receive ETH as profit");
        console.log("Profit sent to trader:", profit);

        // Verify that the position has been liquidated
        (uint128 perpTickArrayLen,,,,,) = perpOTM.perpData(tokenId);
        assertEq(perpTickArrayLen, 1, "Position should still exist after liquidation");

        // Verify that all liquidity has been removed
        (,,,,, uint256 remainingLiquidity) = perpOTM.perpTickMap(tokenId, 0);
        assertEq(remainingLiquidity, 0, "All liquidity should be removed after liquidation");

        // Verify that totalAmountWithdrawnInQuote is zero
        uint256 totalAmountWithdrawnInQuote = perpOTM.totalAmountWithdrawnInQuoteMap(tokenId);
        assertEq(totalAmountWithdrawnInQuote, 0, "totalAmountWithdrawnInQuote should be zero after liquidation");

        // Verify that amountsInQuotePerPerpTickMap is zero
        uint256 amountsInQuotePerPerpTick = perpOTM.amountsInQuotePerPerpTickMap(tokenId, 0);
        assertEq(amountsInQuotePerPerpTick, 0, "amountsInQuotePerPerpTickMap should be zero after liquidation");
    }

    function testLiquidateShort() public {
        testOpenShortPosition();

        uint256 tokenId = perpOTM.positionIds();

        // Simulate time passing
        vm.warp(block.timestamp + 100 days);

        // Liquidate the position
        PerpOTM.LiquidateParams memory params = PerpOTM.LiquidateParams({
            positionId: tokenId,
            swapper: new ISwapper[](1),
            swapData: new bytes[](1),
            liquidityToExercise: new uint256[](1)
        });

        // Get the liquidity amount to liquidate
        (,,,,, uint256 liquidityToUse) = perpOTM.perpTickMap(tokenId, 0);
        params.liquidityToExercise[0] = liquidityToUse;
        params.swapper[0] = ISwapper(address(this));
        params.swapData[0] = abi.encode("");

        perpOTM.liquidate(params);

        // Verify that the position has been liquidated
        (uint128 perpTickArrayLen,,,,,) = perpOTM.perpData(tokenId);
        assertEq(perpTickArrayLen, 1, "Position should still exist after liquidation");

        // Verify that all liquidity has been removed
        (,,,,, uint256 remainingLiquidity) = perpOTM.perpTickMap(tokenId, 0);
        assertEq(remainingLiquidity, 0, "All liquidity should be removed after liquidation");

        // Verify that totalAmountWithdrawnInQuote is zero
        uint256 totalAmountWithdrawnInQuote = perpOTM.totalAmountWithdrawnInQuoteMap(tokenId);
        assertEq(totalAmountWithdrawnInQuote, 0, "totalAmountWithdrawnInQuote should be zero after liquidation");

        // Verify that amountsInQuotePerPerpTickMap is zero
        uint256 amountsInQuotePerPerpTick = perpOTM.amountsInQuotePerPerpTickMap(tokenId, 0);
        assertEq(amountsInQuotePerPerpTick, 0, "amountsInQuotePerPerpTickMap should be zero after liquidation");
    }

    function testUpdateFees() public {
        testOpenLongPosition();

        uint256 tokenId = perpOTM.positionIds();

        // Get initial remaining fees
        (,,,, uint128 initialRemainingFees,) = perpOTM.perpData(tokenId);

        // Test adding fees
        uint128 feesToAdd = 10e6;
        vm.prank(trader);
        perpOTM.updateFees(tokenId, int128(feesToAdd));

        // Verify that the fees have been added
        (,,,, uint128 updatedRemainingFees,) = perpOTM.perpData(tokenId);
        assertEq(updatedRemainingFees, initialRemainingFees + feesToAdd, "Fees should be added correctly");

        uint128 feesToRemove = 5e6;
        vm.prank(trader);
        perpOTM.updateFees(tokenId, -int128(feesToRemove));

        // Verify that the fees have been removed
        (,,,, uint128 finalRemainingFees,) = perpOTM.perpData(tokenId);
        assertEq(finalRemainingFees, updatedRemainingFees - feesToRemove, "Fees should be removed correctly");

        // Test removing more fees than available
        uint128 excessiveFeesToRemove = finalRemainingFees + 1e6;
        vm.prank(trader);
        vm.expectRevert(PerpOTM.NotEnoughFees.selector);
        perpOTM.updateFees(tokenId, -int128(excessiveFeesToRemove));

        // Verify that the fees remain unchanged after failed removal
        (,,,, uint128 unchangedRemainingFees,) = perpOTM.perpData(tokenId);
        assertEq(unchangedRemainingFees, finalRemainingFees, "Fees should remain unchanged after failed removal");
    }

    // Add this function to handle the swap callback
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external {
        if (amount0Delta > 0) {
            USDC.transfer(msg.sender, uint256(amount0Delta));
        } else if (amount1Delta > 0) {
            ETH.transfer(msg.sender, uint256(amount1Delta));
        }
    }

    function onSwapReceived(address _tokenIn, address _tokenOut, uint256 _amountIn, bytes calldata _swapData)
        public
        returns (uint256 amountOut)
    {
        if (_tokenIn == address(USDC)) {
            USDC.approve(address(pool), _amountIn);
            pool.swap(msg.sender, true, int256(_amountIn), TickMath.MIN_SQRT_RATIO + 1, abi.encode(address(this)));
        } else if (_tokenIn == address(ETH)) {
            ETH.approve(address(pool), _amountIn);
            pool.swap(msg.sender, false, int256(_amountIn), TickMath.MAX_SQRT_RATIO - 1, abi.encode(address(this)));
        }
    }
}
