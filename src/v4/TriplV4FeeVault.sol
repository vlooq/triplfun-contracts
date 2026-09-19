// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

interface ITriplV4RevenueShares {
    function notifyRevenue(uint256 amount) external;
}

interface ITriplV4RevenueRewards {
    function notifyManagerReward(uint256 amount) external;
}

interface ITriplV4CollectionRewards {
    function notifyManagerReward(uint256 amount) external;
}

/// @notice Segregated V4 creator/treasury liabilities and claim coordinator.
/// @dev Fee claims are represented by PoolManager ERC6909 balances. No USDC is
/// borrowed from or swept out of the pool manager during a trade.
contract TriplV4FeeVault is ReentrancyGuard, IUnlockCallback {
    using SafeERC20 for IERC20;

    error InvalidConfiguration();
    error Unauthorized();
    error InexactTransfer();
    error NothingToClaim();

    IERC20 public immutable usdc;
    IPoolManager public immutable poolManager;
    address public immutable treasury;
    address public immutable factory;
    address public immutable feeShares;
    address public hook;
    uint256 public totalCreatorAccrued;
    uint256 public totalCreatorClaimed;
    uint256 public totalTreasuryAccrued;
    uint256 public totalTreasuryClaimed;

    mapping(address => address) public creatorOf;
    mapping(address => uint256) public creatorCredits;
    uint256 public treasuryCredits;

    event HookBound(address indexed hook);
    event FeesRouted(
        address indexed market,
        address indexed creator,
        uint256 nftAmount,
        uint256 creatorAmount,
        uint256 holderAmount,
        uint256 treasuryAmount,
        uint256 collectionAmount
    );
    event CreatorClaimed(address indexed creator, address indexed market, uint256 amount);
    event TreasuryClaimed(address indexed treasury, uint256 amount);

    constructor(
        address poolManager_,
        address usdc_,
        address treasury_,
        address factory_,
        address feeShares_
    ) {
        if (
            poolManager_ == address(0) || poolManager_.code.length == 0 || usdc_ == address(0)
                || usdc_.code.length == 0 || treasury_ == address(0) || factory_ == address(0)
                || feeShares_ == address(0) || feeShares_.code.length == 0
        ) revert InvalidConfiguration();
        try IERC20Metadata(usdc_).decimals() returns (uint8 decimals) {
            if (decimals != 6) revert InvalidConfiguration();
        } catch {
            revert InvalidConfiguration();
        }
        poolManager = IPoolManager(poolManager_);
        usdc = IERC20(usdc_);
        treasury = treasury_;
        factory = factory_;
        feeShares = feeShares_;
    }

    function bindHook(address hook_) external {
        if (msg.sender != factory || hook_ == address(0) || hook != address(0)) {
            revert Unauthorized();
        }
        hook = hook_;
        emit HookBound(hook_);
    }

    function registerCreator(address market, address creator) external {
        if (msg.sender != hook || market == address(0)) revert Unauthorized();
        if (creatorOf[market] != address(0) && creatorOf[market] != creator) revert Unauthorized();
        if (creator != address(0)) creatorOf[market] = creator;
    }

    /// @notice Routes claims already minted by the hook to each segregated lane.
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
    ) external nonReentrant {
        if (msg.sender != hook || market == address(0) || rewards == address(0)) revert Unauthorized();
        if (creator != address(0) && creatorOf[market] != creator) revert Unauthorized();
        if (collectionAmount != 0 && collectionRewards == address(0)) {
            revert InvalidConfiguration();
        }
        uint256 total = nftAmount + creatorAmount + holderAmount + treasuryAmount + collectionAmount;
        if (total == 0) revert InvalidConfiguration();
        uint256 id = uint160(address(usdc));
        if (
            poolManager.balanceOf(feeShares, id) < nftAmount
                || poolManager.balanceOf(rewards, id) < holderAmount
                || poolManager.balanceOf(address(this), id) < creatorAmount + treasuryAmount
                || (collectionAmount != 0
                    && poolManager.balanceOf(collectionRewards, id) < collectionAmount)
        ) revert InexactTransfer();

        if (nftAmount != 0) ITriplV4RevenueShares(feeShares).notifyRevenue(nftAmount);
        if (holderAmount != 0) ITriplV4RevenueRewards(rewards).notifyManagerReward(holderAmount);
        if (collectionAmount != 0) {
            ITriplV4CollectionRewards(collectionRewards).notifyManagerReward(collectionAmount);
        }
        if (creatorAmount != 0) {
            if (creator == address(0)) revert InvalidConfiguration();
            creatorCredits[market] += creatorAmount;
            totalCreatorAccrued += creatorAmount;
        }
        if (treasuryAmount != 0) {
            treasuryCredits += treasuryAmount;
            totalTreasuryAccrued += treasuryAmount;
        }
        emit FeesRouted(
            market,
            creator,
            nftAmount,
            creatorAmount,
            holderAmount,
            treasuryAmount,
            collectionAmount
        );
    }

    function claimCreator(address market) external nonReentrant returns (uint256 amount) {
        if (creatorOf[market] != msg.sender) revert Unauthorized();
        amount = creatorCredits[market];
        if (amount == 0) revert NothingToClaim();
        creatorCredits[market] = 0;
        totalCreatorClaimed += amount;
        poolManager.unlock(abi.encode(msg.sender, amount));
        emit CreatorClaimed(msg.sender, market, amount);
    }

    function claimTreasury() external nonReentrant returns (uint256 amount) {
        if (msg.sender != treasury) revert Unauthorized();
        amount = treasuryCredits;
        if (amount == 0) revert NothingToClaim();
        treasuryCredits = 0;
        totalTreasuryClaimed += amount;
        poolManager.unlock(abi.encode(msg.sender, amount));
        emit TreasuryClaimed(msg.sender, amount);
    }

    function unlockCallback(bytes calldata rawData) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert Unauthorized();
        (address recipient, uint256 amount) = abi.decode(rawData, (address, uint256));
        poolManager.burn(address(this), uint160(address(usdc)), amount);
        poolManager.take(Currency.wrap(address(usdc)), recipient, amount);
        return bytes("");
    }
}
