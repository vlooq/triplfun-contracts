// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {TriplV5FeeHook} from "./TriplV5FeeHook.sol";

/// @notice CREATE2 helper for the v4 hook permission bits.
/// @dev The caller mines a salt off-chain and submits it explicitly. There is
/// no unbounded on-chain search and no deployment side effect beyond the hook.
contract TriplV5HookDeployer {
    function deploy(bytes32 salt, address poolManager) external returns (address hook) {
        hook = address(new TriplV5FeeHook{salt: salt}(poolManager, msg.sender));
    }
}
