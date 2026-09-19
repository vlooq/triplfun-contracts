// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {TriplV4Token} from "./TriplV4Token.sol";
import {TriplV4LiquidityLocker} from "./TriplV4LiquidityLocker.sol";
import {TriplV4QuoteFeeHook} from "./TriplV4QuoteFeeHook.sol";
import {TriplV4QuoteFeeVault} from "./TriplV4QuoteFeeVault.sol";
import {TriplV4QuoteLaunchDeployer} from "./TriplV4QuoteLaunchDeployer.sol";
import {TriplV4SwapRouter} from "./TriplV4SwapRouter.sol";

/// @notice Ordinary-only extension for verified Arc RWA quotes. The canonical
/// platform token and USDC launches remain on the original V4 factory.
contract TriplV4QuoteFactory is ReentrancyGuard {
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;

    error InvalidConfiguration();
    error Unauthorized();
    error InvalidLaunch();
    error QuoteUnavailable();

    uint256 public constant TOKEN_SUPPLY = 1_000_000_000e18;
    uint16 public constant NFT_FEE_BPS = 30;
    uint16 public constant MAX_TOTAL_FEE_BPS = 1_000;

    struct QuoteConfig {
        bool enabled;
        uint8 decimals;
        int24 tickMagnitude;
        address adapter;
        bytes32 codeHash;
    }

    struct QuoteInit {
        address quote;
        bool enabled;
        int24 tickMagnitude;
        address adapter;
        bytes32 codeHash;
    }

    struct LaunchParams {
        address quote;
        string name;
        string symbol;
        string metadataURI;
        uint16 creatorFeeBps;
        uint16 holderFeeBps;
    }

    struct LaunchInfo {
        address token;
        address quote;
        address market;
        address locker;
        address rewards;
        bytes32 poolId;
        address creator;
        string name;
        string symbol;
        string metadataURI;
        uint16 creatorFeeBps;
        uint16 holderFeeBps;
    }

    address public immutable owner;
    address public immutable poolManager;
    address public immutable usdc;
    address public immutable feeShares;
    TriplV4QuoteFeeVault public immutable feeVault;
    TriplV4QuoteFeeHook public immutable hook;
    address public immutable router;
    TriplV4QuoteLaunchDeployer public immutable launchDeployer;
    uint256 public launchCount;
    mapping(address => QuoteConfig) private _quotes;
    mapping(bytes32 => bool) public isPool;
    LaunchInfo[] private _launches;

    event QuoteConfigured(
        address indexed quote,
        bool enabled,
        uint8 decimals,
        int24 tickMagnitude,
        address indexed adapter,
        bytes32 codeHash
    );
    event LaunchCreated(
        uint256 indexed index,
        address indexed token,
        address indexed quote,
        address market,
        address locker,
        address rewards,
        bytes32 poolId,
        address creator,
        string name,
        string symbol,
        string metadataURI,
        uint16 creatorFeeBps,
        uint16 holderFeeBps
    );

    constructor(
        address owner_,
        address poolManager_,
        address usdc_,
        address feeShares_,
        address feeVault_,
        address hook_,
        address router_,
        address launchDeployer_,
        QuoteInit[] memory initialQuotes
    ) {
        if (
            owner_ == address(0) || poolManager_.code.length == 0 || usdc_.code.length == 0
                || feeShares_.code.length == 0 || feeVault_.code.length == 0 || hook_.code.length == 0
                || router_.code.length == 0 || launchDeployer_.code.length == 0
                || TriplV4QuoteFeeVault(feeVault_).factory() != address(this)
                || address(TriplV4QuoteFeeVault(feeVault_).poolManager()) != poolManager_
                || address(TriplV4QuoteFeeVault(feeVault_).usdc()) != usdc_
                || TriplV4QuoteFeeVault(feeVault_).feeShares() != feeShares_
                || TriplV4QuoteFeeHook(hook_).factory() != address(this)
                || address(TriplV4QuoteFeeHook(hook_).poolManager()) != poolManager_
                || TriplV4QuoteFeeHook(hook_).feeVault() != feeVault_
                || TriplV4SwapRouter(router_).factory() != address(this)
                || address(TriplV4SwapRouter(router_).poolManager()) != poolManager_
                || TriplV4QuoteLaunchDeployer(launchDeployer_).factory() != address(this)
                || address(TriplV4QuoteLaunchDeployer(launchDeployer_).poolManager()) != poolManager_
                || address(TriplV4QuoteLaunchDeployer(launchDeployer_).hook()) != hook_
                || TriplV4QuoteLaunchDeployer(launchDeployer_).router() != router_
                || TriplV4QuoteLaunchDeployer(launchDeployer_).feeVault() != feeVault_
        ) revert InvalidConfiguration();
        owner = owner_;
        poolManager = poolManager_;
        usdc = usdc_;
        feeShares = feeShares_;
        feeVault = TriplV4QuoteFeeVault(feeVault_);
        hook = TriplV4QuoteFeeHook(hook_);
        router = router_;
        launchDeployer = TriplV4QuoteLaunchDeployer(launchDeployer_);
        feeVault.bindHook(hook_);
        hook.bindLaunchDeployer(launchDeployer_);
        for (uint256 i; i < initialQuotes.length; ++i) _configureQuote(initialQuotes[i]);
    }

    function configureQuote(
        address quote,
        bool enabled,
        int24 tickMagnitude,
        address adapter,
        bytes32 codeHash
    ) external {
        if (msg.sender != owner) revert Unauthorized();
        _configureQuote(QuoteInit(quote, enabled, tickMagnitude, adapter, codeHash));
    }

    function _configureQuote(QuoteInit memory input) private {
        address quote = input.quote;
        address adapter = input.adapter;
        bytes32 codeHash = input.codeHash;
        int24 tickMagnitude = input.tickMagnitude;
        if (
            quote == address(0) || quote == usdc || quote.code.length == 0 || adapter.code.length == 0
                || tickMagnitude <= 0 || tickMagnitude > 287_220 || tickMagnitude % 60 != 0
                || codeHash != quote.codehash
        ) revert InvalidConfiguration();
        uint8 decimals = IERC20Metadata(quote).decimals();
        if (decimals > 18) revert InvalidConfiguration();
        QuoteConfig storage current = _quotes[quote];
        if (current.adapter == address(0)) feeVault.bindQuote(quote, adapter);
        else if (current.adapter != adapter || current.codeHash != codeHash) revert InvalidConfiguration();
        _quotes[quote] = QuoteConfig(input.enabled, decimals, tickMagnitude, adapter, codeHash);
        emit QuoteConfigured(quote, input.enabled, decimals, tickMagnitude, adapter, codeHash);
    }

    function quoteConfig(address quote) external view returns (QuoteConfig memory) { return _quotes[quote]; }
    function launchInfo(uint256 index) external view returns (LaunchInfo memory) { return _launches[index]; }

    function launch(LaunchParams calldata params)
        external
        nonReentrant
        returns (address token, address market, address locker, address rewards)
    {
        QuoteConfig memory quote = _quotes[params.quote];
        if (!quote.enabled || params.quote.codehash != quote.codeHash) revert QuoteUnavailable();
        if (
            bytes(params.name).length == 0 || bytes(params.name).length > 64
                || bytes(params.symbol).length < 2 || bytes(params.symbol).length > 10
                || bytes(params.metadataURI).length == 0 || bytes(params.metadataURI).length > 500
                || uint256(NFT_FEE_BPS) + params.creatorFeeBps + params.holderFeeBps
                    > MAX_TOTAL_FEE_BPS
        ) revert InvalidLaunch();
        PoolKey memory key;
        (token, market, locker, rewards, key) = launchDeployer.deploy(
            params.name, params.symbol, params.quote, quote.tickMagnitude
        );
        TriplV4Token(token).bindMarket(market);
        TriplV4Token(token).bindHolderRewards(rewards);
        IERC20(token).safeTransfer(locker, TOKEN_SUPPLY);
        TriplV4LiquidityLocker(locker).seed();
        bytes32 id = PoolId.unwrap(key.toId());
        hook.bindPool(
            key,
            TriplV4QuoteFeeHook.PoolRegistration({
                token: token,
                quote: params.quote,
                market: market,
                locker: locker,
                rewards: rewards,
                creator: msg.sender,
                creatorBps: params.creatorFeeBps,
                holderBps: params.holderFeeBps
            })
        );
        isPool[id] = true;
        _recordLaunch(params, token, market, locker, rewards, id, msg.sender);
    }

    function _recordLaunch(
        LaunchParams calldata params,
        address token,
        address market,
        address locker,
        address rewards,
        bytes32 id,
        address creator
    ) private {
        uint256 index = launchCount++;
        LaunchInfo memory info = LaunchInfo({
            token: token,
            quote: params.quote,
            market: market,
            locker: locker,
            rewards: rewards,
            poolId: id,
            creator: creator,
            name: params.name,
            symbol: params.symbol,
            metadataURI: params.metadataURI,
            creatorFeeBps: params.creatorFeeBps,
            holderFeeBps: params.holderFeeBps
        });
        _launches.push(info);
        emit LaunchCreated(
            index,
            info.token,
            info.quote,
            info.market,
            info.locker,
            info.rewards,
            info.poolId,
            info.creator,
            info.name,
            info.symbol,
            info.metadataURI,
            info.creatorFeeBps,
            info.holderFeeBps
        );
    }
}
