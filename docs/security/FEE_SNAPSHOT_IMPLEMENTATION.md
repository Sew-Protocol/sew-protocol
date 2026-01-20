# Per-Escrow Fee Snapshot Implementation

**Date:** 2026-01-28  
**Status:** Implementation Plan for Fee Immutability

---

## Overview

**Problem:** Protocol fees (`yieldProtocolFeeBps`, `appealBondProtocolFeeBps`) are global and mutable, meaning they can change during an escrow's lifetime. This creates unpredictable economics for users.

**Solution:** Snapshot protocol fees per-escrow at creation time (like module snapshots), ensuring fees are immutable for each escrow.

---

## Implementation Plan

### 1. Extend ModuleSnapshot Struct

**Current:**
```solidity
struct ModuleSnapshot {
    address resolutionModule;
    address releaseStrategy;
    address yieldGenerationModule;
    address yieldDistributionModule;
}
```

**Updated:**
```solidity
struct ModuleSnapshot {
    address resolutionModule;
    address releaseStrategy;
    address yieldGenerationModule;
    address yieldDistributionModule;
    uint256 yieldProtocolFeeBps;      // NEW: Snapshotted at creation
    uint256 appealBondProtocolFeeBps; // NEW: Snapshotted at creation
}
```

**Storage Impact:**
- Adds 2 `uint256` fields (64 bytes total)
- Uses 2 additional storage slots per escrow
- Gas cost: ~40,000 gas per escrow creation (2 writes)

---

### 2. Update Snapshot Function

**Current (`_snapshotModulesForEscrow`):**
```solidity
function _snapshotModulesForEscrow(uint256 workflowId) internal {
    moduleSnapshots[workflowId] = ModuleSnapshot({
        resolutionModule: resModule,
        releaseStrategy: relStrat,
        yieldGenerationModule: genMod,
        yieldDistributionModule: distMod
    });
}
```

**Updated:**
```solidity
function _snapshotModulesForEscrow(uint256 workflowId) internal {
    moduleSnapshots[workflowId] = ModuleSnapshot({
        resolutionModule: resModule,
        releaseStrategy: relStrat,
        yieldGenerationModule: genMod,
        yieldDistributionModule: distMod,
        yieldProtocolFeeBps: yieldProtocolFeeBps,           // NEW: Snapshot current value
        appealBondProtocolFeeBps: appealBondProtocolFeeBps  // NEW: Snapshot current value
    });
    
    emit EscrowModuleSnapshot(
        workflowId,
        resModule,
        relStrat,
        genMod,
        distMod,
        yieldProtocolFeeBps,           // NEW: Include in event
        appealBondProtocolFeeBps       // NEW: Include in event
    );
}
```

---

### 3. Update Fee Usage to Use Snapshot

**Current (YieldOps.handleYield):**
```solidity
function handleYield(
    ...,
    uint256 protocolFeeBps,  // Passed from BaseEscrow (global value)
    ...
) external returns (YieldResult memory result) {
    if (protocolFeeBps > 0) {
        protocolFeeAmount = (result.yield * protocolFeeBps) / 10000;
        // ...
    }
}
```

**Updated (BaseEscrow._releaseEscrowTransfer / _cancelAndRefund):**
```solidity
function _releaseEscrowTransfer(uint256 workflowId) internal {
    // ...
    if (address(yieldOps) != address(0)) {
        IYieldGenerationModule genModule = _getYieldGenerationModule(workflowId);
        IYieldDistributionModule distModule = _getYieldDistributionModule(workflowId);
        
        // NEW: Use snapshotted fee instead of global fee
        uint256 snapshottedYieldFee = moduleSnapshots[workflowId].yieldProtocolFeeBps;
        
        try yieldOps.handleYield(
            genModule,
            distModule,
            workflowId,
            token,
            amount,
            snapshottedYieldFee,  // CHANGED: Use snapshot instead of global
            escrowFeeAddress
        )
        // ...
    }
}
```

**Current (BaseEscrow.escalateDispute):**
```solidity
if (appealBondProtocolFeeBps > 0 && escrowFeeAddress != address(0)) {
    protocolFeeAmount = (bondAmount * appealBondProtocolFeeBps) / 10000;
    // ...
}
```

**Updated:**
```solidity
// NEW: Use snapshotted fee instead of global fee
uint256 snapshottedBondFee = moduleSnapshots[workflowId].appealBondProtocolFeeBps;

if (snapshottedBondFee > 0 && escrowFeeAddress != address(0)) {
    protocolFeeAmount = (bondAmount * snapshottedBondFee) / 10000;
    // ...
}
```

---

### 4. Update Events

**Current:**
```solidity
event EscrowModuleSnapshot(
    uint256 indexed workflowId,
    address resolutionModule,
    address releaseStrategy,
    address yieldGenerationModule,
    address yieldDistributionModule
);
```

**Updated:**
```solidity
event EscrowModuleSnapshot(
    uint256 indexed workflowId,
    address resolutionModule,
    address releaseStrategy,
    address yieldGenerationModule,
    address yieldDistributionModule,
    uint256 yieldProtocolFeeBps,      // NEW
    uint256 appealBondProtocolFeeBps  // NEW
);
```

---

### 5. Add Fee Disclosure Event at Creation

**New Event:**
```solidity
event EscrowFeeSnapshot(
    uint256 indexed workflowId,
    uint256 escrowFee,
    uint256 yieldProtocolFeeBps,
    uint256 appealBondProtocolFeeBps,
    uint256 effectiveFeeRateBps  // Calculated effective fee (escrow fee only)
);
```

