# Emergency Drills & Deployment Rehearsals

**Last Updated:** 2026-01-06  
**Purpose:** Documentation of emergency drills and deployment rehearsals

---

## Overview

This document tracks emergency drills, recovery drills, and deployment rehearsals performed before mainnet deployment. All drills should be performed on Base Sepolia testnet (or mainnet fork) and documented with transaction hashes.

---

## Emergency + Recovery Drills

### Drill Requirements

**Frequency:** Quarterly  
**Location:** Base Sepolia testnet (or mainnet fork)  
**Duration:** 2-4 hours

**Required Drills:**
1. Emergency drill (pause protocol)
2. Recovery drill (unpause via timelock)

---

## Drill 1: Emergency Pause

**Date:** `[TO BE FILLED]`  
**Location:** Base Sepolia  
**Status:** ⬜ Not Performed

### Procedure

1. **Simulate Emergency**
   - [ ] Identify test scenario
   - [ ] Document emergency situation

2. **Execute Pause**
   - [ ] Guardian multisig calls `pause()` on BaseEscrow
   - [ ] Transaction submitted
   - [ ] Transaction confirmed

3. **Verify Pause**
   - [ ] Check `paused()` returns `true`
   - [ ] Verify new escrows cannot be created
   - [ ] Verify releases/cancellations blocked

### Results

**Transaction Hash:** `[TO BE FILLED]`  
**Block Number:** `[TO BE FILLED]`  
**Timestamp:** `[TO BE FILLED]`  
**Pause Verified:** `[YES/NO]`  
**Issues Found:** `[NONE/ISSUES]`

---

## Drill 2: Recovery (Unpause)

**Date:** `[TO BE FILLED]`  
**Location:** Base Sepolia  
**Status:** ⬜ Not Performed

### Procedure

1. **Create Recovery Proposal**
   - [ ] Create governance proposal to unpause
   - [ ] Proposal ID documented

2. **Vote on Proposal**
   - [ ] Vote on proposal
   - [ ] Verify proposal passes

3. **Queue Proposal**
   - [ ] Queue proposal after vote
   - [ ] Wait for timelock delay (48 hours)

4. **Execute Proposal**
   - [ ] Execute proposal after timelock
   - [ ] Verify unpause successful

5. **Verify Recovery**
   - [ ] Check `paused()` returns `false`
   - [ ] Verify new escrows can be created
   - [ ] Verify releases/cancellations work

### Results

**Proposal ID:** `[TO BE FILLED]`  
**Queue Transaction Hash:** `[TO BE FILLED]`  
**Execution Transaction Hash:** `[TO BE FILLED]`  
**Block Number:** `[TO BE FILLED]`  
**Timestamp:** `[TO BE FILLED]`  
**Recovery Verified:** `[YES/NO]`  
**Issues Found:** `[NONE/ISSUES]`

---

## Drill 3: Disable Aave

**Date:** `[TO BE FILLED]`  
**Location:** Base Sepolia  
**Status:** ⬜ Not Performed (Optional)

### Procedure

1. **Execute Disable**
   - [ ] Guardian multisig calls `guardianDisableAave()`
   - [ ] Transaction submitted
   - [ ] Transaction confirmed

2. **Verify Disable**
   - [ ] Check Aave is disabled
   - [ ] Verify new deposits blocked

### Results

**Transaction Hash:** `[TO BE FILLED]`  
**Block Number:** `[TO BE FILLED]`  
**Timestamp:** `[TO BE FILLED]`  
**Disable Verified:** `[YES/NO]`  
**Issues Found:** `[NONE/ISSUES]`

---

## Fork Deployment Rehearsal

### Rehearsal Requirements

**Frequency:** Before mainnet deployment  
**Location:** Mainnet fork (Base mainnet fork)  
**Duration:** 2-3 hours

**Required Steps:**
1. Fork mainnet
2. Deploy all contracts
3. Verify deployments
4. Assign roles correctly
5. Test critical flows
6. Document all transaction hashes

---

## Rehearsal 1: Mainnet Fork Deployment

**Date:** `[TO BE FILLED]`  
**Location:** Mainnet Fork (Base)  
**Status:** ⬜ Not Performed

### Procedure

