// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {TriplV5Token} from "./TriplV5Token.sol";
import {TriplV5Types} from "./TriplV5Types.sol";

/// @notice Opt-in v5 token with the bounded, factory-known venue policy.
/// @dev The default TriplV5Token intentionally has no _update override. This
/// derived implementation is deployed only when the launch explicitly opts in
/// to the 30-day restriction, and still cannot identify undisclosed AMM pools.
contract TriplV5ProtectedToken is TriplV5Token {
    constructor(
        string memory name_,
        string memory symbol_,
        address factory_,
        address creator_,
        bool firstBlockBuyTax_,
        bool transferRestriction30Days_,
        string memory metadataURI_
    )
        TriplV5Token(
            name_,
            symbol_,
            factory_,
            creator_,
            firstBlockBuyTax_,
            transferRestriction30Days_,
            metadataURI_
        )
    {
        if (!transferRestriction30Days_) {
            revert InvalidConfiguration();
        }
    }

    function _update(address from, address to, uint256 amount) internal override(ERC20) {
        if (
            block.timestamp < launchTime + TriplV5Types.TRANSFER_RESTRICTION_DURATION
                && to != address(0)
                && ((knownPool[from] && !canonicalVenue[from])
                    || (knownPool[to] && !canonicalVenue[to]))
        ) revert UnauthorizedPool();
        super._update(from, to, amount);
    }
}
