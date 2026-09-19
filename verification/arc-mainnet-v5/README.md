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

## Verified child contracts

The active factory has three launches and 15 child contracts. All 15 have Sourcify exact runtime matches. `creationMatch` is exact when Arc exposes the internal creation trace; otherwise it is `null`.

### Launch 0

- TriplV5ProtectedToken (token): 0xdDCD0ccBCF1e8f74c18ea5ef76aFA40c46CdFe74 — match 51325715, exact_match, runtime exact_match, creation exact_match
- TriplV5Market (market): 0xA14f0A4843b1E73dDC8bd3dFC8894141a2873786 — match 51325718, exact_match, runtime exact_match, creation exact_match
- TriplV5FeeVault (vault): 0xe3613821be6407B96767a62c4DED92efD61f6485 — match 51325717, exact_match, runtime exact_match, creation exact_match
- TriplV5StakingRewards (staking): 0xb1d3052D56837b65be47072806C6f7925cc4e515 — match 51325722, exact_match, runtime exact_match, creation null
- TriplV5LiquidityLocker (locker): 0x8fD9769c7bc8831B7BbB1b11D4795De01FA2BE4a — match 51325728, exact_match, runtime exact_match, creation null

### Launch 1

- TriplV5ProtectedToken (token): 0xac5A4361321Bb78bd1a18d52375cc5fe2C6E5830 — match 51325721, exact_match, runtime exact_match, creation null
- TriplV5Market (market): 0xF057C82Fb4256AF3732509533fe0B0bd5A68082d — match 51325724, exact_match, runtime exact_match, creation null
- TriplV5FeeVault (vault): 0x1dbc01Ff6A02f848d728B3DC92816DdD1cAa8008 — match 51325729, exact_match, runtime exact_match, creation null
- TriplV5StakingRewards (staking): 0x7F3983A6Dc3F3E987FFfeaa26121AA0808d7FdbF — match 51325727, exact_match, runtime exact_match, creation null
- TriplV5LiquidityLocker (locker): 0x915e2a72CcDe3fc19dFE70fA30E144681FA695Ea — match 51325723, exact_match, runtime exact_match, creation null

### Launch 2

- TriplV5ProtectedToken (token): 0xd21741e396d0c5653f21144720268661D055260d — match 51325725, exact_match, runtime exact_match, creation null
- TriplV5Market (market): 0x306cCcaE8eA042e62bD16f890996C13DC3d4f7F9 — match 51325720, exact_match, runtime exact_match, creation exact_match
- TriplV5FeeVault (vault): 0xB78CAa75805Ce3649E3900f813718219293c15Cc — match 51325719, exact_match, runtime exact_match, creation exact_match
- TriplV5StakingRewards (staking): 0xE19E54Bb5D4a0645E201126e1CADBf7cfa666b6F — match 51325726, exact_match, runtime exact_match, creation null
- TriplV5LiquidityLocker (locker): 0xe65fb9fDd987E6253FE63DC2185691276f1C8745 — match 51325730, exact_match, runtime exact_match, creation null

Each raw response is stored in `sourcify-responses/`; the corresponding endpoint and submission ID are recorded in `manifest.json`.
