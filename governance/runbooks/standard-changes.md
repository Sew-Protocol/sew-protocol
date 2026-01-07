# Standard Change Procedures Runbook

**Last Updated:** 2026-01-06  
**Purpose:** Step-by-step procedures for standard lane governance changes

---

## Overview

This runbook provides step-by-step procedures for **Standard Lane** governance changes. Standard lane changes have a **48-hour timelock delay** and are used for bounded parameter updates.

**Standard Lane Scope:**
- Bounded parameter changes (timeouts, max attachments, caps within bounds)
- Resolver updates (DefaultResolutionModule)
- Yield distribution defaults
- Non-critical configuration changes

**Examples:**
- `setDefaultAutoCancelTime(uint256)`
- `setMaxAttachments(uint256)`
- `setTokenCap(address, uint256)` (within bounds)
- `DefaultResolutionModule.setResolver(address)`

---

## Prerequisites

- Access to Governor contract
- Access to TimelockController
- Governance token for voting
- Network access to Base mainnet
- Block explorer access (Basescan)
- Understanding of governance process (see `docs/governance.md`)

---

## Standard Change Process

### Phase 1: Proposal Creation

1. **Prepare Proposal**
   - [ ] Identify target contract and function
   - [ ] Determine new parameter value
   - [ ] Verify parameter is within bounds
   - [ ] Write clear proposal description
   - [ ] Document rationale

2. **Create Proposal**
   - [ ] Navigate to Governor contract on Basescan
   - [ ] Connect wallet with governance tokens
   - [ ] Call `propose()` function with:
     - Targets: Array of contract addresses
     - Values: Array of ETH values (usually all 0)
     - Calldatas: Array of function call data
     - Description: Proposal description (IPFS hash or string)
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

### Phase 3: Queue Proposal

1. **Queue After Vote**
   - [ ] After voting period ends, queue proposal
   - [ ] Call `queue()` function on Governor
   - [ ] Wait for transaction confirmation
   - [ ] Document queue transaction

**Queue Transaction Hash:** `[TO BE FILLED]`  
**Execution ETA:** `[TO BE FILLED]` (48 hours from queue)

### Phase 4: Execution

1. **Wait for Timelock**
   - [ ] Wait 48 hours from queue time
   - [ ] Verify execution ETA has passed
   - [ ] Check block timestamp

2. **Execute Proposal**
   - [ ] Call `execute()` function on Governor
   - [ ] Verify execution transaction
   - [ ] Document execution transaction

**Execution Transaction Hash:** `[TO BE FILLED]`  
**Block Number:** `[TO BE FILLED]`

### Phase 5: Verification

1. **Verify Change**
   - [ ] Check parameter value updated correctly
   - [ ] Verify change is active
   - [ ] Test affected functionality
   - [ ] Document verification

2. **Post-Change**
   - [ ] Notify community (if significant)
   - [ ] Update documentation
   - [ ] Record change in changelog

---

## Example: Update Default Auto-Cancel Time

### Step 1: Prepare Proposal

**Target Contract:** `EscrowVault` or `EscrowableERC20`  
**Function:** `setDefaultAutoCancelTime(uint256 newTime)`  
**New Value:** `2592000` (30 days in seconds)  
**Current Value:** `[CHECK BEFORE PROPOSAL]`

**Proposal Description:**
```
Update default auto-cancel time to 30 days (2592000 seconds).

Rationale:
- Current default is [X] days
- 30 days provides better balance between user convenience and dispute resolution time
- Change affects new escrows only (existing escrows unchanged)
```

### Step 2: Create Proposal

```solidity
// Governor.propose()
targets: [EscrowVault_address]
values: [0]
calldatas: [abi.encodeWithSignature("setDefaultAutoCancelTime(uint256)", 2592000)]
description: "IPFS_HASH_OR_STRING"
```

### Step 3-5: Follow Standard Process

Follow Phases 2-5 from "Standard Change Process" above.

---

## Example: Update Resolver

### Step 1: Prepare Proposal

**Target Contract:** `DefaultResolutionModule`  
**Function:** `setResolver(address newResolver)`  
**New Resolver:** `0x...`  
**Current Resolver:** `[CHECK BEFORE PROPOSAL]`

**Proposal Description:**
```
Update default resolver address to [NEW_ADDRESS].

Rationale:
- Current resolver: [OLD_ADDRESS]
- New resolver has [REASONS]
- Change affects new escrows only (existing escrows unchanged)
```

### Step 2: Create Proposal

```solidity
// Governor.propose()
targets: [DefaultResolutionModule_address]
values: [0]
calldatas: [abi.encodeWithSignature("setResolver(address)", newResolver)]
description: "IPFS_HASH_OR_STRING"
```

### Step 3-5: Follow Standard Process

Follow Phases 2-5 from "Standard Change Process" above.

---

## Parameter Bounds

**Important:** All parameter changes must respect onchain bounds. Proposals that violate bounds will revert.

**Common Bounds:**
- Auto-cancel time: Min/Max values (check contract)
- Max attachments: Min/Max values (check contract)
- Token caps: Must be within bounds (check contract)
- Fee rates: Must be within bounds (check contract)

**Verification:**
- Check contract's `SettingsValidationLibrary` or equivalent
- Review `docs/GOVERNANCE_SURFACE_MAP.md` for bounds
- Test on testnet before mainnet proposal

---

## Checklist

### Pre-Proposal

- [ ] Parameter change is within bounds
- [ ] Change affects new escrows only (by design)
- [ ] Rationale is documented
- [ ] Community discussion (if significant)
- [ ] Testnet testing (if applicable)

### During Proposal

- [ ] Proposal created successfully
- [ ] Proposal ID documented
- [ ] Voting period monitored
- [ ] Quorum and majority verified

### Post-Proposal

- [ ] Proposal queued
- [ ] Timelock delay waited
- [ ] Proposal executed
- [ ] Change verified
- [ ] Documentation updated

---

## Timeline

**Typical Timeline:**
- **Day 0:** Proposal created
- **Day 0-7:** Voting period (3-7 days)
- **Day 7:** Proposal queued
- **Day 9:** Proposal executed (48h timelock delay)

**Total Time:** ~9 days from proposal to execution

---

## Related Documents

- [`slow-changes.md`](./slow-changes.md) - Slow lane procedures (module swaps, fee changes)
- [`docs/governance.md`](../docs/governance.md) - Governance model
- [`docs/GOVERNANCE_SURFACE_MAP.md`](../docs/GOVERNANCE_SURFACE_MAP.md) - Complete function mapping

---

**Note:** Always verify parameter bounds and test on testnet before mainnet proposals.


