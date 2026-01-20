# Phase 1: Appeal Window Enforcement - Review Document

## Overview

Phase 1 implements appeal window enforcement for DR v1 (fee-only escalation). This ensures tokens are only transferred (set as claimable) **after** the appeal window expires, preventing premature transfers when disputes are still appealable.

## Current State Analysis

### Current Resolution Flow

**In `_executeFullResolution()` and `_executePartialResolution()`:**

1. ✅ Update state (remainingBalance, escrowState = RESOLVED)
2. ✅ Handle yield
3. ✅ Set claimable balance (pull model - Phase 0 complete)
4. ❌ Call `_recordResolutionOutcome()` **AFTER** setting claimable

**Problem:** Resolution is recorded **after** funds are made claimable. If an appeal happens, the funds are already claimable.

### Current `_recordResolutionOutcome()` Function

```solidity
function _recordResolutionOutcome(
  uint256 workflowId,
  address disputeResolver,
  bool isRelease,
  bytes32 /* resolutionHash */
) internal {
  address module = address(_getResolutionModule(workflowId));
  if (module == address(0)) return;
  (bool success, ) = module.call(
    abi.encodeWithSignature(
      'recordResolution(uint256,address,uint8,bool,uint256)',
      workflowId,
      disputeResolver,
      isRelease ? 1 : 2,
      false,
      0
    )
  );
  success;
}
```

**Issue:** The function signature being called doesn't match `DecentralizedResolutionModule.recordResolution()`:

- Current call: `recordResolution(uint256,address,uint8,bool,uint256)`
- Actual function: `recordResolution(uint256 workflowId, address resolver, ResolutionOutcome outcome, uint256 resolutionTime)`

This appears to be a bug that needs fixing.

### DecentralizedResolutionModule.recordResolution()

```solidity
function recordResolution(
  uint256 workflowId,
  address resolver,
  ResolutionOutcome outcome,
  uint256 resolutionTime
) external onlyEscrowContract {
  DisputeMetadata storage dm = disputeMetadata[workflowId];
  uint8 currentRound = dm.currentRound;

  dm.decisionAtRound[currentRound] = outcome;
  dm.decidedAtRound[currentRound] = block.timestamp;
  dm.appealDeadline[currentRound] = block.timestamp + appealWindows[currentRound];
  dm.status = DisputeStatus.Decided;
  // ... rest of function
}
```

**Key observations:**

- Sets `appealDeadline[currentRound] = block.timestamp + appealWindows[currentRound]`
- Sets `status = DisputeStatus.Decided`
- `appealWindows = [2 days, 3 days, 0]` (round 0, 1, 2)
- Round 2 (Kleros) has `appealWindow = 0` (final level, no appeals)

## Proposed Changes

### 1. Pending Settlement Storage ✅ (Already Added)

**Location:** `contracts/core/BaseEscrow.sol`

**Added:**

```solidity
struct PendingSettlement {
    bool exists;
    bool isRelease;
    uint256 amount;
    uint256 appealDeadline;
    uint8 round;
    bytes32 resolutionHash;
}
mapping(uint256 => PendingSettlement) public pendingSettlements;

event PendingSettlementSet(uint256 indexed workflowId, bool isRelease, uint256 amount, uint256 appealDeadline, uint8 round);
event PendingSettlementCancelled(uint256 indexed workflowId);
event EscrowFinalized(uint256 indexed workflowId, address indexed recipient, uint256 amount);
```

**Status:** ✅ Already implemented

### 2. Refactor Resolution Recording Order

**Function:** `_executeFullResolution()` and `_executePartialResolution()`

**Current flow:**

1. Update state → RESOLVED
2. Handle yield
3. Set claimable balance
4. Call `_recordResolutionOutcome()`

**Proposed flow:**

1. **Call `_recordResolutionOutcome()` FIRST** (records decision, sets appeal deadline in module)
2. **Query appeal deadline from module** (need helper function)
3. **If appeal window = 0 (final level)**:
   - Finalize immediately (set claimable, state = RESOLVED)
4. **Else (appeal window > 0)**:
   - Store pending settlement
   - Keep state as DISPUTED (not RESOLVED)
   - Emit `PendingSettlementSet` event
   - Do NOT set claimable balance yet

**State management:**

