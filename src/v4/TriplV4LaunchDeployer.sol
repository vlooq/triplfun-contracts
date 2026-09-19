// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {TriplV4Types} from "./TriplV4Types.sol";
import {TriplV4Token} from "./TriplV4Token.sol";
import {TriplV4HolderRewards} from "./TriplV4HolderRewards.sol";
import {TriplV4FeeHook} from "./TriplV4FeeHook.sol";
import {TriplV4Market} from "./TriplV4Market.sol";
import {TriplV4LiquidityLocker} from "./TriplV4LiquidityLocker.sol";

/// @notice Component creation helper kept out of the factory runtime.
contract TriplV4LaunchDeployer {
    error Unauthorized();
    error InvalidLaunch();

    address public immutable factory;
    IPoolManager public immutable poolManager;
    address public immutable usdc;
    TriplV4FeeHook public immutable hook;
    address public immutable router;
    address public immutable feeVault;

    constructor(
        address factory_,
        address poolManager_,
        address usdc_,
        address hook_,
        address router_,
        address feeVault_
    ) {
        if (
            factory_ == address(0) || poolManager_ == address(0) || usdc_ == address(0)
                || hook_ == address(0) || router_ == address(0) || feeVault_ == address(0)
        ) revert Unauthorized();
        factory = factory_;
        poolManager = IPoolManager(poolManager_);
        usdc = usdc_;
        hook = TriplV4FeeHook(hook_);
        router = router_;
        feeVault = feeVault_;
    }

    function deploy(TriplV4Types.LaunchParams calldata params)
        external
        returns (
            address token,
            address market,
            address locker,
            address rewards,
            PoolKey memory key,
            int24 lower,
            int24 upper,
            int24 initialTick
        )
    {
        if (msg.sender != factory) revert Unauthorized();
        TriplV4Token deployedToken = new TriplV4Token(params.name, params.symbol, factory);
        (key, lower, upper, initialTick) = _makeKey(address(deployedToken), params);
        poolManager.initialize(key, TickMath.getSqrtPriceAtTick(initialTick));
        TriplV4Market deployedMarket = new TriplV4Market(factory, address(deployedToken), router, key);
        TriplV4LiquidityLocker deployedLocker = new TriplV4LiquidityLocker(
            address(poolManager), factory, address(deployedToken), key, lower, upper
        );
        address[] memory exclusions = new address[](2);
        exclusions[0] = address(deployedLocker);
        exclusions[1] = feeVault;
        TriplV4HolderRewards deployedRewards = new TriplV4HolderRewards(
            usdc,
            address(deployedToken),
            factory,
            address(deployedMarket),
            feeVault,
            address(poolManager),
            exclusions
        );
        token = address(deployedToken);
        market = address(deployedMarket);
        locker = address(deployedLocker);
        rewards = address(deployedRewards);
    }

    function _makeKey(address token, TriplV4Types.LaunchParams calldata params)
        private
        view
        returns (PoolKey memory key, int24 lower, int24 upper, int24 initialTick)
    {
        bool tokenIs0 = token < usdc;
        initialTick = tokenIs0 ? int24(-400620) : int24(400620);
        if (params.initialTick != 0 && params.initialTick != initialTick) revert InvalidLaunch();
        key = PoolKey({
            currency0: Currency.wrap(tokenIs0 ? token : usdc),
            currency1: Currency.wrap(tokenIs0 ? usdc : token),
            fee: 0,
            tickSpacing: 60,
            hooks: hook
        });
        if (tokenIs0) {
            lower = initialTick;
            upper = params.upperTick == 0 ? initialTick + 600_000 : params.upperTick;
        } else {
            lower = params.upperTick == 0 ? initialTick - 600_000 : params.upperTick;
            upper = initialTick;
        }
        if (lower >= upper || lower % 60 != 0 || upper % 60 != 0) revert InvalidLaunch();
    }
}
