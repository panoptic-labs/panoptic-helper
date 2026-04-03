# PanopticHelper

## Installation

Panoptic uses the Foundry framework for testing and deployment, and Prettier for linting.

To get started, clone the repo and install the pre-commit hooks.

```bash
git clone https://github.com/panoptic-labs/panoptic-v1-helper.git --recurse-submodules
npm i
```

## Testing

Run the Foundry test suite:

```bash
forge test
```

Get a coverage report (requires `genhtml` to be installed):

```bash
forge coverage --report lcov && genhtml lcov.info --branch-coverage --output-dir coverage
```

## PanopticQuery Deployment

`PanopticQuery` is deployed behind a `TransparentUpgradeableProxy`. The repo supports two workflows:

- direct Foundry scripts for an EOA or hot wallet
- Safe Transaction Builder JSON generation for multisig execution

The supporting files are:

- [`script/DeployQuery.s.sol`](script/DeployQuery.s.sol)
- [`script/UpgradeQuery.s.sol`](script/UpgradeQuery.s.sol)
- [`src/PanopticQueryProxyAdmin.sol`](src/PanopticQueryProxyAdmin.sol)
- [`tools/generate_query_safe_batch.py`](tools/generate_query_safe_batch.py)
- [`tools/generate_query_upgrade_safe_batch.py`](tools/generate_query_upgrade_safe_batch.py)
- [`tools/generate_query_verify_commands.py`](tools/generate_query_verify_commands.py)

Before running any flow, build the repo so the local artifacts are up to date:

```bash
forge build
```

### Direct Deploy Script

This path deploys the implementation, deploys `PanopticQueryProxyAdmin`, and deploys the proxy.

Required env vars:

- `DEPLOYER_PRIVATE_KEY`
- `PANOPTIC_QUERY_PROXY_ADMIN_OWNER`

Optional env vars for vanity deployment:

- `PANOPTIC_QUERY_PROXY_USE_VANITY=true`
- `PANOPTIC_QUERY_PROXY_VANITY_MARKET`
- `PANOPTIC_QUERY_PROXY_ADDRESS`
- `PANOPTIC_QUERY_PROXY_SALT`
- `PANOPTIC_QUERY_PROXY_NONCE`
- `PANOPTIC_QUERY_PROXY_SALT_OWNER`
- `PANOPTIC_QUERY_PROXY_MINT=true|false`
- `PANOPTIC_QUERY_PROXY_EXECUTE=true|false`

Normal proxy deployment:

```bash
export DEPLOYER_PRIVATE_KEY=...
export PANOPTIC_QUERY_PROXY_ADMIN_OWNER=0x2ad7353c2ed82845FDF5246bc7b10278a34bca1F

forge script script/DeployQuery.s.sol --chain mainnet --broadcast
```

Vanity proxy deployment:

```bash
export DEPLOYER_PRIVATE_KEY=...
export PANOPTIC_QUERY_PROXY_ADMIN_OWNER=0x2ad7353c2ed82845FDF5246bc7b10278a34bca1F
export PANOPTIC_QUERY_PROXY_USE_VANITY=true
export PANOPTIC_QUERY_PROXY_ADDRESS=0x0000000000000e1aE9c66C1c3B0A547D23389C93
export PANOPTIC_QUERY_PROXY_SALT=0x82bf455e9ebd6a541ef10b683de1edcaf05ce7a14c9b27ef20f74200db645f6f
export PANOPTIC_QUERY_PROXY_NONCE=27
export PANOPTIC_QUERY_PROXY_MINT=true

forge script script/DeployQuery.s.sol --chain mainnet --broadcast
```

Set `PANOPTIC_QUERY_PROXY_EXECUTE=false` to print calldata without sending transactions.

### Direct Upgrade Script

Upgrades only deploy a new `PanopticQuery` implementation and call `ProxyAdmin.upgrade(...)`.

Required env vars:

