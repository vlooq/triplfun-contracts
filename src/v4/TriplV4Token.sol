// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

interface ITriplV4TransferRewards {
    function beforeTokenTransfer(address from, address to, uint256 amount) external;
}

/// @notice One-billion-token fixed-supply token for a V4 pool.
contract TriplV4Token is ERC20 {
    error InvalidConfiguration();
    error Unauthorized();
    error AlreadyBound();

    uint256 public constant INITIAL_SUPPLY = 1_000_000_000e18;
    address public immutable factory;
    address public market;
    address public holderRewards;

    constructor(string memory name_, string memory symbol_, address factory_) ERC20(name_, symbol_) {
        if (factory_ == address(0)) revert InvalidConfiguration();
        factory = factory_;
        _mint(factory_, INITIAL_SUPPLY);
    }

    function bindMarket(address market_) external {
        if (msg.sender != factory || market_ == address(0) || market != address(0)) revert Unauthorized();
        market = market_;
    }

    function bindHolderRewards(address rewards_) external {
        if (msg.sender != factory || rewards_ == address(0) || holderRewards != address(0)) {
            revert AlreadyBound();
        }
        holderRewards = rewards_;
    }

    function _update(address from, address to, uint256 amount) internal override {
        address rewards = holderRewards;
        if (rewards != address(0)) ITriplV4TransferRewards(rewards).beforeTokenTransfer(from, to, amount);
        super._update(from, to, amount);
    }
}
