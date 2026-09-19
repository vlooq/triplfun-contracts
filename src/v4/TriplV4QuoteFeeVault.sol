// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ITriplV2QuoteAdapter} from "../v2/TriplV2QuoteInterfaces.sol";

interface ITriplV4QuoteRevenueShares {
    function depositRevenue(uint256 amount) external;
}

interface ITriplV4QuoteRewards {
    function notifyManagerReward(uint256 amount) external;
}

/// @notice Holds quote-denominated V4 fee claims. Creator and holder rewards
/// remain in the selected quote asset; only the fixed NFT leg is converted to
/// USDC through the quote's immutable, TWAP-bounded adapter.
contract TriplV4QuoteFeeVault is ReentrancyGuard, IUnlockCallback {
    using SafeERC20 for IERC20;

    error InvalidConfiguration();
    error Unauthorized();
    error InexactTransfer();
    error NothingToClaim();

    IPoolManager public immutable poolManager;
    address public immutable factory;
    IERC20 public immutable usdc;
    address public immutable feeShares;
    address public hook;

    mapping(address => address) public adapterFor;
    mapping(address => bytes32) public adapterCodeHash;
    mapping(address => address) public quoteOfMarket;
    mapping(address => address) public creatorOf;
    mapping(address => uint256) public creatorCredits;
    mapping(address => uint256) public totalCreatorCreditsByQuote;
    mapping(address => uint256) public pendingNftFees;

    event HookBound(address indexed hook);
    event QuoteBound(address indexed quote, address indexed adapter, bytes32 codeHash);
    event FeesRouted(
        address indexed market,
        address indexed quote,
        address indexed creator,
        uint256 nftAmount,
        uint256 creatorAmount,
        uint256 holderAmount
    );
    event NftFeesConverted(address indexed quote, uint256 amountIn, uint256 usdcOut);
    event CreatorClaimed(address indexed creator, address indexed market, address indexed quote, uint256 amount);

    constructor(address poolManager_, address factory_, address usdc_, address feeShares_) {
        if (
            poolManager_.code.length == 0 || factory_ == address(0) || usdc_.code.length == 0
                || feeShares_.code.length == 0 || IERC20Metadata(usdc_).decimals() != 6
        ) revert InvalidConfiguration();
        poolManager = IPoolManager(poolManager_);
        factory = factory_;
        usdc = IERC20(usdc_);
        feeShares = feeShares_;
    }

    function bindHook(address hook_) external {
        if (msg.sender != factory || hook_ == address(0) || hook != address(0)) revert Unauthorized();
        hook = hook_;
        emit HookBound(hook_);
    }

    function bindQuote(address quote, address adapter) external {
        if (
            msg.sender != factory || quote.code.length == 0 || adapter.code.length == 0
                || adapterFor[quote] != address(0)
        ) revert Unauthorized();
        if (
            ITriplV2QuoteAdapter(adapter).quoteAsset() != quote
                || ITriplV2QuoteAdapter(adapter).usdc() != address(usdc)
        ) revert InvalidConfiguration();
        adapterFor[quote] = adapter;
        adapterCodeHash[quote] = adapter.codehash;
        emit QuoteBound(quote, adapter, adapter.codehash);
    }

    function registerMarket(address market, address quote, address creator) external {
        if (
            msg.sender != hook || market == address(0) || quote == address(0) || creator == address(0)
                || adapterFor[quote] == address(0) || quoteOfMarket[market] != address(0)
        ) revert Unauthorized();
        quoteOfMarket[market] = quote;
        creatorOf[market] = creator;
    }

    function routeClaims(
        address market,
        address quote,
        address rewards,
        uint256 nftAmount,
        uint256 creatorAmount,
        uint256 holderAmount
    ) external nonReentrant {
        if (
            msg.sender != hook || quoteOfMarket[market] != quote || rewards == address(0)
                || nftAmount + creatorAmount + holderAmount == 0
        ) revert Unauthorized();
        uint256 id = uint160(quote);
        if (
            poolManager.balanceOf(address(this), id)
                < pendingNftFees[quote] + totalCreatorCreditsByQuote[quote] + nftAmount
                    + creatorAmount
                || poolManager.balanceOf(rewards, id) < holderAmount
        ) revert InexactTransfer();
        pendingNftFees[quote] += nftAmount;
        creatorCredits[market] += creatorAmount;
        totalCreatorCreditsByQuote[quote] += creatorAmount;
        if (holderAmount != 0) ITriplV4QuoteRewards(rewards).notifyManagerReward(holderAmount);
        emit FeesRouted(market, quote, creatorOf[market], nftAmount, creatorAmount, holderAmount);
    }

    function flushNftFees(address quote, uint256 maxAmount, uint256 minOut, uint256 deadline)
        external
        nonReentrant
        returns (uint256 usdcOut)
    {
        uint256 pending = pendingNftFees[quote];
        uint256 amount = maxAmount < pending ? maxAmount : pending;
        address adapter = adapterFor[quote];
        if (amount == 0 || adapter == address(0)) revert NothingToClaim();
        if (adapter.codehash != adapterCodeHash[quote]) revert InvalidConfiguration();
        pendingNftFees[quote] = pending - amount;
        poolManager.unlock(abi.encode(uint8(1), quote, address(this), amount));
        IERC20 quoteToken = IERC20(quote);
        uint256 beforeQuote = quoteToken.balanceOf(address(this));
        uint256 beforeUsdc = usdc.balanceOf(address(this));
        quoteToken.forceApprove(adapter, amount);
        usdcOut = ITriplV2QuoteAdapter(adapter).convertToUsdc(quote, amount, minOut, deadline);
        quoteToken.forceApprove(adapter, 0);
        if (
            quoteToken.balanceOf(address(this)) != beforeQuote - amount
                || usdc.balanceOf(address(this)) != beforeUsdc + usdcOut || usdcOut == 0
        ) revert InexactTransfer();
        usdc.forceApprove(feeShares, usdcOut);
        ITriplV4QuoteRevenueShares(feeShares).depositRevenue(usdcOut);
        usdc.forceApprove(feeShares, 0);
        if (usdc.balanceOf(address(this)) != beforeUsdc) revert InexactTransfer();
        emit NftFeesConverted(quote, amount, usdcOut);
    }

    function claimCreator(address market) external nonReentrant returns (uint256 amount) {
        if (creatorOf[market] != msg.sender) revert Unauthorized();
        amount = creatorCredits[market];
        if (amount == 0) revert NothingToClaim();
        creatorCredits[market] = 0;
        address quote = quoteOfMarket[market];
        totalCreatorCreditsByQuote[quote] -= amount;
        poolManager.unlock(abi.encode(uint8(2), quote, msg.sender, amount));
        emit CreatorClaimed(msg.sender, market, quote, amount);
    }

    function unlockCallback(bytes calldata rawData) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert Unauthorized();
        (uint8 action, address quote, address recipient, uint256 amount) =
            abi.decode(rawData, (uint8, address, address, uint256));
        if ((action != 1 && action != 2) || recipient == address(0) || amount == 0) {
            revert InvalidConfiguration();
        }
        uint256 beforeBalance = IERC20(quote).balanceOf(recipient);
        poolManager.burn(address(this), uint160(quote), amount);
        poolManager.take(Currency.wrap(quote), recipient, amount);
        if (IERC20(quote).balanceOf(recipient) != beforeBalance + amount) revert InexactTransfer();
        return "";
    }
}
