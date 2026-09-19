// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {TriplV3QuoteAdapter} from "./TriplV3QuoteAdapter.sol";
import {TriplV4SwapRouter} from "./TriplV4SwapRouter.sol";
import {TriplV4QuoteFactory} from "./TriplV4QuoteFactory.sol";
import {TriplV4QuoteFeeVault} from "./TriplV4QuoteFeeVault.sol";
import {TriplV4QuoteHookDeployer} from "./TriplV4QuoteHookDeployer.sol";
import {TriplV4QuoteLaunchDeployer} from "./TriplV4QuoteLaunchDeployer.sol";

/// @notice Atomically deploys the reviewed NVDA/CRCL V4 extension so the owner
/// signs one transaction and cannot leave partially bound infrastructure.
contract TriplV4QuoteInfrastructureDeployer {
    error InvalidConfiguration();

    struct QuoteSetup {
        address quote;
        address v3Pool;
        int24 tickMagnitude;
        uint32 twapWindow;
        uint16 maxDeviationBps;
    }

    address public immutable factory;
    address public immutable hook;
    address public immutable router;
    address public immutable feeVault;
    address public immutable launchDeployer;

    constructor(
        address owner,
        address poolManager,
        address usdc,
        address feeShares,
        address v3Router,
        bytes32 hookSalt,
        QuoteSetup[] memory setups
    ) {
        if (owner == address(0) || setups.length == 0 || setups.length > 8) revert InvalidConfiguration();
        address[] memory adapters = new address[](setups.length);
        for (uint256 i; i < setups.length; ++i) {
            QuoteSetup memory setup = setups[i];
            adapters[i] = address(new TriplV3QuoteAdapter(
                setup.v3Pool, v3Router, setup.quote, usdc, setup.twapWindow, setup.maxDeviationBps
            ));
        }

        TriplV4QuoteHookDeployer hookHelper = new TriplV4QuoteHookDeployer();
        // Adapters consume nonces 1..N; helper, vault, router, launch deployer
        // consume the next four, so the factory is nonce N+5.
        address predictedFactory = _createAddress(address(this), setups.length + 5);
        TriplV4QuoteFeeVault vault = new TriplV4QuoteFeeVault(poolManager, predictedFactory, usdc, feeShares);
        TriplV4SwapRouter swapRouter = new TriplV4SwapRouter(poolManager, predictedFactory);
        address deployedHook = hookHelper.deploy(hookSalt, poolManager, predictedFactory, address(vault));
        TriplV4QuoteLaunchDeployer launcher = new TriplV4QuoteLaunchDeployer(
            predictedFactory, poolManager, deployedHook, address(swapRouter), address(vault)
        );
        TriplV4QuoteFactory.QuoteInit[] memory initial = new TriplV4QuoteFactory.QuoteInit[](setups.length);
        for (uint256 i; i < setups.length; ++i) {
            initial[i] = TriplV4QuoteFactory.QuoteInit({
                quote: setups[i].quote,
                enabled: true,
                tickMagnitude: setups[i].tickMagnitude,
                adapter: adapters[i],
                codeHash: setups[i].quote.codehash
            });
        }
        TriplV4QuoteFactory deployedFactory = new TriplV4QuoteFactory(
            owner, poolManager, usdc, feeShares, address(vault), deployedHook,
            address(swapRouter), address(launcher), initial
        );
        if (address(deployedFactory) != predictedFactory) revert InvalidConfiguration();
        factory = predictedFactory;
        hook = deployedHook;
        router = address(swapRouter);
        feeVault = address(vault);
        launchDeployer = address(launcher);
    }

    function _createAddress(address deployer, uint256 nonce) private pure returns (address) {
        if (nonce == 0 || nonce > 127) revert InvalidConfiguration();
        return address(uint160(uint256(keccak256(abi.encodePacked(hex"d694", deployer, bytes1(uint8(nonce)))))));
    }
}
