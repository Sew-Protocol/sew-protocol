# Plan for Adding Missing Contracts

## Overview

This document outlines the plan for adding three critical contract types required for the mainnet deployment and progressive decentralization:

1. **OpenZeppelin Governor with Timelock** - For DAO governance
2. **Safe Multisig** - For initial ownership and emergency controls
3. **Sew Token Contract ($ew)** - For governance token with voting capabilities, protocol token

## Current State

### What Exists
- ✅ `ERC20Mock` - Basic ERC20 token (no voting capabilities)
- ✅ OpenZeppelin contracts package (`@openzeppelin/contracts@^5.4.0`)
- ✅ Test infrastructure expecting these contracts
- ✅ Deployment scripts structure

### What's Missing
- ❌ OpenZeppelin governance contracts not compiled/accessible
- ❌ Safe multisig contract
- ❌ ERC20Votes token contract for governance

## 1. OpenZeppelin Governor with Timelock

### Requirements
- `TimelockController` - For timelocked execution of governance proposals
- `GovernorTimelockControl` - Governor contract integrated with Timelock
- `ERC20Votes` - Token with voting snapshots (see section 3)

### Implementation Plan

#### Step 1.1: Verify OpenZeppelin Contracts Availability
- [ ] Check that `@openzeppelin/contracts@^5.4.0` includes governance contracts
- [ ] Verify Hardhat can compile OpenZeppelin contracts directly
- [ ] Test compilation of `TimelockController` and `GovernorTimelockControl`

#### Step 1.2: Create Wrapper Contracts (Optional but Recommended)
**File**: `contracts/governance/TimelockControllerWrapper.sol`
```solidity
// Wrapper for TimelockController with convenience functions
```

**Rationale**: Wrappers make contracts easier to deploy via hardhat-deploy and provide better type safety in tests.

#### Step 1.3: Create Deployment Scripts
**File**: `deploy/20_timelock.ts`
- Deploy `TimelockController` with:
  - `minDelay`: 2 days (configurable)
  - `proposers`: Array of addresses (multisig initially)
  - `executors`: Array of addresses (multisig initially)
  - `admin`: Multisig address (can be revoked later)

**File**: `deploy/30_governor.ts`
- Deploy `GovernorTimelockControl` with:
  - `name`: "SewDAO" (configurable)
  - `token`: SewToken address
  - `votingDelay`: 1 block
  - `votingPeriod`: 5 blocks (configurable)
  - `proposalThreshold`: 10M tokens (1% of 1B supply, configurable)
  - `timelock`: TimelockController address

#### Step 1.4: Update Tests
- [ ] Remove try-catch blocks that skip tests
- [ ] Use proper TypeScript types from `@openzeppelin/contracts`
- [ ] Add comprehensive governance flow tests

### Dependencies
- `@openzeppelin/contracts@^5.4.0` (already installed)
- SewToken contract (see section 3)

### Testing Checklist
- [ ] Deploy TimelockController successfully
- [ ] Deploy GovernorTimelockControl successfully
- [ ] Test proposal creation
- [ ] Test voting
- [ ] Test timelocked execution
- [ ] Test role management (proposer, executor, admin)

---

## 2. Safe Multisig

### Requirements
- Gnosis Safe contract for multisig wallet
- Support for 2-of-3 or 3-of-5 multisig (configurable)
- Integration with deployment scripts
- Mock Safe for testing (optional)

### Implementation Plan

#### Step 2.1: Install Safe Contracts
- [ ] Add `@safe-global/safe-contracts` package
  ```bash
  pnpm add -D @safe-global/safe-contracts
  ```
- [ ] Verify version compatibility with Solidity ^0.8.28

#### Step 2.2: Create Safe Deployment Script
**File**: `deploy/10_safe.ts`
- Deploy Gnosis Safe with:
  - `owners`: Array of owner addresses (from config)
  - `threshold`: Number of signatures required (e.g., 2 for 2-of-3)
  - `to`: Address(0) (no setup transaction)
  - `data`: "0x" (no setup data)
  - `fallbackHandler`: Safe fallback handler address
  - `paymentToken`: Address(0) (native ETH)
  - `payment`: 0 (no payment)
  - `paymentReceiver`: Address(0)

