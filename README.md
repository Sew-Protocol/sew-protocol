# hardhat-deploy-hybrid (classic hardhat-deploy + Foundry)

This scaffold uses **classic** `hardhat-deploy` (not Ignition) and supports:

- **Complex multi-step deployments** (script ordering + tags)
- **Upgradeable deployments**: **Transparent** or **UUPS** (select via `PROXY_KIND`)
- **Hardhat tests** (TypeScript)
- **Foundry tests** (forge)
- A timestamped deployment ledger in `deploy-ledger/<network>/<stamp>/`

## Quick start

```bash
pnpm i
cp .env.example .env
pnpm test
```

## Deploy locally

```bash
pnpm deploy:local
pnpm export --network hardhat
```

## Deploy with proxies

Transparent (default):

```bash
pnpm deploy --network baseSepolia
```

UUPS:

```bash
PROXY_KIND=uups pnpm deploy --network baseSepolia
```

## Deploy flow (example)

- `deploy/00_impl.ts` deploys impl for bookkeeping
- `deploy/11_proxy.ts` deploys proxy + runs initializer
- `deploy/90_post.ts` sanity checks / wiring

## Production safety notes

- Gate upgrades behind **Safe + Timelock**.
- Require **storage layout checks** on every upgrade.
- Never leave upgrade authority on an EOA.

## Security

- [Security Policy](SECURITY.md) - Security contact and responsible disclosure policy
- [Security Model](docs/SECURITY_MODEL.md) - Comprehensive security model and threat analysis

## Governance

The protocol uses onchain governance with TimelockController and OpenZeppelin Governor. See governance documentation:

- [Governance Model](docs/governance/governance.md) - Overview of governance structure
- [Governance Surface Map](docs/governance/GOVERNANCE_SURFACE_MAP.md) - Complete function → role → lane mapping
- [Module Map](docs/reference/MODULE_MAP.md) - Module interface → implementation mapping
- [Operational Runbooks](governance/runbooks/) - Step-by-step procedures for operations
- [Upgrade Policy](docs/policies/UPGRADE_POLICY.md) - Upgrade procedures and ossification plan
- [Emergency Policy](docs/policies/EMERGENCY_POLICY.md) - Emergency controls and procedures
- [Governance Process](docs/governance/GOVERNANCE_PROCESS.md) - Step-by-step governance workflow

### Governance Tooling

```bash
# Build a proposal
pnpm gov:build governance/payloads/0001_set_token_cap.ts

# Simulate on fork
pnpm gov:sim governance/proposals/0001_set_token_cap.json --fork-url=$BASE_RPC

# Stage on testnet/mainnet
pnpm gov:stage governance/proposals/0001_set_token_cap.json --stage=propose --network baseSepolia

# Check execution
pnpm gov:check governance/proposals/0001_set_token_cap.json --network baseMainnet

# Emergency actions (Guardian only)
pnpm gov:emergency pause --contract EscrowableERC20 --network baseMainnet
```

See [Governance Documentation](docs/governance/) for complete tooling overview.