- `DEPLOYER_PRIVATE_KEY`
- `PANOPTIC_QUERY_PROXY_ADDRESS`
- `PANOPTIC_QUERY_PROXY_ADMIN`

Example:

```bash
export DEPLOYER_PRIVATE_KEY=...
export PANOPTIC_QUERY_PROXY_ADDRESS=0x0000000000000e1aE9c66C1c3B0A547D23389C93
export PANOPTIC_QUERY_PROXY_ADMIN=0xFd1Ceb2317Dd551eC0005F82a4B117485398Dc98

forge script script/UpgradeQuery.s.sol --chain mainnet --broadcast
```

Set `PANOPTIC_QUERY_PROXY_EXECUTE=false` to print the upgrade calldata without executing it.

### Safe Batch Generation

The recommended production path is to generate Safe Transaction Builder JSON and execute the batch from the multisig UI.

#### Deployment Batch

Generate a deploy batch from the `3-of-5` Safe to deploy the implementation, deploy the owner-parameterized `ProxyAdmin`, and deploy the vanity proxy:

```bash
python3 tools/generate_query_safe_batch.py \
  --deployment-safe 0x82BF455e9ebd6a541EF10b683dE1edCaf05cE7A1 \
  --upgrade-safe 0x2ad7353c2ed82845FDF5246bc7b10278a34bca1F \
  --proxy-address 0x0000000000000e1aE9c66C1c3B0A547D23389C93 \
  --proxy-salt 0x82bf455e9ebd6a541ef10b683de1edcaf05ce7a14c9b27ef20f74200db645f6f \
  --proxy-nonce 27 \
  --output safe-txns/query_proxy_deploy.json
```

If the vanity slot has only been mined off-chain and has not been claimed on-chain yet, include the mint step:

```bash
python3 tools/generate_query_safe_batch.py \
  --deployment-safe 0x82BF455e9ebd6a541EF10b683dE1edCaf05cE7A1 \
  --upgrade-safe 0x2ad7353c2ed82845FDF5246bc7b10278a34bca1F \
  --proxy-address 0x0000000000000e1aE9c66C1c3B0A547D23389C93 \
  --proxy-salt 0x82bf455e9ebd6a541ef10b683de1edcaf05ce7a14c9b27ef20f74200db645f6f \
  --proxy-nonce 27 \
  --mint \
  --output safe-txns/query_proxy_deploy_with_mint.json
```

The output files can be imported directly into Safe Transaction Builder.

#### Upgrade Batch

Generate an upgrade batch for the `1-of-1` Safe:

```bash
python3 tools/generate_query_upgrade_safe_batch.py \
  --upgrade-safe 0x2ad7353c2ed82845FDF5246bc7b10278a34bca1F \
  --proxy-address 0x0000000000000e1aE9c66C1c3B0A547D23389C93 \
  --proxy-admin 0xFd1Ceb2317Dd551eC0005F82a4B117485398Dc98 \
  --version-label v2 \
  --output safe-txns/query_proxy_upgrade_v2.json
```

Use a new `--version-label` for each upgrade, or pass an explicit `--implementation-salt`.

### Verification

After deployment, verify the implementation, `PanopticQueryProxyAdmin`, and proxy on Etherscan. After upgrades, only the new implementation needs verification.

Set:

```bash
export ETHERSCAN_API_KEY=...
```

Generate deployment verification commands:

```bash
python3 tools/generate_query_verify_commands.py \
  --mode deploy \
  --proxy-address 0x0000000000000e1aE9c66C1c3B0A547D23389C93 \
  --upgrade-safe 0x2ad7353c2ed82845FDF5246bc7b10278a34bca1F
```

Generate upgrade verification commands:

```bash
python3 tools/generate_query_verify_commands.py \
  --mode upgrade \
  --proxy-address 0x0000000000000e1aE9c66C1c3B0A547D23389C93 \
  --version-label v2
```

These commands print the exact `forge verify-contract` invocations for the relevant contracts.
