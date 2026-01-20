# Recovery Procedures Runbook

**Last Updated:** 2026-01-06  
**Purpose:** Step-by-step procedures for recovering from emergency states

---

## Overview

This runbook provides step-by-step procedures for recovering from emergency states. **All recovery actions require timelock governance** - Guardian cannot unpause or re-enable features.

**Recovery Actions:**

- `unpause()` - Unpause protocol (requires `ROLE_TIMELOCK`)
- Re-enable Aave (if disabled) - Requires timelock governance
- Raise caps (if lowered) - Requires timelock governance

**Important:** Recovery actions are **governance-controlled** and require:

1. Governance proposal
2. Community vote
3. Timelock execution (48h delay for Standard lane)

---

## Prerequisites

- Access to Governor contract
- Access to TimelockController
- Governance token for voting
- Network access to Base mainnet
- Block explorer access (Basescan)
- Understanding of governance process (see `docs/governance.md`)

---

## Procedure 1: Unpause Protocol

**When to use:** After emergency is resolved and fix is deployed (if needed)

### Step 1: Verify Recovery Conditions

- [ ] Emergency is resolved
- [ ] Fix is deployed (if vulnerability was found)
- [ ] Fix is tested and verified
- [ ] Community is informed
- [ ] Governance proposal is prepared

### Step 2: Create Governance Proposal

**Contract:** `BaseEscrow` (or `EscrowVault` / `EscrowableERC20`)  
**Function:** `unpause()`  
**Parameters:** None  
**Role Required:** `ROLE_TIMELOCK` (via governance)

**Proposal Details:**

```solidity
// Target: BaseEscrow address
// Value: 0
// Calldata: abi.encodeWithSignature("unpause()")
// Description: "Unpause protocol after emergency resolution"
```

### Step 3: Submit Proposal

1. [ ] Navigate to Governor contract on Basescan
2. [ ] Connect wallet with governance tokens
3. [ ] Create proposal with:
   - Target: `BaseEscrow` address
   - Value: `0`
   - Calldata: `unpause()` function call
   - Description: Clear description of recovery
4. [ ] Submit proposal
5. [ ] Document proposal ID

**Proposal ID:** `[TO BE FILLED DURING DRILL]`  
**Transaction Hash:** `[TO BE FILLED DURING DRILL]`

### Step 4: Voting Period

- [ ] Monitor voting period (typically 3-7 days)
- [ ] Ensure proposal passes quorum and majority
- [ ] Document vote results

**Vote Results:** `[TO BE FILLED DURING DRILL]`  
**For:** `[TO BE FILLED]`  
**Against:** `[TO BE FILLED]`  
**Abstain:** `[TO BE FILLED]`

### Step 5: Queue Proposal

1. [ ] After voting period ends, queue proposal
2. [ ] Wait for timelock delay (48 hours for Standard lane)
3. [ ] Document queue transaction

**Queue Transaction Hash:** `[TO BE FILLED DURING DRILL]`  
**Execution ETA:** `[TO BE FILLED DURING DRILL]`

### Step 6: Execute Proposal

1. [ ] After timelock delay, execute proposal
2. [ ] Verify execution transaction
3. [ ] Document execution transaction

**Execution Transaction Hash:** `[TO BE FILLED DURING DRILL]`  
**Block Number:** `[TO BE FILLED DURING DRILL]`

### Step 7: Verify Unpause

- [ ] Check `paused()` returns `false`
- [ ] Verify new escrows can be created
- [ ] Verify releases/cancellations work
- [ ] Test critical flows
- [ ] Document verification
- [ ] Notify community

---

## Procedure 2: Re-enable Aave (If Disabled)

**When to use:** After Aave issue is resolved

### Step 1: Verify Aave Recovery

- [ ] Aave issue is resolved
- [ ] Aave protocol is stable
- [ ] No ongoing risks

### Step 2: Create Governance Proposal

**Contract:** `AaveYieldGenerationModule`  
**Function:** `setAaveEnabled(bool enabled)` (or equivalent)  
**Parameters:** `enabled = true`  
**Role Required:** `ROLE_TIMELOCK` (via governance)

**Note:** Exact function name may vary. Check contract interface.

### Step 3-7: Follow Standard Governance Process

Follow steps 3-7 from Procedure 1 (Unpause Protocol), but for Aave re-enablement.

### Step 8: Verify Aave Re-enabled

- [ ] Check `aaveEnabled()` returns `true` (if view function exists)
- [ ] Verify new deposits to Aave work
- [ ] Test yield generation
- [ ] Document verification

---

## Procedure 3: Raise Caps (If Lowered)

**When to use:** After risk is mitigated and higher caps are safe

### Step 1: Verify Safety

- [ ] Risk that caused cap lowering is mitigated
- [ ] Higher cap is safe
- [ ] Community consensus on new cap

### Step 2: Create Governance Proposal

**Contract:** `AaveYieldGenerationModule` (or relevant contract)  
**Function:** `setTokenCap(address token, uint256 newCap)` (or equivalent)  
**Parameters:**

- `token`: Token address
- `newCap`: New cap value
  **Role Required:** `ROLE_TIMELOCK` (via governance)

**Note:** Exact function name may vary. Check contract interface.

### Step 3-7: Follow Standard Governance Process

Follow steps 3-7 from Procedure 1 (Unpause Protocol), but for cap raising.

### Step 8: Verify Cap Raised

- [ ] Check token cap is now `newCap`
- [ ] Verify deposits respect new cap
- [ ] Test cap enforcement
- [ ] Document verification

---

## Recovery Checklist

### Pre-Recovery

- [ ] Emergency is resolved
- [ ] Fix is deployed and tested (if needed)
- [ ] Community is informed
- [ ] Governance proposal is prepared
- [ ] Recovery plan is documented

### During Recovery

- [ ] Proposal submitted
- [ ] Voting period monitored
- [ ] Proposal queued after vote
- [ ] Timelock delay waited
- [ ] Proposal executed
- [ ] Recovery verified

### Post-Recovery

- [ ] Protocol functionality verified
- [ ] Critical flows tested
- [ ] Community notified
- [ ] Incident post-mortem completed
- [ ] Lessons learned documented

---

## Recovery Timeline

**Typical Recovery Timeline:**

- **Day 0:** Emergency resolved, fix deployed
- **Day 0-1:** Governance proposal created
- **Day 1-4:** Voting period (3-7 days)
- **Day 4:** Proposal queued
- **Day 6:** Proposal executed (48h timelock delay)
- **Day 6+:** Protocol fully operational

**Total Time:** ~6-8 days from emergency resolution to full recovery

---

## Testing & Drills

**Frequency:** Quarterly (combined with emergency drills)  
**Last Drill:** `[TO BE FILLED]`  
**Next Drill:** `[TO BE FILLED]`

**Drill Scenario:**

1. Simulate emergency pause
2. Create recovery proposal
3. Vote on proposal
4. Queue and execute
5. Verify recovery

See `docs/OUTSTANDING_ISSUES.md` for drill requirements.

---

## Related Documents

- [`emergency.md`](./emergency.md) - Emergency procedures
- [`docs/governance.md`](../docs/governance.md) - Governance model
- [`docs/EMERGENCY_POLICY.md`](../docs/EMERGENCY_POLICY.md) - Emergency policy
- [`standard-changes.md`](./standard-changes.md) - Standard change procedures

---

**Note:** This runbook should be tested regularly. Update transaction hashes and block numbers after each drill.