**Alternative**: Use Safe's `createProxyWithNonce` or `createProxy` factory pattern

#### Step 2.3: Create Safe Mock for Testing
**File**: `contracts/mocks/SafeMock.sol`
```solidity
// Simple mock that implements basic Safe interface
// Allows testing without deploying full Safe contract
```

#### Step 2.4: Update Test Infrastructure
- [ ] Replace `multisigAddress = multisigOwner1.address` with actual Safe contract
- [ ] Add helper functions for Safe operations (submit transaction, confirm, execute)
- [ ] Update `MainnetReleaseSequence.test.ts` to use real Safe

#### Step 2.5: Create Configuration
**File**: `config/safe.config.ts`
```typescript
export const SAFE_CONFIG = {
  owners: [
    process.env.SAFE_OWNER_1,
    process.env.SAFE_OWNER_2,
    process.env.SAFE_OWNER_3,
  ],
  threshold: 2, // 2-of-3 multisig
};
```

### Dependencies
- `@safe-global/safe-contracts` (to be installed)
- Safe factory contract (deployed on target network)

### Testing Checklist
- [ ] Deploy Safe contract successfully
- [ ] Add owners and set threshold
- [ ] Submit transaction from Safe
- [ ] Confirm transaction with required signatures
- [ ] Execute transaction
- [ ] Transfer ownership of contracts to Safe
- [ ] Verify Safe can perform owner-only operations

### Network Considerations
- **Mainnet**: Use official Safe factory at `0xa6B71E26C5e0845f74c812102Ca7114b6a896AB2`
- **Testnets**: Use testnet Safe factory addresses
- **Local**: Deploy Safe factory locally for testing

---

## 3. Sew Token Contract

### Requirements
- Governance token with voting snapshots
- Compatible with OpenZeppelin Governor
- Initial supply distribution
- Delegation support

### Implementation Plan

#### Step 3.1: Create ERC20Votes Token Contract
**File**: `contracts/token/SewToken.sol`
```solidity
// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract SewToken is ERC20Votes, Ownable {
    constructor(
        string memory name,
        string memory symbol,
        address initialOwner,
        uint256 initialSupply
    ) ERC20(name, symbol) ERC20Permit(name) Ownable(initialOwner) {
        _mint(initialOwner, initialSupply);
    }

    // Optional: Add minting function for future token distribution
    function mint(address to, uint256 amount) public onlyOwner {
        _mint(to, amount);
    }
}
```

#### Step 3.2: Create Deployment Script
**File**: `deploy/00_governance_token.ts`
- Deploy `SewToken` with:
  - `name`: "Sew Protocol Token" (configurable)
  - `symbol`: "$EW" (configurable)
  - `initialOwner`: Deployer address (will transfer to Safe later)
  - `initialSupply`: 1,000,000,000 tokens (fixed supply)

#### Step 3.3: Update Existing Tests
- [ ] Replace `ERC20Mock` with `SewToken` in `MainnetReleaseSequence.test.ts`
- [ ] Add delegation tests
- [ ] Add voting snapshot tests

#### Step 3.4: Create Token Distribution Script (Optional)
**File**: `scripts/distribute-tokens.ts`
- Distribute initial supply to:
  - Team/Founders
  - Investors
  - Community treasury
  - Liquidity pools

### Dependencies
- `@openzeppelin/contracts@^5.4.0` (already installed)
- `ERC20Permit` (included in OpenZeppelin)

### Testing Checklist
- [ ] Deploy SewToken successfully
- [ ] Mint initial supply
- [ ] Test token transfers
- [ ] Test delegation
- [ ] Test voting snapshots
- [ ] Test integration with Governor contract

---

## Deployment Order

The contracts must be deployed in this order:

1. **Sew Token** (`deploy/00_governance_token.ts`)
   - Required for Governor deployment

2. **Safe Multisig** (`deploy/10_safe.ts`)
   - Required for initial ownership

3. **Libraries** (`deploy/01_libraries.ts`)
   - Required for main contracts

4. **Modules** (`deploy/05_modules.ts`)
   - Required for main contracts

5. **Main Contracts** (`deploy/10_escrowable_erc20.ts`, `deploy/11_escrow_vault.ts`)
   - Core protocol contracts

