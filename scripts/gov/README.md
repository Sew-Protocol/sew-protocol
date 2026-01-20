# Governance Scripts

Scripts for building, simulating, staging, and executing governance proposals.

## Scripts

- **`build-proposal.ts`** - Build proposal artifacts from payloads
- **`simulate-hardhat.ts`** - Fork simulation for proposal testing
- **`stage.ts`** - Propose/queue/execute on testnet
- **`check.ts`** - Post-execution verification
- **`emergency.ts`** - Guardian emergency actions

## Usage

```bash
# Build a proposal
pnpm ts-node scripts/gov/build-proposal.ts governance/payloads/0001_set_token_cap.ts

# Simulate on fork
pnpm ts-node scripts/gov/simulate-hardhat.ts governance/proposals/0001_set_token_cap.json

# Stage on testnet
pnpm ts-node scripts/gov/stage.ts governance/proposals/0001_set_token_cap.json --network baseSepolia

# Check execution
pnpm ts-node scripts/gov/check.ts governance/proposals/0001_set_token_cap.json
```
