# Dispute Safety Mechanism: Preventing Permanently Stuck Escrows

**Date**: 2025-01-XX  
**Status**: Design Document  
**Purpose**: Ensure escrows can never be permanently stuck in DISPUTED state, even if resolution module fails

---

## Current State Analysis

### Auto-Release/Auto-Cancel Behavior

**Current Implementation** (`automateTimedActions`):
```solidity
function automateTimedActions(uint256 workflowId) public nonReentrant returns (bool) {
    EscrowTransfer storage et = escrowTransfers[workflowId];
    
    // Only process if still pending
    if(et.escrowState != EscrowState.PENDING) {
        return false;  // ❌ Does NOT work for DISPUTED escrows
    }
    
    // Check auto-release/auto-cancel...
}
```

**Finding**: ❌ **Auto-release/auto-cancel do NOT work for DISPUTED escrows**

- Only processes `PENDING` state escrows
- Once dispute is raised, state changes to `DISPUTED`
- `DISPUTED` escrows are **not covered** by auto-timeouts
- **Risk**: Escrows can be permanently stuck if:
  - Resolution module never calls `resolverRelease`/`resolverCancel`
  - Resolver never makes a decision
  - Module fails or is removed
  - Module has bugs preventing finalization

---

## Proposed Safety Mechanism

### Design Principles

1. **Zero Risk of Permanent Stuck Escrows**: Guaranteed resolution path
2. **DAO Control**: Timeout set by governance (ROLE_TIMELOCK)
3. **Conservative Default**: Safe default (e.g., 90 days)
4. **Per-Escrow Tracking**: Track when dispute was raised
5. **Automatic Execution**: Anyone can trigger after timeout
6. **Conservative Outcome**: Auto-cancel (refund to sender) as safest default

---

## Implementation Design

### Option 1: Dispute Max Timeout (Recommended)

**Add to BaseEscrow**:
```solidity
// DAO-controlled maximum dispute duration
uint256 public maxDisputeDuration = 90 days; // Default: 90 days

// Track when dispute was raised (for timeout calculation)
mapping(uint256 => uint256) public disputeRaisedTimestamp;

// Event
event DisputeAutoCancelled(uint256 indexed workflowId, address indexed from, uint256 amount, string reason);

/**
 * @notice Set maximum dispute duration (DAO only)
 * @param duration Maximum time a dispute can remain unresolved (in seconds)
 * @dev Must be between 7 days and 1 year
 */
function setMaxDisputeDuration(uint256 duration) external onlyRole(ROLE_TIMELOCK) {
    require(duration >= 7 days, "Too short");
    require(duration <= 365 days, "Too long");
    maxDisputeDuration = duration;
    emit MaxDisputeDurationUpdated(duration);
}

/**
 * @notice Auto-cancel disputed escrow if max duration exceeded
 * @param workflowId The escrow transfer ID
 * @dev Anyone can call this after timeout
 *      Automatically cancels and refunds to sender
 */
function autoCancelDisputedEscrow(uint256 workflowId) external nonReentrant returns (bool) {
    _validateWorkflowId(workflowId);
    EscrowTransfer storage et = escrowTransfers[workflowId];
    
    require(et.escrowState == EscrowState.DISPUTED, "Not in dispute");
    
    uint256 disputeTimestamp = disputeRaisedTimestamp[workflowId];
    require(disputeTimestamp > 0, "Dispute timestamp not set");
    require(block.timestamp >= disputeTimestamp + maxDisputeDuration, "Not yet timed out");
    
    // Auto-cancel: refund to sender (safest default)
    address from = et.from;
    uint256 amount = et.remainingBalance;
    
    _cancelAndRefund(workflowId);
    et.escrowState = EscrowState.RESOLVED;
    
    emit EscrowStateChanged(workflowId, EscrowState.DISPUTED, EscrowState.RESOLVED);
    emit DisputeAutoCancelled(workflowId, from, amount, "Max dispute duration exceeded");
    emit EscrowTransferResolved(workflowId, from, et.to, et.totalDeposited);
    
    return true;
}

/**
 * @notice Check if disputed escrow has exceeded max duration
 * @param workflowId The escrow transfer ID
 * @return isTimedOut True if max duration exceeded
 * @return timeRemaining Seconds until timeout (0 if timed out)
 */
function isDisputeTimedOut(uint256 workflowId) external view returns (bool isTimedOut, uint256 timeRemaining) {
    EscrowTransfer storage et = escrowTransfers[workflowId];
    if (et.escrowState != EscrowState.DISPUTED) {
        return (false, 0);
    }
    
    uint256 disputeTimestamp = disputeRaisedTimestamp[workflowId];
    if (disputeTimestamp == 0) {
        return (false, 0);
    }
    
    uint256 elapsed = block.timestamp - disputeTimestamp;
    if (elapsed >= maxDisputeDuration) {
        return (true, 0);
    }
    
    return (false, maxDisputeDuration - elapsed);
}
```

