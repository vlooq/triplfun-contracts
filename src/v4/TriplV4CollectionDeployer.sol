// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {TriplV4FeeShares} from "./TriplV4FeeShares.sol";
import {TriplV4CollectionRewards} from "./TriplV4CollectionRewards.sol";

/// @notice Bounded creator for the V4's single 100-share collection.
/// @dev Keeping this creation code outside Factory is required by EIP-3860.
contract TriplV4CollectionDeployer {
    error Unauthorized();

    address public immutable factory;

    struct CollectionConfig {
        address usdc;
        address treasury;
        address nftRecipient;
        uint256 mintPrice;
        uint256 saleStart;
        string baseURI;
        address factory;
        address poolManager;
    }

    struct ExternalCollectionConfig {
        address collection;
        address quote;
        address poolManager;
        address vault;
        bytes32 snapshotRoot;
        uint256 tokenCount;
    }

    constructor(address factory_) {
        if (factory_ == address(0)) revert Unauthorized();
        factory = factory_;
    }

    function deploy(address caller, CollectionConfig calldata config)
        external
        returns (address shares)
    {
        if (msg.sender != factory || caller != factory || config.factory != factory) {
            revert Unauthorized();
        }
        shares = address(_create(config));
    }

    function deployExternalRewards(address caller, ExternalCollectionConfig calldata config)
        external
        returns (address rewards)
    {
        if (msg.sender != factory || caller != factory) revert Unauthorized();
        rewards = address(
            new TriplV4CollectionRewards(
                config.collection,
                config.quote,
                config.poolManager,
                config.vault,
                config.snapshotRoot,
                config.tokenCount
            )
        );
    }

    function _create(CollectionConfig calldata config) private returns (TriplV4FeeShares shares) {
        shares = new TriplV4FeeShares(
            config.usdc,
            config.treasury,
            config.nftRecipient,
            config.mintPrice,
            config.saleStart,
            config.baseURI,
            config.factory,
            config.poolManager
        );
    }
}
