// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {TriplV5LiquidityLocker} from "./TriplV5LiquidityLocker.sol";

/// @notice Keeps locker creation bytecode outside every market runtime.
contract TriplV5LockerDeployer {
    function deploy(
        address poolManager_,
        address token_,
        address quote_,
        PoolKey calldata key_,
        int24 lower_,
        int24 upper_
    ) external returns (address locker) {
        locker = address(
            new TriplV5LiquidityLocker(
                poolManager_, msg.sender, token_, quote_, key_, lower_, upper_
            )
        );
    }
}
