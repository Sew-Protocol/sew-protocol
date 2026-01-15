# Impact Analysis: Locking Escalation to 3 Fixed Rounds

## Overview

This document analyzes the impact of locking escalation rounds (removing `escalationConfig` mapping) on:

1. Escalation fees (DR v1)
2. Configuration flexibility
3. DR v2 integration

## Current System Architecture

### Escalation Configuration (DR v1)

**Structure:**

```solidity
struct EscalationConfig {
    address resolver;        // Resolver for this level (or address(0) for dynamic)
    uint256 fee;            // Fee required to escalate to this level
    bool enabled;           // Whether this level is enabled
}

mapping(uint8 => EscalationConfig) public escalationConfig;
```

**Initialization:**

- Round 0 (Resolver): `enabled=true, fee=0, resolver=address(0)`
- Round 1 (Senior): `enabled=true, fee=0, resolver=address(0)`
- Round 2 (Kleros): `enabled=false, fee=0, resolver=address(0)`

**Key Functions:**

- `canEscalate()`: Checks `escalationConfig[nextRound].enabled` and returns `escalationConfig[nextRound].fee`
- `executeEscalation()`: Checks `escalationConfig[toRound].enabled` and verifies fee payment using `escalationConfig[toRound].fee`
- `setExternalResolver()`: Enables round 2 when external resolver is set
- `queueEscalationConfig()` / `activateEscalationConfig()`: Governance functions to update per-round config

### DR v2 Escalation Cost System

**Structure:**

```solidity
EscalationCostConfig public escalationCostConfig;
// Uses cost curves (linear, quadratic, geometric) instead of fixed fees
```

**Key Differences:**

- DR v2 uses `escalationCostConfig` (different from `escalationConfig`)
- DR v2 calculates costs based on escalation count and curve type
- DR v2 is currently **disabled** (`escalationCostConfig.enabled = false`)
- DR v2 uses appeal bonds, not simple fees

---

## Impact Analysis

### 1. Escalation Fees (DR v1)

#### Current Behavior

**Fee Flow:**

1. `BaseEscrow.escalateDispute()` calls `DisputeOps.computeEscalation()`
2. `computeEscalation()` calls `module.canEscalate()` which returns `escalationConfig[nextRound].fee`
3. `BaseEscrow` validates fee payment and calls `markEscalationFeePaid()`
4. `executeEscalation()` verifies fee was paid using `escalationConfig[toRound].fee`

**Current Fees:**

- Round 0 → 1: Fee = 0 (hardcoded in initialization)
- Round 1 → 2: Fee = 0 (hardcoded in initialization)
- Fees are **always 0** in current implementation

#### Impact of Locking Rounds

**If we lock rounds and remove `escalationConfig`:**

✅ **Positive:**

- Fees are currently 0, so removing config has no functional impact on fees
- Simplifies code by removing unused fee configuration
- Hardcoding `fee=0` is equivalent to current behavior

❌ **Negative:**

- **Cannot add fees later** without contract upgrade
- Loses flexibility to charge escalation fees per round
- If fees are needed in future, requires contract upgrade

**Recommendation:**

- **Lock to fixed fees (0 for now)** or keep simple fee structure
- Since fees are always 0, hardcoding `fee=0` is safe
- If fees are needed later, can add governance-controlled fee parameters separately

---

### 2. Configuration Flexibility

#### Current Configuration Options

**Per-Round Configuration:**

1. **Enable/Disable Rounds:**
   - Can disable round 2 (Kleros) until external resolver is set
   - Can enable/disable rounds via governance
   - `setExternalResolver()` enables round 2

2. **Per-Round Resolver:**
   - Can set specific resolver per round (currently `address(0)` = dynamic)
   - Round 0: Dynamic selection (round-robin)
   - Round 1: Dynamic selection (senior round-robin)
   - Round 2: External resolver (Kleros)

3. **Per-Round Fees:**
   - Can configure fees per round (currently all 0)

#### Impact of Locking Rounds

**If we remove `escalationConfig` and hardcode path:**

✅ **Positive:**

- **Simpler code:** No mapping, no configuration logic
- **Predictable:** Always 3 rounds, always enabled
- **Less governance overhead:** No need to configure rounds
- **Fewer edge cases:** No "round disabled" states

