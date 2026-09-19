# Triplfun contracts

Public Solidity source and exact verification material for the Triplfun V4 deployment on Arc mainnet (chain ID 5042).

## Canonical V4 deployment

- Factory: `0xEc2Cfd2749D7De9662615DbA63742888f6250287`
- Fee hook: `0xF3dd4C1A67F7d970a5D77E9b8D1466A613a820CC`
- Swap router: `0x0A2B7fcc81210ff7326F2A6571E821686823948c`
- Fee shares: `0x0C95AD83ff7e0F6b35368998747901fc9A1DfE5D`
- Fee vault: `0x1429f58F91fFD0625D6227B6a19dBACB402CEA5E`
- Platform token: `0x92bc59b005eA6A57E804AF8233b8a2B2704D19d8`
- Platform pool ID: `0xb8f3fa8fdea09bd96c74a2ea791fa51dc47552e61bafbf091442e7927f2e62b5`

The hook and infrastructure contracts are published with exact-match verification through Sourcify. The `verification/arc-mainnet-v4` directory contains the exact Solidity standard JSON input and ABI-encoded constructor arguments for the hook, plus the deployment manifest and constructor arguments for the related infrastructure.

The hook charges the configured platform fee during swaps and accounts for NFT-holder and treasury shares. It is immutable, is not a proxy, requires no custom swap calldata, and supports exact-input swaps only. Its active permissions are `beforeInitialize`, `beforeSwap`, `afterSwap`, `beforeSwapReturnDelta`, and `afterSwapReturnDelta`.

Official product: [tripl.fun](https://tripl.fun)

Contact: [tripldotfun@gmail.com](mailto:tripldotfun@gmail.com)

## License

Triplfun-authored sources are MIT licensed. Imported upstream code embedded in the standard JSON input retains its original SPDX identifier and license terms.