**Update `raiseDispute`**:
```solidity
function raiseDispute(uint256 workflowId) public returns (bool) {
    // ... existing code ...
    
    et.escrowState = EscrowState.DISPUTED;
    
    // Record dispute timestamp for timeout tracking
    disputeRaisedTimestamp[workflowId] = block.timestamp;
    
    // ... rest of function ...
}
```

**Update `resolverRelease`/`resolverCancel`**:
```solidity
function resolverRelease(uint256 workflowId) public nonReentrant returns (bool) {
    // ... existing code ...
    
    // Clear dispute timestamp (no longer needed)
    delete disputeRaisedTimestamp[workflowId];
    
    // ... rest of function ...
}
```

---

### Option 2: Enhanced Auto-Timeouts (Alternative)

**Extend existing `automateTimedActions`**:
```solidity
function automateTimedActions(uint256 workflowId) public nonReentrant returns (bool) {
    _validateWorkflowId(workflowId);
    EscrowTransfer storage et = escrowTransfers[workflowId];
    
    // Handle PENDING escrows (existing logic)
    if(et.escrowState == EscrowState.PENDING) {
        // ... existing auto-release/auto-cancel logic ...
    }
    
    // NEW: Handle DISPUTED escrows
    if(et.escrowState == EscrowState.DISPUTED) {
        uint256 disputeTimestamp = disputeRaisedTimestamp[workflowId];
        if (disputeTimestamp > 0 && 
            block.timestamp >= disputeTimestamp + maxDisputeDuration) {
            // Auto-cancel disputed escrow
            address from = et.from;
            _cancelAndRefund(workflowId);
            et.escrowState = EscrowState.RESOLVED;
            emit DisputeAutoCancelled(workflowId, from, et.totalDeposited, "Max dispute duration exceeded");
            return true;
        }
    }
    
    return false;
}
```

**Pros**: Reuses existing infrastructure  
**Cons**: Less explicit, harder to call directly

---

## Comparison: Option 1 vs Option 2

| Aspect | Option 1 (Dedicated Function) | Option 2 (Extended automateTimedActions) |
|--------|------------------------------|------------------------------------------|
| **Explicitness** | ✅ Clear, dedicated function | ⚠️ Mixed with PENDING logic |
| **Gas Efficiency** | ✅ Only checks DISPUTED | ⚠️ Checks both PENDING and DISPUTED |
| **Callability** | ✅ Can be called directly | ⚠️ Must call automateTimedActions |
| **Clarity** | ✅ Clear intent | ⚠️ Less obvious |
| **Contract Size** | ⚠️ +~200 bytes | ✅ Reuses existing code |

**Recommendation**: **Option 1** - More explicit and clear, better for safety-critical functionality

---

## Integration with Approach 2 (Module as Intermediary)

### How It Works Together

**Flow**:
1. Dispute raised → `disputeRaisedTimestamp[workflowId] = block.timestamp`
2. Resolver makes decision via module → Module records decision, starts grace period
3. **If module fails to finalize**:
   - After `maxDisputeDuration`, anyone can call `autoCancelDisputedEscrow()`
   - Escrow auto-cancels, refunds to sender
4. **If module works correctly**:
   - Module calls `resolverRelease`/`resolverCancel` before timeout
   - `disputeRaisedTimestamp` is cleared
   - No auto-cancel needed

**Safety Guarantee**: Even if module completely fails, escrow is guaranteed to resolve within `maxDisputeDuration`.

---

## Configuration Recommendations

### Default Values

**Conservative Default**: `90 days`
- Long enough for complex disputes
- Short enough to prevent long-term lockups
- Allows for multiple escalation rounds

**Minimum**: `7 days`
- Prevents accidental very short timeouts
- Allows basic dispute resolution

**Maximum**: `365 days`
- Prevents extremely long timeouts
- Still allows for complex cases

### Governance Considerations

**Setting `maxDisputeDuration`**:
- Should be set before mainnet launch
- Can be adjusted by DAO if needed
- Consider typical dispute resolution times
- Account for escalation to Kleros (can take weeks)

**Example Timeline**:
- Level 0 resolver: 7 days
- Level 1 escalation: +7 days
- Level 2 escalation: +7 days
- Kleros arbitration: +30-60 days
- **Total**: ~60-90 days for complex cases

---

## Edge Cases and Considerations

### Case 1: Module Finalizes After Timeout

**Scenario**: Module tries to finalize after `maxDisputeDuration` has passed

**Handling**:
```solidity
function resolverRelease(uint256 workflowId) public nonReentrant returns (bool) {
    // ... existing checks ...
    
    // Check if already auto-cancelled
    if (et.escrowState != EscrowState.DISPUTED) {
        revert TransferNotInDispute(workflowId, et.escrowState);
    }
    
    // Proceed with release (timeout hasn't been triggered yet)
    // ...
}
```

**Result**: First-come-first-served. If timeout triggered first, module call will fail. If module calls first, timeout check will fail.

### Case 2: Multiple Timeout Calls

**Scenario**: Multiple people call `autoCancelDisputedEscrow()` simultaneously