❌ **Negative:**

- **Loss of flexibility:** Cannot disable rounds
- **Cannot enable round 2 conditionally:** Round 2 always available (requires `externalResolver != address(0)`)
- **Breaking change:** Removes governance functions (`queueEscalationConfig`, `activateEscalationConfig`)
- **No per-round resolver override:** Must use dynamic selection

**Key Question:**

- **Do we need to disable round 2 before external resolver is set?**
  - Current: Round 2 disabled by default, enabled when `setExternalResolver()` is called
  - Locked: Round 2 always enabled if `externalResolver != address(0)`, or we check resolver existence

**Recommendation:**

- **Lock rounds but keep `externalResolver` check:**
  - Round 0 → 1: Always allowed (if senior resolvers exist)
  - Round 1 → 2: Allowed if `externalResolver != address(0)`
- This maintains safety while removing config complexity

---

### 3. DR v2 Integration

#### DR v2 Escalation Cost System

**Current State:**

- DR v2 uses **different system** (`escalationCostConfig`) than DR v1 (`escalationConfig`)
- DR v2 is **disabled** (`escalationCostConfig.enabled = false`)
- DR v2 uses **cost curves** (linear, quadratic, geometric) instead of fixed fees
- DR v2 uses **appeal bonds**, not simple fee payments

**Key Functions:**

- `getRequiredAppealBond()`: Calculates bond using `EscalationCostLibrary.calculateEscalationCost()`
- `calculateEscalationCost()`: Uses `escalationCostConfig` (not `escalationConfig`)

#### Impact of Locking Rounds on DR v2

✅ **Positive:**

- **No impact on DR v2:** DR v2 uses `escalationCostConfig`, not `escalationConfig`
- **Simpler DR v1 → DR v2 transition:** Removing DR v1 config reduces confusion
- **Clear separation:** DR v1 = fixed rounds, DR v2 = cost curves

❌ **Negative:**

- **None identified:** DR v2 is independent of `escalationConfig`

**Recommendation:**

- **Safe to remove `escalationConfig`:** DR v2 uses different system
- DR v2 can still be enabled/disabled via `escalationCostConfig.enabled`
- Locking rounds doesn't affect DR v2 functionality

---

## Implementation Strategy

### Proposed Changes

1. **Remove `escalationConfig` Mapping:**
   - Remove `mapping(uint8 => EscalationConfig) public escalationConfig`
   - Remove `mapping(uint8 => PendingEscalationConfig) private _pendingEscalationConfig`
   - Remove `EscalationConfig` struct (if not used elsewhere)

2. **Simplify `canEscalate()`:**

   ```solidity
   function canEscalate(
     uint256 workflowId,
     uint8 currentLevel,
     bytes calldata
   ) external view override returns (bool allowed, address nextResolver, uint256 escalationFee) {
     uint8 nextRound = currentLevel + 1;
     if (nextRound > MAX_ROUND) return (false, address(0), 0);

     // Round 0 → 1: Always allowed (if senior resolvers exist)
     if (nextRound == 1) {
       nextResolver = selectResolverRoundRobin(escrowCategory[workflowId], true);
       return (nextResolver != address(0), nextResolver, 0); // Fee = 0
     }

     // Round 1 → 2: Allowed if external resolver is set
     if (nextRound == 2) {
       if (externalResolver == address(0)) return (false, address(0), 0);
       return (true, externalResolver, 0); // Fee = 0
     }

     return (false, address(0), 0);
   }
   ```

