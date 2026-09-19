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
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

/// @notice Irrevocable token-only V4 liquidity position.
/// @dev There is intentionally no remove, sweep, rescue, or admin function.
contract TriplV4LiquidityLocker is IUnlockCallback {
    using SafeERC20 for IERC20;
    using TransientStateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using BalanceDeltaLibrary for BalanceDelta;

    error InvalidConfiguration();
    error Unauthorized();
    error AlreadySeeded();
    error LiquidityOverflow();
    error InexactTransfer();

    IPoolManager public immutable poolManager;
    address public immutable factory;
    address public immutable token;
    PoolKey private _key;
    int24 public immutable tickLower;
    int24 public immutable tickUpper;
    uint128 public lockedLiquidity;
    uint256 public lockedToken;
    bool public seeded;

    event LiquidityLocked(bytes32 indexed poolId, address indexed token, uint128 liquidity, uint256 tokenAmount);

    constructor(
        address poolManager_,
        address factory_,
        address token_,
        PoolKey memory key_,
        int24 tickLower_,
        int24 tickUpper_
    ) {
        if (
            poolManager_ == address(0) || factory_ == address(0) || token_ == address(0)
                || tickLower_ >= tickUpper_ || Currency.unwrap(key_.currency0) == address(0)
                || Currency.unwrap(key_.currency1) == address(0)
        ) revert InvalidConfiguration();
        poolManager = IPoolManager(poolManager_);
        factory = factory_;
        token = token_;
        _key = key_;
        tickLower = tickLower_;
        tickUpper = tickUpper_;
    }

    function poolId() external view returns (bytes32) {
        return PoolId.unwrap(_key.toId());
    }

    function poolKey() external view returns (PoolKey memory) {
        return _key;
    }

    function seed() external {
        if (msg.sender != factory) revert Unauthorized();
        if (seeded) revert AlreadySeeded();
        uint256 amount = IERC20(token).balanceOf(address(this));
        if (amount == 0) revert InvalidConfiguration();
        uint128 liquidity = _liquidityForAmount(amount);
        if (liquidity == 0) revert LiquidityOverflow();
        uint256 required = _amountForLiquidity(liquidity);
        if (required == 0 || required > amount) revert InvalidConfiguration();
        poolManager.unlock(abi.encode(liquidity, required));
        seeded = true;
        lockedLiquidity = liquidity;
        lockedToken = required;
        emit LiquidityLocked(PoolId.unwrap(_key.toId()), token, liquidity, required);
    }

    function unlockCallback(bytes calldata rawData) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert Unauthorized();
        (uint128 liquidity, uint256 required) = abi.decode(rawData, (uint128, uint256));
        (BalanceDelta delta,) = poolManager.modifyLiquidity(
            _key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: int256(uint256(liquidity)),
                salt: bytes32(0)
            }),
            bytes("")
        );
        Currency tokenCurrency = Currency.unwrap(_key.currency0) == token ? _key.currency0 : _key.currency1;
        Currency quoteCurrency = Currency.unwrap(_key.currency0) == token ? _key.currency1 : _key.currency0;
        int256 tokenDelta = poolManager.currencyDelta(address(this), tokenCurrency);
        int256 quoteDelta = poolManager.currencyDelta(address(this), quoteCurrency);
        if (tokenDelta >= 0 || quoteDelta != 0 || uint256(-tokenDelta) != required) {
            revert InvalidConfiguration();
        }
        // Keep the returned delta observable for invariant tooling.
        if (delta.amount0() == 0 && delta.amount1() == 0) revert InvalidConfiguration();
        _settle(tokenCurrency, uint256(-tokenDelta));
        return bytes("");
    }

    function _settle(Currency currency, uint256 amount) private {
        IERC20 asset = IERC20(Currency.unwrap(currency));
        poolManager.sync(currency);
        uint256 beforeBalance = asset.balanceOf(address(poolManager));
        asset.safeTransfer(address(poolManager), amount);
        uint256 afterBalance = asset.balanceOf(address(poolManager));
        if (afterBalance < beforeBalance || afterBalance - beforeBalance != amount) revert InexactTransfer();
        if (poolManager.settle() != amount) revert InexactTransfer();
    }

    function _liquidityForAmount(uint256 amount) private view returns (uint128) {
        uint160 sqrtLower = _sqrt(tickLower);
        uint160 sqrtUpper = _sqrt(tickUpper);
        uint256 liquidity;
        if (Currency.unwrap(_key.currency0) == token) {
            uint256 first = FullMath.mulDiv(amount, sqrtLower, FixedPoint96.Q96);
            liquidity = FullMath.mulDiv(first, sqrtUpper, sqrtUpper - sqrtLower);
        } else {
            liquidity = FullMath.mulDiv(amount, FixedPoint96.Q96, sqrtUpper - sqrtLower);
        }
        if (liquidity > type(uint128).max) revert LiquidityOverflow();
        return uint128(liquidity);
    }

    function _amountForLiquidity(uint128 liquidity) private view returns (uint256) {
        uint160 sqrtLower = _sqrt(tickLower);
        uint160 sqrtUpper = _sqrt(tickUpper);
        if (Currency.unwrap(_key.currency0) == token) {
            return SqrtPriceMath.getAmount0Delta(sqrtLower, sqrtUpper, liquidity, true);
        }
        return SqrtPriceMath.getAmount1Delta(sqrtLower, sqrtUpper, liquidity, true);
    }

    function _sqrt(int24 tick) private pure returns (uint160) {
        // TickMath is deliberately not imported into the public ABI.
        return _tickSqrt(tick);
    }

    function _tickSqrt(int24 tick) private pure returns (uint160) {
        // Delegated through a small internal library shim to keep the locker
        // bytecode independent of any deployment-time price state.
        return TickMathShim.getSqrtPriceAtTick(tick);
    }
}

library TickMathShim {
    function getSqrtPriceAtTick(int24 tick) internal pure returns (uint160) {
        return TickMath.getSqrtPriceAtTick(tick);
    }
}
