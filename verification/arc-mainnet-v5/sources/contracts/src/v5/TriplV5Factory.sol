// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {TriplV5Types} from "./TriplV5Types.sol";
import {TriplV5Token} from "./TriplV5Token.sol";
import {TriplV5Market} from "./TriplV5Market.sol";
import {TriplV5FeeVault} from "./TriplV5FeeVault.sol";
import {TriplV5StakingRewards} from "./TriplV5StakingRewards.sol";
import {TriplV5FeeHook} from "./TriplV5FeeHook.sol";
import {TriplV5HookDeployer} from "./TriplV5HookDeployer.sol";
import {ITriplV2QuoteAdapter} from "../v2/TriplV2QuoteInterfaces.sol";

interface ITriplV5SharesIdentity {
    function usdc() external view returns (address);
    function poolManager() external view returns (address);
}

interface ITriplV5TokenDeployer {
    function deploy(string calldata, string calldata, address, bool, bool, string calldata)
        external
        returns (address);
}

interface ITriplV5VaultDeployer {
    function deploy(
        address,
        address,
        address,
        address,
        address,
        address[] calldata,
        uint16[] calldata
    ) external returns (address);
}

interface ITriplV5StakingDeployer {
    function deploy(address, address, address, bool, uint64, uint64, uint16, uint16)
        external
        returns (address);
}

interface ITriplV5MarketDeployer {
    function deploy(TriplV5Market.Config calldata) external returns (address);
}

