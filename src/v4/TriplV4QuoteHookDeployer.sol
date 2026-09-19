// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {TriplV4QuoteFeeHook} from "./TriplV4QuoteFeeHook.sol";

contract TriplV4QuoteHookDeployer {
    function deploy(bytes32 salt, address poolManager, address factory, address feeVault)
        external
        returns (address)
    {
        return address(new TriplV4QuoteFeeHook{salt: salt}(poolManager, factory, feeVault));
    }
}
