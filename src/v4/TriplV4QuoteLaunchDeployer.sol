// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {TriplV4Token} from "./TriplV4Token.sol";
import {TriplV4HolderRewards} from "./TriplV4HolderRewards.sol";
import {TriplV4Market} from "./TriplV4Market.sol";
import {TriplV4LiquidityLocker} from "./TriplV4LiquidityLocker.sol";
import {TriplV4QuoteFeeHook} from "./TriplV4QuoteFeeHook.sol";

contract TriplV4QuoteLaunchDeployer {
    error Unauthorized();
    error InvalidLaunch();

    address public immutable factory;
    IPoolManager public immutable poolManager;
    TriplV4QuoteFeeHook public immutable hook;
    address public immutable router;
    address public immutable feeVault;

    constructor(address factory_, address poolManager_, address hook_, address router_, address feeVault_) {
        if (
            factory_ == address(0) || poolManager_.code.length == 0 || hook_ == address(0)
                || router_ == address(0) || feeVault_ == address(0)
        ) revert Unauthorized();
        factory = factory_;
        poolManager = IPoolManager(poolManager_);
        hook = TriplV4QuoteFeeHook(hook_);
        router = router_;
        feeVault = feeVault_;
    }

    function deploy(
        string calldata name,
        string calldata symbol,
        address quote,
        int24 tickMagnitude
    ) external returns (address token, address market, address locker, address rewards, PoolKey memory key) {
        if (msg.sender != factory || tickMagnitude <= 0 || tickMagnitude % 60 != 0) revert Unauthorized();
        TriplV4Token deployedToken = new TriplV4Token(name, symbol, factory);
        bool tokenIs0 = address(deployedToken) < quote;
        int24 initialTick = tokenIs0 ? -tickMagnitude : tickMagnitude;
        key = PoolKey({
            currency0: Currency.wrap(tokenIs0 ? address(deployedToken) : quote),
            currency1: Currency.wrap(tokenIs0 ? quote : address(deployedToken)),
            fee: 0,
            tickSpacing: 60,
            hooks: hook
        });
        poolManager.initialize(key, TickMath.getSqrtPriceAtTick(initialTick));
        TriplV4Market deployedMarket = new TriplV4Market(factory, address(deployedToken), router, key);
        int24 lower = tokenIs0 ? initialTick : initialTick - 600_000;
        int24 upper = tokenIs0 ? initialTick + 600_000 : initialTick;
        if (lower < TickMath.MIN_TICK || upper > TickMath.MAX_TICK) revert InvalidLaunch();
        TriplV4LiquidityLocker deployedLocker = new TriplV4LiquidityLocker(
            address(poolManager), factory, address(deployedToken), key, lower, upper
        );
        address[] memory exclusions = new address[](2);
        exclusions[0] = address(deployedLocker);
        exclusions[1] = feeVault;
        TriplV4HolderRewards deployedRewards = new TriplV4HolderRewards(
            quote,
            address(deployedToken),
            factory,
            address(deployedMarket),
            feeVault,
            address(poolManager),
            exclusions
        );
        return (
            address(deployedToken),
            address(deployedMarket),
            address(deployedLocker),
            address(deployedRewards),
            key
        );
    }
}
