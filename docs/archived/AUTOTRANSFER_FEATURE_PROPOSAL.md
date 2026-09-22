# AutoTransfer Feature Proposal

**Date:** 2026-01-13  
**Status:** Proposal - Discussion Required  
**Priority:** Medium

---

## Overview

Currently, the protocol uses a **pull model** for escrow finalization: when an escrow is released or cancelled, funds are stored in a claimable balance mapping, and recipients must call `withdrawEscrow()` to claim their funds.

This proposal adds an **autotransfer** option that automatically transfers funds to the recipient on release/cancel, with `withdrawEscrow()` as a fallback for failed transfers.

---

## Current Behavior (Pull Model)

### Release Flow
1. Sender calls `releaseEscrowTransfer(workflowId)`
2. State transitions to `RELEASED`
3. Yield is handled (if applicable)
4. Claimable balance is incremented: `claimable[workflowId][recipient][token] += amount`
5. **No token transfer occurs** - recipient must call `withdrawEscrow()`

### Cancel Flow
1. Similar to release, but funds go to sender instead of recipient
2. Claimable balance set for sender
3. Recipient/sender must call `withdrawEscrow()` to claim

### Benefits of Current Model
- ✅ Works with contracts that can't receive ERC20 (non-standard implementations)
- ✅ Recipients control when to claim (can batch multiple claims)
- ✅ Avoids gas waste from failed transfers
- ✅ Multi-payout support (if module supports it)

### Drawbacks of Current Model
- ❌ Requires additional transaction (user experience)
- ❌ Users may not realize they need to withdraw
- ❌ Funds can remain unclaimed indefinitely
- ❌ More complex for simple use cases

---

## Proposed AutoTransfer Feature

### Concept

Add a **setting flag** (`autoTransfer`) that controls whether funds are automatically transferred on finalization:

- **`autoTransfer = false`** (default): Current pull model behavior
- **`autoTransfer = true`**: Attempt automatic transfer, fallback to claimable if transfer fails

### Implementation Approach

#### Option 1: Settings Flag (Recommended)

Add to `EscrowSettings`:
```solidity
struct EscrowSettings {
    address customResolver;
    bool yieldEnabled;
    bool autoTransfer;        // NEW: Auto-transfer on finalization
    uint256 autoReleaseTime;
    uint256 autoCancelTime;
    EscrowType escrowType;
}
```

**Modified Release Flow:**
```solidity
function _releaseEscrowTransfer(uint256 workflowId) internal {
    EscrowTransfer storage et = escrowTransfers[workflowId];
    uint256 amount = et.amountAfterFee;
    address to = et.to;
    address token = et.token;
    
    // ... state transition ...
    // ... yield handling ...
    
    _updateEscrowBalance(token, amount, false);
    
    // Get settings to check autoTransfer flag
    EscrowSettings memory settings = escrowSettings[workflowId];
    
    if (settings.autoTransfer) {
        // Attempt automatic transfer
        try IERC20(token).safeTransfer(to, amount) {
            // Transfer succeeded - emit event
            emit EscrowTransferAutoCompleted(workflowId, to, token, amount);
            // Don't set claimable balance
            return;
        } catch {
            // Transfer failed - fallback to pull model
            claimable[workflowId][to][token] += amount;
            emit ClaimableBalanceSet(workflowId, to, token, amount);
            emit EscrowTransferAutoFailed(workflowId, to, token, amount);
        }
    } else {
        // Default pull model
        claimable[workflowId][to][token] += amount;
        emit ClaimableBalanceSet(workflowId, to, token, amount);
    }
}
```

#### Option 2: Per-Escrow Transfer Preference (Alternative)

Allow changing transfer preference after creation:
```solidity
function setAutoTransfer(uint256 workflowId, bool enabled) external {
    // Only sender or recipient can change
    EscrowTransfer storage et = escrowTransfers[workflowId];
    require(
        _msgSender() == et.from || _msgSender() == et.to,
        'Not participant'
    );
    require(
        et.escrowState == EscrowState.PENDING,
        'Not pending'
    );
    
    EscrowSettings storage settings = escrowSettings[workflowId];
    settings.autoTransfer = enabled;
    emit AutoTransferUpdated(workflowId, enabled);
}
```

**Recommendation:** Option 1 (settings flag at creation) is simpler and ensures consistency.

---

## Design Decisions

### 1. Graceful Fallback

**Decision:** If autotransfer fails, fallback to pull model (set claimable balance)

**Rationale:**
- Ensures funds are never lost
- Maintains compatibility with non-standard contracts
- Provides best of both worlds