6. **Timelock** (`deploy/20_timelock.ts`)
   - For timelocked upgrades

7. **Governor** (`deploy/30_governor.ts`)
   - For DAO governance

8. **Wiring** (`deploy/90_wiring.ts`)
   - Transfer ownership to Safe
   - Grant roles to Governor
   - Wire modules to contracts

---

## Configuration Files

### Environment Variables
Add to `.env.example`:
```bash
# Governance
GOVERNANCE_TOKEN_NAME="Sew Token"
GOVERNANCE_TOKEN_SYMBOL="$EW"
GOVERNANCE_TOKEN_SUPPLY="1000000000000000000000000000" # 1B tokens (18 decimals)

# Safe Multisig
SAFE_OWNER_1=0x...
SAFE_OWNER_2=0x...
SAFE_OWNER_3=0x...
SAFE_THRESHOLD=2

# Timelock
TIMELOCK_DELAY=172800 # 2 days in seconds

# Governor
VOTING_DELAY=1 # blocks
VOTING_PERIOD=5 # blocks
PROPOSAL_THRESHOLD=10000000000000000000000000 # 10M tokens (1% of 1B supply)
```

### Configuration File
**File**: `config/governance.config.ts`
```typescript
export const GOVERNANCE_CONFIG = {
  token: {
    name: process.env.GOVERNANCE_TOKEN_NAME || "Sew Token",
    symbol: process.env.GOVERNANCE_TOKEN_SYMBOL || "$EW",
    initialSupply: process.env.GOVERNANCE_TOKEN_SUPPLY || "1000000000000000000000000000",
  },
  safe: {
    owners: [
      process.env.SAFE_OWNER_1!,
      process.env.SAFE_OWNER_2!,
      process.env.SAFE_OWNER_3!,
    ],
    threshold: parseInt(process.env.SAFE_THRESHOLD || "2"),
  },
  timelock: {
    minDelay: parseInt(process.env.TIMELOCK_DELAY || "172800"), // 2 days
  },
  governor: {
    votingDelay: parseInt(process.env.VOTING_DELAY || "1"),
    votingPeriod: parseInt(process.env.VOTING_PERIOD || "5"),
    proposalThreshold: process.env.PROPOSAL_THRESHOLD || "10000000000000000000000000",
  },
};
```

---

## Testing Strategy

### Unit Tests
- [ ] Test each contract in isolation
- [ ] Test constructor parameters
- [ ] Test access control

### Integration Tests
- [ ] Test full deployment sequence
- [ ] Test ownership transfers
- [ ] Test governance flow (propose → vote → execute)
- [ ] Test timelocked upgrades

### End-to-End Tests
- [ ] Test complete mainnet release sequence
- [ ] Test progressive decentralization path
- [ ] Test emergency scenarios

---

## Documentation Updates

- [ ] Update `MAINNET_DEPLOYMENT_PLAN.md` with new contracts
- [ ] Create `GOVERNANCE_SETUP.md` guide
- [ ] Create `SAFE_MULTISIG_SETUP.md` guide
- [ ] Update README with governance information

---

## Timeline Estimate

- **OpenZeppelin Governor**: 2-3 days
  - Day 1: Setup and wrapper contracts
  - Day 2: Deployment scripts and tests
  - Day 3: Integration and documentation

- **Safe Multisig**: 2-3 days
  - Day 1: Package installation and deployment script
  - Day 2: Mock creation and test updates
  - Day 3: Integration and documentation

- **Sew Token**: 1-2 days
  - Day 1: Contract creation and deployment script
  - Day 2: Test updates and integration

**Total**: 5-8 days

---

## Risk Mitigation

1. **OpenZeppelin Contracts Compatibility**
   - Risk: Version mismatch or compilation issues
   - Mitigation: Test compilation early, pin versions

2. **Safe Contract Deployment**
   - Risk: Factory not available on target network
   - Mitigation: Check network support, have fallback deployment method

3. **Gas Costs**
   - Risk: High deployment costs on mainnet
   - Mitigation: Optimize contracts, consider deployment on L2 (Base)

4. **Security**
   - Risk: Governance vulnerabilities
   - Mitigation: Follow OpenZeppelin best practices, consider audit