- Option A: Reuse `DISPUTED` state (simpler, less explicit)
- Option B: Add `DECIDED_PENDING_APPEAL` state (requires enum change)
- **Recommendation:** Option A for v1 (reuse DISPUTED)

### 3. Fix `_recordResolutionOutcome()` Function Signature

**Current (WRONG):**

```solidity
module.call(abi.encodeWithSignature("recordResolution(uint256,address,uint8,bool,uint256)", workflowId, disputeResolver, isRelease ? 1 : 2, false, 0));
```

**Proposed:**

```solidity
// Convert bool isRelease to ResolutionOutcome enum (0=NONE, 1=RELEASE, 2=CANCEL)
uint8 outcome = isRelease ? 1 : 2; // ResolutionOutcome.RELEASE = 1, CANCEL = 2
uint256 resolutionTime = block.timestamp; // Could be passed as parameter if needed
module.call(abi.encodeWithSignature("recordResolution(uint256,address,uint8,uint256)", workflowId, disputeResolver, outcome, resolutionTime));
```

**Note:** Need to verify `ResolutionOutcome` enum values match (RELEASE=1, CANCEL=2)

### 4. Helper Function to Query Appeal Information

**Function:** `_getAppealInfo(uint256 workflowId)` (internal view)

**Purpose:** Query appeal deadline and current round from resolution module

**Implementation approach:**

- Option A: Use `getDisputeMetadata(workflowId)` if module implements it
- Option B: Use low-level call to query `disputeMetadata[workflowId]`
- Option C: Add interface method (requires module interface change)

**For DecentralizedResolutionModule:**

- Has public `getDisputeMetadata(uint256 workflowId) returns (DisputeMetadata memory)`
- Can query `appealWindows[currentRound]` (public array)
- Can query `disputeMetadata[workflowId].appealDeadline[currentRound]` via getDisputeMetadata

**Proposed helper:**

```solidity
function _getAppealInfo(
  uint256 workflowId
) internal view returns (uint256 appealDeadline, uint8 currentRound, uint256 appealWindow) {
  address module = address(_getResolutionModule(workflowId));
  if (module == address(0)) return (0, 0, 0);

  // Try to get dispute metadata (DecentralizedResolutionModule has getDisputeMetadata)
  (bool success, bytes memory data) = module.staticcall(
    abi.encodeWithSignature('getDisputeMetadata(uint256)', workflowId)
  );

  if (success && data.length > 0) {
    // Decode DisputeMetadata struct
    // Extract: currentRound, appealDeadline[currentRound]
    // Query appealWindows[currentRound]
  }

  return (appealDeadline, currentRound, appealWindow);
}
```

**Challenge:** Decoding `DisputeMetadata` struct requires knowing the struct layout. This is module-specific.

**Alternative (simpler):**

- Query `appealDeadline` and `currentRound` via separate calls
- Query `appealWindows[currentRound]` directly (public array)

### 5. Add `finalizeAfterAppealWindow()` Function

**Function:** `finalizeAfterAppealWindow(uint256 workflowId) external nonReentrant`

**Logic:**

1. Validate workflowId
2. Check pending settlement exists
3. Check appeal deadline has expired (`block.timestamp >= pending.appealDeadline`)
4. Verify dispute wasn't escalated (check module status == Decided, not Escalated)
5. Handle yield (if any)
6. Set claimable balance
7. Update state to RESOLVED
8. Delete pending settlement
9. Emit `EscrowFinalized` event

**Key checks:**

- Must verify dispute status is still `Decided` (not `Escalated`)
- Requires querying module's `disputeMetadata[workflowId].status`

### 6. Update `escalateDispute()` to Cancel Pending Settlements

**Location:** `contracts/core/BaseEscrow.sol:escalateDispute()`

**Add logic at start of function:**

```solidity
// Cancel pending settlement if exists
if (pendingSettlements[workflowId].exists) {
    delete pendingSettlements[workflowId];
    emit PendingSettlementCancelled(workflowId);
}
```

**Invariant:** Escalation deterministically cancels any pending settlement

### 7. Handle Final-Level Resolutions (Immediate Finalization)

**Logic:** After calling `recordResolution()`, check if `appealWindows[currentRound] == 0`

- **If 0 (final level, e.g., round 2 / Kleros):**
  - Finalize immediately (set claimable, state = RESOLVED)
  - Skip pending settlement storage