**Alternative Considered:**
- Revert on failed transfer
- **Rejected:** Would break escrow finalization for non-standard contracts

### 2. Default Behavior

**Decision:** `autoTransfer = false` by default (maintain current behavior)

**Rationale:**
- Backward compatibility
- Conservative approach
- Users can opt-in explicitly

**Alternative Considered:**
- `autoTransfer = true` by default
- **Rejected:** Might cause issues for contracts that can't receive tokens

### 3. Transfer Failure Detection

**Decision:** Use try-catch with `safeTransfer`

**Rationale:**
- Detects both revert and return false (for non-standard tokens)
- SafeERC20 provides additional safety
- Standard OpenZeppelin pattern

### 4. Claimable Balance Behavior

**Decision:** Only set claimable balance if autotransfer fails or is disabled

**Rationale:**
- Prevents double-claiming
- Cleaner state management
- Clear intent

**Alternative Considered:**
- Always set claimable balance, check first
- **Rejected:** Unnecessary gas cost and complexity

---

## Events

### New Events
```solidity
event EscrowTransferAutoCompleted(
    uint256 indexed workflowId,
    address indexed recipient,
    address indexed token,
    uint256 amount
);

event EscrowTransferAutoFailed(
    uint256 indexed workflowId,
    address indexed recipient,
    address indexed token,
    uint256 amount,
    string reason
);

event AutoTransferUpdated(
    uint256 indexed workflowId,
    bool enabled
); // Only if Option 2 implemented
```

---

## Implementation Details

### Modified Functions

1. **`_releaseEscrowTransfer()`**
   - Check `autoTransfer` setting
   - Attempt transfer if enabled
   - Fallback to claimable on failure

2. **`_cancelAndRefund()`**
   - Same logic as release but for sender

3. **`createEscrow()`**
   - Accept `autoTransfer` in settings
   - Validate and store setting

4. **`updateEscrowSettings()`** (if Option 2)
   - Allow updating `autoTransfer` while PENDING

### Gas Impact

**Additional Gas Costs:**
- Settings check: ~50 gas
- Try-catch overhead: ~2,000-5,000 gas (only if autotransfer enabled)
- Transfer gas: ~21,000 gas (only if autotransfer succeeds)
- Fallback path: ~100 gas (only if transfer fails)

**Total Additional Cost:**
- Autotransfer disabled: ~50 gas (negligible)
- Autotransfer enabled (success): ~23,000 gas
- Autotransfer enabled (failure): ~7,000 gas

**Gas Savings:**
- User doesn't need separate withdrawal transaction: ~21,000 gas saved
- Net cost if autotransfer succeeds: ~2,000 gas (offset by user convenience)

---

## Use Cases

### Use Case 1: Simple EOA-to-EOA Escrows

**Scenario:** Buyer and seller are both EOA addresses (wallets)

**Current:** Buyer must release, then seller must withdraw (2 transactions)

**With Autotransfer:** Buyer releases, seller receives funds automatically (1 transaction)

**Benefit:** Better UX, fewer transactions

### Use Case 2: Contract Recipients

**Scenario:** Recipient is a smart contract that properly implements ERC20

**Current:** Works with pull model

**With Autotransfer:** Works with autotransfer (success path)

**Benefit:** Faster finalization, better UX

### Use Case 3: Non-Standard Contract Recipients

**Scenario:** Recipient is a contract that doesn't properly handle ERC20 transfers

**Current:** Works with pull model (contract calls `withdrawEscrow()`)

**With Autotransfer:** Transfer fails, falls back to pull model (same behavior)

**Benefit:** No change, still works

### Use Case 4: Batch Operations

**Scenario:** User wants to claim multiple escrows at once

**Current:** Can batch withdrawals in one transaction

**With Autotransfer:** If autotransfer enabled, can't batch (each escrow transfers separately)

**Consideration:** Users who want batching should use `autoTransfer = false`

---

## Edge Cases and Considerations

### 1. Reentrancy

**Issue:** Automatic transfer might trigger reentrancy

**Mitigation:**
- Already using `nonReentrant` modifier on all public functions
- Transfer happens after state transition (checks-effects-interactions)
- Try-catch prevents reentrancy through failure path

### 2. Transfer Failures

**Issue:** What if transfer fails for unknown reasons?

**Mitigation:**
- Fallback to claimable balance ensures funds never lost
- Event emitted for monitoring
- Recipient can still claim via `withdrawEscrow()`

### 3. Yield Handling

**Issue:** Should yield be included in autotransfer?

**Decision:** Yes, yield should be handled before autotransfer (current flow already does this)

