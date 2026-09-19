// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {TriplV5Market} from "./TriplV5Market.sol";

/// @notice Keeps market creation bytecode outside the EIP-170-limited factory.
contract TriplV5MarketDeployer {
    function deploy(TriplV5Market.Config calldata config_) external returns (address) {
        return address(new TriplV5Market(config_));
    }
}
