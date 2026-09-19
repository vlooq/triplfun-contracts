// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {TriplV5FeeVault} from "./TriplV5FeeVault.sol";

/// @notice Keeps fee-vault creation bytecode outside the EIP-170-limited factory.
contract TriplV5VaultDeployer {
    function deploy(
        address quote_,
        address creator_,
        address poolManager_,
        address feeShares_,
        address nftAdapter_,
        address[] calldata splitRecipients_,
        uint16[] calldata splitWeights_
    ) external returns (address vault) {
        vault = address(
            new TriplV5FeeVault(
                msg.sender,
                quote_,
                creator_,
                poolManager_,
                feeShares_,
                nftAdapter_,
                splitRecipients_,
                splitWeights_
            )
        );
    }
}
