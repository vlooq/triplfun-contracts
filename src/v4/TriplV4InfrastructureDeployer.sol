// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {TriplV4FeeVault} from "./TriplV4FeeVault.sol";
import {TriplV4HookDeployer} from "./TriplV4HookDeployer.sol";
import {TriplV4FeeHook} from "./TriplV4FeeHook.sol";
import {TriplV4SwapRouter} from "./TriplV4SwapRouter.sol";

/// @notice Creates the non-collection V4 infrastructure for a factory.
/// @dev The helper is predeployed so Factory initcode remains under EIP-3860.
contract TriplV4InfrastructureDeployer {
    error Unauthorized();

    address public immutable factory;

    struct InfrastructureConfig {
        address poolManager;
        address usdc;
        address treasury;
        address feeShares;
        address launchFactory;
        bytes32 hookSalt;
    }

    constructor(address factory_) {
        if (factory_ == address(0)) revert Unauthorized();
        factory = factory_;
    }

    function deploy(
        address caller,
        InfrastructureConfig calldata config
    )
        external
        returns (
            address feeVault,
            address hookDeployer,
            address hook,
            address router,
            address launchDeployer
        )
    {
        if (msg.sender != factory || caller != factory) revert Unauthorized();
        TriplV4FeeVault vault = new TriplV4FeeVault(
            config.poolManager, config.usdc, config.treasury, caller, config.feeShares
        );
        TriplV4HookDeployer deployer = new TriplV4HookDeployer(address(this), config.hookSalt);
        address deployedHook = deployer.deploy(
            config.poolManager, caller, config.usdc, config.feeShares, address(vault)
        );
        TriplV4SwapRouter deployedRouter = new TriplV4SwapRouter(config.poolManager, caller);
        if (config.launchFactory == address(0) || config.launchFactory.code.length == 0) revert Unauthorized();
        bytes memory launchArgs = abi.encode(
            caller,
            config.poolManager,
            config.usdc,
            deployedHook,
            address(deployedRouter),
            address(vault)
        );
        (bool launchSuccess, bytes memory launchResult) = config.launchFactory.call(launchArgs);
        if (!launchSuccess || launchResult.length != 32) revert Unauthorized();
        address deployedLaunch = abi.decode(launchResult, (address));
        if (deployedLaunch == address(0) || deployedLaunch.code.length == 0) revert Unauthorized();
        return (address(vault), address(deployer), deployedHook, address(deployedRouter), deployedLaunch);
    }
}
