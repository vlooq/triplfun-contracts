// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

interface ITriplV4RouterFactory {
    function isPool(bytes32 poolId) external view returns (bool);
    function hook() external view returns (address);
}

interface ITriplV4RouterHook {
    function settleFees(PoolKey calldata key) external;
}

/// @notice Exact-input ERC20 router for Triplfun V4 pools.
/// @dev It uses PoolManager's real unlock accounting. The token input is
/// transferred only after the manager reports the exact resulting delta.
contract TriplV4SwapRouter is IUnlockCallback {
    using SafeERC20 for IERC20;
    using CurrencyLibrary for Currency;
    using TransientStateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using BalanceDeltaLibrary for BalanceDelta;

    error Expired();
    error InvalidPool();
    error InvalidAmount();
    error Slippage();
    error UnsupportedExactOutput();
    error Unauthorized();
    error InexactTransfer();

    /// @notice Emitted after PoolManager settlement, with the actual deltas
    /// observed by this router. PoolManager's own Swap event remains the
    /// canonical event for callers using other routers.
    event SwapExecuted(
        bytes32 indexed poolId,
        address indexed trader,
        bool zeroForOne,
        uint256 amountIn,
        uint256 amountOut
    );

    IPoolManager public immutable poolManager;
    address public immutable factory;

    struct CallbackData {
        address sender;
        PoolKey key;
        bool zeroForOne;
        uint256 amountIn;
        uint256 minOut;
    }

    constructor(address poolManager_, address factory_) {
        if (poolManager_ == address(0) || factory_ == address(0)) revert InvalidPool();
        poolManager = IPoolManager(poolManager_);
        factory = factory_;
    }

    function swapExactInput(PoolKey calldata key, bool zeroForOne, uint256 amountIn, uint256 minOut, uint256 deadline)
        external
        returns (uint256 amountOut)
    {
        if (block.timestamp > deadline) revert Expired();
        if (amountIn == 0 || !ITriplV4RouterFactory(factory).isPool(PoolId.unwrap(key.toId()))) revert InvalidPool();
        if (address(key.hooks) != ITriplV4RouterFactory(factory).hook()) revert InvalidPool();
        if (key.currency0.isAddressZero() || key.currency1.isAddressZero()) revert InvalidPool();
        bytes memory result = poolManager.unlock(
            abi.encode(CallbackData(msg.sender, key, zeroForOne, amountIn, minOut))
        );
        amountOut = abi.decode(result, (uint256));
    }

    function swapExactOutput(
        PoolKey calldata,
        bool,
        uint256,
        uint256,
        uint256
    ) external pure returns (uint256) {
        revert UnsupportedExactOutput();
    }

    function unlockCallback(bytes calldata rawData) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert Unauthorized();
        CallbackData memory data = abi.decode(rawData, (CallbackData));
        if (data.sender == address(0) || data.amountIn == 0) revert InvalidAmount();
        BalanceDelta swapDelta = poolManager.swap(
            data.key,
            IPoolManager.SwapParams({
                zeroForOne: data.zeroForOne,
                amountSpecified: -int256(data.amountIn),
                sqrtPriceLimitX96: data.zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            bytes("")
        );
        // Force the compiler to retain the return value in the ABI path and
        // provide a cheap sanity check for malformed upstream implementations.
        if (swapDelta == BalanceDeltaLibrary.ZERO_DELTA) revert InvalidAmount();

        Currency input = data.zeroForOne ? data.key.currency0 : data.key.currency1;
        Currency output = data.zeroForOne ? data.key.currency1 : data.key.currency0;
        int256 inputDelta = poolManager.currencyDelta(address(this), input);
        int256 outputDelta = poolManager.currencyDelta(address(this), output);
        if (inputDelta >= 0 || outputDelta <= 0) revert InvalidAmount();
        uint256 actualInput = uint256(-inputDelta);
        uint256 amountOut = uint256(outputDelta);
        if (actualInput > data.amountIn || amountOut < data.minOut) revert Slippage();

        _settle(data.sender, input, actualInput);
        _take(data.sender, output, amountOut);
        emit SwapExecuted(PoolId.unwrap(data.key.toId()), data.sender, data.zeroForOne, actualInput, amountOut);
        return abi.encode(amountOut);
    }

    function _settle(address sender, Currency currency, uint256 amount) private {
        address asset = Currency.unwrap(currency);
        if (asset == address(0)) revert InvalidPool();
        IERC20 token = IERC20(asset);
        poolManager.sync(currency);
        uint256 beforeBalance = token.balanceOf(address(poolManager));
        token.safeTransferFrom(sender, address(poolManager), amount);
        uint256 afterBalance = token.balanceOf(address(poolManager));
        if (afterBalance < beforeBalance || afterBalance - beforeBalance != amount) revert InexactTransfer();
        if (poolManager.settle() != amount) revert InexactTransfer();
    }

    function _take(address recipient, Currency currency, uint256 amount) private {
        IERC20 token = IERC20(Currency.unwrap(currency));
        uint256 beforeRecipient = token.balanceOf(recipient);
        poolManager.take(currency, recipient, amount);
        uint256 afterRecipient = token.balanceOf(recipient);
        if (afterRecipient < beforeRecipient || afterRecipient - beforeRecipient != amount) {
            revert InexactTransfer();
        }
    }
}
