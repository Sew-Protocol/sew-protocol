# Slow Change Procedures Runbook

**Last Updated:** 2026-01-06  
**Purpose:** Step-by-step procedures for slow lane governance changes

---

## Overview

This runbook provides step-by-step procedures for **Slow Lane** governance changes. Slow lane changes use a **queue/activate pattern** with a **~9 day total delay** (48h queue + 7d wait + 48h activate).

**Slow Lane Scope:**
- Module swaps (resolution modules, yield modules)
- Fee changes (escrow fee, fee recipient)
- Escalation configuration changes
- High-impact parameter changes

**Examples:**
- `queueDefaultResolutionModule(address)` / `activateDefaultResolutionModule()`
- `queueEscrowFee(uint256)` / `activateEscrowFee()`
- `queueEscalationConfig(...)` / `activateEscalationConfig(...)`

---

## Prerequisites

- Access to Governor contract
- Access to TimelockController
- Governance token for voting
- Network access to Base mainnet
- Block explorer access (Basescan)
- Understanding of governance process (see `docs/governance.md`)

---

## Slow Change Process (Queue/Activate Pattern)

### Phase 1: Queue Proposal

1. **Prepare Queue Proposal**
   - [ ] Identify target contract and queue function
   - [ ] Determine new value (module address, fee, etc.)
   - [ ] Write clear proposal description
   - [ ] Document rationale

2. **Create Queue Proposal**
   - [ ] Navigate to Governor contract on Basescan
   - [ ] Connect wallet with governance tokens
   - [ ] Call `propose()` function with:
     - Targets: Array of contract addresses
     - Values: Array of ETH values (usually all 0)
     - Calldatas: Array of queue function call data
     - Description: Proposal description
   - [ ] Submit transaction
   - [ ] Document proposal ID

**Proposal ID:** `[TO BE FILLED]`  
**Transaction Hash:** `[TO BE FILLED]`

### Phase 2: Voting Period

1. **Monitor Voting**
   - [ ] Voting period typically 3-7 days
   - [ ] Monitor vote counts
   - [ ] Ensure quorum is met
   - [ ] Ensure majority support

2. **Vote Results**
   - [ ] Document final vote counts
   - [ ] Verify proposal passed
   - [ ] Note execution eligibility

**Vote Results:**  
**For:** `[TO BE FILLED]`  
**Against:** `[TO BE FILLED]`  
**Abstain:** `[TO BE FILLED]`  
**Quorum Met:** `[YES/NO]`

### Phase 3: Queue Execution

1. **Queue After Vote**
   - [ ] After voting period ends, queue proposal
   - [ ] Call `queue()` function on Governor
   - [ ] Wait for transaction confirmation
   - [ ] Document queue transaction

**Queue Transaction Hash:** `[TO BE FILLED]`  
**Queue Time:** `[TO BE FILLED]`

2. **Verify Queue**
   - [ ] Check pending change exists
   - [ ] Verify ETA is set correctly (7 days from queue)
   - [ ] Document ETA

**Activation ETA:** `[TO BE FILLED]` (7 days from queue)

### Phase 4: Wait Period

1. **Wait for Activation Window**
   - [ ] Wait 7 days from queue time
   - [ ] Verify activation ETA has passed
   - [ ] Check block timestamp

**Wait Period:** 7 days  
**Activation Window Opens:** `[TO BE FILLED]`

### Phase 5: Activation Proposal

1. **Prepare Activation Proposal**
   - [ ] Verify queue ETA has passed
   - [ ] Identify activate function
   - [ ] Write clear proposal description

2. **Create Activation Proposal**
   - [ ] Navigate to Governor contract on Basescan
   - [ ] Connect wallet with governance tokens
   - [ ] Call `propose()` function with:
     - Targets: Array of contract addresses
     - Values: Array of ETH values (usually all 0)
     - Calldatas: Array of activate function call data
     - Description: "Activate queued [CHANGE_TYPE]"
   - [ ] Submit transaction
   - [ ] Document proposal ID

**Activation Proposal ID:** `[TO BE FILLED]`  
**Transaction Hash:** `[TO BE FILLED]`

### Phase 6: Activation Voting

1. **Monitor Voting**
   - [ ] Voting period typically 3-7 days
   - [ ] Monitor vote counts
   - [ ] Ensure quorum is met
   - [ ] Ensure majority support

**Vote Results:**  
**For:** `[TO BE FILLED]`  
**Against:** `[TO BE FILLED]`  
**Abstain:** `[TO BE FILLED]`  
**Quorum Met:** `[YES/NO]`

### Phase 7: Activation Execution

1. **Queue Activation**
   - [ ] After voting period ends, queue activation proposal
   - [ ] Call `queue()` function on Governor
   - [ ] Wait for transaction confirmation
   - [ ] Document queue transaction

**Activation Queue Transaction Hash:** `[TO BE FILLED]`  
**Activation Execution ETA:** `[TO BE FILLED]` (48 hours from queue)

