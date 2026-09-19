// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {TriplV5Token} from "./TriplV5Token.sol";
import {TriplV5ProtectedToken} from "./TriplV5ProtectedToken.sol";

/// @notice Keeps token creation bytecode outside the EIP-170-limited factory.
contract TriplV5TokenDeployer {
    function deploy(
        string calldata name_,
        string calldata symbol_,
        address creator_,
        bool firstBlockBuyTax_,
        bool protected_,
        string calldata metadataURI_
    ) external returns (address token) {
        if (protected_) {
            token = address(
                new TriplV5ProtectedToken(
                    name_, symbol_, msg.sender, creator_, firstBlockBuyTax_, true, metadataURI_
                )
            );
        } else {
            token = address(
                new TriplV5Token(
                    name_, symbol_, msg.sender, creator_, firstBlockBuyTax_, false, metadataURI_
                )
            );
        }
    }
}
