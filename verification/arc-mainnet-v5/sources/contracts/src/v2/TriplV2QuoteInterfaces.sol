// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @notice Owner-approved quote registry consumed by TriplV2Factory.
interface ITriplV2QuoteRegistry {
    function usdc() external view returns (address);

    function quoteConfig(address asset)
        external
        view
        returns (bool enabled, uint8 decimals, address nftAdapter, bytes32 codeHash);

    function getQuote(address asset)
        external
        view
        returns (bool enabled, uint8 decimals, address nftAdapter, bytes32 codeHash);
}

/// @notice Explicit quote-to-V1-USDC conversion boundary for NFT revenue.
/// @dev Implementations must enforce their own trusted oracle/route floor and
/// freshness checks. The user minOut/deadline are an additional lower bound;
/// the vault never accepts arbitrary router calldata from callers.
interface ITriplV2QuoteAdapter {
    function quoteAsset() external view returns (address);

    function usdc() external view returns (address);

    function convertToUsdc(address quote, uint256 amount, uint256 minOut, uint256 deadline)
        external
        returns (uint256 usdcOut);
}
