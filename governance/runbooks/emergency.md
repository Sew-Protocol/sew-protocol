# Emergency Procedures Runbook

**Last Updated:** 2026-01-06  
**Purpose:** Step-by-step procedures for emergency situations

---

## Overview

This runbook provides step-by-step procedures for activating emergency controls. Emergency controls can only **reduce risk** (down-only). They cannot be used to increase risk or modify protocol parameters.

**Guardian Powers:**
- `pause()` - Pause all protocol operations
- `guardianDisableAave()` - Disable Aave yield generation
- `guardianLowerTokenCap()` - Lower token exposure cap
- `guardianLowerGlobalCap()` - Lower global exposure cap

**Guardian Limitations:**
- Cannot unpause (only timelock can)
- Cannot enable Aave (only timelock can)
- Cannot raise caps (down-only)
- Cannot modify escrow rules

---

## Prerequisites

- Access to Guardian Multisig wallet
- Network access to Base mainnet (or testnet for drills)
- Block explorer access (Basescan)
- Emergency contact list

---

## Emergency Triggers

Activate emergency controls when:

1. **Critical Vulnerability** - Critical vulnerability discovered that could lead to fund loss
2. **Active Exploit** - Active exploit draining funds or manipulating state
3. **External Dependency Failure** - Critical external dependency (e.g., Aave) has failed
4. **Governance Attack** - Governance compromised or being abused
5. **Regulatory Requirement** - Legal/regulatory requirement to pause operations

**Do NOT activate for:**
- Routine parameter adjustments
- Planned upgrades
- Non-critical bugs
- Performance issues

---

## Procedure 1: Pause Protocol

**When to use:** Critical vulnerability or active exploit

### Step 1: Verify Emergency

- [ ] Confirm emergency situation exists
- [ ] Verify it's not a false alarm
- [ ] Document the emergency (screenshot, transaction hash, etc.)

### Step 2: Prepare Transaction

**Contract:** `BaseEscrow` (or `EscrowVault` / `EscrowableERC20` if deployed separately)  
**Function:** `pause()`  
**Parameters:** None  
**Role Required:** `ROLE_GUARDIAN`

**Transaction Details:**
```solidity
function pause() external onlyRole(ROLE_GUARDIAN);
```

### Step 3: Execute via Multisig

1. [ ] Open Guardian Multisig wallet
2. [ ] Navigate to contract on Basescan
3. [ ] Connect wallet
4. [ ] Call `pause()` function
5. [ ] Submit transaction
6. [ ] Wait for required multisig confirmations
7. [ ] Confirm transaction on blockchain

### Step 4: Verify Pause

- [ ] Check `paused()` returns `true`
- [ ] Verify new escrows cannot be created
- [ ] Verify releases/cancellations are blocked
- [ ] Document transaction hash
- [ ] Notify team and community

### Step 5: Post-Pause Actions

- [ ] Document emergency in incident log
- [ ] Begin investigation of root cause
- [ ] Prepare recovery plan (see `recovery.md`)
- [ ] Communicate with community (if appropriate)

**Transaction Hash:** `[TO BE FILLED DURING DRILL]`  
**Block Number:** `[TO BE FILLED DURING DRILL]`  
**Timestamp:** `[TO BE FILLED DURING DRILL]`

---

## Procedure 2: Disable Aave Yield Generation

**When to use:** Aave protocol failure or vulnerability

### Step 1: Verify Need

- [ ] Confirm Aave issue exists
- [ ] Verify impact on protocol
- [ ] Document the issue

### Step 2: Prepare Transaction

**Contract:** `AaveYieldGenerationModule`  
**Function:** `guardianDisableAave()`  
**Parameters:** None  
**Role Required:** `ROLE_GUARDIAN`

**Transaction Details:**
```solidity
function guardianDisableAave() external onlyRole(ROLE_GUARDIAN);
```

### Step 3: Execute via Multisig

1. [ ] Open Guardian Multisig wallet
2. [ ] Navigate to `AaveYieldGenerationModule` on Basescan
3. [ ] Connect wallet
4. [ ] Call `guardianDisableAave()` function
5. [ ] Submit transaction
6. [ ] Wait for required multisig confirmations
7. [ ] Confirm transaction on blockchain

### Step 4: Verify Disable

- [ ] Check `aaveEnabled()` returns `false` (if view function exists)
- [ ] Verify new deposits to Aave are blocked
- [ ] Document transaction hash
- [ ] Notify team

**Transaction Hash:** `[TO BE FILLED DURING DRILL]`  
**Block Number:** `[TO BE FILLED DURING DRILL]`  
**Timestamp:** `[TO BE FILLED DURING DRILL]`

---

## Procedure 3: Lower Token Exposure Cap