**Implementation:**
- Yield handling occurs before balance update
- Autotransfer uses final amount (including yield)

### 4. Partial Payments

**Issue:** What if transfer partially succeeds?

**Mitigation:**
- `safeTransfer` reverts on failure, so partial success impossible
- Either full transfer succeeds or it fails completely

### 5. Gas Limit Issues

**Issue:** What if transfer requires more gas than available?

**Mitigation:**
- Transfer failure caught by try-catch
- Falls back to pull model
- Recipient can claim later with sufficient gas

---

## Backward Compatibility

### Existing Escrows

**Impact:** None

**Reason:** 
- `autoTransfer` defaults to `false`
- Existing escrows use default settings
- No behavior change for existing escrows

### Frontend/Integration

**Impact:** Low

**Required Changes:**
- UI can add checkbox for "Auto-transfer on release"
- Default to unchecked (current behavior)
- Display autotransfer status in escrow details

---

## Testing Requirements

### Unit Tests
- [ ] Autotransfer enabled, transfer succeeds
- [ ] Autotransfer enabled, transfer fails (fallback)
- [ ] Autotransfer disabled (current behavior)
- [ ] Autotransfer on cancel (sender receives)
- [ ] Autotransfer with yield handling
- [ ] Claimable balance not set if autotransfer succeeds
- [ ] Claimable balance set if autotransfer fails

### Integration Tests
- [ ] Full flow: create → release → autotransfer
- [ ] Full flow: create → cancel → autotransfer
- [ ] Full flow: create → dispute → resolve → autotransfer
- [ ] Autotransfer with non-standard token (failure handling)

### Edge Case Tests
- [ ] Autotransfer with contract that reverts on receive
- [ ] Autotransfer with contract that returns false
- [ ] Autotransfer with zero balance recipient
- [ ] Autotransfer with yield included

---

## Migration Path

### Phase 1: Add Setting (No Behavior Change)
1. Add `autoTransfer` to `EscrowSettings`
2. Default to `false`
3. Validate and store setting
4. No functional changes yet

### Phase 2: Implement Autotransfer Logic
1. Modify `_releaseEscrowTransfer()` and `_cancelAndRefund()`
2. Add try-catch logic
3. Add fallback to claimable
4. Add events

### Phase 3: Testing and Deployment
1. Comprehensive testing
2. Security review
3. Deploy to testnet
4. Monitor for issues
5. Deploy to mainnet

---

## Alternative Approaches Considered

### Alternative 1: Global Autotransfer Setting

**Proposal:** Single global setting for all escrows

**Rejected Because:**
- Less flexible
- Can't handle edge cases per escrow
- All-or-nothing approach

### Alternative 2: Always Attempt Autotransfer

**Proposal:** Always try to transfer, fallback to claimable

**Rejected Because:**
- Gas overhead for all escrows
- Breaks backward compatibility expectations
- Unnecessary try-catch for all cases

### Alternative 3: Recipient Preference

**Proposal:** Let recipient choose autotransfer preference

**Considered But:**
- More complex (requires recipient interaction)
- Delays escrow creation
- Sender might not know recipient preference

**Decision:** Settings flag at creation is cleaner

---

## Recommendations

### Implementation Priority: Medium

**Rationale:**
- Improves UX significantly for common cases
- Low risk (graceful fallback)
- Backward compatible
- Not critical for core functionality

### Recommended Approach: Option 1 (Settings Flag)

**Rationale:**
- Simplest implementation
- Clear intent
- Easy to understand
- Minimal complexity

### Recommended Default: `autoTransfer = false`

**Rationale:**
- Maintains current behavior
- Conservative approach
- Users opt-in explicitly
- Prevents unexpected behavior

---

## Open Questions

1. **Should autotransfer be changeable after creation?** (Option 2)
   - **Recommendation:** No, keep it simple (Option 1)
   - Can be added later if needed

2. **Should there be a gas limit for autotransfer?**
   - **Recommendation:** No, let it fail and fallback
   - Gas limits are handled by try-catch

3. **Should failed autotransfers be retryable?**
   - **Recommendation:** No, use `withdrawEscrow()` as fallback
   - Keeps logic simple

4. **Should autotransfer work for partial payments?**
   - **Note:** Not applicable - partial payments removed
   - Autotransfer only for full release/cancel

---

## Conclusion

The autotransfer feature provides a good balance between UX improvement and compatibility. By defaulting to the current pull model and gracefully falling back on transfer failures, we maintain compatibility while improving the experience for simple use cases.

**Recommendation:** Implement Option 1 with default `autoTransfer = false`.