3. **Simplify `executeEscalation()`:**

   ```solidity
   function executeEscalation(
     uint256 workflowId,
     bytes calldata
   ) external override nonReentrant returns (bool success, address newResolver, uint8 newLevel) {
     DisputeMetadata storage dm = disputeMetadata[workflowId];
     uint8 fromRound = dm.currentRound;
     uint8 toRound = fromRound + 1;

     if (toRound > MAX_ROUND) {
       return (false, address(0), dm.currentRound);
     }

     // Verify escalation fee was paid (hardcoded to 0 for now)
     // Note: Fee checking logic can be removed or simplified
     uint256 requiredFee = 0; // Hardcoded
     if (requiredFee > 0) {
       require(escalationFeePaid[workflowId], 'Escalation fee not paid');
       escalationFeePaid[workflowId] = false;
     }

     // Hardcode resolver selection
     address nextRes;
     if (toRound == 1) {
       nextRes = selectResolverRoundRobin(escrowCategory[workflowId], true);
       if (nextRes != address(0)) advanceRoundRobinCounter(escrowCategory[workflowId], true);
     } else if (toRound == 2) {
       if (externalResolver == address(0)) {
         return (false, address(0), dm.currentRound);
       }
       nextRes = externalResolver;
     }

     if (nextRes == address(0)) {
       return (false, address(0), dm.currentRound);
     }

     // Update metadata...
     // (rest of function unchanged)
   }
   ```

4. **Remove Governance Functions:**
   - Remove `queueEscalationConfig()`
   - Remove `activateEscalationConfig()`
   - Remove `getPendingEscalationConfig()`
   - Keep `setExternalResolver()` (still needed to set Kleros address)

5. **Remove Events:**
   - Remove `EscalationConfigUpdated`
   - Remove `EscalationConfigQueued`
   - Remove `EscalationConfigActivated`

---

## Migration Considerations

### Breaking Changes

1. **Governance Functions Removed:**
   - `queueEscalationConfig()` - No longer available
   - `activateEscalationConfig()` - No longer available
   - `getPendingEscalationConfig()` - No longer available

2. **Public Mapping Removed:**
   - `escalationConfig(uint8)` - No longer accessible

3. **Behavior Changes:**
   - Round 2 always enabled if `externalResolver != address(0)`
   - Cannot disable rounds via governance
   - Fees hardcoded to 0 (currently already 0)

### Migration Steps

1. **Before Deployment:**
   - Verify no pending `escalationConfig` changes
   - Ensure `externalResolver` is set if round 2 is needed
   - Confirm all rounds are in desired state

2. **Deployment:**
   - Deploy updated contract
   - Verify `canEscalate()` returns correct values
   - Verify `executeEscalation()` works correctly

3. **Post-Deployment:**
   - Monitor escalation behavior
   - Verify no regression in escalation flow

---

## Risk Assessment

### Low Risk

✅ **Fees:** Currently 0, hardcoding has no impact
✅ **DR v2:** Independent system, no impact
✅ **Round 2:** Can still be controlled via `externalResolver`

### Medium Risk

⚠️ **Loss of Flexibility:** Cannot disable rounds or configure fees
⚠️ **Breaking Changes:** Removes governance functions

### High Risk

❌ **None identified**

---

## Recommendations

### ✅ Proceed with Locking Rounds

**Rationale:**

1. **Fees are always 0:** No functional impact
2. **DR v2 is independent:** No impact on DR v2
3. **Simplifies code significantly:** Removes complexity
4. **Maintains safety:** Round 2 still controlled via `externalResolver`

**Implementation:**

1. Remove `escalationConfig` mapping and related functions
2. Hardcode escalation path: 0 → 1 → 2
3. Keep `externalResolver` check for round 2
4. Hardcode fees to 0 (matches current behavior)

**Future Considerations:**

- If fees are needed later, add separate governance-controlled fee parameters
- DR v2 can be enabled when needed (independent of this change)
- Round disabling not needed if `externalResolver` check is sufficient

---

## Summary

| Aspect                        | Impact                               | Risk   | Recommendation          |
| ----------------------------- | ------------------------------------ | ------ | ----------------------- |
| **Escalation Fees (DR v1)**   | No functional impact (fees always 0) | Low    | ✅ Lock to 0            |
| **Configuration Flexibility** | Loss of per-round enable/disable     | Medium | ✅ Acceptable trade-off |
| **DR v2 Integration**         | No impact (independent system)       | Low    | ✅ Safe                 |
| **Breaking Changes**          | Removes governance functions         | Medium | ⚠️ Document clearly     |

**Overall Assessment:** ✅ **Safe to proceed** with locking rounds. The benefits (simplified code, predictable behavior) outweigh the costs (loss of flexibility that isn't currently used).
