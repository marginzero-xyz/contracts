// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.0 <0.9.0;

import {Multicall} from "openzeppelin-contracts/contracts/utils/Multicall.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721} from "openzeppelin-contracts/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "openzeppelin-contracts/contracts/token/ERC721/IERC721Receiver.sol";
import {IOptionMarketOTMFE} from "../../interfaces/apps/options/IOptionMarketOTMFE.sol";
import {ISwapper} from "../../interfaces/ISwapper.sol";
import {IWETH} from "../../interfaces/IWETH.sol";
import {EIP712} from "openzeppelin-contracts/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "openzeppelin-contracts/contracts/utils/cryptography/ECDSA.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {IV3Pool} from "../../interfaces/handlers/V3/IV3Pool.sol";

contract MintOptionFirewall is Multicall, EIP712, Ownable, IERC721Receiver {
    using SafeERC20 for IERC20;
    using ECDSA for bytes32;

    mapping(address => bool) public whitelistedSigners;

    error InvalidSignature();
    error InvalidDeadline();
    error InvalidTick();
    error InvalidSqrtPriceX96();
    error InvalidOptionParams();
    error InvalidSignatureLen();

    struct RangeCheckData {
        address user;
        address pool;
        address market;
        int24 minTickLower;
        int24 maxTickUpper;
        uint160 minSqrtPriceX96;
        uint160 maxSqrtPriceX96;
        uint256 deadline;
    }

    struct Signature {
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    struct PoolData {
        IV3Pool pool;
        uint160 sqrtPriceX96;
        int24 tick;
    }

    bytes32 private constant RANGE_CHECK_TYPEHASH = keccak256(
        "RangeCheck(address user,address pool,int24 minTickLower,int24 maxTickUpper,uint160 minSqrtPriceX96,uint160 maxSprtPriceX96,uint256 deadline)"
    );

    constructor(address _signer) EIP712("MintOptionFirewall", "1") Ownable(msg.sender) {
        whitelistedSigners[_signer] = true;
    }

    function updateWhitelistedSigner(address _signer, bool _isWhitelisted) external onlyOwner {
        whitelistedSigners[_signer] = _isWhitelisted;
    }

    /// @notice Emitted when an option is minted through this router
    /// @param user The address initiating the mint
    /// @param receiver The address receiving the minted option
    /// @param market The address of the option market
    /// @param optionId The ID of the minted option
    event MintOption(address user, address receiver, address market, uint256 optionId);

    /// @notice Wraps ETH into WETH
    /// @param weth The address of the WETH contract
    /// @param amount The amount of ETH to wrap
    function wrap(address weth, uint256 amount) external payable {
        IWETH(weth).deposit{value: amount}();
        IERC20(weth).safeTransfer(msg.sender, amount);
    }

    /// @notice Executes multiple token swaps through specified swapper contracts
    /// @param swapper Array of swapper contract addresses
    /// @param tokensIn Array of input token addresses
    /// @param tokensOut Array of output token addresses
    /// @param amounts Array of input amounts
    /// @param swapData Array of encoded swap data for each swap
    function swap(
        address[] calldata swapper,
        address[] calldata tokensIn,
        address[] calldata tokensOut,
        uint256[] calldata amounts,
        bytes[] calldata swapData
    ) external {
        for (uint256 i; i < tokensIn.length; i++) {
            IERC20(tokensIn[i]).safeTransferFrom(msg.sender, swapper[i], amounts[i]);
            ISwapper(swapper[i]).onSwapReceived(tokensIn[i], tokensOut[i], amounts[i], swapData[i]);
        }
    }

    /// @notice Mints an option through the specified option market
    /// @param market The option market contract
    /// @param optionParams The parameters for the option to be minted
    /// @param optionRecipient The address that will receive the minted option
    /// @param self Whether to transfer tokens through this contract first
    /// @param rangeCheckData The range check data for the option
    /// @param signature The signature of the range check data
    function mintOption(
        IOptionMarketOTMFE market,
        IOptionMarketOTMFE.OptionParams memory optionParams,
        address optionRecipient,
        bool self,
        RangeCheckData[] calldata rangeCheckData,
        Signature[] calldata signature
    ) external {
        if (rangeCheckData.length != signature.length) {
            revert InvalidSignatureLen();
        }

        if (optionParams.optionTicks.length != rangeCheckData.length) {
            revert InvalidSignatureLen();
        }

        for (uint256 i; i < rangeCheckData.length; i++) {
            _checkRange(market, optionParams.optionTicks[i], rangeCheckData[i], signature[i]);
        }

        address callAsset = market.callAsset();
        address putAsset = market.putAsset();

        if (!self) {
            if (optionParams.isCall) {
                IERC20(callAsset).safeTransferFrom(msg.sender, address(this), optionParams.maxCostAllowance);
                IERC20(callAsset).approve(address(market), optionParams.maxCostAllowance);
            } else {
                IERC20(putAsset).safeTransferFrom(msg.sender, address(this), optionParams.maxCostAllowance);
                IERC20(putAsset).approve(address(market), optionParams.maxCostAllowance);
            }
        } else {
            if (optionParams.isCall) {
                IERC20(callAsset).safeIncreaseAllowance(address(market), optionParams.maxCostAllowance);
            } else {
                IERC20(putAsset).safeIncreaseAllowance(address(market), optionParams.maxCostAllowance);
            }
        }

        market.mintOption(optionParams);

        uint256 tokenId = market.optionIds();

        IERC721(address(market)).transferFrom(address(this), optionRecipient, tokenId);

        emit MintOption(msg.sender, optionRecipient, address(market), tokenId);
    }

    /// @notice Sweeps any remaining tokens from the contract to a specified address
    /// @param token The token address to sweep
    /// @param to The address to send the tokens to
    function sweep(address token, address to) external {
        IERC20(token).safeTransfer(to, IERC20(token).balanceOf(address(this)));
    }

    /// @notice Required implementation for IERC721Receiver
    /// @dev Allows this contract to receive ERC721 tokens
    /// @return bytes4 The function selector
    function onERC721Received(address, address, uint256, bytes memory) public virtual override returns (bytes4) {
        return this.onERC721Received.selector;
    }

    function _checkRange(
        IOptionMarketOTMFE market,
        IOptionMarketOTMFE.OptionTicks memory optionTicks,
        RangeCheckData calldata rangeCheckData,
        Signature calldata signature
    ) internal view {
        bytes32 structHash = keccak256(
            abi.encode(
                RANGE_CHECK_TYPEHASH,
                msg.sender,
                address(optionTicks.pool),
                address(market),
                rangeCheckData.minTickLower,
                rangeCheckData.maxTickUpper,
                rangeCheckData.minSqrtPriceX96,
                rangeCheckData.maxSqrtPriceX96,
                rangeCheckData.deadline
            )
        );

        bytes32 hash = _hashTypedDataV4(structHash);

        if (!whitelistedSigners[hash.recover(signature.v, signature.r, signature.s)]) {
            revert InvalidSignature();
        }

        if (rangeCheckData.deadline < block.timestamp) {
            revert InvalidDeadline();
        }

        PoolData memory poolData;
        poolData.pool = IV3Pool(address(optionTicks.pool));
        (poolData.sqrtPriceX96, poolData.tick,,,,,) = poolData.pool.slot0();

        if (poolData.tick < rangeCheckData.minTickLower || poolData.tick > rangeCheckData.maxTickUpper) {
            revert InvalidTick();
        }

        if (
            poolData.sqrtPriceX96 < rangeCheckData.minSqrtPriceX96
                || poolData.sqrtPriceX96 > rangeCheckData.maxSqrtPriceX96
        ) revert InvalidSqrtPriceX96();
    }

    function hashTypedDataV4(bytes32 structHash) public view returns (bytes32) {
        return _hashTypedDataV4(structHash);
    }

    function getRangeCheckTypehash() public pure returns (bytes32) {
        return RANGE_CHECK_TYPEHASH;
    }

    function getDomainSeparator() public view returns (bytes32) {
        return _domainSeparatorV4();
    }
}