---

## Next Steps

1. **Immediate**: Review and approve this plan
2. **Week 1**: Implement OpenZeppelin Governor with Timelock
3. **Week 1**: Implement Sew Token
4. **Week 2**: Implement Safe Multisig
5. **Week 2**: Integration testing and documentation
6. **Week 3**: Mainnet deployment preparation

---

## References

- [OpenZeppelin Governor Documentation](https://docs.openzeppelin.com/contracts/5.x/api/governance)
- [Gnosis Safe Documentation](https://docs.safe.global/)
- [ERC20Votes Documentation](https://docs.openzeppelin.com/contracts/5.x/api/token/erc20#ERC20Votes)
- [Progressive Decentralization Best Practices](https://docs.openzeppelin.com/defender/guide-governance)

---

## Questions Requiring Clarification

Before proceeding with implementation, please clarify the following:

### 1. Token Supply and Distribution
- **Question**: The total supply is set to 1B tokens. What is the initial distribution plan?
  - How much goes to team/founders?
  - How much goes to investors?
  - How much goes to community treasury?
  - How much goes to liquidity pools?
  - Are there any vesting schedules?
- **Impact**: Affects the `distribute-tokens.ts` script and initial minting logic

Yes vesting schedules. Will paste in exact details later

### 2. Proposal Threshold
- **Question**: The proposal threshold is set to 10M tokens (1% of supply). Is this the desired threshold?
  - Alternative: 1M tokens (0.1% of supply) for more accessible governance
  - Alternative: 50M tokens (5% of supply) for more conservative governance
- **Impact**: Affects who can create governance proposals

### 3. Token Minting Capability
- **Question**: Should `SewToken` have a `mint()` function for future token distribution, or should it be a fixed supply token?
  - If minting is allowed: Who can mint? (Owner only? Governance only? Never?)
  - If fixed supply: Should we remove the `mint()` function entirely?
- **Impact**: Affects contract design and security model

Fixed, remove mint

### 4. Governor Name
- **Question**: Should the Governor contract name be "SewDAO" or something else?
  - Alternative: "Sew Protocol DAO"
  - Alternative: "Sew Governance"
- **Impact**: Cosmetic, but affects contract deployment and documentation

Sew Protocol DAO

### 5. Token Symbol Format
- **Question**: The symbol is "$EW". Is this the final format?
  - Note: Some exchanges/standards prefer symbols without special characters
  - Alternative: "SEW" or "SEWT"
- **Impact**: Token listing and exchange compatibility

If $ is a problem with exchanges, then SEW or SEWT (depending on availability)

### 6. Initial Owner
- **Question**: Who should be the initial owner of `SewToken`?
  - Deployer EOA (temporary, will transfer to Safe)
  - Safe multisig directly
  - Timelock (requires Safe → Timelock → Governor progression)
- **Impact**: Affects deployment sequence and ownership transfer flow

Safe -> timelock -> governor

### 7. Voting Parameters
- **Question**: Are the voting parameters appropriate for mainnet?
  - `votingDelay`: 1 block (very short - is this for testing only?)
  - `votingPeriod`: 5 blocks (very short - typical is 3-7 days)
  - Should these be configurable per network (short for testnets, longer for mainnet)?
- **Impact**: Affects governance responsiveness and security

Those are for testing. 7 day voting period

### 8. Timelock Delay
- **Question**: Is 2 days the appropriate timelock delay for mainnet?
  - Typical range: 1-7 days
  - Longer delays = more security but slower response
- **Impact**: Affects upgrade and governance execution speed

7 days

### 9. Safe Multisig Configuration
- **Question**: What is the final Safe multisig configuration?
  - Number of owners: 3, 5, or more?
  - Threshold: 2-of-3, 3-of-5, or other?
  - Who are the initial owners? (addresses needed)
- **Impact**: Affects Safe deployment and security model

Assume 3 of 5

### 10. Network Selection
- **Question**: Which network will be used for mainnet deployment?
  - Base Mainnet (Chain ID: 8453) - Lower gas costs
  - Ethereum Mainnet (Chain ID: 1) - Higher gas costs, more established
  - Other L2?
- **Impact**: Affects Safe factory addresses and deployment costs

Base Mainnet