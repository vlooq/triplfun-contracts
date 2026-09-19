// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TriplV5Types} from "./TriplV5Types.sol";

/// @notice Opt-in holder rewards vault. Token transfers never call this
/// contract; users explicitly stake, claim, and unstake.
contract TriplV5StakingRewards is ReentrancyGuard, IUnlockCallback {
    using SafeERC20 for IERC20;

    error AlreadyBound();
    error InexactTransfer();
    error InvalidConfiguration();
    error NoStake();
    error NoReward();
    error Unauthorized();

    uint256 public constant SCALE = 1e24;
    IERC20 public immutable token;
    IERC20 public immutable quote;
    IPoolManager public immutable poolManager;
    address public immutable factory;
    bool public immutable diamondHands;
    uint64 public immutable tierOneDuration;
    uint64 public immutable tierTwoDuration;
    uint16 public immutable tierOneMultiplierBps;
    uint16 public immutable tierTwoMultiplierBps;
    uint256 public immutable launchTime;
    address public market;
    address public feeHook;

    uint256 public totalStaked;
    uint256 public totalShares;
    uint256 public rewardPerShareStored;
    uint256 public pendingReward;
    uint256 public totalFunded;
    uint256 public totalClaimed;
    uint256 public poolRewardPerShareStored;
    uint256 public poolPendingReward;
    uint256 public poolFunded;
    uint256 public poolClaimed;

    mapping(address => uint256) public staked;
    mapping(address => uint256) public shares;
    mapping(address => uint256) public rewardDebt;
    mapping(address => uint256) public poolRewardDebt;
    mapping(address => uint256) public accrued;
    mapping(address => uint256) public poolAccrued;
    mapping(address => uint256) public stakeStarted;
    bool private redeeming;

    event MarketBound(address indexed market);
    event Staked(address indexed account, uint256 amount, uint256 shares);
    event Unstaked(address indexed account, uint256 amount);
    event RewardNotified(uint256 amount);
    event Claimed(address indexed account, uint256 amount);
    event Checkpointed(address indexed account, uint8 tier, uint256 shares);

    constructor(
        address factory_,
        address token_,
        address quote_,
        address poolManager_,
        bool diamondHands_,
        uint64 tierOneDuration_,
        uint64 tierTwoDuration_,
        uint16 tierOneMultiplierBps_,
        uint16 tierTwoMultiplierBps_
    ) {
        if (
            factory_ == address(0) || token_ == address(0) || quote_ == address(0)
                || quote_.code.length == 0
        ) {
            revert InvalidConfiguration();
        }
        if (
            diamondHands_
                && (tierTwoDuration_ < tierOneDuration_
                    || tierOneMultiplierBps_ < 10_000
                    || tierTwoMultiplierBps_ < tierOneMultiplierBps_)
        ) revert InvalidConfiguration();
        factory = factory_;
        token = IERC20(token_);
        quote = IERC20(quote_);
        poolManager = IPoolManager(poolManager_);
        diamondHands = diamondHands_;
        tierOneDuration = tierOneDuration_;
        tierTwoDuration = tierTwoDuration_;
        tierOneMultiplierBps = diamondHands_ ? tierOneMultiplierBps_ : 10_000;
        tierTwoMultiplierBps = diamondHands_ ? tierTwoMultiplierBps_ : 10_000;
        launchTime = block.timestamp;
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

    function tierFor(address account) public view returns (uint8) {
        if (!diamondHands || staked[account] == 0) return 0;
        uint256 elapsed = block.timestamp - stakeStarted[account];
        if (elapsed >= tierTwoDuration) return 2;
        if (elapsed >= tierOneDuration) return 1;
        return 0;
    }

    function multiplierFor(address account) public view returns (uint16) {
        uint8 tier = tierFor(account);
        if (tier == 2) return tierTwoMultiplierBps;
        if (tier == 1) return tierOneMultiplierBps;
        return 10_000;
    }

    function effectiveShares(address account) external view returns (uint256) {
        // This is the weight currently used by accounting. Tenure changes are
        // activated by checkpoint(), never by a view call or by elapsed time
        // mutating global totalShares implicitly.
        return shares[account];
    }

    /// @notice Syncs an account's accrued rewards and applies its elapsed
    /// tenure tier to future distributions. Rewards earned before this call
    /// keep the prior tier; no keeper or holder loop is required.
    function checkpoint(address account) external nonReentrant {
        if (account == address(0)) revert Unauthorized();
        _sync(account);
        _distributePending();
        _distributePendingPool();
        emit Checkpointed(account, tierFor(account), shares[account]);
    }

    function stake(uint256 amount) external nonReentrant {
        if (amount == 0) revert NoStake();
        _sync(msg.sender);
        _pullExact(token, msg.sender, amount);
        if (staked[msg.sender] == 0) stakeStarted[msg.sender] = block.timestamp;
        staked[msg.sender] += amount;
        totalStaked += amount;
        _refreshShares(msg.sender);
        _distributePending();
        _distributePendingPool();
        emit Staked(msg.sender, amount, shares[msg.sender]);
    }

    function unstake(uint256 amount) external nonReentrant {
        if (amount == 0 || amount > staked[msg.sender]) revert NoStake();
        _sync(msg.sender);
        staked[msg.sender] -= amount;
        totalStaked -= amount;
        if (staked[msg.sender] == 0) stakeStarted[msg.sender] = 0;
        _refreshShares(msg.sender);
        _sendExact(token, msg.sender, amount);
        emit Unstaked(msg.sender, amount);
    }

    function notifyReward(uint256 amount) external nonReentrant {
        if (msg.sender != market || amount == 0) revert Unauthorized();
        if (quote.balanceOf(address(this)) < totalFunded - totalClaimed + amount) {
            revert InexactTransfer();
        }
        totalFunded += amount;
        if (totalShares == 0) pendingReward += amount;
        else rewardPerShareStored += amount * SCALE / totalShares;
        emit RewardNotified(amount);
    }

    function notifyPoolReward(uint256 amount) external nonReentrant {
        if (msg.sender != feeHook || amount == 0 || address(poolManager) == address(0)) {
            revert Unauthorized();
        }
        if (
            poolManager.balanceOf(address(this), uint160(address(quote)))
                < poolFunded - poolClaimed + amount
        ) revert InexactTransfer();
        poolFunded += amount;
        if (totalShares == 0) poolPendingReward += amount;
        else poolRewardPerShareStored += amount * SCALE / totalShares;
        emit RewardNotified(amount);
    }

    function withdrawable(address account) public view returns (uint256) {
        uint256 currentShares = shares[account];
        uint256 pending = currentShares * rewardPerShareStored / SCALE;
        uint256 debt = rewardDebt[account];
        uint256 poolPending = currentShares * poolRewardPerShareStored / SCALE;
        uint256 poolDebt = poolRewardDebt[account];
        return accrued[account] + (pending > debt ? pending - debt : 0) + poolAccrued[account]
            + (poolPending > poolDebt ? poolPending - poolDebt : 0);
    }

    function claim() external nonReentrant returns (uint256 amount) {
        _sync(msg.sender);
        amount = accrued[msg.sender] + poolAccrued[msg.sender];
        if (amount == 0) revert NoReward();
        uint256 physicalAmount = accrued[msg.sender];
        uint256 poolAmount = poolAccrued[msg.sender];
        accrued[msg.sender] = 0;
        poolAccrued[msg.sender] = 0;
        totalClaimed += physicalAmount;
        poolClaimed += poolAmount;
        _sendExact(quote, msg.sender, physicalAmount);
        _redeemPool(msg.sender, poolAmount);
        emit Claimed(msg.sender, amount);
    }

    function _sync(address account) private {
        uint256 current = shares[account] * rewardPerShareStored / SCALE;
        uint256 debt = rewardDebt[account];
        if (current > debt) accrued[account] += current - debt;
        uint256 poolCurrent = shares[account] * poolRewardPerShareStored / SCALE;
        uint256 poolDebt = poolRewardDebt[account];
        if (poolCurrent > poolDebt) poolAccrued[account] += poolCurrent - poolDebt;
        _refreshShares(account);
    }

    function _refreshShares(address account) private {
        uint256 oldShares = shares[account];
        uint256 newShares = staked[account] * multiplierFor(account) / 10_000;
        if (newShares > oldShares) totalShares += newShares - oldShares;
        else totalShares -= oldShares - newShares;
        shares[account] = newShares;
        rewardDebt[account] = newShares * rewardPerShareStored / SCALE;
        poolRewardDebt[account] = newShares * poolRewardPerShareStored / SCALE;
    }

    function _distributePending() private {
        if (pendingReward != 0 && totalShares != 0) {
            rewardPerShareStored += pendingReward * SCALE / totalShares;
            pendingReward = 0;
        }
    }

    function _distributePendingPool() private {
        if (poolPendingReward != 0 && totalShares != 0) {
            poolRewardPerShareStored += poolPendingReward * SCALE / totalShares;
            poolPendingReward = 0;
        }
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

    function _pullExact(IERC20 asset, address from, uint256 amount) private {
        uint256 fromBefore = asset.balanceOf(from);
        uint256 vaultBefore = asset.balanceOf(address(this));
        asset.safeTransferFrom(from, address(this), amount);
        if (
            fromBefore < asset.balanceOf(from) || fromBefore - asset.balanceOf(from) != amount
                || asset.balanceOf(address(this)) < vaultBefore
                || asset.balanceOf(address(this)) - vaultBefore != amount
        ) revert InexactTransfer();
    }

    function _sendExact(IERC20 asset, address to, uint256 amount) private {
        uint256 beforeVault = asset.balanceOf(address(this));
        uint256 beforeRecipient = asset.balanceOf(to);
        asset.safeTransfer(to, amount);
        if (
            beforeVault < asset.balanceOf(address(this))
                || beforeVault - asset.balanceOf(address(this)) != amount
                || asset.balanceOf(to) < beforeRecipient
                || asset.balanceOf(to) - beforeRecipient != amount
        ) revert InexactTransfer();
    }
}
