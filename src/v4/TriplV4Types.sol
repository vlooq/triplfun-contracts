// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @notice ABI structs shared by the standalone Uniswap v4 launchpad.
/// @dev The first successful launch is the canonical platform token. No V1
/// deployment is required; the factory deploys its own 100 share collection.
library TriplV4Types {
    uint16 internal constant BPS = 10_000;
    uint16 internal constant NFT_FEE_BPS = 30;
    uint16 internal constant PLATFORM_NFT_FEE_BPS = 100;
    uint16 internal constant PLATFORM_TREASURY_FEE_BPS = 100;
    uint16 internal constant MAX_TOTAL_FEE_BPS = 1_000;
    uint256 internal constant TOKEN_SUPPLY = 1_000_000_000e18;
    uint256 internal constant TARGET_INITIAL_FDV_USDC = 4_000e6;

    struct LaunchParams {
        string name;
        string symbol;
        string metadataURI;
        uint16 creatorFeeBps;
        uint16 holderFeeBps;
        uint16 collectionFeeBps;
        uint16 moduleFeeBps;
        uint8 moduleKind;
        int24 initialTick;
        int24 upperTick;
    }

    struct LaunchInfo {
        address token;
        address market;
        address hook;
        address locker;
        address rewards;
        bytes32 poolId;
        address creator;
        string name;
        string symbol;
        string metadataURI;
        uint16 creatorFeeBps;
        uint16 holderFeeBps;
        uint16 collectionFeeBps;
        uint16 moduleFeeBps;
        uint8 moduleKind;
        int24 initialTick;
        int24 upperTick;
        uint256 totalSupply;
        bool platformToken;
    }
}
