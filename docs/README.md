# Escrow Protocol (Hardhat Deploy + Foundry)

This repository contains the smart contracts, deployment scripts, governance tooling, and documentation for the escrow protocol.

It uses:
- **Hardhat + hardhat-deploy** for deployments, verification, and TypeScript tooling
- **Foundry** for fast Solidity unit tests, fuzzing, and invariants

## Documentation

- **Start here**: [INDEX.md](INDEX.md)
- **Deployment**: [deployment/](deployment/)
  - Base Sepolia core testnet guide: [deployment/BASE_SEPOLIA_CORE_TESTNET_GUIDE.md](deployment/BASE_SEPOLIA_CORE_TESTNET_GUIDE.md)
  - Release tracking: [deployment/RELEASES.md](deployment/RELEASES.md)
- **Governance**: [governance/](governance/) and [../governance/runbooks/](../governance/runbooks/) (operational runbooks)
- **Security**:
  - Responsible disclosure: [SECURITY.md](SECURITY.md)
  - Security model: [SECURITY_MODEL.md](SECURITY_MODEL.md)

## Quick start (local)

```bash
pnpm i
cp .env.example .env
pnpm compile
pnpm test
```

## Tests

```bash
pnpm test                 # foundry
pnpm test:foundry
pnpm lint
pnpm typecheck
```

## Deploy

Local:

```bash
pnpm deploy:local
```

Base Sepolia (example):

```bash
pnpm deploy --network baseSepolia
```

Verification and release workflow docs:
- [deployment/BASE_SEPOLIA_CORE_TESTNET_GUIDE.md](deployment/BASE_SEPOLIA_CORE_TESTNET_GUIDE.md)
- [deployment/RELEASES.md](deployment/RELEASES.md)

## Production safety notes (high level)

- Gate upgrades behind **Safe + Timelock**.
- Require **storage layout checks** on every upgrade.
- Never leave upgrade authority on an EOA.

## Governance

The protocol uses onchain governance with `TimelockController` and OpenZeppelin Governor.

- [Governance Model](archived/governance.md) - Overview of governance structure (archived)
- [Governance Surface Map](governance/GOVERNANCE_SURFACE_MAP.md) - Complete function → role → lane mapping
- [Module Map](reference/MODULE_MAP.md) - Module interface → implementation mapping
- [Operational Runbooks](../governance/runbooks/) - Step-by-step procedures for operations
- [Upgrade Policy](policies/UPGRADE_POLICY.md) - Upgrade procedures and ossification plan
- [Emergency Policy](policies/EMERGENCY_POLICY.md) - Emergency controls and procedures
- [Governance Process](governance/GOVERNANCE_PROCESS.md) - Step-by-step governance workflow

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

See [Governance Documentation](governance/) for complete tooling overview.
