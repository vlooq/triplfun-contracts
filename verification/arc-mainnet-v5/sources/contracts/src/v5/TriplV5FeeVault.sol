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

interface ITriplV5FeeShares {
    function usdc() external view returns (address);
    function poolManager() external view returns (address);
    function depositRevenue(uint256 amount) external;
}

/// @notice Pull-based accounting for one v5 launch's non-curve fee legs.
/// @dev The market transfers the complete fee before calling
/// {recordTradeFees}. All liabilities stay quote-denominated and separate
/// from the market's real quote reserve.
contract TriplV5FeeVault is ReentrancyGuard, IUnlockCallback {
    using SafeERC20 for IERC20;

    error InvalidConfiguration();
    error InexactTransfer();
    error NoCredit();
    error Unauthorized();

    IERC20 public immutable quote;
    IPoolManager public immutable poolManager;
    address public immutable feeShares;
    address public immutable usdc;
    address public immutable nftAdapter;
    bytes32 public immutable nftAdapterCodeHash;
    address public immutable factory;
    address public immutable creator;
    address public market;
    address public feeHook;

    address[] private _splitRecipients;
    uint16[] private _splitWeights;
    mapping(address => uint16) public splitWeightBps;
    mapping(address => uint256) public splitCredits;
    mapping(address => bool) public isSplitRecipient;

    uint256 public nftFees;
    uint256 public creatorCredits;
    uint256 public buybackCredits;
    uint256 public totalFeesRecorded;
    uint256 public totalClaimed;

    // PoolManager-backed claims are tracked separately from ERC20 balances.
    // The aggregate liabilities below remain one quote-denominated view for
    // callers, while claims can be redeemed without server upkeep.
    uint256 public poolNftFees;
    uint256 public poolCreatorCredits;
    uint256 public poolBuybackCredits;
    mapping(address => uint256) public poolSplitCredits;

    uint256 public totalNftClaimed;
    uint256 public pendingNftFees;
    bool private redeeming;

    event MarketBound(address indexed market);
    event FeesRecorded(uint256 nft, uint256 creator, uint256 buyback, uint256 split);
    event NftFeesFlushed(uint256 quoteAmount, uint256 usdcAmount, address indexed feeShares);
    event Claimed(address indexed account, uint256 amount);

    constructor(
        address factory_,
        address quote_,
        address creator_,
        address poolManager_,
        address feeShares_,
        address nftAdapter_,
        address[] memory recipients,
        uint16[] memory weights
    ) {
        if (
            factory_ == address(0) || quote_ == address(0) || quote_.code.length == 0
                || creator_ == address(0) || feeShares_ == address(0) || feeShares_.code.length == 0
        ) {
            revert InvalidConfiguration();
        }
        address configuredUsdc;
        address configuredManager;
        try ITriplV5FeeShares(feeShares_).usdc() returns (address value) {
            configuredUsdc = value;
        } catch {
            revert InvalidConfiguration();
        }
        try ITriplV5FeeShares(feeShares_).poolManager() returns (address value) {
            configuredManager = value;
        } catch {
            revert InvalidConfiguration();
        }
        if (
            configuredUsdc == address(0) || configuredUsdc.code.length == 0
                || configuredManager != poolManager_
                || IERC20Metadata(configuredUsdc).decimals() != 6
        ) revert InvalidConfiguration();
        if (nftAdapter_ != address(0)) {
            if (quote_ == configuredUsdc || nftAdapter_.code.length == 0) {
                revert InvalidConfiguration();
            }
            try ITriplV2QuoteAdapter(nftAdapter_).quoteAsset() returns (address asset) {
                if (asset != quote_) revert InvalidConfiguration();
            } catch {
                revert InvalidConfiguration();
            }
            try ITriplV2QuoteAdapter(nftAdapter_).usdc() returns (address asset) {
                if (asset != configuredUsdc) revert InvalidConfiguration();
            } catch {
                revert InvalidConfiguration();
            }
        }
        if (recipients.length != weights.length || recipients.length > 5) {
            revert InvalidConfiguration();
        }
        if (recipients.length == 0) {
            recipients = new address[](1);
            weights = new uint16[](1);
            recipients[0] = creator_;
            weights[0] = 10_000;
        }
        uint256 totalWeight;
        for (uint256 i; i < recipients.length; ++i) {
            if (recipients[i] == address(0) || weights[i] == 0 || isSplitRecipient[recipients[i]]) {
                revert InvalidConfiguration();
            }
            isSplitRecipient[recipients[i]] = true;
            splitWeightBps[recipients[i]] = weights[i];
            _splitRecipients.push(recipients[i]);
            _splitWeights.push(weights[i]);
            totalWeight += weights[i];
        }
        if (totalWeight != 10_000) revert InvalidConfiguration();
        factory = factory_;
        quote = IERC20(quote_);
        poolManager = IPoolManager(poolManager_);
        feeShares = feeShares_;
        usdc = configuredUsdc;
        nftAdapter = nftAdapter_;
        nftAdapterCodeHash = nftAdapter_ == address(0) ? bytes32(0) : nftAdapter_.codehash;
        creator = creator_;
    }

    function splitRecipients() external view returns (address[] memory) {
        return _splitRecipients;
    }

    function splitWeights() external view returns (uint16[] memory) {
        return _splitWeights;
    }

    function bindMarket(address market_) external {
        if (msg.sender != factory || market != address(0) || market_ == address(0)) {
            revert Unauthorized();
        }
        market = market_;
        emit MarketBound(market_);
    }

    function bindFeeHook(address hook_) external {
        if (msg.sender != factory || feeHook != address(0) || hook_ == address(0)) {
            revert Unauthorized();
        }
        feeHook = hook_;
    }

    function recordTradeFees(uint256 nft, uint256 creatorFee, uint256 buyback, uint256 split)
        external
    {
        if (msg.sender != market) revert Unauthorized();
        uint256 total = nft + creatorFee + buyback + split;
        if (quote.balanceOf(address(this)) < physicalLiability() + total) revert InexactTransfer();
        _recordAccounting(nft, creatorFee, buyback, split, false);
        emit FeesRecorded(nft, creatorFee, buyback, split);
    }

    /// @notice Records fees represented by PoolManager ERC6909 claims.
    /// @dev The hook mints claims to this vault and staking contract before
    /// calling this function. This keeps every post-graduation lane solvent
    /// without requiring a keeper to move quote tokens.
    function recordPoolTradeFees(uint256 nft, uint256 creatorFee, uint256 buyback, uint256 split)
        external
    {
        if (msg.sender != feeHook || address(poolManager) == address(0)) revert Unauthorized();
        uint256 total = nft + creatorFee + buyback + split;
        if (poolManager.balanceOf(address(this), uint160(address(quote))) < poolLiability() + total)
        {
            revert InexactTransfer();
        }
        _recordAccounting(nft, creatorFee, buyback, split, true);
        emit FeesRecorded(nft, creatorFee, buyback, split);
    }

    function _recordAccounting(
        uint256 nft,
        uint256 creatorFee,
        uint256 buyback,
        uint256 split,
        bool poolBacked
    ) private {
        nftFees += nft;
        creatorCredits += creatorFee;
        buybackCredits += buyback;
        if (poolBacked) {
            poolNftFees += nft;
            poolCreatorCredits += creatorFee;
            poolBuybackCredits += buyback;
        }
        pendingNftFees += nft;
        uint256 splitDust;
        if (split != 0) {
            uint256 distributed;
            for (uint256 i; i < _splitRecipients.length; ++i) {
                uint256 leg = split * _splitWeights[i] / 10_000;
                if (poolBacked) poolSplitCredits[_splitRecipients[i]] += leg;
                splitCredits[_splitRecipients[i]] += leg;
                distributed += leg;
            }
            // Preserve every charged quote unit even when weighted split legs
            // floor independently. The creator receives the dust.
            splitDust = split - distributed;
            creatorCredits += splitDust;
            if (poolBacked) poolCreatorCredits += splitDust;
        }
        // splitDust is already part of `split`; adding it again would make
        // the cumulative fee counter exceed the solvent lane liabilities.
        totalFeesRecorded += nft + creatorFee + buyback + split;
    }

    function totalSplitCredits() public view returns (uint256 total) {
        for (uint256 i; i < _splitRecipients.length; ++i) {
            total += splitCredits[_splitRecipients[i]];
        }
    }

    function totalLiability() public view returns (uint256) {
        return nftFees + creatorCredits + buybackCredits + totalSplitCredits();
    }

    function poolLiability() public view returns (uint256) {
        return poolNftFees + poolCreatorCredits + poolBuybackCredits + totalPoolSplitCredits();
    }

    function physicalLiability() public view returns (uint256) {
        return totalLiability() - poolLiability();
    }

    function totalPoolSplitCredits() public view returns (uint256 total) {
        for (uint256 i; i < _splitRecipients.length; ++i) {
            total += poolSplitCredits[_splitRecipients[i]];
        }
    }

    function claimCreator() external nonReentrant returns (uint256 amount) {
        if (msg.sender != creator) revert Unauthorized();
        amount = creatorCredits;
        if (amount == 0) revert NoCredit();
        creatorCredits = 0;
        totalClaimed += amount;
        uint256 poolAmount = amount < poolCreatorCredits ? amount : poolCreatorCredits;
        poolCreatorCredits -= poolAmount;
        _sendExact(msg.sender, amount - poolAmount);
        _redeemPool(msg.sender, poolAmount);
        emit Claimed(msg.sender, amount);
    }

    function claimSplit() external nonReentrant returns (uint256 amount) {
        if (!isSplitRecipient[msg.sender]) revert Unauthorized();
        amount = splitCredits[msg.sender];
        if (amount == 0) revert NoCredit();
        splitCredits[msg.sender] = 0;
        totalClaimed += amount;
        uint256 poolAmount =
            amount < poolSplitCredits[msg.sender] ? amount : poolSplitCredits[msg.sender];
        poolSplitCredits[msg.sender] -= poolAmount;
        _sendExact(msg.sender, amount - poolAmount);
        _redeemPool(msg.sender, poolAmount);
        emit Claimed(msg.sender, amount);
    }

    /// @notice Flush at most `maxAmount` of quote-denominated NFT fees into
    /// the existing transferable platform FeeShares collection. A caller may
    /// execute this in bounded chunks; pool claims are redeemed atomically and
    /// non-USDC quotes require the immutable approved adapter.
    function flushNftFees(uint256 maxAmount, uint256 minOut, uint256 deadline)
        external
        nonReentrant
        returns (uint256 usdcOut)
    {
        if (maxAmount == 0 || block.timestamp > deadline) revert NoCredit();
        uint256 amount = maxAmount < pendingNftFees ? maxAmount : pendingNftFees;
        if (amount == 0) revert NoCredit();
        uint256 poolAmount = amount < poolNftFees ? amount : poolNftFees;
        pendingNftFees -= amount;
        nftFees -= amount;
        poolNftFees -= poolAmount;
        totalClaimed += amount;
        totalNftClaimed += amount;
        if (poolAmount != 0) _redeemPool(address(this), poolAmount);
        if (quote.balanceOf(address(this)) < amount - poolAmount) revert InexactTransfer();
        if (address(quote) == usdc) {
            if (minOut > amount) revert InvalidConfiguration();
            _depositRevenue(amount);
            emit NftFeesFlushed(amount, amount, feeShares);
            return amount;
        }
        if (nftAdapter == address(0) || nftAdapter.codehash != nftAdapterCodeHash) {
            revert InvalidConfiguration();
        }
        uint256 beforeQuote = quote.balanceOf(address(this));
        uint256 beforeUsdc = IERC20(usdc).balanceOf(address(this));
        quote.forceApprove(nftAdapter, amount);
        usdcOut = ITriplV2QuoteAdapter(nftAdapter)
            .convertToUsdc(address(quote), amount, minOut, deadline);
        quote.forceApprove(nftAdapter, 0);
        if (
            beforeQuote < quote.balanceOf(address(this))
                || beforeQuote - quote.balanceOf(address(this)) != amount
                || IERC20(usdc).balanceOf(address(this)) < beforeUsdc
                || IERC20(usdc).balanceOf(address(this)) - beforeUsdc != usdcOut || usdcOut < minOut
        ) revert InexactTransfer();
        _depositRevenue(usdcOut);
        emit NftFeesFlushed(amount, usdcOut, feeShares);
    }

    function payBuyback(uint256 amount) external nonReentrant {
        if (msg.sender != market) revert Unauthorized();
        if (amount == 0 || amount > buybackCredits) revert NoCredit();
        _redeemBuyback(msg.sender, amount);
    }

    /// @notice Redeems buyback credit into the market for a graduated pool
    /// swap. Pool-backed credit is burned from this vault's PoolManager claim;
    /// physical credit is transferred directly. The market is always the
    /// recipient, so a permissionless caller cannot redirect proceeds.
    function redeemBuyback(address recipient, uint256 amount) external nonReentrant {
        if (msg.sender != market || recipient != market) revert Unauthorized();
        if (amount == 0 || amount > buybackCredits) revert NoCredit();
        _redeemBuyback(recipient, amount);
    }

    function _redeemBuyback(address recipient, uint256 amount) private {
        buybackCredits -= amount;
        totalClaimed += amount;
        uint256 poolAmount = amount < poolBuybackCredits ? amount : poolBuybackCredits;
        poolBuybackCredits -= poolAmount;
        _sendExact(recipient, amount - poolAmount);
        _redeemPool(recipient, poolAmount);
    }

    function _redeemPool(address recipient, uint256 amount) private {
        if (amount == 0) return;
        if (address(poolManager) == address(0)) revert InexactTransfer();
        uint256 beforeRecipient = quote.balanceOf(recipient);
        redeeming = true;
        poolManager.unlock(abi.encode(recipient, amount));
        redeeming = false;
        if (quote.balanceOf(recipient) != beforeRecipient + amount) revert InexactTransfer();
    }

    function unlockCallback(bytes calldata rawData) external returns (bytes memory) {
        if (msg.sender != address(poolManager) || !redeeming) revert Unauthorized();
        (address recipient, uint256 amount) = abi.decode(rawData, (address, uint256));
        if (recipient == address(0) || amount == 0) revert InvalidConfiguration();
        poolManager.burn(address(this), uint160(address(quote)), amount);
        poolManager.take(Currency.wrap(address(quote)), recipient, amount);
        return bytes("");
    }

    function _depositRevenue(uint256 amount) private {
        if (amount == 0) revert InvalidConfiguration();
        IERC20 revenue = IERC20(usdc);
        uint256 beforeShares = revenue.balanceOf(feeShares);
        revenue.forceApprove(feeShares, amount);
        ITriplV5FeeShares(feeShares).depositRevenue(amount);
        revenue.forceApprove(feeShares, 0);
        if (revenue.balanceOf(feeShares) != beforeShares + amount) revert InexactTransfer();
    }

    function _sendExact(address to, uint256 amount) private {
        uint256 beforeVault = quote.balanceOf(address(this));
        uint256 beforeRecipient = quote.balanceOf(to);
        quote.safeTransfer(to, amount);
        if (
            beforeVault < quote.balanceOf(address(this))
                || beforeVault - quote.balanceOf(address(this)) != amount
                || quote.balanceOf(to) < beforeRecipient
                || quote.balanceOf(to) - beforeRecipient != amount
        ) revert InexactTransfer();
    }
}
