# Mainnet Release Sequence Test Suite

## Overview

This document describes the comprehensive test suite (`test/hardhat/MainnetReleaseSequence.test.ts`) that validates the complete mainnet deployment and progressive decentralization path. These tests mirror the actual mainnet release sequence required for the Coinstore IEO.

## Test Structure

The test suite is organized into stages that match the progressive decentralization roadmap outlined in `docs/token/2026_token_expectations.md`:

### Stage 0: Initial Deployment - Governance Token
- **Test**: Deploy governance token (ERC20) for token holders
- **Purpose**: Validates that a governance token can be deployed and distributed to token holders
- **Production Equivalent**: Deploy the actual governance token contract

### Stage 1: Deploy Fixed and Upgradeable Parts
- **Test**: Deploy libraries, modules, and main contracts
- **Sub-tests**:
  - Deploy libraries first (fixed parts)
  - Deploy simplest modules (starting with basic modules)
  - Deploy upgradeable main contracts via proxy
- **Purpose**: Validates the deployment order and proper linking of contracts
- **Production Equivalent**: 
  - Deploy libraries
  - Deploy modules (DefaultReleaseStrategy, DefaultResolutionModule, etc.)
  - Deploy EscrowableERC20 and EscrowVault via proxy

### Stage 2: Transfer Ownership to Safe Multisig
- **Test**: Transfer ownership of all contracts to Safe multisig
- **Sub-tests**:
  - Transfer ownership to multisig
  - Verify multisig can perform owner-only operations
- **Purpose**: Validates the transition from deployer control to multisig control
- **Production Equivalent**: Transfer ownership to Safe multisig after initial deployment

### Stage 3: Deploy Timelock and Setup Timelocked Upgrades
- **Test**: Deploy TimelockController and transfer ownership to it
- **Sub-tests**:
  - Deploy TimelockController
  - Transfer contract ownership to Timelock
  - Trigger timelocked upgrade with Safe multisig
- **Purpose**: Validates the timelock mechanism for delayed execution
- **Production Equivalent**: 
  - Deploy OpenZeppelin TimelockController
  - Transfer ownership to Timelock
  - Execute upgrades through timelock

### Stage 4: Upgrade to DAO Governance
- **Test**: Deploy OpenZeppelin Governor and enable DAO-controlled upgrades
- **Sub-tests**:
  - Deploy OpenZeppelin Governor with Timelock
  - Grant Governor proposer and executor roles in Timelock
  - Transfer contract ownership from Timelock to Governor-controlled Timelock
  - Create and execute DAO proposal to change contract parameter
  - Demonstrate full DAO governance flow for upgrade
- **Purpose**: Validates the complete DAO governance flow
- **Production Equivalent**: 
  - Deploy OpenZeppelin Governor (GovernorTimelockControl)
  - Grant roles to Governor
  - Enable token holders to propose and vote on changes

### End-to-End Test
- **Test**: Execute complete sequence from deployment to DAO governance
- **Purpose**: Validates the entire flow in a single test
- **Production Equivalent**: Full mainnet deployment sequence

## Test Requirements

### Dependencies
- OpenZeppelin Contracts (`@openzeppelin/contracts`)
  - `TimelockController`
  - `GovernorTimelockControl` (or compatible Governor implementation)
  - `ERC20Votes` (for governance token, optional - can use ERC20Mock for testing)

### Test Configuration
- **Timelock Delay**: 2 days (configurable)
- **Voting Delay**: 1 block
- **Voting Period**: 5 blocks
- **Proposal Threshold**: 100,000 tokens

### Contract Parameters
- **Escrow Fee**: 100 (1% = 100/10000)
- **Initial Token Supply**: 10,000,000 tokens
- **Token Distribution**: Distributed to multiple token holders for testing

## Running the Tests

```bash
# Run all tests
pnpm test:hardhat

# Run only the mainnet release sequence tests
pnpm test:hardhat test/hardhat/MainnetReleaseSequence.test.ts

# Run with verbose output
pnpm test:hardhat -- --verbose
```

## Test Coverage

The test suite covers:

1. ✅ Governance token deployment
2. ✅ Library deployment and linking
3. ✅ Module deployment (starting with simplest)
4. ✅ Main contract deployment via proxy
5. ✅ Ownership transfer to multisig
6. ✅ Timelock deployment and setup
7. ✅ Timelocked upgrade execution
8. ✅ DAO governance deployment
9. ✅ DAO proposal creation and execution
10. ✅ End-to-end deployment sequence

## Production Deployment Checklist

When deploying to mainnet, follow this sequence:

### Pre-Deployment
- [ ] Deploy governance token (ERC20Votes)
- [ ] Distribute tokens to holders
- [ ] Set up Safe multisig

### Initial Deployment
- [ ] Deploy libraries
- [ ] Deploy modules
- [ ] Deploy main contracts via proxy
- [ ] Wire modules to contracts
- [ ] Transfer ownership to Safe multisig

### Timelock Setup
- [ ] Deploy TimelockController
- [ ] Transfer contract ownership to Timelock
- [ ] Configure timelock delay (recommended: 24-72 hours)

### DAO Governance Setup
- [ ] Deploy OpenZeppelin Governor
- [ ] Grant Governor proposer role in Timelock
- [ ] Grant Governor executor role in Timelock
- [ ] Set up delegation for token holders
- [ ] Configure voting parameters

### Post-Deployment
- [ ] Verify all contracts on block explorer
- [ ] Document all addresses
- [ ] Create governance surface map
- [ ] Publish upgrade playbooks

## Notes

### Simplified Testing
- The test suite uses simplified multisig (single address) for testing
- In production, use actual Safe multisig contract
- Governor contracts may not be available in typechain - tests handle this gracefully

### OpenZeppelin Contracts
- The test suite attempts to use OpenZeppelin governance contracts
- If contracts aren't available, some tests will be skipped
- To enable full testing, ensure OpenZeppelin contracts are compiled:
  ```bash
  hardhat compile
  ```

### Proxy Type
- Tests support both Transparent and UUPS proxy patterns
- Set `PROXY_KIND` environment variable to choose:
  ```bash
  PROXY_KIND=transparent pnpm test:hardhat
  PROXY_KIND=uups pnpm test:hardhat
  ```

## Alignment with Token Expectations

This test suite aligns with the Jan 2026 token expectations:

1. **Progressive Decentralization**: Tests the staged rollout (multisig → timelock → DAO)
2. **Timelock Requirement**: Validates timelock between approval and execution
3. **DAO-Controlled Upgrades**: Tests onchain governance-controlled upgrades
4. **Clear Control Surface**: Documents who controls what at each stage
5. **Best Practices**: Follows patterns from Uniswap, Aave, Compound, Lido

## Related Documentation

- `docs/MAINNET_DEPLOYMENT_PLAN.md` - Deployment plan for mainnet
- `docs/token/2026_token_expectations.md` - Token launch expectations
- `docs/GOVERNANCE_AND_UPGRADE_PLAN.md` - Governance and upgrade strategy
- `docs/DAO tooling notes.md` - DAO tooling comparison






