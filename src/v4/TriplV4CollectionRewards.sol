// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

interface ITriplV4ExternalCollection {
    function ownerOf(uint256 tokenId) external view returns (address);
}

/// @notice Pull-based rewards for a fixed snapshot of an external ERC-721.
/// @dev Revenue is represented by a PoolManager ERC6909 claim. Ownership is
/// checked at claim time, matching the V2 external collection semantics.
contract TriplV4CollectionRewards is ReentrancyGuard, IUnlockCallback {
    uint256 public constant MAX_TOKEN_IDS = 5_000;
    uint256 public constant MAX_CLAIM_TOKENS = 64;

    error InvalidConfiguration();
    error Unauthorized();
    error NothingToClaim();
    error InexactTransfer();

    ITriplV4ExternalCollection public immutable collection;
    IERC20Metadata public immutable quote;
    IPoolManager public immutable poolManager;
    address public immutable vault;
    bytes32 public immutable snapshotRoot;
    uint256 public immutable tokenCount;
    mapping(uint256 => uint256) public tokenCursor;

    uint256 public cumulativeRewardPerToken;
    uint256 public pendingReward;
    uint256 public totalFunded;
    uint256 public totalClaimed;
    uint256 public accountedLiabilities;

    event RewardNotified(uint256 indexed amount, uint256 indexed distributed, uint256 pending);
    event RewardClaimed(uint256 indexed tokenId, address indexed holder, uint256 amount);

    constructor(
        address collection_,
        address quote_,
        address poolManager_,
        address vault_,
        bytes32 snapshotRoot_,
        uint256 tokenCount_
    ) {
        if (
            collection_ == address(0) || collection_.code.length == 0 || quote_ == address(0)
                || quote_.code.length == 0 || poolManager_ == address(0)
                || poolManager_.code.length == 0 || vault_ == address(0)
                || snapshotRoot_ == bytes32(0) || tokenCount_ == 0 || tokenCount_ > MAX_TOKEN_IDS
        ) revert InvalidConfiguration();
        try IERC20Metadata(quote_).decimals() returns (uint8 decimals) {
            if (decimals != 6) revert InvalidConfiguration();
        } catch {
            revert InvalidConfiguration();
        }
        collection = ITriplV4ExternalCollection(collection_);
        quote = IERC20Metadata(quote_);
        poolManager = IPoolManager(poolManager_);
        vault = vault_;
        snapshotRoot = snapshotRoot_;
        tokenCount = tokenCount_;
    }

    function pendingFor(uint256 tokenId) public view returns (uint256 amount) {
        uint256 cursor = tokenCursor[tokenId];
        if (cumulativeRewardPerToken > cursor) amount = cumulativeRewardPerToken - cursor;
    }

    function pendingFor(uint256 tokenId, uint256 index, bytes32[] calldata proof)
        external
        view
        returns (uint256 amount)
    {
        if (_verify(tokenId, index, proof)) amount = pendingFor(tokenId);
    }

    function verifySnapshot(uint256 tokenId, uint256 index, bytes32[] calldata proof)
        public
        view
        returns (bool)
    {
        return _verify(tokenId, index, proof);
    }

    function notifyManagerReward(uint256 amount) external {
        if (msg.sender != vault || amount == 0) revert Unauthorized();
        uint256 claims = poolManager.balanceOf(address(this), uint160(address(quote)));
        if (claims < accountedLiabilities + amount) revert InexactTransfer();
        totalFunded += amount;
        cumulativeRewardPerToken = totalFunded / tokenCount;
        pendingReward = totalFunded % tokenCount;
        uint256 previousIndex = cumulativeRewardPerToken;
        if (totalFunded >= amount) previousIndex = (totalFunded - amount) / tokenCount;
        uint256 distributed = (cumulativeRewardPerToken - previousIndex) * tokenCount;
        accountedLiabilities += amount;
        emit RewardNotified(amount, distributed, pendingReward);
    }

    function claim(uint256 tokenId, uint256 index, bytes32[] calldata proof)
        external
        nonReentrant
        returns (uint256 amount)
    {
        amount = _claimToken(tokenId, index, proof, msg.sender);
        if (amount == 0) revert NothingToClaim();
    }

    function claimMany(
        uint256[] calldata tokenIds,
        uint256[] calldata indices,
        bytes32[][] calldata proofs
    ) external nonReentrant returns (uint256 total) {
        if (
            tokenIds.length == 0 || tokenIds.length > MAX_CLAIM_TOKENS
                || tokenIds.length != indices.length || tokenIds.length != proofs.length
        ) revert InvalidConfiguration();
        for (uint256 i; i < tokenIds.length; ++i) {
            total += _claimToken(tokenIds[i], indices[i], proofs[i], msg.sender);
        }
        if (total == 0) revert NothingToClaim();
    }

    function _claimToken(uint256 tokenId, uint256 index, bytes32[] calldata proof, address claimant)
        private
        returns (uint256 amount)
    {
        if (!_verify(tokenId, index, proof)) revert Unauthorized();
        address owner = collection.ownerOf(tokenId);
        if (owner == address(0) || owner != claimant) revert Unauthorized();
        uint256 cursor = tokenCursor[tokenId];
        if (cumulativeRewardPerToken <= cursor) return 0;
        amount = cumulativeRewardPerToken - cursor;
        tokenCursor[tokenId] = cumulativeRewardPerToken;
        accountedLiabilities -= amount;
        totalClaimed += amount;
        poolManager.unlock(abi.encode(owner, amount));
        emit RewardClaimed(tokenId, owner, amount);
    }

    function unlockCallback(bytes calldata rawData) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert Unauthorized();
        (address recipient, uint256 amount) = abi.decode(rawData, (address, uint256));
        poolManager.burn(address(this), uint160(address(quote)), amount);
        poolManager.take(Currency.wrap(address(quote)), recipient, amount);
        return bytes("");
    }

    function _verify(uint256 tokenId, uint256 index, bytes32[] calldata proof)
        private
        view
        returns (bool)
    {
        if (index >= tokenCount || proof.length > 32) return false;
        bytes32 computed = _hashLeaf(index, tokenId);
        for (uint256 i; i < proof.length; ++i) {
            bytes32 sibling = proof[i];
            computed = (index & (1 << i)) == 0
                ? _hashPair(computed, sibling)
                : _hashPair(sibling, computed);
        }
        return computed == snapshotRoot;
    }

    function _hashPair(bytes32 left, bytes32 right) private pure returns (bytes32) {
        (left, right) = left < right ? (left, right) : (right, left);
        assembly ("memory-safe") {
            mstore(0x00, left)
            mstore(0x20, right)
            left := keccak256(0x00, 0x40)
        }
        return left;
    }

    function _hashLeaf(uint256 index, uint256 tokenId) private pure returns (bytes32 leaf) {
        assembly ("memory-safe") {
            mstore(0x00, index)
            mstore(0x20, tokenId)
            leaf := keccak256(0x00, 0x40)
        }
    }
}
