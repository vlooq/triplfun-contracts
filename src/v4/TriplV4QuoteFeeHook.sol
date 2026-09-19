// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

interface ITriplV4QuoteVault {
    function registerMarket(address market, address quote, address creator) external;
    function routeClaims(
        address market,
        address quote,
        address rewards,
        uint256 nftAmount,
        uint256 creatorAmount,
        uint256 holderAmount
    ) external;
}

/// @notice Shared Uniswap v4 fee hook for approved non-USDC quote assets.
/// The fixed 30 bps NFT leg is held for bounded conversion into USDC.
contract TriplV4QuoteFeeHook is IHooks {
    using PoolIdLibrary for PoolKey;

    uint16 internal constant BPS = 10_000;
    uint16 internal constant NFT_BPS = 30;
    uint16 internal constant MAX_TOTAL_BPS = 1_000;

    error InvalidConfiguration();
    error Unauthorized();
    error InvalidPool();
    error UnsupportedSwap();
    error FeeOverflow();
    error PartialFill();

    struct PoolRegistration {
        address token;
        address quote;
        address market;
        address locker;
        address rewards;
        address creator;
        uint16 creatorBps;
        uint16 holderBps;
    }

    struct PoolConfig {
        bool enabled;
        address token;
        address quote;
        address market;
        address locker;
        address rewards;
        address creator;
        uint16 creatorBps;
        uint16 holderBps;
    }

    IPoolManager public immutable poolManager;
    address public immutable factory;
    address public immutable feeVault;
    address public launchDeployer;
    mapping(bytes32 => PoolConfig) private _pools;
    mapping(bytes32 => uint256) private _expectedBuyInput;

    event PoolBound(
        bytes32 indexed poolId,
        address indexed token,
        address indexed quote,
        address market,
        address creator,
        uint16 creatorBps,
        uint16 holderBps
    );
    event SwapFeeRecorded(
        bytes32 indexed poolId, address indexed trader, address indexed quote, uint256 grossAmount, uint256 feeAmount, bool buy
    );

    constructor(address poolManager_, address factory_, address feeVault_) {
        if (poolManager_.code.length == 0 || factory_ == address(0) || feeVault_ == address(0)) {
            revert InvalidConfiguration();
        }
        poolManager = IPoolManager(poolManager_);
        factory = factory_;
        feeVault = feeVault_;
        Hooks.validateHookPermissions(
            IHooks(address(this)),
            Hooks.Permissions({
                beforeInitialize: true,
                afterInitialize: false,
                beforeAddLiquidity: false,
                afterAddLiquidity: false,
                beforeRemoveLiquidity: false,
                afterRemoveLiquidity: false,
                beforeSwap: true,
                afterSwap: true,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: true,
                afterSwapReturnDelta: true,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            })
        );
    }

    function bindLaunchDeployer(address launchDeployer_) external {
        if (msg.sender != factory || launchDeployer_ == address(0) || launchDeployer != address(0)) {
            revert Unauthorized();
        }
        launchDeployer = launchDeployer_;
    }

    function bindPool(PoolKey calldata key, PoolRegistration calldata r) external {
        if (msg.sender != factory || r.creator == address(0) || r.rewards == address(0)) {
            revert Unauthorized();
        }
        address c0 = Currency.unwrap(key.currency0);
        address c1 = Currency.unwrap(key.currency1);
        if (
            c0 == address(0) || c1 == address(0) || c0 >= c1
                || !((c0 == r.token && c1 == r.quote) || (c1 == r.token && c0 == r.quote))
                || address(key.hooks) != address(this)
        ) revert InvalidPool();
        if (uint256(NFT_BPS) + r.creatorBps + r.holderBps > MAX_TOTAL_BPS) {
            revert InvalidConfiguration();
        }
        bytes32 id = PoolId.unwrap(key.toId());
        if (_pools[id].enabled) revert InvalidPool();
        _pools[id] = PoolConfig({
            enabled: true,
            token: r.token,
            quote: r.quote,
            market: r.market,
            locker: r.locker,
            rewards: r.rewards,
            creator: r.creator,
            creatorBps: r.creatorBps,
            holderBps: r.holderBps
        });
        ITriplV4QuoteVault(feeVault).registerMarket(r.market, r.quote, r.creator);
        emit PoolBound(id, r.token, r.quote, r.market, r.creator, r.creatorBps, r.holderBps);
    }

    function getPool(bytes32 id) external view returns (PoolConfig memory) {
        return _pools[id];
    }

    function beforeSwap(
        address trader,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata hookData
    ) external override returns (bytes4, BeforeSwapDelta, uint24) {
        if (msg.sender != address(poolManager) || hookData.length != 0 || params.amountSpecified >= 0) {
            revert UnsupportedSwap();
        }
        bytes32 id = PoolId.unwrap(key.toId());
        PoolConfig memory p = _pools[id];
        if (!p.enabled || _expectedBuyInput[id] != 0) revert InvalidPool();
        address input = Currency.unwrap(params.zeroForOne ? key.currency0 : key.currency1);
        if (input != p.quote) return (IHooks.beforeSwap.selector, toBeforeSwapDelta(0, 0), 0);
        uint256 gross = uint256(-params.amountSpecified);
        uint256 fee = Math.mulDiv(gross, uint256(NFT_BPS) + p.creatorBps + p.holderBps, BPS);
        if (fee == 0 || fee >= gross || fee > uint256(uint128(type(int128).max))) {
            revert InvalidConfiguration();
        }
        _expectedBuyInput[id] = gross - fee;
        _route(p, fee);
        emit SwapFeeRecorded(id, trader, p.quote, gross, fee, true);
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(int128(uint128(fee)), 0), 0);
    }

    function afterSwap(
        address trader,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) external override returns (bytes4, int128) {
        if (msg.sender != address(poolManager) || hookData.length != 0 || params.amountSpecified >= 0) {
            revert UnsupportedSwap();
        }
        bytes32 id = PoolId.unwrap(key.toId());
        PoolConfig memory p = _pools[id];
        if (!p.enabled) revert InvalidPool();
        address input = Currency.unwrap(params.zeroForOne ? key.currency0 : key.currency1);
        if (input == p.quote) {
            int128 rawInput = params.zeroForOne ? delta.amount0() : delta.amount1();
            uint256 expected = _expectedBuyInput[id];
            delete _expectedBuyInput[id];
            if (rawInput >= 0 || uint256(-int256(rawInput)) != expected) revert PartialFill();
            return (IHooks.afterSwap.selector, 0);
        }
        int128 rawOutput = params.zeroForOne ? delta.amount1() : delta.amount0();
        if (rawOutput <= 0) revert UnsupportedSwap();
        uint256 gross = uint256(uint128(rawOutput));
        uint256 fee = Math.mulDiv(gross, uint256(NFT_BPS) + p.creatorBps + p.holderBps, BPS);
        if (fee == 0 || fee > uint256(uint128(type(int128).max))) revert FeeOverflow();
        _route(p, fee);
        emit SwapFeeRecorded(id, trader, p.quote, gross, fee, false);
        return (IHooks.afterSwap.selector, int128(uint128(fee)));
    }

    function _route(PoolConfig memory p, uint256 amount) private {
        uint256 totalBps = uint256(NFT_BPS) + p.creatorBps + p.holderBps;
        uint256 nftAmount = Math.mulDiv(amount, NFT_BPS, totalBps);
        uint256 creatorAmount = Math.mulDiv(amount, p.creatorBps, totalBps);
        uint256 holderAmount = amount - nftAmount - creatorAmount;
        uint256 claimId = uint160(p.quote);
        poolManager.mint(feeVault, claimId, nftAmount + creatorAmount);
        if (holderAmount != 0) poolManager.mint(p.rewards, claimId, holderAmount);
        ITriplV4QuoteVault(feeVault)
            .routeClaims(p.market, p.quote, p.rewards, nftAmount, creatorAmount, holderAmount);
    }

    function beforeInitialize(address sender, PoolKey calldata, uint160)
        external
        view
        override
        returns (bytes4)
    {
        if (msg.sender != address(poolManager) || (sender != factory && sender != launchDeployer)) {
            revert Unauthorized();
        }
        return IHooks.beforeInitialize.selector;
    }

    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure override returns (bytes4) { revert UnsupportedSwap(); }
    function beforeAddLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata) external pure override returns (bytes4) { revert UnsupportedSwap(); }
    function afterAddLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, BalanceDelta, BalanceDelta, bytes calldata) external pure override returns (bytes4, BalanceDelta) { revert UnsupportedSwap(); }
    function beforeRemoveLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata) external pure override returns (bytes4) { revert UnsupportedSwap(); }
    function afterRemoveLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, BalanceDelta, BalanceDelta, bytes calldata) external pure override returns (bytes4, BalanceDelta) { revert UnsupportedSwap(); }
    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure override returns (bytes4) { revert UnsupportedSwap(); }
    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure override returns (bytes4) { revert UnsupportedSwap(); }
}