**When to use:** Token-specific risk (e.g., token depegging, exploit risk)

### Step 1: Verify Need

- [ ] Confirm token-specific risk exists
- [ ] Determine appropriate new cap (must be ≤ current cap)
- [ ] Document the risk

### Step 2: Prepare Transaction

**Contract:** `AaveYieldGenerationModule` (or relevant contract)  
**Function:** `guardianLowerTokenCap(address token, uint256 newCap)`  
**Parameters:**
- `token`: Token address
- `newCap`: New cap (must be ≤ current cap)
**Role Required:** `ROLE_GUARDIAN`

**Transaction Details:**
```solidity
function guardianLowerTokenCap(address token, uint256 newCap) 
    external 
    onlyRole(ROLE_GUARDIAN);
```

### Step 3: Execute via Multisig

1. [ ] Open Guardian Multisig wallet
2. [ ] Navigate to contract on Basescan
3. [ ] Connect wallet
4. [ ] Call `guardianLowerTokenCap(token, newCap)` function
5. [ ] Verify `newCap <= currentCap` (will revert if not)
6. [ ] Submit transaction
7. [ ] Wait for required multisig confirmations
8. [ ] Confirm transaction on blockchain

### Step 4: Verify Cap Lowered

- [ ] Check token cap is now `newCap`
- [ ] Verify new deposits respect new cap
- [ ] Document transaction hash
- [ ] Notify team

**Transaction Hash:** `[TO BE FILLED DURING DRILL]`  
**Block Number:** `[TO BE FILLED DURING DRILL]`  
**Timestamp:** `[TO BE FILLED DURING DRILL]`

---

## Procedure 4: Lower Global Exposure Cap

**When to use:** System-wide risk (e.g., Aave protocol-wide issue)

### Step 1: Verify Need

- [ ] Confirm system-wide risk exists
- [ ] Determine appropriate new cap (must be ≤ current cap)
- [ ] Document the risk

### Step 2: Prepare Transaction

**Contract:** `AaveYieldGenerationModule` (or relevant contract)  
**Function:** `guardianLowerGlobalCap(uint256 newCap)`  
**Parameters:**
- `newCap`: New global cap (must be ≤ current cap)
**Role Required:** `ROLE_GUARDIAN`

**Transaction Details:**
```solidity
function guardianLowerGlobalCap(uint256 newCap) 
    external 
    onlyRole(ROLE_GUARDIAN);
```

### Step 3: Execute via Multisig

1. [ ] Open Guardian Multisig wallet
2. [ ] Navigate to contract on Basescan
3. [ ] Connect wallet
4. [ ] Call `guardianLowerGlobalCap(newCap)` function
5. [ ] Verify `newCap <= currentCap` (will revert if not)
6. [ ] Submit transaction
7. [ ] Wait for required multisig confirmations
8. [ ] Confirm transaction on blockchain

### Step 4: Verify Cap Lowered

- [ ] Check global cap is now `newCap`
- [ ] Verify new deposits respect new cap
- [ ] Document transaction hash
- [ ] Notify team

**Transaction Hash:** `[TO BE FILLED DURING DRILL]`  
**Block Number:** `[TO BE FILLED DURING DRILL]`  
**Timestamp:** `[TO BE FILLED DURING DRILL]`

---

## Emergency Communication

### Internal Communication

1. **Immediate:** Notify core team via emergency channel
2. **Within 1 hour:** Document incident in incident log
3. **Within 4 hours:** Prepare incident report

### External Communication

1. **If funds at risk:** Immediate public communication
2. **If exploit active:** Immediate public communication + pause
3. **If vulnerability found:** Coordinate disclosure (see `SECURITY.md`)

---

## Post-Emergency Actions

1. [ ] Document incident in incident log
2. [ ] Root cause analysis
3. [ ] Prepare fix (if needed)
4. [ ] Prepare recovery plan (see `recovery.md`)
5. [ ] Post-mortem (within 1 week)

---

## Testing & Drills

**Frequency:** Quarterly  
**Last Drill:** `[TO BE FILLED]`  
**Next Drill:** `[TO BE FILLED]`

See `docs/OUTSTANDING_ISSUES.md` for drill requirements.

---

## Related Documents

- [`docs/EMERGENCY_POLICY.md`](../docs/EMERGENCY_POLICY.md) - High-level emergency policy
- [`recovery.md`](./recovery.md) - Recovery procedures
- [`docs/SECURITY_MODEL.md`](../docs/SECURITY_MODEL.md) - Security model
- [`SECURITY.md`](../SECURITY.md) - Security contact and disclosure policy

---

**Note:** This runbook should be tested regularly. Update transaction hashes and block numbers after each drill.



