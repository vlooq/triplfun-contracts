// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {TriplV5StakingRewards} from "./TriplV5StakingRewards.sol";

/// @notice Keeps rewards creation bytecode outside the EIP-170-limited factory.
contract TriplV5StakingDeployer {
    function deploy(
        address token_,
        address quote_,
        address poolManager_,
        bool diamondHands_,
        uint64 tierOneDuration_,
        uint64 tierTwoDuration_,
        uint16 tierOneMultiplierBps_,
        uint16 tierTwoMultiplierBps_
    ) external returns (address staking) {
        staking = address(
            new TriplV5StakingRewards(
                msg.sender,
                token_,
                quote_,
                poolManager_,
                diamondHands_,
                tierOneDuration_,
                tierTwoDuration_,
                tierOneMultiplierBps_,
                tierTwoMultiplierBps_
            )
        );
    }
}
