// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

interface ITriplV4Router {
    function swapExactInput(PoolKey calldata key, bool zeroForOne, uint256 amountIn, uint256 minOut, uint256 deadline)
        external
        returns (uint256 amountOut);
    function poolManager() external view returns (IPoolManager);
}

/// @notice Readable per-launch PoolKey wrapper. PoolManager remains the source
/// of truth; this contract has no reserve or privileged withdrawal state.
contract TriplV4Market {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    error InvalidConfiguration();

    address public immutable factory;
    address public immutable token;
    address public immutable router;
    PoolKey private _key;

    constructor(address factory_, address token_, address router_, PoolKey memory key_) {
        if (factory_ == address(0) || token_ == address(0) || router_ == address(0)) revert InvalidConfiguration();
        factory = factory_;
        token = token_;
        router = router_;
        _key = key_;
    }

    function poolKey() external view returns (PoolKey memory) {
        return _key;
    }

    function currency0() external view returns (Currency) {
        return _key.currency0;
    }

    function currency1() external view returns (Currency) {
        return _key.currency1;
    }

    function fee() external view returns (uint24) {
        return _key.fee;
    }

    function tickSpacing() external view returns (int24) {
        return _key.tickSpacing;
    }

    function hooks() external view returns (IHooks) {
        return _key.hooks;
    }

    function poolId() external view returns (bytes32) {
        return PoolId.unwrap(_key.toId());
    }

    function getState() external view returns (uint160 sqrtPriceX96, int24 tick, uint128 liquidity) {
        IPoolManager manager = ITriplV4Router(router).poolManager();
        (sqrtPriceX96, tick,,) = manager.getSlot0(_key.toId());
        liquidity = manager.getLiquidity(_key.toId());
    }

    function swapExactInput(bool zeroForOne, uint256 amountIn, uint256 minOut, uint256 deadline)
        external
        returns (uint256 amountOut)
    {
        // A market wrapper cannot safely forward msg.sender to a router that
        // pulls tokens from its caller. Integrators should call the shared
        // router directly; this entrypoint intentionally fails closed.
        zeroForOne;
        amountIn;
        minOut;
        deadline;
        revert InvalidConfiguration();
    }
}
