// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {TriplV4LaunchDeployer} from "./TriplV4LaunchDeployer.sol";

/// @notice Minimal creation proxy for the per-market launch helper.
/// @dev The creation code is kept in this separately deployed component so
/// the infrastructure helper remains below EIP-170. Constructor arguments are
/// supplied as calldata and appended to the pinned creation code verbatim.
contract TriplV4LaunchFactory {
    fallback() external {
        bytes memory creationCode = type(TriplV4LaunchDeployer).creationCode;
        assembly {
            let length := mload(creationCode)
            calldatacopy(add(creationCode, add(0x20, length)), 0, calldatasize())
            let deployed := create(0, add(creationCode, 0x20), add(length, calldatasize()))
            mstore(0, deployed)
            return(0, 0x20)
        }
    }
}
