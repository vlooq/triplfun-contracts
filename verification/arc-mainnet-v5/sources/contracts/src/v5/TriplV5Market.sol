// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {TriplV5Types} from "./TriplV5Types.sol";
import {TriplV5Token} from "./TriplV5Token.sol";
import {TriplV5FeeVault} from "./TriplV5FeeVault.sol";
import {TriplV5StakingRewards} from "./TriplV5StakingRewards.sol";
import {TriplV5LiquidityLocker} from "./TriplV5LiquidityLocker.sol";

interface ITriplV5LockerDeployer {
    function deploy(address, address, address, PoolKey calldata, int24, int24)
        external
        returns (address);
}

/// @dev Identity surface required from a graduation fee adapter. The adapter
/// itself owns the v4 fee-routing policy; the market only accepts one bound to
/// this factory and PoolManager.
interface ITriplV5HookIdentity {
    function poolManager() external view returns (address);
    function factory() external view returns (address);
    function supportsTriplV5FeeRouting() external view returns (bytes4);
}

/// @notice Per-launch constant-product market with an explicitly tracked
/// real quote reserve and a separate virtual quote opening parameter.
contract TriplV5Market is ReentrancyGuard, IUnlockCallback {
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;
    using TransientStateLibrary for IPoolManager;

    error CurveDisabled();
    error DeadlineExpired();
    error GraduationUnavailable();
    error InexactTransfer();
    error InsufficientOutput();
    error InsufficientQuoteReserve();
    error InvalidConfiguration();
    error InvalidFee();
    error InvalidHook();
    error SlippageExceeded();
    error Unauthorized();
    error ZeroAmount();

    struct BuybackSwap {
        uint256 quoteIn;
        uint256 minTokenOut;
    }

    uint256 public constant BPS = TriplV5Types.BPS;
    uint16 public constant NFT_FEE_BPS = TriplV5Types.NFT_FEE_BPS;
    uint16 public constant MAX_TOTAL_FEE_BPS = TriplV5Types.MAX_TOTAL_FEE_BPS;
    bytes4 public constant V5_FEE_ROUTING_MAGIC = bytes4(keccak256("TriplV5FeeHook.v1"));

    IERC20 public immutable quote;
    TriplV5Token public immutable token;
    address public immutable factory;
    TriplV5FeeVault public immutable feeVault;
    TriplV5StakingRewards public immutable staking;
    address public immutable creator;
    /// @notice Deployment block, retained for provenance. The first trading
    /// block is exposed by {launchBlock} and lives on the token.
    uint256 public immutable deploymentBlock;
    uint256 public immutable launchTime;
    uint256 public immutable initialVirtualQuoteReserve;
    uint256 public immutable initialVirtualTokenReserve;
    uint256 public immutable invariantK;
    uint256 public immutable graduationThreshold;
    uint16 public immutable creatorFeeBps;
    uint16 public immutable holderFeeBps;
    uint16 public immutable buybackFeeBps;
    uint16 public immutable splitFeeBps;
    uint8 public immutable moduleKind;
    uint256 public immutable maxBuybackQuote;
    bool public immutable firstBlockBuyTax;
    bool public immutable transferRestriction30Days;
    address public immutable poolManager;
    address public immutable lockerDeployer;
    address public immutable poolHook;
    uint24 public immutable poolFee;
    int24 public immutable poolTickSpacing;
    /// @notice Snapped terminal curve tick used for graduation. It is zero
    /// until seedGraduation derives it from the virtual reserves.
    int24 public openingTick;

    uint256 public virtualTokenReserve;
    uint256 public virtualQuoteReserve;
    uint256 public realQuoteReserve;
    bool public curveEnabled = true;
    bool public graduationRequested;
    bool public graduated;
    bool public poolInitialized;
    address public graduationLocker;
    address public liquidityLocker;
    address public canonicalVenue;
    bool private buybackUnlocking;

    event Bought(
        address indexed buyer,
        uint256 grossQuoteIn,
        uint256 tokenOut,
        uint256 curveTokenOut,
        uint256 totalFee,
        uint256 netQuoteIn
    );
    event Sold(
        address indexed seller,
        uint256 tokenIn,
        uint256 quoteOut,
        uint256 grossQuoteOut,
        uint256 totalFee
    );
    event GraduationBegun(uint256 indexed threshold, uint256 realQuoteReserve);
    event Graduated(address indexed locker, address indexed venue, bytes32 indexed poolId);
    event LiquidityInitialized(
        address indexed locker, address indexed venue, bytes32 indexed poolId, int24 openingTick
    );
    event CanonicalVenueSet(address indexed venue);

    struct Config {
        address factory;
        address token;
        address quote;
        address feeVault;
        address staking;
        address creator;
        uint256 initialVirtualQuoteReserve;
        uint256 graduationThreshold;
        uint16 creatorFeeBps;
        uint16 holderFeeBps;
        uint16 buybackFeeBps;
        uint16 splitFeeBps;
        uint8 moduleKind;
        uint256 maxBuybackQuote;
        bool firstBlockBuyTax;
        bool transferRestriction30Days;
        address poolManager;
        address lockerDeployer;
        address poolHook;
        uint24 poolFee;
        int24 poolTickSpacing;
    }

    constructor(Config memory config) {
        if (
            config.factory == address(0) || config.token == address(0) || config.quote == address(0)
                || config.feeVault == address(0) || config.staking == address(0)
                || config.creator == address(0) || config.initialVirtualQuoteReserve == 0
                || config.graduationThreshold == 0 || IERC20Metadata(config.quote).decimals() > 18
                || config.moduleKind > uint8(TriplV5Types.ModuleKind.LotteryReserved)
                || config.lockerDeployer.code.length == 0
        ) revert InvalidConfiguration();
        uint256 totalBps = NFT_FEE_BPS + config.creatorFeeBps + config.holderFeeBps
            + config.buybackFeeBps + config.splitFeeBps;
        if (totalBps > MAX_TOTAL_FEE_BPS) revert InvalidFee();
        if (config.moduleKind == uint8(TriplV5Types.ModuleKind.LotteryReserved)) {
            revert InvalidConfiguration();
        }
        if (
            config.moduleKind == uint8(TriplV5Types.ModuleKind.None)
                && (config.buybackFeeBps != 0 || config.maxBuybackQuote != 0)
        ) {
            revert InvalidConfiguration();
        }
        if (
            config.moduleKind == uint8(TriplV5Types.ModuleKind.Buyback)
                && (config.buybackFeeBps == 0 || config.maxBuybackQuote == 0)
        ) {
            revert InvalidConfiguration();
        }
        if (
            config.poolTickSpacing < 1 || config.poolTickSpacing > type(int16).max
                || config.poolFee > 1_000_000
        ) {
            revert InvalidConfiguration();
        }
        if (config.poolHook != address(0)) {
            if (config.poolHook.code.length == 0) revert InvalidHook();
            // beforeInitialize, beforeSwap, afterSwap, and both return-delta
            // permissions are required for a fee enforcing v4 adapter.
            uint160 requiredHookBits = (uint160(1) << 13) | (uint160(1) << 7) | (uint160(1) << 6)
                | (uint160(1) << 3) | (uint160(1) << 2);
            if (uint160(config.poolHook) & requiredHookBits != requiredHookBits) {
                revert InvalidHook();
            }
            try ITriplV5HookIdentity(config.poolHook).poolManager() returns (address hookManager) {
                if (hookManager != config.poolManager) revert InvalidHook();
            } catch {
                revert InvalidHook();
            }
            try ITriplV5HookIdentity(config.poolHook).factory() returns (address hookFactory) {
                if (hookFactory != config.factory) revert InvalidHook();
            } catch {
                revert InvalidHook();
            }
            try ITriplV5HookIdentity(config.poolHook).supportsTriplV5FeeRouting() returns (
                bytes4 marker
            ) {
                if (marker != V5_FEE_ROUTING_MAGIC) revert InvalidHook();
            } catch {
                revert InvalidHook();
            }
        }
        uint256 supply = TriplV5Types.TOKEN_SUPPLY;
        if (config.initialVirtualQuoteReserve > type(uint256).max / supply) {
            revert InvalidConfiguration();
        }

        factory = config.factory;
        token = TriplV5Token(config.token);
        quote = IERC20(config.quote);
        feeVault = TriplV5FeeVault(config.feeVault);
        staking = TriplV5StakingRewards(config.staking);
        creator = config.creator;
        deploymentBlock = block.number;
        launchTime = block.timestamp;
        initialVirtualQuoteReserve = config.initialVirtualQuoteReserve;
        initialVirtualTokenReserve = supply;
        invariantK = supply * config.initialVirtualQuoteReserve;
        graduationThreshold = config.graduationThreshold;
        creatorFeeBps = config.creatorFeeBps;
        holderFeeBps = config.holderFeeBps;
        buybackFeeBps = config.buybackFeeBps;
        splitFeeBps = config.splitFeeBps;
        moduleKind = config.moduleKind;
        maxBuybackQuote = config.maxBuybackQuote;
        firstBlockBuyTax = config.firstBlockBuyTax;
        transferRestriction30Days = config.transferRestriction30Days;
        poolManager = config.poolManager;
        lockerDeployer = config.lockerDeployer;
        poolHook = config.poolHook;
        poolFee = config.poolFee;
        poolTickSpacing = config.poolTickSpacing;
        virtualTokenReserve = supply;
        virtualQuoteReserve = config.initialVirtualQuoteReserve;
    }

    /// @notice First block in which the market successfully activated trading.
    /// It is zero until the first buy, so tax policy never keys off deployment.
    function launchBlock() external view returns (uint256) {
        return token.launchBlock();
    }

    function totalFeeBps() public view returns (uint16) {
        return NFT_FEE_BPS + creatorFeeBps + holderFeeBps + buybackFeeBps + splitFeeBps;
    }

    /// @notice Atomically initializes and permanently locks the complete
    /// launch supply as one-sided Uniswap v4 liquidity.
    function initializeLiquidity() external nonReentrant {
        if (
            msg.sender != factory || poolInitialized || poolManager.code.length == 0
                || poolHook == address(0)
        ) revert Unauthorized();
        PoolKey memory key = _poolKey();
        int24 tick = _initialPoolTick();
        int24 minTick = TickMath.minUsableTick(poolTickSpacing);
        int24 maxTick = TickMath.maxUsableTick(poolTickSpacing);
        IPoolManager(poolManager).initialize(key, TickMath.getSqrtPriceAtTick(tick));
        poolInitialized = true;
        openingTick = tick;
        bool tokenIs0 = address(token) < address(quote);
        TriplV5LiquidityLocker locker = TriplV5LiquidityLocker(
            ITriplV5LockerDeployer(lockerDeployer)
                .deploy(
                    poolManager,
                    address(token),
                    address(quote),
                    key,
                    tokenIs0 ? tick : minTick,
                    tokenIs0 ? maxTick : tick
                )
        );
        uint256 tokenAmount = token.balanceOf(address(this));
        if (tokenAmount != TriplV5Types.TOKEN_SUPPLY) revert InvalidConfiguration();
        _pushExact(IERC20(address(token)), address(locker), tokenAmount);
        locker.seed();
        liquidityLocker = address(locker);
        graduationLocker = address(locker);
        curveEnabled = false;
        graduationRequested = false;
        graduated = true;
        canonicalVenue = poolManager;
        token.activateTrading();
        emit LiquidityInitialized(address(locker), poolManager, PoolId.unwrap(key.toId()), tick);
        emit Graduated(address(locker), poolManager, PoolId.unwrap(key.toId()));
    }

    function minimumQuoteReserve() external pure returns (uint256) {
        return 0;
    }

    function accountedQuoteReserve() external view returns (uint256) {
        return realQuoteReserve;
    }

    function feeBreakdown(uint256 amount)
        public
        view
        returns (TriplV5Types.FeeBreakdown memory result)
    {
        result.nft = amount * NFT_FEE_BPS / BPS;
        result.creator = amount * creatorFeeBps / BPS;
        result.holder = amount * holderFeeBps / BPS;
        result.buyback = amount * buybackFeeBps / BPS;
        result.split = amount * splitFeeBps / BPS;
        result.total = result.nft + result.creator + result.holder + result.buyback + result.split;
        // Integer division can leave a fee remainder. Keep it in the creator
        // bucket so the charged amount is fully conserved.
        if (result.total < amount * totalFeeBps() / BPS) {
            result.creator += amount * totalFeeBps() / BPS - result.total;
            result.total = amount * totalFeeBps() / BPS;
        }
    }

    function previewBuy(uint256 quoteIn)
        public
        pure
        returns (uint256 tokenOut, uint256 fee, uint256 netQuoteIn)
    {
        quoteIn;
        return (0, 0, 0);
    }

    function previewBuyFor(address recipient, uint256 quoteIn)
        public
        pure
        returns (uint256 tokenOut, uint256 fee, uint256 netQuoteIn)
    {
        recipient;
        quoteIn;
        return (0, 0, 0);
    }

    function previewSell(uint256 tokenIn)
        public
        pure
        returns (uint256 quoteOut, uint256 fee, uint256 grossQuoteOut)
    {
        tokenIn;
        return (0, 0, 0);
    }

    function buy(uint256 quoteIn, uint256 minTokenOut, uint256 deadline)
        external
        nonReentrant
        returns (uint256 tokenOut)
    {
        quoteIn;
        minTokenOut;
        deadline;
        tokenOut;
        revert CurveDisabled();
    }

    function sell(uint256 tokenIn, uint256 minQuoteOut, uint256 deadline)
        external
        nonReentrant
        returns (uint256 quoteOut)
    {
        tokenIn;
        minQuoteOut;
        deadline;
        quoteOut;
        revert CurveDisabled();
    }

    /// @notice Starts the first phase. Trading is disabled before any external
    /// venue call so a failed seed can be retried without reopening the curve.
    function beginGraduation() external {
        revert GraduationUnavailable();
    }

    /// @notice Retryable second phase. A failed pool initialization or seed
    /// leaves {graduationRequested} true and the curve disabled.
    function seedGraduation() external nonReentrant {
        revert GraduationUnavailable();
    }

    function setCanonicalVenue(address venue) external {
        if (msg.sender != factory || !graduated || venue == address(0)) revert Unauthorized();
        canonicalVenue = venue;
        emit CanonicalVenueSet(venue);
    }

    function executeBuyback(uint256 quoteIn, uint256 minTokenOut, uint256 deadline)
        external
        nonReentrant
        returns (uint256 tokenOut)
    {
        if (moduleKind != uint8(TriplV5Types.ModuleKind.Buyback)) {
            revert GraduationUnavailable();
        }
        if (quoteIn == 0) revert ZeroAmount();
        if (block.timestamp > deadline) revert DeadlineExpired();
        if (quoteIn > maxBuybackQuote) {
            revert InvalidConfiguration();
        }
        // A graduated buyback uses the validated fee hook and the canonical
        // PoolManager venue. Credit is redeemed into this market first, then
        // spent as exact input; any hook fee is routed atomically by the hook.
        if (!graduated || poolManager.code.length == 0 || poolHook == address(0)) {
            revert GraduationUnavailable();
        }
        TriplV5FeeVault(feeVault).redeemBuyback(address(this), quoteIn);
        buybackUnlocking = true;
        bytes memory result =
            IPoolManager(poolManager).unlock(abi.encode(BuybackSwap(quoteIn, minTokenOut)));
        buybackUnlocking = false;
        tokenOut = abi.decode(result, (uint256));
        if (tokenOut < minTokenOut || tokenOut == 0) revert InsufficientOutput();
        token.burnFromMarket(tokenOut);
    }

    function unlockCallback(bytes calldata rawData) external returns (bytes memory) {
        if (msg.sender != poolManager || !buybackUnlocking) revert Unauthorized();
        BuybackSwap memory data = abi.decode(rawData, (BuybackSwap));
        if (data.quoteIn == 0 || data.quoteIn > uint256(type(int256).max)) revert ZeroAmount();
        PoolKey memory key = _poolKey();
        bool zeroForOne = address(quote) == Currency.unwrap(key.currency0);
        BalanceDelta swapDelta = IPoolManager(poolManager)
            .swap(
                key,
                IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(data.quoteIn),
                sqrtPriceLimitX96: zeroForOne
                    ? TickMath.MIN_SQRT_PRICE + 1
                    : TickMath.MAX_SQRT_PRICE - 1
            }),
                bytes("")
            );
        // The hook may charge an additional quote lane, but the returned
        // manager delta must still consume exactly the redeemed budget.
        Currency input = zeroForOne ? key.currency0 : key.currency1;
        Currency output = zeroForOne ? key.currency1 : key.currency0;
        int256 inputDelta = IPoolManager(poolManager).currencyDelta(address(this), input);
        int256 outputDelta = IPoolManager(poolManager).currencyDelta(address(this), output);
        if (swapDelta == BalanceDelta.wrap(0) || inputDelta >= 0 || outputDelta <= 0) {
            revert InsufficientOutput();
        }
        if (uint256(-inputDelta) != data.quoteIn || uint256(outputDelta) < data.minTokenOut) {
            revert SlippageExceeded();
        }
        IPoolManager(poolManager).sync(input);
        uint256 beforeManager = IERC20(Currency.unwrap(input)).balanceOf(address(poolManager));
        IERC20(Currency.unwrap(input)).safeTransfer(address(poolManager), data.quoteIn);
        if (
            IERC20(Currency.unwrap(input)).balanceOf(address(poolManager))
                != beforeManager + data.quoteIn
        ) revert InexactTransfer();
        if (IPoolManager(poolManager).settle() != data.quoteIn) revert InexactTransfer();
        IPoolManager(poolManager).take(output, address(this), uint256(outputDelta));
        return abi.encode(uint256(outputDelta));
    }

    function poolKey() external view returns (PoolKey memory) {
        return _poolKey();
    }

    function poolId() external view returns (bytes32) {
        return PoolId.unwrap(_poolKey().toId());
    }

    /// @notice Returns the price that graduation will use, derived from the
    /// terminal constant-product curve and raw PoolManager currency ordering.
    function graduationSqrtPriceX96() external view returns (uint160) {
        return TickMath.getSqrtPriceAtTick(openingTick);
    }

    /// @notice Returns the valid tick after snapping terminal price to the
    /// configured v4 tick spacing.
    function graduationTick() external view returns (int24) {
        return openingTick;
    }

    /// @dev Exposed as a pure audit helper so integrations can reproduce the
    /// raw-unit ordering calculation without trusting a caller supplied tick.
    function sqrtPriceForRawReserves(
        address token_,
        address quote_,
        uint256 tokenReserve_,
        uint256 quoteReserve_
    ) external pure returns (uint160) {
        return _sqrtPriceForReserves(token_, quote_, tokenReserve_, quoteReserve_);
    }

    function _poolKey() private view returns (PoolKey memory key) {
        (address currency0, address currency1) = address(token) < address(quote)
            ? (address(token), address(quote))
            : (address(quote), address(token));
        key = PoolKey({
            currency0: Currency.wrap(currency0),
            currency1: Currency.wrap(currency1),
            fee: poolFee,
            tickSpacing: poolTickSpacing,
            hooks: IHooks(poolHook)
        });
    }

    function _initialPoolTick() private view returns (int24) {
        uint160 sqrtPrice = _sqrtPriceForReserves(
            address(token), address(quote), TriplV5Types.TOKEN_SUPPLY, initialVirtualQuoteReserve
        );
        int24 rawTick = TickMath.getTickAtSqrtPrice(sqrtPrice);
        int24 minTick = TickMath.minUsableTick(poolTickSpacing);
        int24 maxTick = TickMath.maxUsableTick(poolTickSpacing);
        if (rawTick <= minTick || rawTick >= maxTick) revert InvalidConfiguration();
        int24 remainder = rawTick % poolTickSpacing;
        int24 snapped = rawTick - remainder;
        if (rawTick < 0 && remainder != 0) snapped -= poolTickSpacing;
        if (snapped <= minTick || snapped >= maxTick) revert InvalidConfiguration();
        return snapped;
    }

    /// @dev Computes sqrt(amount1 / amount0) * Q96 from raw ERC20 reserves.
    /// Currency ordering is address based, matching PoolKey's canonical order.
    function _sqrtPriceForReserves(
        address token_,
        address quote_,
        uint256 tokenReserve_,
        uint256 quoteReserve_
    ) private pure returns (uint160) {
        if (tokenReserve_ == 0 || quoteReserve_ == 0) {
            revert GraduationUnavailable();
        }
        uint256 amount0 = token_ < quote_ ? tokenReserve_ : quoteReserve_;
        uint256 amount1 = token_ < quote_ ? quoteReserve_ : tokenReserve_;
        uint256 ratioX192 = FullMath.mulDiv(amount1, uint256(1) << 192, amount0);
        uint256 sqrtPrice = Math.sqrt(ratioX192);
        if (sqrtPrice < TickMath.MIN_SQRT_PRICE || sqrtPrice > TickMath.MAX_SQRT_PRICE) {
            revert GraduationUnavailable();
        }
        return uint160(sqrtPrice);
    }

    function _pushExact(IERC20 asset, address to, uint256 amount) private {
        if (amount == 0) return;
        uint256 marketBefore = asset.balanceOf(address(this));
        uint256 recipientBefore = asset.balanceOf(to);
        asset.safeTransfer(to, amount);
        if (
            marketBefore < asset.balanceOf(address(this))
                || marketBefore - asset.balanceOf(address(this)) != amount
                || asset.balanceOf(to) < recipientBefore
                || asset.balanceOf(to) - recipientBefore != amount
        ) revert InexactTransfer();
    }
}