/// @notice Deploys independently configured v5 markets against factory-approved
/// ERC-20 quote assets.
contract TriplV5Factory is ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct QuoteConfig {
        bool approved;
        uint256 openingVirtualQuoteRaw;
        uint256 graduationThresholdRaw;
    }

    struct Deployers {
        address token;
        address vault;
        address staking;
        address market;
        address locker;
        address hook;
    }

    error AlreadyConfigured();
    error InvalidConfiguration();
    error InvalidCreator();
    error InvalidQuote();
    error InvalidSplit();
    error LotteryDisabled();
    error EconomicsMismatch();
    error Unauthorized();

    address public immutable owner;
    address public immutable treasury;
    address public immutable defaultQuote;
    address public immutable defaultPoolManager;
    address public immutable feeShares;
    address public immutable tokenDeployer;
    address public immutable vaultDeployer;
    address public immutable stakingDeployer;
    address public immutable marketDeployer;
    address public immutable lockerDeployer;
    address public immutable hookDeployer;
    /// @notice The single CREATE2 fee hook approved for every market created by
    /// this factory. It is configured once and cannot be replaced.
    address public feeHook;
    mapping(address => bool) public approvedQuote;
    mapping(address => QuoteConfig) public quoteConfig;
    mapping(address => address) public nftAdapterForQuote;
    mapping(address => address) public marketForToken;
    mapping(address => address) public tokenForMarket;
    mapping(bytes32 => bool) private _knownPools;
    mapping(address => TriplV5Types.LaunchInfo) private _launches;
    address[] private _tokens;
    address[] private _markets;

    event QuoteApproved(
        address indexed quote, uint256 openingVirtualQuoteRaw, uint256 graduationThresholdRaw
    );
    event LaunchCreated(
        address indexed creator,
        address indexed token,
        address indexed market,
        address quote,
        string metadataURI
    );
    event KnownPoolRegistered(address indexed token, address indexed pool, bool canonical);

    constructor(
        address quote_,
        address treasury_,
        address poolManager_,
        address feeShares_,
        Deployers memory deployers_,
        uint256 openingVirtualQuoteRaw_,
        uint256 graduationThresholdRaw_
    ) {
        if (quote_ == address(0) || quote_.code.length == 0 || treasury_ == address(0)) {
            revert InvalidConfiguration();
        }
        if (feeShares_ == address(0) || feeShares_.code.length == 0) revert InvalidConfiguration();
        if (
            deployers_.token.code.length == 0 || deployers_.vault.code.length == 0
                || deployers_.staking.code.length == 0 || deployers_.market.code.length == 0
                || deployers_.locker.code.length == 0 || deployers_.hook.code.length == 0
        ) revert InvalidConfiguration();
        address configuredUsdc;
        address configuredManager;
        try ITriplV5SharesIdentity(feeShares_).usdc() returns (address value) {
            configuredUsdc = value;
        } catch {
            revert InvalidConfiguration();
        }
        try ITriplV5SharesIdentity(feeShares_).poolManager() returns (address value) {
            configuredManager = value;
        } catch {
            revert InvalidConfiguration();
        }
        if (
            configuredUsdc == address(0) || configuredUsdc.code.length == 0
                || configuredManager != poolManager_
        ) revert InvalidConfiguration();
        _validateQuote(quote_);
        _validateQuoteEconomics(openingVirtualQuoteRaw_, graduationThresholdRaw_);
        owner = msg.sender;
        defaultQuote = quote_;
        treasury = treasury_;
        defaultPoolManager = poolManager_;
        feeShares = feeShares_;
        tokenDeployer = deployers_.token;
        vaultDeployer = deployers_.vault;
        stakingDeployer = deployers_.staking;
        marketDeployer = deployers_.market;
        lockerDeployer = deployers_.locker;
        hookDeployer = deployers_.hook;
        approvedQuote[quote_] = true;
        quoteConfig[quote_] = QuoteConfig({
            approved: true,
            openingVirtualQuoteRaw: openingVirtualQuoteRaw_,
            graduationThresholdRaw: graduationThresholdRaw_
        });
        emit QuoteApproved(quote_, openingVirtualQuoteRaw_, graduationThresholdRaw_);
    }

    /// @notice Adds an approved quote together with deployment-time reviewed
    /// raw-unit economics. No live oracle or decimal inference is used.
    function approveQuote(
        address quote_,
        uint256 openingVirtualQuoteRaw_,
        uint256 graduationThresholdRaw_
    ) external {
        if (msg.sender != owner) revert Unauthorized();
        if (quote_ == address(0) || quote_.code.length == 0) revert InvalidQuote();
        if (approvedQuote[quote_]) revert AlreadyConfigured();
        _validateQuote(quote_);
        _validateQuoteEconomics(openingVirtualQuoteRaw_, graduationThresholdRaw_);
        approvedQuote[quote_] = true;
        quoteConfig[quote_] = QuoteConfig({
            approved: true,
            openingVirtualQuoteRaw: openingVirtualQuoteRaw_,
            graduationThresholdRaw: graduationThresholdRaw_
        });
        emit QuoteApproved(quote_, openingVirtualQuoteRaw_, graduationThresholdRaw_);
    }

    /// @notice Mainnet release helper: atomically approves reviewed quotes and
    /// pins their NFT conversion adapters in one owner transaction.
    function configureQuotes(
        address[] calldata quotes_,
        uint256[] calldata openingVirtualQuoteRaw_,
        uint256[] calldata graduationThresholdRaw_,
        address[] calldata adapters_
    ) external {
        if (msg.sender != owner) revert Unauthorized();
        uint256 count = quotes_.length;
        if (
            count == 0 || count > 32 || openingVirtualQuoteRaw_.length != count
                || graduationThresholdRaw_.length != count || adapters_.length != count
        ) revert InvalidConfiguration();
        for (uint256 i; i < count; ++i) {
            address quote_ = quotes_[i];
            if (quote_ == address(0) || quote_.code.length == 0 || approvedQuote[quote_]) {
                revert InvalidQuote();
            }
            _validateQuote(quote_);
            _validateQuoteEconomics(openingVirtualQuoteRaw_[i], graduationThresholdRaw_[i]);
            approvedQuote[quote_] = true;
            quoteConfig[quote_] = QuoteConfig({
                approved: true,
                openingVirtualQuoteRaw: openingVirtualQuoteRaw_[i],
                graduationThresholdRaw: graduationThresholdRaw_[i]
            });
            _setNftAdapter(quote_, adapters_[i]);
            emit QuoteApproved(quote_, openingVirtualQuoteRaw_[i], graduationThresholdRaw_[i]);
        }
    }

    /// @notice Pins a reviewed quote-to-USDC adapter for NFT fee flushing.
    /// This must be configured before launching a non-USDC quote because the
    /// vault pins its adapter immutably. A quote may launch without one, but
    /// its NFT lane then remains explicitly pending and cannot be flushed.
    function setNftAdapter(address quote_, address adapter_) external {
        if (msg.sender != owner || !approvedQuote[quote_] || adapter_ == address(0)) {
            revert Unauthorized();
        }
        _setNftAdapter(quote_, adapter_);
    }

    function _setNftAdapter(address quote_, address adapter_) private {
        address configuredUsdc = ITriplV5SharesIdentity(feeShares).usdc();
        if (quote_ == configuredUsdc) revert InvalidQuote();
        if (adapter_.code.length == 0) revert InvalidConfiguration();
        try ITriplV2QuoteAdapter(adapter_).quoteAsset() returns (address asset) {
            if (asset != quote_) revert InvalidConfiguration();
        } catch {
            revert InvalidConfiguration();
        }
        try ITriplV2QuoteAdapter(adapter_).usdc() returns (address asset) {
            if (asset != configuredUsdc) revert InvalidConfiguration();
        } catch {
            revert InvalidConfiguration();
        }
        nftAdapterForQuote[quote_] = adapter_;
    }

    function launch(TriplV5Types.LaunchParams calldata params)
        external
        nonReentrant
        returns (address token, address market, address vault, address staking)
    {
        if (params.creator != address(0) && params.creator != msg.sender) {
            revert InvalidCreator();
        }
        if (
            feeHook == address(0) || params.poolHook != feeHook
                || (params.poolManager != address(0) && params.poolManager != defaultPoolManager)
                || params.poolFee != 0
                || (params.poolTickSpacing != 0 && params.poolTickSpacing != 60)
                || params.openingTick != 0
        ) revert InvalidConfiguration();
        address creator = params.creator == address(0) ? msg.sender : params.creator;
        address selectedQuote = params.quote == address(0) ? defaultQuote : params.quote;
        QuoteConfig memory config = quoteConfig[selectedQuote];
        if (!approvedQuote[selectedQuote] || !config.approved) revert InvalidQuote();
        if (
            params.initialVirtualQuoteReserve != config.openingVirtualQuoteRaw
                || params.graduationThreshold != config.graduationThresholdRaw
        ) revert EconomicsMismatch();
        if (
            selectedQuote != ITriplV5SharesIdentity(feeShares).usdc()
                && nftAdapterForQuote[selectedQuote] == address(0)
        ) revert InvalidQuote();
        if (bytes(params.name).length == 0 || bytes(params.name).length > 64) {
            revert InvalidConfiguration();
        }
        if (bytes(params.symbol).length == 0 || bytes(params.symbol).length > 12) {
            revert InvalidConfiguration();
        }
        if (bytes(params.metadataURI).length == 0 || bytes(params.metadataURI).length > 2048) {
            revert InvalidConfiguration();
        }
        if (params.initialVirtualQuoteReserve == 0 || params.graduationThreshold == 0) {
            revert InvalidConfiguration();
        }
        if (params.moduleKind == TriplV5Types.ModuleKind.LotteryReserved) revert LotteryDisabled();
        _validateSplit(params.splitRecipients, params.splitWeights);
        _validateFees(params);

        (token, market, vault, staking) = _createLaunch(params, selectedQuote, creator);
        _knownPools[TriplV5Market(market).poolId()] = true;
        marketForToken[token] = market;
        tokenForMarket[market] = token;
        _tokens.push(token);
        _markets.push(market);
        _launches[token] = TriplV5Types.LaunchInfo({
            token: token,
            market: market,
            feeVault: vault,
            staking: staking,
            creator: creator,
            quote: selectedQuote,
            poolHook: params.poolHook,
            launchBlock: 0,
            graduationThreshold: params.graduationThreshold,
            creatorFeeBps: params.creatorFeeBps,
            holderFeeBps: params.holderFeeBps,
            buybackFeeBps: params.buybackFeeBps,
            splitFeeBps: params.splitFeeBps,
            moduleKind: params.moduleKind,
            firstBlockBuyTax: params.firstBlockBuyTax,
            transferRestriction30Days: params.transferRestriction30Days,
            diamondHands: params.diamondHands,
            graduated: false,
            metadataURI: params.metadataURI
        });
        _emitLaunchCreated(creator, token, market, selectedQuote, params.metadataURI);
    }

    function getLaunch(address token) external view returns (TriplV5Types.LaunchInfo memory) {
        TriplV5Types.LaunchInfo memory info = _launches[token];
        if (info.market != address(0)) {
            info.graduated = TriplV5Market(info.market).graduated();
            info.launchBlock = TriplV5Token(info.token).launchBlock();
        }
        return info;
    }

    function _createLaunch(
        TriplV5Types.LaunchParams calldata params,
        address selectedQuote,
        address creator_
    ) private returns (address token, address market, address vault, address staking) {
        TriplV5Token tokenContract = _deployToken(params, creator_);
        address manager = params.poolManager == address(0) ? defaultPoolManager : params.poolManager;
        TriplV5FeeVault vaultContract = _deployVault(params, selectedQuote, creator_, manager);
        TriplV5StakingRewards stakingContract =
            _deployStaking(params, selectedQuote, address(tokenContract), manager);
        TriplV5Market marketContract = _deployMarket(
            params,
            selectedQuote,
            creator_,
            address(tokenContract),
            address(vaultContract),
            address(stakingContract)
        );
        vaultContract.bindMarket(address(marketContract));
        stakingContract.bindMarket(address(marketContract));
        tokenContract.bindMarket(address(marketContract));
        _bindFeeHook(
            params,
            selectedQuote,
            creator_,
            tokenContract,
            marketContract,
            vaultContract,
            stakingContract
        );
        IERC20(address(tokenContract))
            .safeTransfer(address(marketContract), TriplV5Types.TOKEN_SUPPLY);
        marketContract.initializeLiquidity();
        return (
            address(tokenContract),
            address(marketContract),
            address(vaultContract),
            address(stakingContract)
        );
    }

    function launchCount() external view returns (uint256) {
        return _tokens.length;
    }

    function tokenAt(uint256 index) external view returns (address) {
        return _tokens[index];
    }

    function marketAt(uint256 index) external view returns (address) {
        return _markets[index];
    }

    /// @notice V4-router compatibility for the verified V5 venue.
    function isPool(bytes32 poolId_) external view returns (bool) {
        return _knownPools[poolId_];
    }

    /// @notice V4-router compatibility for the single factory-approved hook.
    function hook() external view returns (address) {
        return feeHook;
    }

    /// @notice Register an address the token can actually classify. Wallet to
    /// wallet transfers remain available during the restriction window.
    function registerKnownPool(address token, address pool, bool canonical) external {
        if (msg.sender != owner || marketForToken[token] == address(0) || pool == address(0)) {
            revert Unauthorized();
        }
        TriplV5Token(token).registerKnownPool(pool, canonical);
        emit KnownPoolRegistered(token, pool, canonical);
    }

    function setCanonicalVenue(address token, address venue) external {
        if (msg.sender != owner || marketForToken[token] == address(0)) revert Unauthorized();
        TriplV5Market(marketForToken[token]).setCanonicalVenue(venue);
        TriplV5Token(token).registerKnownPool(venue, true);
    }

    /// @notice Deploy a v5 fee hook at a caller-mined CREATE2 address.
    function deployFeeHook(bytes32 salt, address poolManager_)
        external
        returns (address deployedHook)
    {
        if (msg.sender != owner) revert Unauthorized();
        if (feeHook != address(0)) revert AlreadyConfigured();
        if (poolManager_ != defaultPoolManager) revert InvalidConfiguration();
        deployedHook = TriplV5HookDeployer(hookDeployer).deploy(salt, poolManager_);
        feeHook = deployedHook;
    }

    function _deployToken(TriplV5Types.LaunchParams calldata params, address creator_)
        private
        returns (TriplV5Token)
    {
        return TriplV5Token(
            ITriplV5TokenDeployer(tokenDeployer)
                .deploy(
                    params.name,
                    params.symbol,
                    creator_,
                    params.firstBlockBuyTax,
                    params.transferRestriction30Days,
                    params.metadataURI
                )
        );
    }

    function _deployVault(
        TriplV5Types.LaunchParams calldata params,
        address quote_,
        address creator_,
        address manager_
    ) private returns (TriplV5FeeVault) {
        return TriplV5FeeVault(
            ITriplV5VaultDeployer(vaultDeployer)
                .deploy(
                    quote_,
                    creator_,
                    manager_,
                    feeShares,
                    nftAdapterForQuote[quote_],
                    params.splitRecipients,
                    params.splitWeights
                )
        );
    }

    function _deployStaking(
        TriplV5Types.LaunchParams calldata params,
        address quote_,
        address token_,
        address manager_
    ) private returns (TriplV5StakingRewards) {
        return TriplV5StakingRewards(
            ITriplV5StakingDeployer(stakingDeployer)
                .deploy(
                    token_,
                    quote_,
                    manager_,
                    params.diamondHands,
                    params.tierOneDuration,
                    params.tierTwoDuration,
                    params.tierOneMultiplierBps,
                    params.tierTwoMultiplierBps
                )
        );
    }

    function _deployMarket(
        TriplV5Types.LaunchParams calldata params,
        address quote_,
        address creator_,
        address token_,
        address vault_,
        address staking_
    ) private returns (TriplV5Market) {
        return TriplV5Market(
            ITriplV5MarketDeployer(marketDeployer)
                .deploy(_marketConfig(params, quote_, creator_, token_, vault_, staking_))
        );
    }

    function _bindFeeHook(
        TriplV5Types.LaunchParams calldata params,
        address quote_,
        address creator_,
        TriplV5Token token_,
        TriplV5Market market_,
        TriplV5FeeVault vault_,
        TriplV5StakingRewards staking_
    ) private {
        if (params.poolHook == address(0)) return;
        vault_.bindFeeHook(params.poolHook);
        staking_.bindFeeHook(params.poolHook);
        TriplV5FeeHook(params.poolHook)
            .bindPool(
                market_.poolKey(),
                TriplV5FeeHook.PoolRegistration({
                token: address(token_),
                quote: quote_,
                market: address(market_),
                feeVault: address(vault_),
                staking: address(staking_),
                creator: creator_,
                creatorFeeBps: params.creatorFeeBps,
                holderFeeBps: params.holderFeeBps,
                buybackFeeBps: params.buybackFeeBps,
                splitFeeBps: params.splitFeeBps,
                firstBlockBuyTax: params.firstBlockBuyTax
            })
            );
    }

    function _marketConfig(
        TriplV5Types.LaunchParams calldata params,
        address quote_,
        address creator_,
        address token_,
        address vault_,
        address staking_
    ) private view returns (TriplV5Market.Config memory) {
        address manager = params.poolManager == address(0) ? defaultPoolManager : params.poolManager;
        uint24 fee = params.poolFee;
        int24 spacing = params.poolTickSpacing == 0 ? int24(60) : params.poolTickSpacing;
        return TriplV5Market.Config({
            factory: address(this),
            token: token_,
            quote: quote_,
            feeVault: vault_,
            staking: staking_,
            creator: creator_,
            initialVirtualQuoteReserve: params.initialVirtualQuoteReserve,
            graduationThreshold: params.graduationThreshold,
            creatorFeeBps: params.creatorFeeBps,
            holderFeeBps: params.holderFeeBps,
            buybackFeeBps: params.buybackFeeBps,
            splitFeeBps: params.splitFeeBps,
            moduleKind: uint8(params.moduleKind),
            maxBuybackQuote: params.maxBuybackQuote,
            firstBlockBuyTax: params.firstBlockBuyTax,
            transferRestriction30Days: params.transferRestriction30Days,
            poolManager: manager,
            lockerDeployer: lockerDeployer,
            poolHook: params.poolHook,
            poolFee: fee,
            poolTickSpacing: spacing
        });
    }

    function _validateQuote(address quote_) private view {
        try IERC20Metadata(quote_).decimals() returns (uint8 decimals) {
            if (decimals < 6 || decimals > 18) revert InvalidQuote();
        } catch {
            revert InvalidQuote();
        }
    }

    /// @dev Economics are reviewed in quote raw units at configuration time.
    /// The product's USD conversion therefore never depends on a live oracle,
    /// and launch callers cannot silently change the opening cap or graduation
    /// target for an approved quote.
    function _validateQuoteEconomics(uint256 openingRaw, uint256 graduationRaw) private pure {
        if (openingRaw == 0 || graduationRaw == 0) revert InvalidConfiguration();
        // The curve's initial invariant multiplies token supply by this value.
        // Keep that product inside uint256 before a launch is accepted.
        if (openingRaw > type(uint256).max / TriplV5Types.TOKEN_SUPPLY) {
            revert InvalidConfiguration();
        }
    }

    function _emitLaunchCreated(
        address creator_,
        address token_,
        address market_,
        address quote_,
        string calldata metadataURI_
    ) private {
        emit LaunchCreated(creator_, token_, market_, quote_, metadataURI_);
    }

    function _validateSplit(address[] calldata recipients, uint16[] calldata weights) private pure {
        if (
            recipients.length != weights.length
                || recipients.length > TriplV5Types.MAX_SPLIT_RECIPIENTS
        ) {
            revert InvalidSplit();
        }
        if (recipients.length == 0) return;
        uint256 total;
        for (uint256 i; i < recipients.length; ++i) {
            if (recipients[i] == address(0) || weights[i] == 0) revert InvalidSplit();
            for (uint256 j; j < i; ++j) {
                if (recipients[i] == recipients[j]) revert InvalidSplit();
            }
            total += weights[i];
        }
        if (total != TriplV5Types.BPS) revert InvalidSplit();
    }

    function _validateFees(TriplV5Types.LaunchParams calldata params) private pure {
        uint256 total = TriplV5Types.NFT_FEE_BPS + params.creatorFeeBps + params.holderFeeBps
            + params.buybackFeeBps + params.splitFeeBps;
        if (total > TriplV5Types.MAX_TOTAL_FEE_BPS) revert InvalidConfiguration();
        if (
            params.moduleKind == TriplV5Types.ModuleKind.None
                && (params.buybackFeeBps != 0 || params.maxBuybackQuote != 0)
        ) {
            revert InvalidConfiguration();
        }
        if (
            params.moduleKind == TriplV5Types.ModuleKind.Buyback
                && (params.buybackFeeBps == 0 || params.maxBuybackQuote == 0)
        ) {
            revert InvalidConfiguration();
        }
        if (params.splitFeeBps != 0 && params.splitRecipients.length == 0) revert InvalidSplit();
        if (params.diamondHands) {
            if (
                params.tierTwoDuration < params.tierOneDuration
                    || params.tierOneMultiplierBps < 10_000
                    || params.tierTwoMultiplierBps < params.tierOneMultiplierBps
            ) revert InvalidConfiguration();
        }
    }
}
