# Arc Mainnet active V5 source verification

This bundle reproduces the active Arc mainnet V5 deployment from the exact deployment-time source snapshot. Every direct deployment transaction is matched byte-for-byte against its compiled creation bytecode. Sourcify reports exact matches for all nine contracts. The fee hook has an exact runtime match; Arc does not expose its internal CREATE2 creation trace to Sourcify, so creationMatch is null.

- Chain: 5042
- Compiler: Solidity 0.8.30+commit.73712a01
- Optimizer: enabled, 200 runs
- EVM version: cancun
- Factory: 0xb23fedE11E2D209E6dE449dA073e9E14f0aEd5fD
- Fee hook: 0x74990D37DFB0ba1b104264FC06f6fa0698b9a0cc
- Router: 0x8a7bE71b8299472eBE37e7477F004bD8079003df

See manifest.json for deployment transactions, raw constructor arguments, submission IDs, match IDs, endpoints, and source hashes.
