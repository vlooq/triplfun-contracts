// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

interface ITriplV4FeeVault {
    function registerCreator(address market, address creator) external;
    function routeClaims(
        address market,
        address rewards,
        address creator,
        uint256 nftAmount,
        uint256 creatorAmount,
        uint256 holderAmount,
        uint256 treasuryAmount,
        address collectionRewards,
        uint256 collectionAmount
    ) external;
}

/// @notice Shared V4 swap hook. Fees are PoolManager ERC6909 claims, so the
/// fee is solvent before any receiver attempts to withdraw USDC.
contract TriplV4FeeHook is IHooks {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using TransientStateLibrary for IPoolManager;
    using SafeCast for uint256;

    uint16 internal constant BPS = 10_000;
    uint16 internal constant NFT_FEE_BPS = 30;
    uint16 internal constant PLATFORM_NFT_BPS = 100;
    uint16 internal constant PLATFORM_TREASURY_BPS = 100;
    uint16 internal constant MAX_TOTAL_BPS = 1_000;

    error InvalidConfiguration();
    error Unauthorized();
    error InvalidPool();
    error UnsupportedSwap();
    error FeeOverflow();
    error FeeNotSettled();
    error PoolAlreadyBound();
    error PartialFill();

    struct PoolConfig {
        bool enabled;
        bool platform;
        address token;
        address market;
        address locker;
        address rewards;
        address creator;
        uint16 creatorBps;
        uint16 holderBps;
        uint16 nftBps;
        uint16 treasuryBps;
        address collectionRewards;
        uint16 collectionBps;
    }

    struct PoolRegistration {
        address token;
        address market;
        address locker;
        address rewards;
        address creator;
        uint16 creatorBps;
        uint16 holderBps;
        bool platform;
        address collectionRewards;
        uint16 collectionBps;
    }

    struct FeeSplit {
        uint256 nftAmount;
        uint256 creatorAmount;
        uint256 holderAmount;
        uint256 treasuryAmount;
        uint256 collectionAmount;
    }

    IPoolManager public immutable poolManager;
    address public immutable factory;
    address public immutable usdc;
    address public immutable feeShares;
    address public immutable feeVault;
    address public launchDeployer;
    mapping(bytes32 => PoolConfig) private _pools;
    mapping(bytes32 => uint256) private _expectedBuyInput;

    event PoolBound(
        bytes32 indexed poolId,
        address indexed token,
        address indexed market,
        address rewards,
        address creator,
        bool platform,
        uint16 creatorBps,
        uint16 holderBps
    );
    event LaunchDeployerBound(address indexed launchDeployer);
    event SwapFeeRecorded(
        bytes32 indexed poolId,
        address indexed trader,
        uint256 grossAmount,
        uint256 feeAmount,
        bool buy
    );
    event FeesSettled(bytes32 indexed poolId, uint256 amount);

    constructor(
        address poolManager_,
        address factory_,
        address usdc_,
        address feeShares_,
        address feeVault_
    ) {
        if (
            poolManager_ == address(0) || factory_ == address(0) || usdc_ == address(0)
                || feeShares_ == address(0) || feeVault_ == address(0)
        ) revert InvalidConfiguration();
        poolManager = IPoolManager(poolManager_);
        factory = factory_;
        usdc = usdc_;
        feeShares = feeShares_;
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
        if (msg.sender != factory || launchDeployer_ == address(0) || launchDeployer != address(0))
        {
            revert Unauthorized();
        }
        launchDeployer = launchDeployer_;
        emit LaunchDeployerBound(launchDeployer_);
    }

    function bindPool(PoolKey calldata key, PoolRegistration calldata registration) external {
        if (
            msg.sender != factory || registration.token == address(0)
                || registration.market == address(0) || registration.locker == address(0)
        ) {
            revert Unauthorized();
        }
        if (
            Currency.unwrap(key.currency0) == address(0)
                || Currency.unwrap(key.currency1) == address(0)
                || Currency.unwrap(key.currency0) >= Currency.unwrap(key.currency1)
                || (Currency.unwrap(key.currency0) != registration.token
                    && Currency.unwrap(key.currency1) != registration.token)
                || (Currency.unwrap(key.currency0) != usdc
                    && Currency.unwrap(key.currency1) != usdc)
                || address(key.hooks) != address(this)
        ) revert InvalidPool();
        bytes32 id = _id(key);
        if (_pools[id].enabled || registration.rewards == address(0)) revert PoolAlreadyBound();
        uint16 nftBps = registration.platform ? PLATFORM_NFT_BPS : NFT_FEE_BPS;
        uint16 treasuryBps = registration.platform ? PLATFORM_TREASURY_BPS : 0;
        if (
            (registration.collectionBps == 0 && registration.collectionRewards != address(0))
                || (registration.collectionBps != 0 && registration.collectionRewards == address(0))
                || (registration.platform && registration.collectionBps != 0)
        ) revert InvalidConfiguration();
        uint256 total = uint256(nftBps) + registration.creatorBps + registration.holderBps
            + treasuryBps + registration.collectionBps;
        if (
            total == 0 || total > MAX_TOTAL_BPS
                || (registration.platform
                    && (registration.creatorBps != 0 || registration.holderBps != 0))
        ) {
            revert InvalidConfiguration();
        }
        if (!registration.platform && registration.creator == address(0)) {
            revert InvalidConfiguration();
        }
        _pools[id] = PoolConfig({
            enabled: true,
            platform: registration.platform,
            token: registration.token,
            market: registration.market,
            locker: registration.locker,
            rewards: registration.rewards,
            creator: registration.creator,
            creatorBps: registration.creatorBps,
            holderBps: registration.holderBps,
            nftBps: nftBps,
            treasuryBps: treasuryBps,
            collectionRewards: registration.collectionRewards,
            collectionBps: registration.collectionBps
        });
        ITriplV4FeeVault(feeVault).registerCreator(registration.market, registration.creator);
        emit PoolBound(
            id,
            registration.token,
            registration.market,
            registration.rewards,
            registration.creator,
            registration.platform,
            registration.creatorBps,
            registration.holderBps
        );
    }

    function getPool(bytes32 id)
        external
        view
        returns (
            bool enabled,
            bool platform,
            address token,
            address market,
            address locker,
            address rewards,
            address creator,
            uint16 creatorBps,
            uint16 holderBps,
            uint16 nftBps,
            uint16 treasuryBps
        )
    {
        PoolConfig memory p = _pools[id];
        return (
            p.enabled,
            p.platform,
            p.token,
            p.market,
            p.locker,
            p.rewards,
            p.creator,
            p.creatorBps,
            p.holderBps,
            p.nftBps,
            p.treasuryBps
        );
    }

    function beforeSwap(
        address trader,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata hookData
    ) external override returns (bytes4, BeforeSwapDelta, uint24) {
        if (
            msg.sender != address(poolManager) || hookData.length != 0
                || params.amountSpecified >= 0
        ) {
            revert UnsupportedSwap();
        }
        bytes32 id = _id(key);
        PoolConfig memory p = _pools[id];
        if (!p.enabled || _expectedBuyInput[id] != 0) revert InvalidPool();
        Currency input = params.zeroForOne ? key.currency0 : key.currency1;
        if (Currency.unwrap(input) != usdc) {
            return (IHooks.beforeSwap.selector, toBeforeSwapDelta(0, 0), 0);
        }
        uint256 gross = uint256(-params.amountSpecified);
        uint256 totalBps =
            uint256(p.nftBps) + p.creatorBps + p.holderBps + p.treasuryBps + p.collectionBps;
        uint256 fee = Math.mulDiv(gross, totalBps, BPS);
        if (fee == 0 || fee >= gross) revert InvalidConfiguration();
        _expectedBuyInput[id] = gross - fee;
        _route(p, id, fee);
        emit SwapFeeRecorded(id, trader, gross, fee, true);
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(int128(uint128(fee)), 0), 0);
    }

    function afterSwap(
        address trader,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) external override returns (bytes4, int128) {
        if (
            msg.sender != address(poolManager) || hookData.length != 0
                || params.amountSpecified >= 0
        ) {
            revert UnsupportedSwap();
        }
        bytes32 id = _id(key);
        PoolConfig memory p = _pools[id];
        if (!p.enabled) revert InvalidPool();
        Currency input = params.zeroForOne ? key.currency0 : key.currency1;
        if (Currency.unwrap(input) == usdc) {
            int128 rawInput = params.zeroForOne ? delta.amount0() : delta.amount1();
            uint256 expected = _expectedBuyInput[id];
            delete _expectedBuyInput[id];
            if (rawInput >= 0 || uint256(-int256(rawInput)) != expected) revert PartialFill();
            return (IHooks.afterSwap.selector, 0);
        }
        int128 rawOutput = params.zeroForOne ? delta.amount1() : delta.amount0();
        if (rawOutput <= 0) revert UnsupportedSwap();
        uint256 gross = uint256(uint128(rawOutput));
        uint256 fee = Math.mulDiv(
            gross,
            uint256(p.nftBps) + p.creatorBps + p.holderBps + p.treasuryBps + p.collectionBps,
            BPS
        );
        if (fee == 0 || fee > uint256(uint128(type(int128).max))) revert FeeOverflow();
        _route(p, id, fee);
        emit SwapFeeRecorded(id, trader, gross, fee, false);
        return (IHooks.afterSwap.selector, int128(uint128(fee)));
    }

    function _route(PoolConfig memory p, bytes32 id, uint256 amount) private {
        if (amount > uint256(uint128(type(int128).max))) revert FeeOverflow();
        uint256 totalBps =
            uint256(p.nftBps) + p.creatorBps + p.holderBps + p.treasuryBps + p.collectionBps;
        FeeSplit memory split;
        split.nftAmount = Math.mulDiv(amount, p.nftBps, totalBps);
        split.creatorAmount = Math.mulDiv(amount, p.creatorBps, totalBps);
        split.holderAmount = Math.mulDiv(amount, p.holderBps, totalBps);
        split.collectionAmount = Math.mulDiv(amount, p.collectionBps, totalBps);
        if (p.platform) {
            // The canonical 2% platform fee has exactly 1% NFT and 1%
            // treasury lanes; its rounding residue stays in treasury.
            split.treasuryAmount = amount - split.nftAmount;
        } else {
            // Ordinary markets never create an implicit treasury fee. Keep
            // the floor residue in an enabled discretionary lane, or NFT if
            // both optional lanes are zero.
            uint256 residue = amount - split.nftAmount - split.creatorAmount - split.holderAmount
                - split.collectionAmount;
            if (residue != 0) {
                if (p.creatorBps != 0) split.creatorAmount += residue;
                else if (p.holderBps != 0) split.holderAmount += residue;
                else if (p.collectionBps != 0) split.collectionAmount += residue;
                else split.nftAmount += residue;
            }
        }
        uint256 claimId = uint160(usdc);
        if (split.nftAmount != 0) poolManager.mint(feeShares, claimId, split.nftAmount);
        if (split.holderAmount != 0) poolManager.mint(p.rewards, claimId, split.holderAmount);
        if (split.collectionAmount != 0) {
            poolManager.mint(p.collectionRewards, claimId, split.collectionAmount);
        }
        uint256 vaultAmount = split.creatorAmount + split.treasuryAmount;
        if (vaultAmount != 0) poolManager.mint(feeVault, claimId, vaultAmount);
        ITriplV4FeeVault(feeVault)
            .routeClaims(
                p.market,
                p.rewards,
                p.creator,
                split.nftAmount,
                split.creatorAmount,
                split.holderAmount,
                split.treasuryAmount,
                p.collectionRewards,
                split.collectionAmount
            );
        emit FeesSettled(id, amount);
    }

    function _id(PoolKey calldata key) private pure returns (bytes32) {
        return PoolId.unwrap(key.toId());
    }

    /// @notice Deprecated compatibility selector. Fees are routed inline in
    /// beforeSwap/afterSwap; there is no pending fee window to flush.
    function settleFees(PoolKey calldata) external pure {
        revert FeeNotSettled();
    }

    /*
    function _legacySettle(PoolKey calldata key) external {
        if (!poolManager.isUnlocked()) revert FeeNotSettled();
        bytes32 id = key.toId();
        PoolConfig memory p = _pools[id];
    }
    */

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

    function afterInitialize(address, PoolKey calldata, uint160, int24)
        external
        pure
        override
        returns (bytes4)
    {
        revert UnsupportedSwap();
    }

    function beforeAddLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external pure override returns (bytes4) {
        revert UnsupportedSwap();
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure override returns (bytes4, BalanceDelta) {
        revert UnsupportedSwap();
    }

    function beforeRemoveLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external pure override returns (bytes4) {
        revert UnsupportedSwap();
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure override returns (bytes4, BalanceDelta) {
        revert UnsupportedSwap();
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        revert UnsupportedSwap();
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        revert UnsupportedSwap();
    }
}
