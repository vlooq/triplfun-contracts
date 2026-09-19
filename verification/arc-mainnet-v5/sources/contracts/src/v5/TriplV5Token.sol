// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {TriplV5Types} from "./TriplV5Types.sol";

/// @notice Fixed-cap launch token used by a v5 curve.
/// @dev The factory mints exactly one billion tokens once. No public mint or
/// arbitrary tax setter exists. The optional first-block tax is applied only
/// when the canonical market sends tokens to a buyer; sells remain possible.
contract TriplV5Token is ERC20 {
    error AlreadyBound();
    error InvalidConfiguration();
    error Unauthorized();
    error UnauthorizedPool();

    uint256 public constant INITIAL_SUPPLY = TriplV5Types.TOKEN_SUPPLY;

    address public immutable factory;
    address public immutable creator;
    bool public immutable firstBlockBuyTax;
    bool public immutable transferRestriction30Days;
    /// @notice Immutable-by-construction launch metadata pointer.
    string public metadataURI;
    /// @notice Set on the first market interaction, so the optional tax is
    /// keyed to the first trading block rather than deployment ordering.
    uint256 public launchBlock;
    uint256 public immutable launchTime;

    address public market;
    mapping(address => bool) public taxExempt;
    mapping(address => bool) public knownPool;
    mapping(address => bool) public canonicalVenue;

    event MarketBound(address indexed market);
    event KnownPoolRegistered(address indexed pool, bool canonical);

    constructor(
        string memory name_,
        string memory symbol_,
        address factory_,
        address creator_,
        bool firstBlockBuyTax_,
        bool transferRestriction30Days_,
        string memory metadataURI_
    ) ERC20(name_, symbol_) {
        if (
            factory_ == address(0) || creator_ == address(0) || bytes(metadataURI_).length == 0
                || bytes(metadataURI_).length > 2048
        ) {
            revert InvalidConfiguration();
        }
        factory = factory_;
        creator = creator_;
        firstBlockBuyTax = firstBlockBuyTax_;
        transferRestriction30Days = transferRestriction30Days_;
        metadataURI = metadataURI_;
        launchTime = block.timestamp;
        taxExempt[factory_] = true;
        taxExempt[creator_] = true;
        _mint(factory_, INITIAL_SUPPLY);
    }

    function bindMarket(address market_) external {
        if (msg.sender != factory || market != address(0) || market_ == address(0)) {
            revert Unauthorized();
        }
        market = market_;
        knownPool[market_] = true;
        canonicalVenue[market_] = true;
        emit MarketBound(market_);
    }

    function activateTrading() external {
        if (msg.sender != market) revert Unauthorized();
        if (launchBlock == 0) launchBlock = block.number;
    }

    /// @notice The factory may record a pool address it knows about. This is
    /// deliberately explicit: arbitrary undisclosed AMM pools cannot be
    /// detected by a standard ERC-20 transfer policy.
    function registerKnownPool(address pool, bool canonical) external {
        if (msg.sender != factory || pool == address(0)) revert Unauthorized();
        knownPool[pool] = true;
        canonicalVenue[pool] = canonical;
        emit KnownPoolRegistered(pool, canonical);
    }

    function setTaxExempt(address account, bool exempt) external {
        if (msg.sender != factory || account == address(0)) revert Unauthorized();
        taxExempt[account] = exempt;
    }

    function buyTaxBpsFor(address recipient) public view returns (uint16) {
        if (
            !firstBlockBuyTax || (launchBlock != 0 && block.number != launchBlock)
                || recipient == address(0) || taxExempt[recipient]
        ) return 0;
        return TriplV5Types.BUY_TAX_BPS;
    }

    function buyTaxFor(uint256 amount, address recipient) public view returns (uint256) {
        return amount * buyTaxBpsFor(recipient) / TriplV5Types.BPS;
    }

    function buyOutputFor(uint256 amount, address recipient) public view returns (uint256) {
        return amount - buyTaxFor(amount, recipient);
    }

    /// @dev Buyback burns are market-only and cannot be redirected by their
    /// permissionless caller.
    function burnFromMarket(uint256 amount) external {
        if (msg.sender != market || amount == 0) revert Unauthorized();
        _burn(market, amount);
    }
}
