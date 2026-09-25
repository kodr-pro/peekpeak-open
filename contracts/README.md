# PeekPeak Contracts

Foundry project. Normative spec: `../docs/ground-truth/spec.md`.

```bash
forge build
forge test -vvv
forge coverage --report summary
FOUNDRY_PROFILE=fuzz forge test   # long invariant campaign (100k runs / 2048x128)
```

Deploying (all values via env, never committed):

```bash
# registry (TREASURY = Safe address; CREATE2_SALT optional for a
# cross-chain-stable address via the universal deployer)
DEPLOYER_KEY=0x.. TREASURY=0x.. forge script script/DeployRegistry.s.sol --rpc-url $RPC --broadcast

# MockJob dry run on Fuji (SPEC-11)
DEPLOYER_KEY=0x.. REGISTRY=0x.. DEPOSIT_WEI=200000000000000000 \
  forge script script/RegisterJob.s.sol:DeployMockJob --rpc-url $RPC --broadcast

# register any IAutoJob target
DEPLOYER_KEY=0x.. REGISTRY=0x.. TARGET=0x.. GAS_LIMIT=500000 MAX_GAS_PRICE_GWEI=100 DEPOSIT_WEI=... \
  forge script script/RegisterJob.s.sol:RegisterJob --rpc-url $RPC --broadcast
```

Layout: `src/` (IAutoJob, PeekRegistry, adapters, mocks), `test/` (unit + invariant),
`script/` (deploy + register), `fuzz/` (invariant harness). Deployed addresses are
recorded per chain in `../deploy/chains/*.json` after deployment (public data only).