**Handling**: `nonReentrant` modifier + state check prevents double-execution:
```solidity
require(et.escrowState == EscrowState.DISPUTED, "Not in dispute");
// ... execute ...
et.escrowState = EscrowState.RESOLVED; // Prevents second call
```

### Case 3: Dispute Resolved Before Timeout

**Scenario**: Module successfully resolves before timeout

**Handling**: `disputeRaisedTimestamp` is cleared in `resolverRelease`/`resolverCancel`:
```solidity
delete disputeRaisedTimestamp[workflowId];
```

**Result**: Timeout check will fail (timestamp is 0), preventing auto-cancel.

### Case 4: Partial Resolutions

**Scenario**: `resolverPartialRelease` or `resolverPartialCancel` used

**Handling**: These also clear the timestamp:
```solidity
function resolverPartialRelease(uint256 workflowId, uint256 amount) public {
    // ... existing code ...
    
    // Clear timestamp if fully resolved
    if (et.remainingBalance == 0) {
        delete disputeRaisedTimestamp[workflowId];
    }
}
```

---

## Gas Costs

**Additional Storage**:
- `disputeRaisedTimestamp` mapping: ~20,000 gas per dispute (one-time)
- `maxDisputeDuration` state variable: ~20,000 gas (one-time setup)

**Function Calls**:
- `autoCancelDisputedEscrow`: ~50,000-80,000 gas (similar to `resolverCancel`)
- `isDisputeTimedOut`: ~2,100 gas (view function)

**Total Impact**: Minimal (~40,000 gas per dispute for safety mechanism)

---

## Testing Considerations

### Test Cases

1. **Normal Flow**: Dispute resolved before timeout → No auto-cancel
2. **Timeout Triggered**: Dispute not resolved → Auto-cancel after timeout
3. **Module Finalizes After Timeout**: First-come-first-served behavior
4. **Multiple Timeout Calls**: Only first succeeds
5. **Partial Resolution**: Timestamp cleared when fully resolved
6. **Edge Case**: Timeout exactly at boundary

### Integration Tests

- Test with `DecentralizedResolutionModule`
- Test with `DefaultResolutionModule`
- Test with module failure scenarios
- Test with Kleros integration (longer timeouts)

---

## Migration Strategy

### For Existing Escrows

**No Migration Needed**: New escrows automatically get dispute timestamp tracking.

### For Existing Disputes

**If deployed with disputes already raised**:
- Option A: Set timestamp to current time (conservative)
- Option B: Set timestamp to dispute creation time (if tracked)
- Option C: Leave as 0 (won't auto-cancel, but new disputes will work)

**Recommendation**: Set to current time for existing disputes (safest).

---

## Alternative: Per-Escrow Max Duration

**Instead of global `maxDisputeDuration`**, allow per-escrow configuration:

```solidity
mapping(uint256 => uint256) public escrowMaxDisputeDuration;

function setEscrowMaxDisputeDuration(uint256 workflowId, uint256 duration) 
    external onlyRole(ROLE_TIMELOCK) 
{
    require(duration >= 7 days && duration <= 365 days, "Invalid duration");
    escrowMaxDisputeDuration[workflowId] = duration;
}
```

**Pros**: More flexibility for high-value escrows  
**Cons**: More complexity, more gas, governance overhead

**Recommendation**: Start with global duration, add per-escrow if needed

---

## Recommendation

**Implement Option 1 (Dedicated Function)**:

1. ✅ **Clear and Explicit**: Dedicated function makes intent obvious
2. ✅ **Safety First**: Guaranteed resolution path
3. ✅ **DAO Controlled**: Governance sets timeout
4. ✅ **Conservative Default**: 90 days is reasonable
5. ✅ **Minimal Changes**: Only adds safety mechanism, doesn't change existing logic
6. ✅ **Works with Approach 2**: Module can still handle normal flow, safety mechanism is backup

**Implementation Steps**:
1. Add `maxDisputeDuration` state variable (default: 90 days)
2. Add `disputeRaisedTimestamp` mapping
3. Update `raiseDispute` to record timestamp
4. Update `resolverRelease`/`resolverCancel` to clear timestamp
5. Add `autoCancelDisputedEscrow()` function
6. Add `isDisputeTimedOut()` view function
7. Add `setMaxDisputeDuration()` governance function

**Contract Size Impact**: ~200-300 bytes (acceptable for safety mechanism)

---

## Conclusion

This safety mechanism ensures **zero risk of permanently stuck escrows** by:

1. ✅ Tracking when disputes are raised
2. ✅ Enforcing a maximum dispute duration (DAO-controlled)
3. ✅ Providing automatic cancellation path if module fails
4. ✅ Allowing anyone to trigger timeout (no reliance on specific actors)
5. ✅ Using conservative default (refund to sender)

**The mechanism is a safety net** - it should rarely be needed if modules work correctly, but provides critical protection against module failures, bugs, or malicious behavior.

---

*This document should be updated as implementation progresses.*

