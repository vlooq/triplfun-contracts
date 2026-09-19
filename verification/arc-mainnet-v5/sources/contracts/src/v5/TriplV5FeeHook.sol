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
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {TriplV5Types} from "./TriplV5Types.sol";
import {TriplV5FeeVault} from "./TriplV5FeeVault.sol";
import {TriplV5StakingRewards} from "./TriplV5StakingRewards.sol";

interface ITriplV5LaunchToken {
    function launchBlock() external view returns (uint256);
}

/// @notice Fee enforcing adapter for a graduated v5 pool.
/// @dev Fees are minted as solvent PoolManager ERC6909 quote claims before
/// being recorded in the vault/staking ledgers. The positive hook delta makes
/// the trader pay those claims in the same swap, including both directions.
contract TriplV5FeeHook is IHooks {
    using PoolIdLibrary for PoolKey;

    uint256 private constant BPS = 10_000;
    uint256 private constant NFT_FEE_BPS = TriplV5Types.NFT_FEE_BPS;
    uint256 private constant MAX_TOTAL_FEE_BPS = TriplV5Types.MAX_TOTAL_FEE_BPS;
    bytes4 public constant V5_FEE_ROUTING_MAGIC = bytes4(keccak256("TriplV5FeeHook.v1"));

    error InvalidConfiguration();
    error InvalidPool();
    error PartialFill();
    error Unauthorized();
    error UnsupportedSwap();

    struct PoolConfig {
        bool enabled;
        address token;
        address quote;
        address market;
        address feeVault;
        address staking;
        address creator;
        uint16 creatorFeeBps;
        uint16 holderFeeBps;
        uint16 buybackFeeBps;
        uint16 splitFeeBps;
        bool firstBlockBuyTax;
    }

    struct PoolRegistration {
        address token;
        address quote;
        address market;
        address feeVault;
        address staking;
        address creator;
        uint16 creatorFeeBps;
        uint16 holderFeeBps;
        uint16 buybackFeeBps;
        uint16 splitFeeBps;
        bool firstBlockBuyTax;
    }

    IPoolManager public immutable poolManager;
    address public immutable factory;
    mapping(bytes32 => PoolConfig) private _pools;
    mapping(bytes32 => uint256) private _expectedBuyInput;
    mapping(bytes32 => uint256) public grossVolume;
    mapping(bytes32 => uint256) public feeVolume;
    mapping(bytes32 => uint256) public protectionFeeVolume;

    event PoolBound(
        bytes32 indexed poolId, address indexed token, address indexed market, address quote
    );
    event SwapFeeRecorded(
        bytes32 indexed poolId,
        address indexed trader,
        address indexed quote,
        uint256 grossAmount,
        uint256 feeAmount,
        bool buy
    );
    event FirstBlockProtectionCharged(
        bytes32 indexed poolId, address indexed trader, uint256 grossAmount, uint256 feeAmount
    );

    constructor(address poolManager_, address factory_) {
        if (poolManager_.code.length == 0 || factory_ == address(0)) revert InvalidConfiguration();
        poolManager = IPoolManager(poolManager_);
        factory = factory_;
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

    function supportsTriplV5FeeRouting() external pure returns (bytes4) {
        return V5_FEE_ROUTING_MAGIC;
    }

    function bindPool(PoolKey calldata key, PoolRegistration calldata registration) external {
        if (
            msg.sender != factory || registration.market == address(0)
                || registration.feeVault == address(0) || registration.staking == address(0)
                || registration.creator == address(0)
        ) {
            revert Unauthorized();
        }
        address c0 = Currency.unwrap(key.currency0);
        address c1 = Currency.unwrap(key.currency1);
        if (
            c0 == address(0) || c1 == address(0) || c0 >= c1
                || (c0 != registration.token && c1 != registration.token)
                || (c0 != registration.quote && c1 != registration.quote)
                || address(key.hooks) != address(this)
        ) revert InvalidPool();
        uint256 total = NFT_FEE_BPS + registration.creatorFeeBps + registration.holderFeeBps
            + registration.buybackFeeBps + registration.splitFeeBps;
        if (total > MAX_TOTAL_FEE_BPS) revert InvalidConfiguration();
        bytes32 id = PoolId.unwrap(key.toId());
        if (_pools[id].enabled) revert InvalidPool();
        _pools[id] = PoolConfig({
            enabled: true,
            token: registration.token,
            quote: registration.quote,
            market: registration.market,
            feeVault: registration.feeVault,
            staking: registration.staking,
            creator: registration.creator,
            creatorFeeBps: registration.creatorFeeBps,
            holderFeeBps: registration.holderFeeBps,
            buybackFeeBps: registration.buybackFeeBps,
            splitFeeBps: registration.splitFeeBps,
            firstBlockBuyTax: registration.firstBlockBuyTax
        });
        emit PoolBound(id, registration.token, registration.market, registration.quote);
    }

    function getPool(bytes32 id) external view returns (PoolConfig memory) {
        return _pools[id];
    }

    function beforeInitialize(address sender, PoolKey calldata key, uint160)
        external
        view
        override
        returns (bytes4)
    {
        if (
            msg.sender != address(poolManager) || !_pools[PoolId.unwrap(key.toId())].enabled
                || sender != _pools[PoolId.unwrap(key.toId())].market
        ) revert Unauthorized();
        return IHooks.beforeInitialize.selector;
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
        bytes32 id = PoolId.unwrap(key.toId());
        PoolConfig memory p = _pools[id];
        if (!p.enabled || _expectedBuyInput[id] != 0) revert InvalidPool();
        Currency input = params.zeroForOne ? key.currency0 : key.currency1;
        if (Currency.unwrap(input) != p.quote) {
            return (IHooks.beforeSwap.selector, toBeforeSwapDelta(0, 0), 0);
        }
        uint256 gross = uint256(-params.amountSpecified);
        uint256 fee = _fee(gross, p);
        uint256 protectionFee;
        if (p.firstBlockBuyTax && ITriplV5LaunchToken(p.token).launchBlock() == block.number) {
            protectionFee = Math.mulDiv(gross, TriplV5Types.BUY_TAX_BPS, BPS);
        }
        uint256 totalCharge = fee + protectionFee;
        if (fee == 0 || totalCharge >= gross || totalCharge > uint256(uint128(type(int128).max))) {
            revert InvalidConfiguration();
        }
        _expectedBuyInput[id] = gross - totalCharge;
        _route(id, p, fee, gross);
        if (protectionFee != 0) {
            poolManager.mint(
                address(0x000000000000000000000000000000000000dEaD), uint160(p.quote), protectionFee
            );
            protectionFeeVolume[id] += protectionFee;
            emit FirstBlockProtectionCharged(id, trader, gross, protectionFee);
        }
        emit SwapFeeRecorded(id, trader, p.quote, gross, fee, true);
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(int128(uint128(totalCharge)), 0), 0);
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
        bytes32 id = PoolId.unwrap(key.toId());
        PoolConfig memory p = _pools[id];
        if (!p.enabled) revert InvalidPool();
        Currency input = params.zeroForOne ? key.currency0 : key.currency1;
        if (Currency.unwrap(input) == p.quote) {
            int128 rawInput = params.zeroForOne ? delta.amount0() : delta.amount1();
            uint256 expected = _expectedBuyInput[id];
            delete _expectedBuyInput[id];
            if (rawInput >= 0 || uint256(-int256(rawInput)) != expected) revert PartialFill();
            return (IHooks.afterSwap.selector, 0);
        }
        int128 rawOutput = params.zeroForOne ? delta.amount1() : delta.amount0();
        if (rawOutput <= 0) revert UnsupportedSwap();
        uint256 gross = uint256(uint128(rawOutput));
        uint256 fee = _fee(gross, p);
        if (fee == 0 || fee > uint256(uint128(type(int128).max))) revert InvalidConfiguration();
        _route(id, p, fee, gross);
        emit SwapFeeRecorded(id, trader, p.quote, gross, fee, false);
        return (IHooks.afterSwap.selector, int128(uint128(fee)));
    }

    function _fee(uint256 amount, PoolConfig memory p) private pure returns (uint256) {
        return Math.mulDiv(
            amount,
            NFT_FEE_BPS + p.creatorFeeBps + p.holderFeeBps + p.buybackFeeBps + p.splitFeeBps,
            BPS
        );
    }

    function _route(bytes32 id, PoolConfig memory p, uint256 amount, uint256 gross) private {
        TriplV5Types.FeeBreakdown memory split;
        // `amount` is already the total fee charged on `gross`. Split that
        // charge by the configured lane weights; applying bps to `amount`
        // itself would charge and account a fee squared.
        uint256 totalBps =
            NFT_FEE_BPS + p.creatorFeeBps + p.holderFeeBps + p.buybackFeeBps + p.splitFeeBps;
        split.nft = Math.mulDiv(amount, NFT_FEE_BPS, totalBps);
        split.creator = Math.mulDiv(amount, p.creatorFeeBps, totalBps);
        split.holder = Math.mulDiv(amount, p.holderFeeBps, totalBps);
        split.buyback = Math.mulDiv(amount, p.buybackFeeBps, totalBps);
        split.split = Math.mulDiv(amount, p.splitFeeBps, totalBps);
        split.total = split.nft + split.creator + split.holder + split.buyback + split.split;
        // Preserve all charged quote units after independent flooring.
        if (split.total < amount) split.creator += amount - split.total;
        split.total = amount;
        uint256 vaultAmount = split.nft + split.creator + split.buyback + split.split;
        uint256 quoteId = uint160(p.quote);
        if (vaultAmount != 0) {
            poolManager.mint(p.feeVault, quoteId, vaultAmount);
            TriplV5FeeVault(p.feeVault)
                .recordPoolTradeFees(split.nft, split.creator, split.buyback, split.split);
        }
        if (split.holder != 0) {
            poolManager.mint(p.staking, quoteId, split.holder);
            TriplV5StakingRewards(p.staking).notifyPoolReward(split.holder);
        }
        grossVolume[id] += gross;
        feeVolume[id] += split.total;
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