2. **Execute Activation**
   - [ ] Wait 48 hours from activation queue
   - [ ] Verify execution ETA has passed
   - [ ] Call `execute()` function on Governor
   - [ ] Verify execution transaction
   - [ ] Document execution transaction

**Activation Execution Transaction Hash:** `[TO BE FILLED]`  
**Block Number:** `[TO BE FILLED]`

### Phase 8: Verification

1. **Verify Change**
   - [ ] Check change is active
   - [ ] Verify change affects new escrows only
   - [ ] Test affected functionality
   - [ ] Document verification

2. **Post-Change**
   - [ ] Notify community
   - [ ] Update documentation
   - [ ] Record change in changelog

---

## Example: Swap Resolution Module

### Step 1: Queue Module Swap

**Target Contract:** `EscrowVault` or `EscrowableERC20`  
**Function:** `queueDefaultResolutionModule(address newModule)`  
**New Module:** `0x...` (DecentralizedResolutionModule address)  
**Current Module:** `[CHECK BEFORE PROPOSAL]`

**Proposal Description:**
```
Queue swap of default resolution module to DecentralizedResolutionModule.

Rationale:
- Current module: DefaultResolutionModule
- New module provides [FEATURES]
- Change affects new escrows only (existing escrows unchanged)
- Activation will occur after 7-day wait period
```

### Step 2: Create Queue Proposal

```solidity
// Governor.propose()
targets: [EscrowVault_address]
values: [0]
calldatas: [abi.encodeWithSignature("queueDefaultResolutionModule(address)", newModule)]
description: "IPFS_HASH_OR_STRING"
```

### Step 3-4: Follow Standard Process

Follow Phases 2-4 from "Slow Change Process" above.

### Step 5: Activate Module Swap

**Target Contract:** `EscrowVault` or `EscrowableERC20`  
**Function:** `activateDefaultResolutionModule()`  
**Parameters:** None

**Proposal Description:**
```
Activate queued resolution module swap to DecentralizedResolutionModule.

The module swap was queued on [DATE] and the 7-day wait period has passed.
Activation will occur after 48-hour timelock delay.
```

### Step 6-8: Follow Standard Process

Follow Phases 6-8 from "Slow Change Process" above.

---

## Example: Update Escrow Fee

### Step 1: Queue Fee Change

**Target Contract:** `EscrowVault` or `EscrowableERC20`  
**Function:** `queueEscrowFee(uint256 newFee)`  
**New Fee:** `100` (1% = 100 basis points)  
**Current Fee:** `[CHECK BEFORE PROPOSAL]`

**Proposal Description:**
```
Queue escrow fee update to 1% (100 basis points).

Rationale:
- Current fee: [X]%
- New fee: 1%
- Change affects new escrows only (existing escrows unchanged)
- Activation will occur after 7-day wait period
```

### Step 2-8: Follow Standard Process

Follow all phases from "Slow Change Process" above.

---

## Timeline

**Typical Timeline:**
- **Day 0:** Queue proposal created
- **Day 0-7:** Queue voting period (3-7 days)
- **Day 7:** Queue proposal executed
- **Day 7-14:** Wait period (7 days)
- **Day 14:** Activation proposal created
- **Day 14-21:** Activation voting period (3-7 days)
- **Day 21:** Activation proposal queued
- **Day 23:** Activation executed (48h timelock delay)

**Total Time:** ~23 days from queue proposal to activation

---

## Important Notes

1. **Two-Step Process:** Slow lane changes require TWO proposals:
   - Queue proposal (queues the change)
   - Activation proposal (activates after wait period)

2. **Wait Period:** 7-day wait period between queue and activation is enforced onchain

3. **New Escrows Only:** All module swaps affect new escrows only (existing escrows unchanged)

4. **Timelock Delays:** Both queue and activation have 48-hour timelock delays

---

## Checklist

### Pre-Queue Proposal

- [ ] Change is appropriate for slow lane
- [ ] New value is verified (module address, fee, etc.)
- [ ] Rationale is documented
- [ ] Community discussion (if significant)
- [ ] Testnet testing (if applicable)

### During Queue Proposal

- [ ] Queue proposal created successfully
- [ ] Proposal ID documented
- [ ] Voting period monitored
- [ ] Quorum and majority verified
- [ ] Queue proposal executed
- [ ] Wait period started

### During Activation

- [ ] Wait period completed (7 days)
- [ ] Activation proposal created
- [ ] Activation voting monitored
- [ ] Activation proposal queued
- [ ] Activation executed
- [ ] Change verified

### Post-Change

- [ ] Change is active
- [ ] New escrows use new configuration
- [ ] Existing escrows unchanged
- [ ] Documentation updated
- [ ] Community notified

---

## Related Documents

- [`standard-changes.md`](./standard-changes.md) - Standard lane procedures
- [`docs/governance.md`](../docs/governance.md) - Governance model
- [`docs/GOVERNANCE_SURFACE_MAP.md`](../docs/GOVERNANCE_SURFACE_MAP.md) - Complete function mapping

---

**Note:** Slow lane changes are high-impact. Always verify addresses and values carefully, and test on testnet before mainnet proposals.

