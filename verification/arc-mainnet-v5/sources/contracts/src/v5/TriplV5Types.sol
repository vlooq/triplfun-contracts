// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @notice Shared immutable launch configuration for the Tripl v5 protocol.
/// @dev This file intentionally keeps the optional module enum stable. The
/// lottery slot is reserved but rejected by the factory until a separately
/// reviewed randomness design exists.
library TriplV5Types {
    uint16 internal constant BPS = 10_000;
    uint16 internal constant NFT_FEE_BPS = 30;
    uint16 internal constant MAX_TOTAL_FEE_BPS = 1_000;
    uint256 internal constant TOKEN_SUPPLY = 1_000_000_000e18;
    uint16 internal constant BUY_TAX_BPS = 9_000;
    uint64 internal constant TRANSFER_RESTRICTION_DURATION = 30 days;
    uint8 internal constant MAX_SPLIT_RECIPIENTS = 5;

    enum ModuleKind {
        None,
        Buyback,
        LotteryReserved
    }

    struct LaunchParams {
        address quote;
        address creator;
        string name;
        string symbol;
        uint256 initialVirtualQuoteReserve;
        uint256 graduationThreshold;
        uint16 creatorFeeBps;
        uint16 holderFeeBps;
        uint16 buybackFeeBps;
        uint16 splitFeeBps;
        address[] splitRecipients;
        uint16[] splitWeights;
        ModuleKind moduleKind;
        uint256 maxBuybackQuote;
        bool firstBlockBuyTax;
        bool transferRestriction30Days;
        bool diamondHands;
        uint64 tierOneDuration;
        uint64 tierTwoDuration;
        uint16 tierOneMultiplierBps;
        uint16 tierTwoMultiplierBps;
        address poolManager;
        /// @dev A deployed v4 hook with the required permission bits. A zero
        /// value intentionally keeps graduation disabled until fee routing is
        /// configured; PoolManager cannot call an arbitrary market method.
        address poolHook;
        uint24 poolFee;
        int24 poolTickSpacing;
        /// @dev Deprecated compatibility slot. v5 ignores caller supplied
        /// opening ticks and derives the terminal curve tick at graduation.
        int24 openingTick;
        /// @dev Immutable launch metadata pointer. The factory bounds this to
        /// a non-empty UTF-8 URI of at most 2048 bytes.
        string metadataURI;
    }

    struct FeeBreakdown {
        uint256 nft;
        uint256 creator;
        uint256 holder;
        uint256 buyback;
        uint256 split;
        uint256 total;
    }

    struct LaunchInfo {
        address token;
        address market;
        address feeVault;
        address staking;
        address creator;
        address quote;
        address poolHook;
        uint256 launchBlock;
        uint256 graduationThreshold;
        uint16 creatorFeeBps;
        uint16 holderFeeBps;
        uint16 buybackFeeBps;
        uint16 splitFeeBps;
        ModuleKind moduleKind;
        bool firstBlockBuyTax;
        bool transferRestriction30Days;
        bool diamondHands;
        bool graduated;
        /// @dev Appended to preserve the original LaunchInfo ABI field order.
        string metadataURI;
    }
}
