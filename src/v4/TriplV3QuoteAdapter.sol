// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {ITriplV2QuoteAdapter} from "../v2/TriplV2QuoteInterfaces.sol";

interface ITriplV3PoolOracle {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function fee() external view returns (uint24);
    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s);
}

interface ITriplV3SwapRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params)
        external
        payable
        returns (uint256 amountOut);
}

/// @notice Converts one explicitly pinned Arc quote token into USDC through a
/// reviewed Uniswap v3 pool. A pool TWAP creates the non-bypassable floor;
/// callers may demand a stricter `minOut` for the current transaction.
contract TriplV3QuoteAdapter is ITriplV2QuoteAdapter, ReentrancyGuard {
    using SafeERC20 for IERC20;

    error InvalidConfiguration();
    error InvalidConversion();
    error PriceOutsideBounds();
    error InexactTransfer();

    address public immutable quoteAsset;
    address public immutable usdc;
    ITriplV3PoolOracle public immutable pool;
    ITriplV3SwapRouter public immutable router;
    bytes32 public immutable poolCodeHash;
    uint24 public immutable fee;
    uint32 public immutable twapWindow;
    uint16 public immutable maxDeviationBps;

    event Converted(address indexed caller, uint256 quoteIn, uint256 usdcOut);

    constructor(
        address pool_,
        address router_,
        address quote_,
        address usdc_,
        uint32 twapWindow_,
        uint16 maxDeviationBps_
    ) {
        if (
            pool_.code.length == 0 || router_.code.length == 0 || quote_.code.length == 0
                || usdc_.code.length == 0 || quote_ == usdc_ || twapWindow_ < 60
                || twapWindow_ > 1 days || maxDeviationBps_ > 1_000
                || IERC20Metadata(usdc_).decimals() != 6
                || IERC20Metadata(quote_).decimals() > 18
        ) revert InvalidConfiguration();
        ITriplV3PoolOracle configuredPool = ITriplV3PoolOracle(pool_);
        address token0 = configuredPool.token0();
        address token1 = configuredPool.token1();
        if (!((token0 == quote_ && token1 == usdc_) || (token1 == quote_ && token0 == usdc_))) {
            revert InvalidConfiguration();
        }
        uint24 configuredFee = configuredPool.fee();
        if (configuredFee == 0) revert InvalidConfiguration();
        pool = configuredPool;
        router = ITriplV3SwapRouter(router_);
        quoteAsset = quote_;
        usdc = usdc_;
        poolCodeHash = pool_.codehash;
        fee = configuredFee;
        twapWindow = twapWindow_;
        maxDeviationBps = maxDeviationBps_;
        _consult();
    }

    function previewFloor(uint256 amount) public view returns (uint256 floor) {
        if (amount == 0 || address(pool).codehash != poolCodeHash) revert InvalidConversion();
        int24 arithmeticMeanTick = _consult();
        uint256 expected = _quoteAtTick(arithmeticMeanTick, amount, quoteAsset, usdc);
        floor = Math.mulDiv(expected, 10_000 - maxDeviationBps, 10_000);
        if (floor == 0) revert PriceOutsideBounds();
    }

    function convertToUsdc(address quote, uint256 amount, uint256 minOut, uint256 deadline)
        external
        nonReentrant
        returns (uint256 output)
    {
        if (quote != quoteAsset || amount == 0 || block.timestamp > deadline) {
            revert InvalidConversion();
        }
        uint256 floor = previewFloor(amount);
        uint256 enforcedMin = minOut > floor ? minOut : floor;
        IERC20 input = IERC20(quoteAsset);
        IERC20 outputToken = IERC20(usdc);
        uint256 beforeInput = input.balanceOf(address(this));
        input.safeTransferFrom(msg.sender, address(this), amount);
        if (input.balanceOf(address(this)) != beforeInput + amount) revert InexactTransfer();
        input.forceApprove(address(router), amount);
        uint256 beforeOutput = outputToken.balanceOf(msg.sender);
        output = router.exactInputSingle(
            ITriplV3SwapRouter.ExactInputSingleParams({
                tokenIn: quoteAsset,
                tokenOut: usdc,
                fee: fee,
                recipient: msg.sender,
                amountIn: amount,
                amountOutMinimum: enforcedMin,
                sqrtPriceLimitX96: 0
            })
        );
        input.forceApprove(address(router), 0);
        if (
            input.balanceOf(address(this)) != beforeInput || output < enforcedMin
                || outputToken.balanceOf(msg.sender) != beforeOutput + output
        ) revert InexactTransfer();
        emit Converted(msg.sender, amount, output);
    }

    function _consult() private view returns (int24 arithmeticMeanTick) {
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = twapWindow;
        secondsAgos[1] = 0;
        (int56[] memory tickCumulatives,) = pool.observe(secondsAgos);
        int56 delta = tickCumulatives[1] - tickCumulatives[0];
        int56 divisor = int56(uint56(twapWindow));
        arithmeticMeanTick = int24(delta / divisor);
        if (delta < 0 && delta % divisor != 0) --arithmeticMeanTick;
    }

    function _quoteAtTick(int24 tick, uint256 baseAmount, address baseToken, address quoteToken)
        private
        pure
        returns (uint256 quoteAmount)
    {
        uint160 sqrtRatioX96 = TickMath.getSqrtPriceAtTick(tick);
        if (sqrtRatioX96 <= type(uint128).max) {
            uint256 ratioX192 = uint256(sqrtRatioX96) * sqrtRatioX96;
            quoteAmount = baseToken < quoteToken
                ? FullMath.mulDiv(ratioX192, baseAmount, 1 << 192)
                : FullMath.mulDiv(1 << 192, baseAmount, ratioX192);
        } else {
            uint256 ratioX128 = FullMath.mulDiv(sqrtRatioX96, sqrtRatioX96, 1 << 64);
            quoteAmount = baseToken < quoteToken
                ? FullMath.mulDiv(ratioX128, baseAmount, 1 << 128)
                : FullMath.mulDiv(1 << 128, baseAmount, ratioX128);
        }
    }
}
