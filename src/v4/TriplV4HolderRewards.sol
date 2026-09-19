// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

interface ITriplV4HolderToken {
    function balanceOf(address account) external view returns (uint256);
    function totalSupply() external view returns (uint256);
}

/// @notice Passive, transfer-aware quote rewards for one V4 token.
/// @dev FeeVault records a PoolManager ERC6909 claim before calling
/// notifyManagerReward. The fractional residue is retained in the magnified
/// index and is never redistributed twice.
contract TriplV4HolderRewards is ReentrancyGuard, IUnlockCallback {
    using SafeERC20 for IERC20;

    error InvalidConfiguration();
    error Unauthorized();
    error NothingToClaim();
    error InexactTransfer();

    uint256 public constant MAGNITUDE = 2 ** 128;
    IERC20 public immutable quote;
    IPoolManager public immutable poolManager;
    ITriplV4HolderToken public immutable token;
    address public immutable factory;
    address public immutable market;
    address public immutable feeVault;
    uint256 public magnifiedRewardPerShare;
    uint256 public pendingReward;
    uint256 public totalFunded;
    uint256 public totalClaimed;
    uint256 public excludedBalance;
    uint256 public exclusionCount;

    mapping(address => uint256) public credits;
    mapping(address => int256) public magnifiedCorrections;
    mapping(address => uint256) public withdrawn;
    mapping(address => bool) public excluded;

    event RewardNotified(uint256 indexed amount, uint256 indexed distributed, uint256 pending);
    event RewardClaimed(address indexed holder, uint256 amount);
    event ExclusionConfigured(address indexed account);

    constructor(
        address quote_,
        address token_,
        address factory_,
        address market_,
        address feeVault_,
        address poolManager_,
        address[] memory exclusions_
    ) {
        if (
            quote_ == address(0) || quote_.code.length == 0 || token_ == address(0)
                || token_.code.length == 0 || factory_ == address(0) || market_ == address(0)
                || feeVault_ == address(0)
        ) revert InvalidConfiguration();
        try IERC20Metadata(quote_).decimals() returns (uint8 decimals) {
            if (decimals > 18) revert InvalidConfiguration();
        } catch {
            revert InvalidConfiguration();
        }
        quote = IERC20(quote_);
        poolManager = IPoolManager(poolManager_);
        if (address(poolManager) == address(0) || address(poolManager).code.length == 0) {
            revert InvalidConfiguration();
        }
        token = ITriplV4HolderToken(token_);
        factory = factory_;
        market = market_;
        feeVault = feeVault_;
        _exclude(address(0));
        _exclude(address(0x000000000000000000000000000000000000dEaD));
        _exclude(address(this));
        _exclude(factory_);
        _exclude(market_);
        _exclude(token_);
        _exclude(feeVault_);
        _exclude(poolManager_);
        for (uint256 i; i < exclusions_.length; ++i) _exclude(exclusions_[i]);
    }

    function eligibleSupply() public view returns (uint256) {
        uint256 supply = token.totalSupply();
        return supply > excludedBalance ? supply - excludedBalance : 0;
    }

    function withdrawable(address account) public view returns (uint256 amount) {
        amount = credits[account];
        if (excluded[account]) return amount;
        int256 magnified = _magnifiedFor(account);
        if (magnified <= 0) return amount;
        uint256 cumulative = uint256(magnified);
        uint256 prior = withdrawn[account];
        if (cumulative > prior) amount += (cumulative - prior) / MAGNITUDE;
    }

    function _notify(uint256 amount) private {
        totalFunded += amount;
        uint256 distributable = amount + pendingReward;
        uint256 supply = eligibleSupply();
        if (supply == 0) {
            pendingReward = distributable;
            emit RewardNotified(amount, 0, pendingReward);
            return;
        }
        uint256 increment = Math.mulDiv(distributable, MAGNITUDE, supply);
        if (increment == 0) {
            pendingReward = distributable;
            emit RewardNotified(amount, 0, pendingReward);
            return;
        }
        uint256 distributed = Math.mulDiv(increment, supply, MAGNITUDE);
        magnifiedRewardPerShare += increment;
        SafeCast.toInt256(Math.mulDiv(token.totalSupply(), magnifiedRewardPerShare, 1));
        // The floor remainder is already represented by the fractional
        // magnified index. Carrying it in pendingReward would commit it once
        // more on the next notification. Only amounts that could not produce
        // an index increment remain pending (zero supply or sub-unit update).
        pendingReward = 0;
        emit RewardNotified(amount, distributed, pendingReward);
    }

    /// @notice Records a reward represented by this contract's ERC6909 claim.
    /// The V4 hook mints the claim before calling the FeeVault, so this remains
    /// solvent even when the PoolManager held no quote before the swap.
    function notifyManagerReward(uint256 amount) external {
        if (msg.sender != feeVault || amount == 0) revert Unauthorized();
        uint256 claims = poolManager.balanceOf(address(this), uint160(address(quote)));
        if (claims < totalFunded - totalClaimed + amount) revert InexactTransfer();
        _notify(amount);
    }

    function claim() external nonReentrant returns (uint256 amount) {
        _settle(msg.sender);
        amount = credits[msg.sender];
        if (amount == 0) revert NothingToClaim();
        credits[msg.sender] = 0;
        totalClaimed += amount;
        poolManager.unlock(abi.encode(msg.sender, amount));
        emit RewardClaimed(msg.sender, amount);
    }

    function unlockCallback(bytes calldata rawData) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert Unauthorized();
        (address recipient, uint256 amount) = abi.decode(rawData, (address, uint256));
        poolManager.burn(address(this), uint160(address(quote)), amount);
        poolManager.take(Currency.wrap(address(quote)), recipient, amount);
        return bytes("");
    }

    function beforeTokenTransfer(address from, address to, uint256 amount) external {
        if (msg.sender != address(token)) revert Unauthorized();
        if (from != address(0)) _settle(from);
        if (to != address(0) && to != from) _settle(to);
        if (from != address(0) && !excluded[from]) {
            magnifiedCorrections[from] += SafeCast.toInt256(Math.mulDiv(magnifiedRewardPerShare, amount, 1));
        }
        if (to != address(0) && to != from && !excluded[to]) {
            magnifiedCorrections[to] -= SafeCast.toInt256(Math.mulDiv(magnifiedRewardPerShare, amount, 1));
        }
        if (from != address(0) && excluded[from]) excludedBalance -= amount;
        if (to != address(0) && excluded[to]) excludedBalance += amount;
    }

    function _settle(address account) private {
        if (excluded[account]) return;
        int256 magnified = _magnifiedFor(account);
        if (magnified <= 0) return;
        uint256 cumulative = uint256(magnified);
        uint256 prior = withdrawn[account];
        if (cumulative > prior) {
            uint256 whole = (cumulative - prior) / MAGNITUDE;
            if (whole != 0) {
                credits[account] += whole;
                withdrawn[account] = prior + whole * MAGNITUDE;
            }
        }
    }

    function _magnifiedFor(address account) private view returns (int256) {
        uint256 product = Math.mulDiv(token.balanceOf(account), magnifiedRewardPerShare, 1);
        return SafeCast.toInt256(product) + magnifiedCorrections[account];
    }

    function _exclude(address account) private {
        if (excluded[account]) return;
        excluded[account] = true;
        ++exclusionCount;
        if (account != address(0)) excludedBalance += token.balanceOf(account);
        emit ExclusionConfigured(account);
    }

}