1. **Fork Setup**
   - [ ] Fork Base mainnet at block `[BLOCK_NUMBER]`
   - [ ] Verify fork is working
   - [ ] Document fork block

2. **Deploy Contracts**
   - [ ] Deploy libraries
   - [ ] Deploy modules
   - [ ] Deploy core contracts
   - [ ] Deploy governance contracts
   - [ ] Document all addresses

3. **Role Assignment**
   - [ ] Assign ROLE_TIMELOCK to TimelockController
   - [ ] Assign ROLE_GUARDIAN to Guardian multisig
   - [ ] Revoke deployer roles
   - [ ] Verify role assignments

4. **Post-Deployment Checks**
   - [ ] Verify all contracts deployed
   - [ ] Verify role assignments correct
   - [ ] Test critical flows
   - [ ] Verify governance works

### Results

**Fork Block:** `[TO BE FILLED]`  
**Fork Network:** Base Mainnet Fork

**Deployed Contracts:**
- BaseEscrow: `[TO BE FILLED]`
- EscrowVault: `[TO BE FILLED]`
- EscrowableERC20: `[TO BE FILLED]`
- DefaultResolutionModule: `[TO BE FILLED]`
- AaveYieldGenerationModule: `[TO BE FILLED]`
- Governor: `[TO BE FILLED]`
- TimelockController: `[TO BE FILLED]`

**Role Assignments:**
- ROLE_TIMELOCK: `[TO BE FILLED]`
- ROLE_GUARDIAN: `[TO BE FILLED]`
- Deployer roles revoked: `[YES/NO]`

**Transaction Hashes:**
- Deployment transactions: `[TO BE FILLED]`
- Role assignment transactions: `[TO BE FILLED]`

**Issues Found:** `[NONE/ISSUES]`

---

## Rehearsal 2: Governance Proposal Simulation

**Date:** `[TO BE FILLED]`  
**Location:** Mainnet Fork (Base)  
**Status:** ⬜ Not Performed (Optional)

### Procedure

1. **Create Test Proposal**
   - [ ] Create governance proposal
   - [ ] Document proposal ID

2. **Vote on Proposal**
   - [ ] Vote on proposal
   - [ ] Verify voting works

3. **Execute Proposal**
   - [ ] Queue proposal
   - [ ] Wait for timelock
   - [ ] Execute proposal
   - [ ] Verify execution

### Results

**Proposal ID:** `[TO BE FILLED]`  
**Vote Transaction Hash:** `[TO BE FILLED]`  
**Queue Transaction Hash:** `[TO BE FILLED]`  
**Execution Transaction Hash:** `[TO BE FILLED]`  
**Execution Verified:** `[YES/NO]`  
**Issues Found:** `[NONE/ISSUES]`

---

## Drill Schedule

**Next Emergency Drill:** `[TO BE FILLED]`  
**Next Recovery Drill:** `[TO BE FILLED]`  
**Next Fork Rehearsal:** `[TO BE FILLED]`

**Frequency:**
- Emergency + Recovery Drills: Quarterly
- Fork Deployment Rehearsal: Before mainnet deployment

---

## Drill Evidence

All drills should produce:
- Transaction hashes
- Block numbers
- Timestamps
- Screenshots (if applicable)
- Verification results
- Issues found (if any)

**Evidence Storage:**
- Transaction hashes documented in this file
- Detailed logs in `governance/runbooks/` (if applicable)
- Screenshots in `governance/runbooks/evidence/` (if created)

---

## Lessons Learned

**From Emergency Drills:**
- `[TO BE FILLED AFTER DRILLS]`

**From Recovery Drills:**
- `[TO BE FILLED AFTER DRILLS]`

**From Fork Rehearsals:**
- `[TO BE FILLED AFTER REHEARSALS]`

---

## Related Documents

- [`governance/runbooks/emergency.md`](../governance/runbooks/emergency.md) - Emergency procedures
- [`governance/runbooks/recovery.md`](../governance/runbooks/recovery.md) - Recovery procedures
- [`docs/EMERGENCY_POLICY.md`](./EMERGENCY_POLICY.md) - Emergency policy
- [`docs/OUTSTANDING_ISSUES.md`](./OUTSTANDING_ISSUES.md) - Drill requirements

---

**Note:** This document should be updated after each drill or rehearsal. All transaction hashes and results should be documented.


