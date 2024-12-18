// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.0 <0.9.0;

import {IPositionManager} from "../../interfaces/IPositionManager.sol";
import {IHandler} from "../../interfaces/IHandler.sol";
import {IPerpOTMPricing} from "../../interfaces/apps/perpetuals/IPerpOTMPricing.sol";
import {ISwapper} from "../../interfaces/ISwapper.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

import {ERC721} from "../../libraries/tokens/ERC721.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {Multicall} from "openzeppelin-contracts/contracts/utils/Multicall.sol";

import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {LiquidityAmounts} from "v3-periphery/libraries/LiquidityAmounts.sol";
import {TickMath} from "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v3-core/contracts/libraries/FullMath.sol";

contract PerpOTM is ERC721, Ownable, ReentrancyGuard, Multicall {
    using SafeERC20 for ERC20;
    using TickMath for int24;

    struct PerpPositionData {
        uint128 perpTickArrayLen;
        int24 tickLower;
        int24 tickUpper;
        bool isLong;
        uint128 remainingFees;
        uint64 lastFeeAccrued;
    }

    struct PerpTicks {
        IHandler _handler;
        IUniswapV3Pool pool;
        address hook;
        int24 tickLower;
        int24 tickUpper;
        uint256 liquidityToUse;
    }

    struct MintParams {
        PerpTicks[] perpTicks;
        int24 tickLower;
        int24 tickUpper;
        bool isLong;
        uint128 initialFee;
        uint128 maxCostAllowance;
    }

    struct ExerciseOptionParams {
        uint256 positionId;
        ISwapper[] swapper;
        bytes[] swapData;
        uint256[] liquidityToExercise;
    }

    struct LiquidateParams {
        uint256 positionId;
        ISwapper[] swapper;
        bytes[] swapData;
        uint256[] liquidityToExercise;
    }

    // events
    event LogMint(
        MintParams params,
        uint256 positionId,
        uint256 openFees,
        address context,
        uint256 assetsWithdrawnInQuote,
        uint256 lastfeeAccrued
    );
    event LogUpdateFees(uint256 positionId, address context, int128 feeDelta);
    event LogExercise(ExerciseOptionParams params, address context, uint256 totalProfit, uint256 amountReduced);
    event LogLiquidate(LiquidateParams params);
    event LogFeesAccured(uint256 positionId, uint256 feesAccrued, uint256 lastAccrued, uint256 feesRemaining);

    // errors
    error InvalidTickLength();
    error InvalidStrikeTick();
    error PoolNotApproved();
    error MaxCostAllowanceExceeded();
    error NotOwnerOrDelegate();
    error NotEnoughAfterSwap();
    error RemainingFeesNotZero();
    error NotEnoughFees();

    uint256 public positionIds;

    IPositionManager public immutable positionManager;
    IUniswapV3Pool public immutable primePool;
    IPerpOTMPricing public immutable pricing;
    address public immutable baseAsset;
    address public immutable quoteAsset;
    uint8 public immutable baseAssetDecimals;
    uint8 public immutable quoteAssetDecimals;

    mapping(uint256 => PerpPositionData) public perpData;
    mapping(uint256 => PerpTicks[]) public perpTickMap;
    mapping(uint256 => uint256) public totalAmountWithdrawnInQuoteMap;
    mapping(uint256 => uint256[]) public amountsInQuotePerPerpTickMap;
    mapping(address => bool) public approvedPools;

    constructor(address _positionManager, address _primePool, address _pricing, address _baseAsset, address _quoteAsset)
        Ownable(msg.sender)
    {
        positionManager = IPositionManager(_positionManager);
        primePool = IUniswapV3Pool(_primePool);
        pricing = IPerpOTMPricing(_pricing);
        baseAsset = _baseAsset;
        quoteAsset = _quoteAsset;
        baseAssetDecimals = ERC20(_baseAsset).decimals();
        quoteAssetDecimals = ERC20(_quoteAsset).decimals();
    }

    function name() public view override returns (string memory) {
        return "MZ Perp OTM";
    }

    function symbol() public view override returns (string memory) {
        return "MZ-PERP-OTM-V1";
    }

    function tokenURI(uint256 id) public view override returns (string memory) {
        return "";
    }

    function mint(MintParams calldata _params) external nonReentrant {
        positionIds += 1;

        if (_params.perpTicks.length == 0 || _params.perpTicks.length > 20) revert InvalidTickLength();

        uint256[] memory amountsPerPerpTick = new uint256[](_params.perpTicks.length);

        uint256 totalAssetWithdrawnInQuote;

        bool isQuoteAsset0 = primePool.token0() == quoteAsset ? true : false;

        PerpTicks memory perpTick;

        for (uint256 i; i < _params.perpTicks.length; i++) {
            perpTick = _params.perpTicks[i];
            if (_params.isLong ? _params.tickUpper != perpTick.tickUpper : _params.tickLower != perpTick.tickLower) {
                revert InvalidStrikeTick();
            }

            perpTickMap[positionIds].push(
                PerpTicks({
                    _handler: perpTick._handler,
                    pool: perpTick.pool,
                    hook: perpTick.hook,
                    tickLower: perpTick.tickLower,
                    tickUpper: perpTick.tickUpper,
                    liquidityToUse: perpTick.liquidityToUse
                })
            );

            //TODO: add pool approval
            // if (!approvedPools[address(perpTick.pool)]) {
            //     revert PoolNotApproved();
            // }

            bytes memory usePositionData = abi.encode(
                perpTick.pool,
                perpTick.hook,
                perpTick.tickLower,
                perpTick.tickUpper,
                perpTick.liquidityToUse,
                abi.encode(address(this), _params.isLong, perpTick.pool, perpTick.tickLower, perpTick.tickUpper)
            );

            (address[] memory tokens, uint256[] memory amounts,) =
                positionManager.usePosition(perpTick._handler, usePositionData);

            if (tokens[0] == baseAsset && tokens[1] == quoteAsset) {
                if (_params.isLong) {
                    require(amounts[0] > 0 && amounts[1] == 0);
                    amountsPerPerpTick[i] = LiquidityAmounts.getAmount1ForLiquidity(
                        perpTick.tickLower.getSqrtRatioAtTick(),
                        perpTick.tickUpper.getSqrtRatioAtTick(),
                        uint128(perpTick.liquidityToUse)
                    );
                    totalAssetWithdrawnInQuote += amountsPerPerpTick[i];
                } else {
                    require(amounts[0] == 0 && amounts[1] > 0);
                    totalAssetWithdrawnInQuote += amounts[1];
                    amountsPerPerpTick[i] = amounts[1];
                }
            } else {
                if (_params.isLong) {
                    require(amounts[0] == 0 && amounts[1] > 0);
                    amountsPerPerpTick[i] = LiquidityAmounts.getAmount0ForLiquidity(
                        perpTick.tickLower.getSqrtRatioAtTick(),
                        perpTick.tickUpper.getSqrtRatioAtTick(),
                        uint128(perpTick.liquidityToUse)
                    );
                    totalAssetWithdrawnInQuote += amountsPerPerpTick[i];
                } else {
                    require(amounts[0] > 0 && amounts[1] == 0);
                    totalAssetWithdrawnInQuote += amounts[0];
                    amountsPerPerpTick[i] = amounts[0];
                }
            }
        }

        totalAmountWithdrawnInQuoteMap[positionIds] = totalAssetWithdrawnInQuote;
        amountsInQuotePerPerpTickMap[positionIds] = amountsPerPerpTick;

        // TODO: calculate opening fees and initial fees

        uint256 openFees = pricing.onOpenPositionPrice(totalAssetWithdrawnInQuote, _params.isLong);

        // TODO: enforce check on initial fee

        if (openFees + _params.initialFee > _params.maxCostAllowance) {
            revert MaxCostAllowanceExceeded();
        }

        ERC20(quoteAsset).transferFrom(msg.sender, address(this), openFees + _params.initialFee);
        ERC20(quoteAsset).approve(address(positionManager), openFees);

        for (uint256 i; i < _params.perpTicks.length; i++) {
            perpTick = _params.perpTicks[i];
            uint256 feesAmountEarned = (amountsPerPerpTick[i] * openFees) / totalAssetWithdrawnInQuote;

            bytes memory donatePositionData = abi.encode(
                perpTick.pool,
                perpTick.hook,
                perpTick.tickLower,
                perpTick.tickUpper,
                isQuoteAsset0 ? feesAmountEarned : 0,
                isQuoteAsset0 ? 0 : feesAmountEarned,
                abi.encode("")
            );
            positionManager.donateToPosition(perpTick._handler, donatePositionData);
        }

        perpData[positionIds] = PerpPositionData({
            perpTickArrayLen: uint128(_params.perpTicks.length),
            tickLower: _params.tickLower,
            tickUpper: _params.tickUpper,
            isLong: _params.isLong,
            remainingFees: _params.initialFee,
            lastFeeAccrued: uint64(block.timestamp)
        });

        _safeMint(msg.sender, positionIds);

        emit LogMint(_params, positionIds, openFees, msg.sender, totalAssetWithdrawnInQuote, block.timestamp);
    }

    function updateFees(uint256 positionId, int128 feesDelta) external nonReentrant {
        if (ownerOf(positionId) != msg.sender) revert NotOwnerOrDelegate();
        PerpPositionData storage data = perpData[positionId];

        if (feesDelta > 0) {
            ERC20(quoteAsset).transferFrom(msg.sender, address(this), uint128(feesDelta));
            data.remainingFees += uint128((feesDelta));
        } else {
            uint256 feesToBeAccrued = calculateFeesAccruedSinceLastUpdate(
                totalAmountWithdrawnInQuoteMap[positionId], data.isLong, data.lastFeeAccrued
            );
            if (data.remainingFees > feesToBeAccrued + uint128(-(feesDelta))) {
                data.remainingFees -= uint128(-(feesDelta));
                ERC20(quoteAsset).transfer(msg.sender, uint128(-feesDelta));
            } else {
                revert NotEnoughFees();
            }
        }

        emit LogUpdateFees(positionId, msg.sender, feesDelta);
    }

    struct AssetCache {
        bool isAmount0;
        bool isQuoteAsset0;
        ERC20 assetToUse;
        ERC20 assetToGet;
        uint256 amountToReduce;
        uint256 totalProfit;
    }

    function exercise(ExerciseOptionParams calldata _params) external nonReentrant {
        if (ownerOf(_params.positionId) != msg.sender) revert NotOwnerOrDelegate();

        accrueFees(_params.positionId);

        PerpPositionData memory data = perpData[_params.positionId];

        if (_params.liquidityToExercise.length != data.perpTickArrayLen) revert InvalidTickLength();

        AssetCache memory cache;

        cache.isAmount0 = data.isLong ? primePool.token0() == baseAsset : primePool.token0() == quoteAsset;
        cache.isQuoteAsset0 = primePool.token0() == quoteAsset ? true : false;

        cache.assetToUse = data.isLong ? ERC20(baseAsset) : ERC20(quoteAsset);
        cache.assetToGet = data.isLong ? ERC20(quoteAsset) : ERC20(baseAsset);

        for (uint256 i; i < data.perpTickArrayLen; i++) {
            if (_params.liquidityToExercise[i] == 0) continue;

            PerpTicks storage perpTick = perpTickMap[_params.positionId][i];

            uint256 amountToSwap = cache.isAmount0
                ? LiquidityAmounts.getAmount0ForLiquidity(
                    perpTick.tickLower.getSqrtRatioAtTick(),
                    perpTick.tickUpper.getSqrtRatioAtTick(),
                    uint128(perpTick.liquidityToUse)
                )
                : LiquidityAmounts.getAmount1ForLiquidity(
                    perpTick.tickLower.getSqrtRatioAtTick(),
                    perpTick.tickUpper.getSqrtRatioAtTick(),
                    uint128(perpTick.liquidityToUse)
                );

            uint256 prevBalance = cache.assetToGet.balanceOf(address(this));

            cache.assetToUse.transfer(address(_params.swapper[i]), amountToSwap);

            _params.swapper[i].onSwapReceived(
                address(cache.assetToUse), address(cache.assetToGet), amountToSwap, _params.swapData[i]
            );

            uint256 amountReq = cache.isAmount0
                ? LiquidityAmounts.getAmount1ForLiquidity(
                    perpTick.tickLower.getSqrtRatioAtTick(),
                    perpTick.tickUpper.getSqrtRatioAtTick(),
                    uint128(_params.liquidityToExercise[i])
                )
                : LiquidityAmounts.getAmount0ForLiquidity(
                    perpTick.tickLower.getSqrtRatioAtTick(),
                    perpTick.tickUpper.getSqrtRatioAtTick(),
                    uint128(_params.liquidityToExercise[i])
                );

            uint256 currentBalance = cache.assetToGet.balanceOf(address(this));

            if (currentBalance < prevBalance + amountReq) {
                revert NotEnoughAfterSwap();
            }

            cache.assetToGet.approve(address(positionManager), amountReq);

            bytes memory unusePositionData = abi.encode(
                perpTick.pool,
                perpTick.hook,
                perpTick.tickLower,
                perpTick.tickUpper,
                _params.liquidityToExercise[i],
                abi.encode("")
            );

            positionManager.unusePosition(perpTick._handler, unusePositionData);

            perpTick.liquidityToUse -= _params.liquidityToExercise[i];

            if (cache.isQuoteAsset0) {
                cache.amountToReduce = LiquidityAmounts.getAmount0ForLiquidity(
                    perpTick.tickLower.getSqrtRatioAtTick(),
                    perpTick.tickUpper.getSqrtRatioAtTick(),
                    uint128(_params.liquidityToExercise[i])
                );
            } else {
                cache.amountToReduce = LiquidityAmounts.getAmount1ForLiquidity(
                    perpTick.tickLower.getSqrtRatioAtTick(),
                    perpTick.tickUpper.getSqrtRatioAtTick(),
                    uint128(_params.liquidityToExercise[i])
                );
            }

            amountsInQuotePerPerpTickMap[_params.positionId][i] -= cache.amountToReduce;
            totalAmountWithdrawnInQuoteMap[_params.positionId] -= cache.amountToReduce;

            cache.totalProfit += currentBalance - (prevBalance + amountReq);
        }

        cache.assetToGet.transfer(msg.sender, cache.totalProfit);

        emit LogExercise(_params, msg.sender, cache.totalProfit, cache.amountToReduce);
    }

    function liquidate(LiquidateParams calldata _params) external nonReentrant {
        accrueFees(_params.positionId);

        PerpPositionData memory data = perpData[_params.positionId];

        if (data.remainingFees > 0) {
            revert RemainingFeesNotZero();
        }

        if (_params.liquidityToExercise.length != data.perpTickArrayLen) revert InvalidTickLength();

        AssetCache memory cache;

        cache.isAmount0 = data.isLong ? primePool.token0() == baseAsset : primePool.token0() == quoteAsset;
        cache.isQuoteAsset0 = primePool.token0() == quoteAsset ? true : false;

        cache.assetToUse = data.isLong ? ERC20(baseAsset) : ERC20(quoteAsset);
        cache.assetToGet = data.isLong ? ERC20(quoteAsset) : ERC20(baseAsset);

        for (uint256 i; i < data.perpTickArrayLen; i++) {
            if (_params.liquidityToExercise[i] == 0) continue;

            PerpTicks storage perpTick = perpTickMap[_params.positionId][i];

            uint256 liquidityToExercise = _params.liquidityToExercise[i];

            (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
                _getCurrentSqrtPriceX96(perpTick.pool),
                perpTick.tickLower.getSqrtRatioAtTick(),
                perpTick.tickUpper.getSqrtRatioAtTick(),
                uint128(liquidityToExercise)
            );

            if ((amount0 > 0 && amount1 == 0) || (amount1 > 0 && amount0 == 0)) {
                if (cache.isAmount0 && amount0 > 0) {
                    cache.assetToUse.approve(address(positionManager), amount0);
                } else if (!cache.isAmount0 && amount1 > 0) {
                    cache.assetToUse.approve(address(positionManager), amount1);
                } else {
                    uint256 amountToSwap = cache.isAmount0
                        ? LiquidityAmounts.getAmount0ForLiquidity(
                            perpTick.tickLower.getSqrtRatioAtTick(),
                            perpTick.tickUpper.getSqrtRatioAtTick(),
                            uint128(liquidityToExercise)
                        )
                        : LiquidityAmounts.getAmount1ForLiquidity(
                            perpTick.tickLower.getSqrtRatioAtTick(),
                            perpTick.tickUpper.getSqrtRatioAtTick(),
                            uint128(liquidityToExercise)
                        );

                    uint256 prevBalance = cache.assetToGet.balanceOf(address(this));

                    cache.assetToUse.transfer(address(_params.swapper[i]), amountToSwap);

                    _params.swapper[i].onSwapReceived(
                        address(cache.assetToUse), address(cache.assetToGet), amountToSwap, _params.swapData[i]
                    );

                    uint256 amountReq = cache.isAmount0
                        ? LiquidityAmounts.getAmount1ForLiquidity(
                            perpTick.tickLower.getSqrtRatioAtTick(),
                            perpTick.tickUpper.getSqrtRatioAtTick(),
                            uint128(liquidityToExercise)
                        )
                        : LiquidityAmounts.getAmount0ForLiquidity(
                            perpTick.tickLower.getSqrtRatioAtTick(),
                            perpTick.tickUpper.getSqrtRatioAtTick(),
                            uint128(liquidityToExercise)
                        );

                    uint256 currentBalance = cache.assetToGet.balanceOf(address(this));

                    if (currentBalance < prevBalance + amountReq) {
                        revert NotEnoughAfterSwap();
                    }

                    cache.assetToGet.approve(address(positionManager), amountReq);

                    cache.assetToGet.transfer(ownerOf(_params.positionId), currentBalance - (prevBalance + amountReq));
                }
            } else {}

            bytes memory unusePositionData = abi.encode(
                perpTick.pool,
                perpTick.hook,
                perpTick.tickLower,
                perpTick.tickUpper,
                liquidityToExercise,
                abi.encode("")
            );

            positionManager.unusePosition(perpTick._handler, unusePositionData);

            perpTick.liquidityToUse = 0;

            amountsInQuotePerPerpTickMap[_params.positionId][i] = 0;
            totalAmountWithdrawnInQuoteMap[_params.positionId] = 0;
        }

        emit LogLiquidate(_params);
    }

    function accrueFees(uint256 positionId) public returns (uint256, uint256) {
        PerpPositionData storage data = perpData[positionId];
        uint256 totalAmountWithdrawnInQuote = totalAmountWithdrawnInQuoteMap[positionId];

        uint256 feesAccrued =
            calculateFeesAccruedSinceLastUpdate(totalAmountWithdrawnInQuote, data.isLong, data.lastFeeAccrued);

        if (data.remainingFees >= feesAccrued) {
            data.remainingFees -= uint128(feesAccrued);
        } else {
            feesAccrued = data.remainingFees;
            data.remainingFees = 0;
        }
        data.lastFeeAccrued = uint64(block.timestamp);

        bool isQuoteAsset0 = primePool.token0() == quoteAsset ? true : false;

        ERC20(quoteAsset).approve(address(positionManager), feesAccrued);

        PerpTicks memory perpTick;

        for (uint256 i; i < data.perpTickArrayLen; i++) {
            perpTick = perpTickMap[positionId][i];

            uint256 feesAmountEarned =
                (amountsInQuotePerPerpTickMap[positionId][i] * feesAccrued) / totalAmountWithdrawnInQuote;

            bytes memory donatePositionData = abi.encode(
                perpTick.pool,
                perpTick.hook,
                perpTick.tickLower,
                perpTick.tickUpper,
                isQuoteAsset0 ? feesAmountEarned : 0,
                isQuoteAsset0 ? 0 : feesAmountEarned,
                abi.encode("")
            );
            positionManager.donateToPosition(perpTick._handler, donatePositionData);
        }

        emit LogFeesAccured(positionId, feesAccrued, block.timestamp, data.remainingFees);

        return (feesAccrued, data.remainingFees);
    }

    function calculateFeesAccruedSinceLastUpdate(
        uint256 totalAmountWithdrawnInQuote,
        bool isLong,
        uint64 lastFeeAccrued
    ) public view returns (uint256) {
        return pricing.getFundingFee(totalAmountWithdrawnInQuote, isLong, lastFeeAccrued);
    }

    function _getCurrentSqrtPriceX96(IUniswapV3Pool pool) internal view returns (uint160 sqrtPriceX96) {
        (, bytes memory result) = address(pool).staticcall(abi.encodeWithSignature("slot0()"));
        sqrtPriceX96 = abi.decode(result, (uint160));
    }

    function emergencyWithdraw(address token) external onlyOwner {
        ERC20(token).transfer(msg.sender, ERC20(token).balanceOf(address(this)));
    }
}