**Emit at escrow creation:**
```solidity
function createEscrow(...) public returns (uint256 workflowId) {
    // ... existing code ...
    
    _snapshotModulesForEscrow(workflowId);
    
    // NEW: Emit fee disclosure event
    emit EscrowFeeSnapshot(
        workflowId,
        escrowFee,
        yieldProtocolFeeBps,
        appealBondProtocolFeeBps,
        escrowFee  // Effective fee (escrow fee only, protocol fees are on yield/bonds)
    );
    
    return workflowId;
}
```

---

## Gas Cost Impact

**Per Escrow Creation:**
- Additional storage: 2 slots × ~20,000 gas = **+40,000 gas**
- Additional event data: ~375 gas per event field × 2 = **+750 gas**
- **Total additional: ~40,750 gas per escrow**

**Per Yield Handling:**
- Storage read from snapshot instead of global: No change (same operation)
- **Total additional: 0 gas**

**Per Escalation:**
- Storage read from snapshot instead of global: No change (same operation)
- **Total additional: 0 gas**

**Net Impact:**
- One-time cost at creation: **+40,750 gas**
- No ongoing costs
- **Acceptable tradeoff for fee immutability**

---

## Testing Requirements

1. **Fee Snapshot at Creation:**
   - Verify `yieldProtocolFeeBps` is snapshotted correctly
   - Verify `appealBondProtocolFeeBps` is snapshotted correctly
   - Verify snapshot values match global values at creation time

2. **Fee Immutability:**
   - Create escrow with `yieldProtocolFeeBps = 10%`
   - Governance changes global `yieldProtocolFeeBps` to 30%
   - Verify escrow still uses 10% (snapshot value)
   - New escrows use 30% (global value)

3. **Yield Fee Application:**
   - Create escrow with snapshot `yieldProtocolFeeBps = 10%`
   - Generate yield
   - Verify 10% fee is applied (not current global value)

4. **Appeal Bond Fee Application:**
   - Create escrow with snapshot `appealBondProtocolFeeBps = 5%`
   - Escalate dispute
   - Verify 5% fee is applied (not current global value)

5. **Event Emission:**
   - Verify `EscrowModuleSnapshot` includes fee values
   - Verify `EscrowFeeSnapshot` is emitted at creation
   - Verify event values match snapshot values

---

## Migration Considerations

**For Existing Escrows:**
- Existing escrows have no fee snapshots
- Options:
  1. **Initialize to zero:** If snapshot is zero, use global value (backward compatible)
  2. **Initialize to current global:** Snapshot current global value on first access
  3. **Migration function:** Allow migration with user consent

**Recommendation:**
- Option 2: Initialize to current global value on first access (lazy initialization)
- This ensures all escrows have snapshots without requiring migration
- Code: `if (moduleSnapshots[workflowId].yieldProtocolFeeBps == 0 && globalYieldFee > 0) { snapshot = global; }`

---

## Code Changes Summary

### Files to Modify:

1. **BaseEscrow.sol:**
   - Extend `ModuleSnapshot` struct (add 2 fields)
   - Update `_snapshotModulesForEscrow()` (snapshot fees)
   - Update `_releaseEscrowTransfer()` (use snapshot fee)
   - Update `_cancelAndRefund()` (use snapshot fee)
   - Update `escalateDispute()` (use snapshot fee)
   - Update `EscrowModuleSnapshot` event
   - Add `EscrowFeeSnapshot` event
   - Emit fee disclosure at creation

2. **YieldOps.sol:**
   - No changes needed (receives fee as parameter)

3. **Test Files:**
   - Update module snapshot tests
   - Add fee snapshot tests
   - Add fee immutability tests

---

## Benefits

1. **Fee Immutability:** Users know fees upfront, no surprises
2. **Economic Predictability:** Total cost is known at creation
3. **Consistency:** Matches module snapshot pattern (same design principle)
4. **Transparency:** Fee disclosure events at creation

---

## Addressing Review Concerns

**Original Review Issue #1: Fee Stacking**
- ✅ **Clarified:** Fee stacking is intentional and justified:
  - Escrow fee = service fee (immutable per-escrow)
  - Yield protocol fee = fee on yield generated (now immutable per-escrow)
  - Appeal bond protocol fee = additional work/complexity fee (now immutable per-escrow)
- ✅ **Solution:** Fee snapshotting addresses transparency concern

**Original Review Issue #3: Protocol Fees Not Snapshotted**
- ✅ **Addressed:** This implementation snapshots protocol fees per-escrow

**Governance Events:**
- ✅ **Existing Events:**
  - `ResolutionModuleQueued(address indexed oldModule, address indexed newModule, uint64 eta)`
  - `ResolutionModuleActivated(address indexed oldModule, address indexed newModule)`
  - `YieldProtocolFeeBpsUpdated(uint256 oldFeeBps, uint256 newFeeBps)`
  - `AppealBondProtocolFeeBpsUpdated(uint256 oldFeeBps, uint256 newFeeBps)`
- ✅ **All fee changes are already evented**

**Module Grandfathering:**
- ✅ **Clarification:** "Module grandfathering window" means making modules immutable at a certain time (when escrow is created)
- ✅ **Already implemented:** Module snapshots ensure old escrows use old modules
- ✅ **No additional mechanism needed**

---

**Implementation Ready:** Yes  
**Next Steps:** Implement code changes and add tests
