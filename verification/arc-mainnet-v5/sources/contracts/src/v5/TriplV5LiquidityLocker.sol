// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

/// @notice Irrevocable full-range Uniswap v4 principal locker.
/// @dev There is intentionally no remove, sweep, rescue, owner, or admin
/// function. Any token or quote left after the initial position is also
/// permanently stranded here, so callers should only seed with the intended
/// principal amounts.
contract TriplV5LiquidityLocker is IUnlockCallback {
    using SafeERC20 for IERC20;
    using TransientStateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using BalanceDeltaLibrary for BalanceDelta;

    error AlreadySeeded();
    error InexactTransfer();
    error InvalidConfiguration();
    error Unauthorized();

    IPoolManager public immutable poolManager;
    address public immutable market;
    address public immutable token;
    address public immutable quote;
    PoolKey private _key;
    int24 public immutable tickLower;
    int24 public immutable tickUpper;
    uint128 public lockedLiquidity;
    uint256 public lockedToken;
    uint256 public lockedQuote;
    bool public seeded;

    event LiquidityLocked(
        bytes32 indexed poolId, uint128 liquidity, uint256 tokenAmount, uint256 quoteAmount
    );

    constructor(
        address poolManager_,
        address market_,
        address token_,
        address quote_,
        PoolKey memory key_,
        int24 tickLower_,
        int24 tickUpper_
    ) {
        if (
            poolManager_ == address(0) || market_ == address(0) || token_ == address(0)
                || quote_ == address(0) || tickLower_ >= tickUpper_
                || Currency.unwrap(key_.currency0) == address(0)
                || Currency.unwrap(key_.currency1) == address(0)
        ) revert InvalidConfiguration();
        poolManager = IPoolManager(poolManager_);
        market = market_;
        token = token_;
        quote = quote_;
        _key = key_;
        tickLower = tickLower_;
        tickUpper = tickUpper_;
    }

    function poolKey() external view returns (PoolKey memory) {
        return _key;
    }

    function poolId() external view returns (bytes32) {
        return PoolId.unwrap(_key.toId());
    }

    function seed(uint128 liquidity) external {
        if (msg.sender != market) revert Unauthorized();
        if (seeded) revert AlreadySeeded();
        if (liquidity == 0) revert InvalidConfiguration();
        uint256 tokenAmount = IERC20(token).balanceOf(address(this));
        uint256 quoteAmount = IERC20(quote).balanceOf(address(this));
        poolManager.unlock(abi.encode(false, liquidity, uint256(0)));
        seeded = true;
        lockedLiquidity = liquidity;
        lockedToken = tokenAmount;
        lockedQuote = quoteAmount;
        emit LiquidityLocked(PoolId.unwrap(_key.toId()), liquidity, tokenAmount, quoteAmount);
    }

    /// @notice Seeds the maximum solvent token-only position. Any rounding
    /// dust remains in this contract and is permanently inaccessible.
    function seed() external {
        if (msg.sender != market) revert Unauthorized();
        if (seeded) revert AlreadySeeded();
        if (IERC20(quote).balanceOf(address(this)) != 0) revert InvalidConfiguration();
        uint256 amount = IERC20(token).balanceOf(address(this));
        if (amount == 0) revert InvalidConfiguration();
        uint128 liquidity = _liquidityForToken(amount);
        if (liquidity == 0) revert InvalidConfiguration();
        uint256 required = _tokenForLiquidity(liquidity);
        if (required == 0 || required > amount) revert InvalidConfiguration();
        poolManager.unlock(abi.encode(true, liquidity, required));
        seeded = true;
        lockedLiquidity = liquidity;
        lockedToken = required;
        lockedQuote = 0;
        emit LiquidityLocked(PoolId.unwrap(_key.toId()), liquidity, required, 0);
    }

    function unlockCallback(bytes calldata rawData) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert Unauthorized();
        (bool tokenOnly, uint128 liquidity, uint256 required) =
            abi.decode(rawData, (bool, uint128, uint256));
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
        // PoolManager represents principal owed by the locker as a negative
        // currency delta (the convention used by the existing v4 locker).
        // A positive delta is manager credit and is taken back into this
        // permanently locked contract.
        if (tokenOnly) {
            Currency tokenCurrency =
                Currency.unwrap(_key.currency0) == token ? _key.currency0 : _key.currency1;
            Currency quoteCurrency =
                Currency.unwrap(_key.currency0) == token ? _key.currency1 : _key.currency0;
            int256 tokenDelta = poolManager.currencyDelta(address(this), tokenCurrency);
            int256 quoteDelta = poolManager.currencyDelta(address(this), quoteCurrency);
            if (tokenDelta >= 0 || quoteDelta != 0 || uint256(-tokenDelta) != required) {
                revert InvalidConfiguration();
            }
            _settleIfOwed(tokenCurrency);
        } else {
            _settleIfOwed(_key.currency0);
            _settleIfOwed(_key.currency1);
        }
        if (delta.amount0() == 0 && delta.amount1() == 0) revert InvalidConfiguration();
        return bytes("");
    }

    function _settleIfOwed(Currency currency) private {
        int256 delta = poolManager.currencyDelta(address(this), currency);
        if (delta == 0) return;
        if (delta > 0) {
            poolManager.take(currency, address(this), uint256(delta));
            return;
        }
        uint256 amount = uint256(-delta);
        IERC20 asset = IERC20(Currency.unwrap(currency));
        uint256 beforePool = asset.balanceOf(address(poolManager));
        poolManager.sync(currency);
        asset.safeTransfer(address(poolManager), amount);
        uint256 afterPool = asset.balanceOf(address(poolManager));
        if (afterPool < beforePool || afterPool - beforePool != amount) revert InexactTransfer();
        if (poolManager.settle() != amount) revert InexactTransfer();
    }

    function _liquidityForToken(uint256 amount) private view returns (uint128) {
        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(tickUpper);
        uint256 liquidity;
        if (Currency.unwrap(_key.currency0) == token) {
            uint256 first = FullMath.mulDiv(amount, sqrtLower, FixedPoint96.Q96);
            liquidity = FullMath.mulDiv(first, sqrtUpper, sqrtUpper - sqrtLower);
        } else {
            liquidity = FullMath.mulDiv(amount, FixedPoint96.Q96, sqrtUpper - sqrtLower);
        }
        if (liquidity > type(uint128).max) revert InvalidConfiguration();
        return uint128(liquidity);
    }

    function _tokenForLiquidity(uint128 liquidity) private view returns (uint256) {
        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(tickUpper);
        if (Currency.unwrap(_key.currency0) == token) {
            return SqrtPriceMath.getAmount0Delta(sqrtLower, sqrtUpper, liquidity, true);
        }
        return SqrtPriceMath.getAmount1Delta(sqrtLower, sqrtUpper, liquidity, true);
    }
}
