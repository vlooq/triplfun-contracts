// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {TriplV4FeeHook} from "./TriplV4FeeHook.sol";

/// @notice CREATE2 helper for v4 hook permission bits.
/// @dev The upstream manager validates hook address bits. The deployer uses a
/// caller supplied CREATE2 salt selected before deployment; it never performs
/// an unbounded on-chain search.
contract TriplV4HookDeployer {
    error Unauthorized();

    address public immutable factory;
    bytes32 public immutable hookSalt;

    constructor(address factory_, bytes32 hookSalt_) {
        if (factory_ == address(0)) revert Unauthorized();
        factory = factory_;
        hookSalt = hookSalt_;
    }

    function deploy(
        address poolManager,
        address hookFactory,
        address usdc,
        address feeShares,
        address feeVault
    ) external returns (address hook) {
        if (msg.sender != factory || hookFactory == address(0)) revert Unauthorized();
        TriplV4FeeHook deployed = new TriplV4FeeHook{salt: hookSalt}(
            poolManager, hookFactory, usdc, feeShares, feeVault
        );
        return address(deployed);
    }
}
