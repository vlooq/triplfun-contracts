// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {TriplV4Types} from "./TriplV4Types.sol";
import {TriplV4Token} from "./TriplV4Token.sol";
import {TriplV4FeeVault} from "./TriplV4FeeVault.sol";
import {TriplV4FeeHook} from "./TriplV4FeeHook.sol";
import {TriplV4HookDeployer} from "./TriplV4HookDeployer.sol";
import {TriplV4SwapRouter} from "./TriplV4SwapRouter.sol";
import {TriplV4LaunchDeployer} from "./TriplV4LaunchDeployer.sol";
import {TriplV4LiquidityLocker} from "./TriplV4LiquidityLocker.sol";
import {TriplV4InfrastructureDeployer} from "./TriplV4InfrastructureDeployer.sol";
import {TriplV4CollectionDeployer} from "./TriplV4CollectionDeployer.sol";

interface ITriplV4SharesFactory {
    function factory() external view returns (address);
    function bindFeeVault(address vault) external;
}

/// @notice Standalone canonical-first factory for Triplfun V4 markets.
/// @dev A supplied V4 FeeShares collection is bound to this factory's vault;
/// no V1 deployment is needed. Launch index zero is authenticated to the
/// immutable platformCreator and is the only platform token.
contract TriplV4Factory is ReentrancyGuard {
    /// @dev Arc mainnet's PoolManager is a protocol dependency, not a
    /// deployer-selected implementation. Local and testnet deployments keep
    /// accepting a code-bearing manager so they can use isolated fixtures.
    address public constant ARC_MAINNET_POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address public constant ARC_MAINNET_USDC = 0x3600000000000000000000000000000000000000;

    error InvalidConfiguration();
    error InvalidLaunch();
    error PlatformCreatorOnly();
    error CanonicalAlreadyLaunched();
    error UnauthorizedInitializer();
    error InfrastructureAlreadyInitialized();
    error InfrastructureNotInitialized();

    uint256 public constant TARGET_INITIAL_FDV_USDC = 4_000e6;
    uint256 public constant TOKEN_SUPPLY = 1_000_000_000e18;
    int24 public constant TICK_SPACING = 60;
    uint256 public constant MAX_COLLECTION_TOKEN_IDS = 5_000;

    IPoolManager public immutable poolManager;
    address public immutable usdc;
    address public immutable treasury;
    address public immutable nftRecipient;
    address public immutable platformCreator;
    address public immutable feeShares;
    TriplV4FeeVault public feeVault;
    TriplV4HookDeployer public hookDeployer;
    TriplV4LaunchDeployer public launchDeployer;
    address public immutable infrastructureDeployer;
    address public immutable collectionDeployer;
    TriplV4FeeHook public hook;
    TriplV4SwapRouter public router;
    address private immutable deploymentSigner;
    address private immutable deploymentLaunchFactory;
    bytes32 private immutable deploymentHookSalt;
    bool public infrastructureInitialized;
    address public platformToken;
    address public platformMarket;
    uint256 public launchCount;

    mapping(address => bool) public isMarket;
    mapping(bytes32 => bool) public isPool;
    TriplV4Types.LaunchInfo[] private _launches;

    struct Binding {
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

    struct Runtime {
        address token;
        address market;
        address locker;
        address rewards;
        bytes32 poolId;
        int24 initialTick;
        int24 upperTick;
        address collectionRewards;
    }

    struct InfrastructureRuntime {
        address feeVault;
        address hookDeployer;
        address hook;
        address router;
        address launchDeployer;
    }

    struct FactoryConfig {
        address poolManager;
        address usdc;
        address treasury;
        address nftRecipient;
        address platformCreator;
        address collectionDeployer;
        address infrastructureDeployer;
        address launchFactory;
        bytes32 hookSalt;
        uint256 mintPrice;
        uint256 saleStart;
        string nftBaseURI;
    }

    struct CollectionConfig {
        address collection;
        address rewards;
        uint16 feeBps;
        bytes32 snapshotRoot;
        uint256 tokenCount;
    }

    mapping(bytes32 => CollectionConfig) public collectionConfig;

    event LaunchCreated(
        uint256 indexed index,
        address indexed token,
        address indexed hook,
        address market,
        address locker,
        address rewards,
        bytes32 poolId,
        address creator,
        string name,
        string symbol,
        string metadataURI,
        uint16 creatorFeeBps,
        uint16 holderFeeBps,
        bool platformToken
    );
    event CollectionConfigured(
        bytes32 indexed poolId,
        address indexed collection,
        address indexed rewards,
        uint16 feeBps,
        bytes32 snapshotRoot,
        uint256 tokenCount,
        uint256[] tokenIds
    );
    event InfrastructureInitialized(
        address indexed feeVault,
        address indexed hook,
        address indexed router,
        address hookDeployer,
        address launchDeployer
    );

    constructor(FactoryConfig memory config) {
        if (
            config.poolManager == address(0) || config.poolManager.code.length == 0
                || config.usdc == address(0) || config.usdc.code.length == 0
                || config.treasury == address(0) || config.nftRecipient == address(0)
                || config.platformCreator == address(0) || config.collectionDeployer == address(0)
                || config.collectionDeployer.code.length == 0
                || config.infrastructureDeployer == address(0)
                || config.infrastructureDeployer.code.length == 0 || config.mintPrice == 0
                || config.saleStart == 0 || bytes(config.nftBaseURI).length == 0
                || config.launchFactory == address(0) || config.launchFactory.code.length == 0
        ) revert InvalidConfiguration();
        if (
            block.chainid == 5042
                && (config.poolManager != ARC_MAINNET_POOL_MANAGER
                    || config.usdc != ARC_MAINNET_USDC)
        ) {
            revert InvalidConfiguration();
        }
        try IERC20Metadata(config.usdc).decimals() returns (uint8 decimals) {
            if (decimals != 6) revert InvalidConfiguration();
        } catch {
            revert InvalidConfiguration();
        }
        poolManager = IPoolManager(config.poolManager);
        usdc = config.usdc;
        treasury = config.treasury;
        nftRecipient = config.nftRecipient;
        platformCreator = config.platformCreator;
        collectionDeployer = config.collectionDeployer;
        infrastructureDeployer = config.infrastructureDeployer;
        deploymentSigner = msg.sender;
        deploymentLaunchFactory = config.launchFactory;
        deploymentHookSalt = config.hookSalt;
        address deployedShares = _createCollection(
            config.collectionDeployer,
            config.poolManager,
            config.usdc,
            config.treasury,
            config.nftRecipient,
            config.mintPrice,
            config.saleStart,
            config.nftBaseURI
        );
        if (deployedShares == address(0) || deployedShares.code.length == 0) {
            revert InvalidConfiguration();
        }
        try ITriplV4SharesFactory(deployedShares).factory() returns (address owner) {
            if (owner != address(this)) revert InvalidConfiguration();
        } catch {
            revert InvalidConfiguration();
        }
        feeShares = deployedShares;
    }

    /// @notice Creates and binds the heavy V4 infrastructure in a separate
    /// transaction so Factory deployment stays below Arc's gas-estimation cap.
    /// @dev Only the account that created this Factory may call this once. Any
    /// failed child creation or binding reverts the whole initialization.
    function initializeInfrastructure() external nonReentrant {
        if (msg.sender != deploymentSigner) revert UnauthorizedInitializer();
        if (infrastructureInitialized) revert InfrastructureAlreadyInitialized();
        InfrastructureRuntime memory infrastructure = _createInfrastructure(
            infrastructureDeployer,
            address(poolManager),
            usdc,
            treasury,
            feeShares,
            deploymentLaunchFactory,
            deploymentHookSalt
        );
        feeVault = TriplV4FeeVault(infrastructure.feeVault);
        hookDeployer = TriplV4HookDeployer(infrastructure.hookDeployer);
        hook = TriplV4FeeHook(infrastructure.hook);
        router = TriplV4SwapRouter(infrastructure.router);
        launchDeployer = TriplV4LaunchDeployer(infrastructure.launchDeployer);
        if (launchDeployer.factory() != address(this)) revert InvalidConfiguration();
        hook.bindLaunchDeployer(infrastructure.launchDeployer);
        feeVault.bindHook(infrastructure.hook);
        ITriplV4SharesFactory(feeShares).bindFeeVault(infrastructure.feeVault);
        infrastructureInitialized = true;
        emit InfrastructureInitialized(
            address(feeVault), address(hook), address(router), address(hookDeployer), address(launchDeployer)
        );
    }

    function _createCollection(
        address deployer,
        address poolManager_,
        address usdc_,
        address treasury_,
        address nftRecipient_,
        uint256 mintPrice_,
        uint256 saleStart_,
        string memory baseURI_
    ) private returns (address) {
        TriplV4CollectionDeployer.CollectionConfig memory config;
        config.usdc = usdc_;
        config.treasury = treasury_;
        config.nftRecipient = nftRecipient_;
        config.mintPrice = mintPrice_;
        config.saleStart = saleStart_;
        config.baseURI = baseURI_;
        config.factory = address(this);
        config.poolManager = poolManager_;
        return TriplV4CollectionDeployer(deployer).deploy(address(this), config);
    }

    function _createInfrastructure(
        address deployer,
        address poolManager_,
        address usdc_,
        address treasury_,
        address feeShares_,
        address launchFactory_,
        bytes32 hookSalt_
    ) private returns (InfrastructureRuntime memory runtime) {
        TriplV4InfrastructureDeployer.InfrastructureConfig memory config;
        config.poolManager = poolManager_;
        config.usdc = usdc_;
        config.treasury = treasury_;
        config.feeShares = feeShares_;
        config.launchFactory = launchFactory_;
        config.hookSalt = hookSalt_;
        (
            runtime.feeVault,
            runtime.hookDeployer,
            runtime.hook,
            runtime.router,
            runtime.launchDeployer
        ) = TriplV4InfrastructureDeployer(deployer).deploy(address(this), config);
    }

    function launch(TriplV4Types.LaunchParams calldata params)
        external
        nonReentrant
        returns (
            address token,
            address market,
            address deployedHook,
            address rewards,
            bytes32 poolId
        )
    {
        if (!infrastructureInitialized) revert InfrastructureNotInitialized();
        bool platform = platformToken == address(0);
        if (!_validLaunchFields(params.name, params.symbol, params.metadataURI)) {
            revert InvalidLaunch();
        }
        if (params.collectionFeeBps != 0 || params.moduleFeeBps != 0 || params.moduleKind != 0) {
            revert InvalidLaunch();
        }
        uint256 totalFee = uint256(params.creatorFeeBps) + params.holderFeeBps + 30;
        if (platform) {
            if (msg.sender != platformCreator) revert PlatformCreatorOnly();
            if (params.creatorFeeBps != 0 || params.holderFeeBps != 0) revert InvalidLaunch();
        } else if (totalFee > 1_000 || params.creatorFeeBps > 1_000 || params.holderFeeBps > 1_000)
        {
            revert InvalidLaunch();
        }
        if (
            platform
                && (keccak256(bytes(params.name)) != keccak256(bytes("tr!pl"))
                    || keccak256(bytes(params.symbol)) != keccak256(bytes("tr!pl")))
        ) revert InvalidLaunch();
        if (params.initialTick % TICK_SPACING != 0 || params.upperTick % TICK_SPACING != 0) {
            revert InvalidLaunch();
        }

        Runtime memory runtime =
            _deployLaunch(params, platform, msg.sender, address(0), bytes32(0), 0);
        poolId = runtime.poolId;
        token = runtime.token;
        market = runtime.market;
        deployedHook = address(hook);
        rewards = runtime.rewards;
        _recordLaunch(params, platform, runtime, msg.sender);
    }

    /// @notice Launch an ordinary market with a fixed external ERC-721
    /// ownership snapshot receiving an additional fee lane.
    /// @dev The explicit sorted token-id list is committed on-chain and emitted
    /// so indexers can reconstruct the exact claim set without trusting an
    /// off-chain root input.
    function launchWithCollection(
        TriplV4Types.LaunchParams calldata params,
        address collection,
        uint256[] calldata tokenIds
    )
        external
        nonReentrant
        returns (
            address token,
            address market,
            address deployedHook,
            address rewards,
            bytes32 poolId
        )
    {
        if (!infrastructureInitialized) revert InfrastructureNotInitialized();
        if (
            platformToken == address(0) || collection == address(0) || collection.code.length == 0
                || params.collectionFeeBps == 0 || params.moduleFeeBps != 0
                || params.moduleKind != 0 || tokenIds.length == 0
                || tokenIds.length > MAX_COLLECTION_TOKEN_IDS
        ) revert InvalidLaunch();
        if (!_validLaunchFields(params.name, params.symbol, params.metadataURI)) {
            revert InvalidLaunch();
        }
        uint256 totalFee =
            uint256(params.creatorFeeBps) + params.holderFeeBps + params.collectionFeeBps + 30;
        if (totalFee > 1_000 || params.creatorFeeBps > 1_000 || params.holderFeeBps > 1_000) {
            revert InvalidLaunch();
        }
        if (params.initialTick % TICK_SPACING != 0 || params.upperTick % TICK_SPACING != 0) {
            revert InvalidLaunch();
        }
        for (uint256 i = 1; i < tokenIds.length; ++i) {
            if (tokenIds[i] <= tokenIds[i - 1]) revert InvalidLaunch();
        }
        bytes32 snapshotRoot = _buildRoot(tokenIds);
        Runtime memory runtime =
            _deployLaunch(params, false, msg.sender, collection, snapshotRoot, tokenIds.length);
        poolId = runtime.poolId;
        token = runtime.token;
        market = runtime.market;
        deployedHook = address(hook);
        rewards = runtime.rewards;
        _recordLaunch(params, false, runtime, msg.sender);
        _recordCollection(
            poolId,
            collection,
            runtime.collectionRewards,
            params.collectionFeeBps,
            snapshotRoot,
            tokenIds
        );
    }

    function getLaunch(uint256 index) external view returns (TriplV4Types.LaunchInfo memory) {
        return _launches[index];
    }

    function _recordLaunch(
        TriplV4Types.LaunchParams calldata params,
        bool platform,
        Runtime memory runtime,
        address creator
    ) private {
        uint256 index = launchCount++;
        isMarket[runtime.market] = true;
        isPool[runtime.poolId] = true;
        if (platform) {
            platformToken = runtime.token;
            platformMarket = runtime.market;
        }
        TriplV4Types.LaunchInfo memory info = TriplV4Types.LaunchInfo({
            token: runtime.token,
            market: runtime.market,
            hook: address(hook),
            locker: runtime.locker,
            rewards: runtime.rewards,
            poolId: runtime.poolId,
            creator: creator,
            name: params.name,
            symbol: params.symbol,
            metadataURI: params.metadataURI,
            creatorFeeBps: platform ? 0 : params.creatorFeeBps,
            holderFeeBps: platform ? 0 : params.holderFeeBps,
            collectionFeeBps: platform ? 0 : params.collectionFeeBps,
            moduleFeeBps: 0,
            moduleKind: 0,
            initialTick: runtime.initialTick,
            upperTick: runtime.upperTick,
            totalSupply: TOKEN_SUPPLY,
            platformToken: platform
        });
        _launches.push(info);
        _emitLaunch(index, info);
    }

    function _emitLaunch(uint256 index, TriplV4Types.LaunchInfo memory info) private {
        emit LaunchCreated(
            index,
            info.token,
            address(hook),
            info.market,
            info.locker,
            info.rewards,
            info.poolId,
            info.creator,
            info.name,
            info.symbol,
            info.metadataURI,
            info.creatorFeeBps,
            info.holderFeeBps,
            info.platformToken
        );
    }

    function _deployLaunch(
        TriplV4Types.LaunchParams calldata params,
        bool platform,
        address creator,
        address collection,
        bytes32 snapshotRoot,
        uint256 tokenCount
    ) private returns (Runtime memory runtime) {
        PoolKey memory key;
        int24 lower;
        int24 upper;
        int24 initialTick;
        (
            runtime.token,
            runtime.market,
            runtime.locker,
            runtime.rewards,
            key,
            lower,
            upper,
            initialTick
        ) = launchDeployer.deploy(params);
        TriplV4Token(runtime.token).bindMarket(runtime.market);
        TriplV4Token(runtime.token).bindHolderRewards(runtime.rewards);
        TriplV4Token(runtime.token).transfer(runtime.locker, TOKEN_SUPPLY);
        if (collection != address(0)) {
            runtime.collectionRewards =
                _createCollectionRewards(collection, snapshotRoot, tokenCount);
        }
        Binding memory binding;
        binding.token = runtime.token;
        binding.market = runtime.market;
        binding.locker = runtime.locker;
        binding.rewards = runtime.rewards;
        binding.creator = platform ? address(0) : creator;
        binding.creatorBps = platform ? 0 : params.creatorFeeBps;
        binding.holderBps = platform ? 0 : params.holderFeeBps;
        binding.platform = platform;
        binding.collectionRewards = runtime.collectionRewards;
        binding.collectionBps = platform ? 0 : params.collectionFeeBps;
        _bindPool(key, binding);
        TriplV4LiquidityLocker(runtime.locker).seed();
        runtime.poolId = PoolId.unwrap(key.toId());
        runtime.initialTick = initialTick;
        runtime.upperTick = params.upperTick == 0
            ? (runtime.token < usdc ? initialTick + 600_000 : initialTick)
            : params.upperTick;
    }

    function _bindPool(PoolKey memory key, Binding memory binding) private {
        hook.bindPool(
            key,
            TriplV4FeeHook.PoolRegistration({
                token: binding.token,
                market: binding.market,
                locker: binding.locker,
                rewards: binding.rewards,
                creator: binding.creator,
                creatorBps: binding.creatorBps,
                holderBps: binding.holderBps,
                platform: binding.platform,
                collectionRewards: binding.collectionRewards,
                collectionBps: binding.collectionBps
            })
        );
    }

    function _createCollectionRewards(address collection, bytes32 snapshotRoot, uint256 tokenCount)
        private
        returns (address rewards)
    {
        TriplV4CollectionDeployer.ExternalCollectionConfig memory config =
            TriplV4CollectionDeployer.ExternalCollectionConfig({
                collection: collection,
                quote: usdc,
                poolManager: address(poolManager),
                vault: address(feeVault),
                snapshotRoot: snapshotRoot,
                tokenCount: tokenCount
            });
        rewards = TriplV4CollectionDeployer(collectionDeployer)
            .deployExternalRewards(address(this), config);
        if (rewards == address(0) || rewards.code.length == 0) revert InvalidConfiguration();
    }

    function _recordCollection(
        bytes32 poolId,
        address collection,
        address rewards,
        uint16 feeBps,
        bytes32 snapshotRoot,
        uint256[] calldata tokenIds
    ) private {
        collectionConfig[poolId] = CollectionConfig({
            collection: collection,
            rewards: rewards,
            feeBps: feeBps,
            snapshotRoot: snapshotRoot,
            tokenCount: tokenIds.length
        });
        emit CollectionConfigured(
            poolId, collection, rewards, feeBps, snapshotRoot, tokenIds.length, tokenIds
        );
    }

    function _buildRoot(uint256[] calldata tokenIds) private pure returns (bytes32 root) {
        uint256 length = tokenIds.length;
        uint256 size = 1;
        while (size < length) size <<= 1;
        bytes32[] memory level = new bytes32[](size);
        for (uint256 i; i < length; ++i) {
            level[i] = _hashLeaf(i, tokenIds[i]);
        }
        // Duplicate the final real leaf hash, including its original index,
        // so off-chain proofs and V2 snapshots use the same complete tree.
        for (uint256 i = length; i < size; ++i) {
            level[i] = level[length - 1];
        }
        while (size > 1) {
            for (uint256 i; i < size; i += 2) {
                level[i / 2] = _hashPair(level[i], level[i + 1]);
            }
            size /= 2;
        }
        return level[0];
    }

    function _hashPair(bytes32 left, bytes32 right) private pure returns (bytes32) {
        (left, right) = left < right ? (left, right) : (right, left);
        return keccak256(abi.encode(left, right));
    }

    function _hashLeaf(uint256 index, uint256 tokenId) private pure returns (bytes32) {
        return keccak256(abi.encode(index, tokenId));
    }

    function _validLaunchFields(
        string calldata name,
        string calldata symbol,
        string calldata metadata
    ) private pure returns (bool) {
        bytes memory n = bytes(name);
        bytes memory s = bytes(symbol);
        bytes memory m = bytes(metadata);
        if (
            n.length == 0 || n.length > 64 || s.length == 0 || s.length > 12 || m.length == 0
                || m.length > 500
        ) {
            return false;
        }
        for (uint256 i; i < s.length; ++i) {
            uint8 c = uint8(s[i]);
            if (!((c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A)
                        || c == 0x21)) {
                return false;
            }
        }
        return true;
    }
}
