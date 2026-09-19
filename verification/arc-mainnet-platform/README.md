# Live canonical V4 market source verification

Generated read-only from Arc chain 5042. Nothing was submitted.

Regenerate and re-check live bytecode:

```sh
TRIPLFUN_ARC_RPC_URL=https://rpc.mainnet.arc.io npx tsx scripts/prepare-live-v4-market-source-verification.ts
```

For each contract, upload `<Contract>.standard-input.json` to the Arc explorer Solidity standard JSON verifier, select compiler `v0.8.30+commit.73712a01`, and paste the contents of `<Contract>.constructor-args.txt`. Keep optimization at 200 runs and EVM version Cancun. Re-run this generator after verification to refresh the Sourcify match fields.
