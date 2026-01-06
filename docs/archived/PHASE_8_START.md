# Phase 8: Governance Tooling & Documentation - Started

## Status: In Progress

Started Phase 8 development after completing test fixes (175 passing, 24 remaining edge cases).

## Completed

### Directory Structure ✅
- Created `governance/` directory with subdirectories:
  - `payloads/` - Reusable proposal payload builders
  - `proposals/` - JSON proposal artifacts
  - `runbooks/` - Operational runbooks
  - `checks/` - Post-execution verification scripts
- Created `scripts/gov/` directory for governance scripts

### Type Definitions ✅
- Created `scripts/gov/types.ts` with:
  - `ProposalArtifact` interface
  - `ProposalCall` interface
  - `PayloadBuilder` type
  - `ExecutionResult` interface

### Address Utilities ✅
- Created `scripts/gov/addresses.ts` with:
  - `getDeployedAddress()` - Get single contract address
  - `getDeployedAddresses()` - Get multiple addresses
  - `getAllDeployedAddresses()` - Get all deployed contracts
  - `validateDeployments()` - Validate required contracts exist

### Proposal Builder ✅
- Created `scripts/gov/build-proposal.ts`:
  - Loads payload builder from TypeScript file
  - Validates required deployments
  - Builds proposal artifact
  - Saves to `governance/proposals/`

## Next Steps

### 8.1 Sample Payload Builders
- [ ] `0001_set_token_cap.ts` - Standard lane example
- [ ] `0002_queue_fee_address.ts` - Slow lane example
- [ ] `0003_emergency_pause.ts` - Emergency lane example

### 8.2 Simulation Script
- [ ] `scripts/gov/simulate-hardhat.ts` - Fork simulation for testing

### 8.3 Staging Script
- [ ] `scripts/gov/stage.ts` - Propose/queue/execute on testnet

### 8.4 Check Script
- [ ] `scripts/gov/check.ts` - Post-execution verification

### 8.5 Emergency Script
- [ ] `scripts/gov/emergency.ts` - Guardian emergency actions

### 8.6 Documentation
- [ ] Governance surface map
- [ ] Module map
- [ ] Operational runbooks

## Usage

```bash
# Build a proposal
pnpm ts-node scripts/gov/build-proposal.ts governance/payloads/0001_set_token_cap.ts

# This creates: governance/proposals/0001_set_token_cap.json
```