- **If > 0 (non-final level):**
  - Store pending settlement
  - Keep state as DISPUTED

## Key Design Decisions

### Decision 1: State Management

- **Option A:** Reuse `DISPUTED` state (simpler)
- **Option B:** Add `DECIDED_PENDING_APPEAL` state (more explicit)
- **Recommendation:** Option A for v1

### Decision 2: Querying Module State

- **Challenge:** BaseEscrow needs to query module-specific state (appeal deadline, current round, appeal windows)
- **Approach:** Use low-level calls or module-specific interface
- **For DecentralizedResolutionModule:** Can use `getDisputeMetadata()` and public `appealWindows` array

### Decision 3: Partial Resolutions

- Partial resolutions should also respect appeal windows
- However, partial resolutions may complete over multiple calls
- **Question:** Should partial resolutions also use pending settlements, or only full resolutions?

### Decision 4: Module Interface Compatibility

- Not all modules may support `getDisputeMetadata()`
- **Fallback:** If query fails, assume no appeal window (immediate finalization) or revert?
- **Recommendation:** For modules without metadata query, fall back to immediate finalization (backward compatibility)

## Implementation Challenges

### Challenge 1: Querying Module State

- BaseEscrow needs module-specific information (appeal deadline, round, appeal windows)
- This creates coupling with DecentralizedResolutionModule
- **Solution:** Use try/catch for queries, fallback to immediate finalization for unsupported modules

### Challenge 2: Fixing `_recordResolutionOutcome()` Signature

- Current signature is incorrect
- Need to match actual `recordResolution()` function
- **Note:** This may break existing code if modules rely on the wrong signature

### Challenge 3: Partial Resolution Handling

- Partial resolutions complete when `remainingBalance == 0`
- Should we store pending settlement for each partial, or only when complete?
- **Recommendation:** Only store pending settlement when resolution is complete (remainingBalance == 0)

### Challenge 4: EscrowState Management

- Current: Sets state to RESOLVED immediately
- Proposed: Keep as DISPUTED during appeal window
- This changes the state machine semantics

## Testing Considerations

### New Test Cases Needed:

1. ✅ Resolution recorded first (before claimable set)
2. ✅ Appeal window > 0 → pending settlement stored
3. ✅ Appeal window = 0 → immediate finalization
4. ✅ `finalizeAfterAppealWindow()` succeeds after deadline
5. ✅ `finalizeAfterAppealWindow()` fails before deadline
6. ✅ `finalizeAfterAppealWindow()` fails if escalated
7. ✅ `escalateDispute()` cancels pending settlement
8. ✅ Multiple resolutions with different appeal windows
9. ✅ Partial resolution + appeal window interaction

## Migration Considerations

### Backward Compatibility:

- Existing escrows will continue to work (they're already RESOLVED)
- Only new resolutions after Phase 1 deployment will use appeal windows
- Modules without appeal window support → immediate finalization (backward compatible)

### Rollback Plan:

- If issues arise, can revert to immediate finalization
- Pending settlements can be manually finalized via emergency function (if needed)

## Open Questions

1. **Should partial resolutions also use pending settlements?**
   - Current plan: Only full resolutions (when remainingBalance == 0)
   - Alternative: Each partial resolution also gets appeal window
2. **How to handle modules without `getDisputeMetadata()`?**
   - Fallback to immediate finalization?
   - Or require all modules to implement metadata query?
3. **What happens if `finalizeAfterAppealWindow()` is never called?**
   - Funds remain locked in escrow (but claimable balance is set)
   - Users need to call `finalizeAfterAppealWindow()` then `withdrawEscrow()`
   - Could add automation/keeper for finalization

4. **Should we add a function to check if escalation cancelled pending settlement?**
   - `finalizeAfterAppealWindow()` already checks status
   - Maybe add a view function for off-chain queries

## Summary

Phase 1 is a **substantial refactoring** that:

- ✅ Fixes resolution recording order (record first, then finalize)
- ✅ Adds appeal window enforcement
- ✅ Maintains backward compatibility (modules without support → immediate finalization)
- ⚠️ Requires querying module-specific state (creates coupling)
- ⚠️ Changes state machine semantics (DISPUTED during appeal window)

**Recommendation:** Proceed with implementation, but use try/catch for module queries to ensure backward compatibility.
