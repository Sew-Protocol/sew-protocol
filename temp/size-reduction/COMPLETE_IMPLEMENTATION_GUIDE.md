# Complete Implementation Guide for Size Reduction

## Overview

This guide provides step-by-step instructions for implementing Phases 3 and 4 of the size reduction plan.

**Current Size**: ~31.3 KB  
**Target Size**: 24 KB  
**Expected Reduction**: 2-5 KB from Phases 3 & 4  
**Combined with Previous**: 6.17-11.17 KB total reduction

---

## Phase 3: Remove View Functions (1-3 KB expected)

### Step 1: Remove `isDisputeTimedOut()` from BaseEscrow.sol

**Location**: Lines ~605-616

**Action**: Delete the entire function:
```solidity
function isDisputeTimedOut(
    uint256 workflowId
) external view returns (bool isTimedOut, uint256 timeRemaining) {
    _validateWorkflowId(workflowId);
    (bool timedOut, uint256 remaining) = DisputeManagementLibrary.isTimedOut(
        workflowId,
        escrowTransfers[workflowId].escrowState,
        disputeRaisedTimestamp[workflowId],
        timeoutConfig.maxDisputeDuration
    );
    return (timedOut, remaining);
}
```

**Impact**: 
- Removes ~12 lines of code
- Saves ~0.3-0.5 KB

### Step 2: Add `isDisputeTimedOut()` to EscrowViewContract.sol

**Location**: After `getTimeoutConfig()` function (around line 165)

**Action**: Add this function:
```solidity
/**
 * @notice Check if a dispute has timed out
 * @param workflowId The escrow ID
 * @return isTimedOut Whether dispute exceeded maxDisputeDuration
 * @return timeRemaining Seconds remaining until timeout (0 if timed out)
 */
function isDisputeTimedOut(
    uint256 workflowId
) external view returns (bool isTimedOut, uint256 timeRemaining) {
    EscrowTransfer memory et = escrowContract.getEscrowTransfer(workflowId);
    (bool timedOut, uint256 remaining) = DisputeManagementLibrary.isTimedOut(
        workflowId,
        et.escrowState,
        escrowContract.disputeRaisedTimestamp(workflowId),
        escrowContract.timeoutConfig().maxDisputeDuration
    );
    return (timedOut, remaining);
}
```

**Also add import** (if not already present):
```solidity
import '../libraries/DisputeManagementLibrary.sol';
```

**Impact**: 
- Adds function to EscrowViewContract (doesn't affect BaseEscrow size)
- Frontend can use EscrowViewContract instead

### Step 3: Update Tests

**Action**: Update any tests that call `isDisputeTimedOut()` on BaseEscrow to use EscrowViewContract instead.

**Files to check**:
- `test/foundry/**/*.sol` - Search for `isDisputeTimedOut`

---

## Phase 4: Settlement Automation Extraction (1-2 KB expected)

### Step 1: Add ActionPlan struct to SettlementOps.sol

**Location**: After `ResolutionResult` struct (around line 39)

**Action**: Add this struct:
```solidity
/**
 * @notice Action plan for settlement automation
 * @dev Returned by computeNextAction() to guide BaseEscrow._applyActionPlan()
 */
struct ActionPlan {
    uint8 action; // 0 = none, 1 = release, 2 = cancel, 3 = set pending
    bool isRelease; // If action == 3 (set pending)
    uint256 appealDeadline; // If action == 3
    bytes32 resolutionHash; // If action == 3
    bool needsFinalization; // Whether to call finalizeDispute on resolution module
}
```

### Step 2: Add `computeNextAction()` to SettlementOps.sol

**Location**: After `computeTimedActions()` function (around line 167)

**Action**: Add this function:
```solidity
/**
 * @notice Compute next action for an escrow based on current state
 * @param workflowId The escrow ID
 * @param et Escrow transfer data
 * @param pending Current pending settlement (if any)
 * @param timeoutConfig Timeout configuration
 * @param disputeRaisedTimestamp When dispute was raised (0 if not disputed)
 * @return plan Action plan to execute
 * @dev Consolidates logic from automateTimedActions() and executePendingSettlement()
 *      This replaces the need for separate computeTimedActions() and computePendingSettlementExecution()
 */
function computeNextAction(
    uint256 workflowId,
    EscrowTransfer memory et,
    SettlementPendingSettlement memory pending,
    TimeoutConfig memory timeoutConfig,
    uint256 disputeRaisedTimestamp
) external view returns (ActionPlan memory plan) {
    // Check for pending settlement execution (appeal window enforcement)
    if (pending.exists) {
        if (block.timestamp >= pending.appealDeadline && et.escrowState == EscrowState.DISPUTED) {
            // Appeal window expired - execute pending settlement
            plan.action = pending.isRelease ? 1 : 2; // 1 = release, 2 = cancel
            plan.needsFinalization = true; // Finalize dispute in resolution module
            return plan;
        }
        // Appeal window still open
        plan.action = 0; // No action yet
        return plan;
    }
    
    // Check for auto-timeout actions (only if not disputed)
    if (et.escrowState == EscrowState.PENDING && disputeRaisedTimestamp == 0) {
        if (et.autoReleaseTime > 0 && block.timestamp >= et.autoReleaseTime) {
            plan.action = 1; // Auto-release
            return plan;
        }
        if (et.autoCancelTime > 0 && block.timestamp >= et.autoCancelTime) {
            plan.action = 2; // Auto-cancel
            return plan;
        }
    }
    
    // No action needed
    plan.action = 0;
    return plan;
}
```

**Note**: This function consolidates `computeTimedActions()` and `computePendingSettlementExecution()` logic. The old functions can be kept for backward compatibility or removed later.

### Step 3: Add `_applyActionPlan()` to BaseEscrow.sol

**Location**: After `_executeResolution()` function (around line 905)

**Action**: Add these functions:
```solidity
/**
 * @notice Apply action plan from SettlementOps
 * @param workflowId The escrow ID
 * @param plan Action plan to execute
 * @dev Minimal function that only handles state transitions and emits events
 */
function _applyActionPlan(uint256 workflowId, SettlementOps.ActionPlan memory plan) internal {
    if (plan.action == 1) {
        // Release
        _releaseEscrowTransfer(workflowId);
        if (plan.needsFinalization) {
            _finalizeDisputeInModule(workflowId);
        }
    } else if (plan.action == 2) {
        // Cancel
        _cancelAndRefund(workflowId);
        if (plan.needsFinalization) {
            _finalizeDisputeInModule(workflowId);
        }
    } else if (plan.action == 3) {
        // Set pending settlement
        pendingSettlements[workflowId] = PendingSettlement({
            exists: true,
            isRelease: plan.isRelease,
            appealDeadline: plan.appealDeadline,
            resolutionHash: plan.resolutionHash
        });
        emit PendingSettlementSet(workflowId, plan.isRelease, plan.appealDeadline);
    }
}

/**
 * @notice Finalize dispute in resolution module (best-effort)
 * @param workflowId The escrow ID
 * @dev Helper function to call finalizeDispute on resolution module if supported
 */
function _finalizeDisputeInModule(uint256 workflowId) internal {
    IResolutionModule resolutionModule = _getResolutionModule(workflowId);
    if (address(resolutionModule) != address(0)) {
        // Try to call finalizeDispute if it exists (DecentralizedResolutionModule)
        // This is a best-effort call - if it fails, we ignore it
        (bool success, ) = address(resolutionModule).call(
            abi.encodeWithSignature('finalizeDispute(uint256)', workflowId)
        );
        success; // Ignore failure
    }
}
```

### Step 4: Replace `automateTimedActions()` in BaseEscrow.sol

**Location**: Lines ~464-525

**Action**: Replace entire function with:
```solidity
/**
 * @notice Automatically execute timed actions (auto-release or auto-cancel)
 * @param workflowId The escrow ID
 * @return success Whether an action was executed
 * @dev Checks auto-release and auto-cancel times and executes if conditions are met.
 *      Can be called by anyone once the time conditions are satisfied.
 */
function automateTimedActions(uint256 workflowId) external nonReentrant returns (bool) {
    _validateWorkflowId(workflowId);
    EscrowTransfer memory et = escrowTransfers[workflowId];
    PendingSettlement storage pending = pendingSettlements[workflowId];
    
    if (address(settlementOps) == address(0)) return false;
    
    SettlementOps.SettlementPendingSettlement memory pendingMem = SettlementOps.SettlementPendingSettlement({
        exists: pending.exists,
        isRelease: pending.isRelease,
        appealDeadline: pending.appealDeadline,
        resolutionHash: pending.resolutionHash
    });
    
    SettlementOps.ActionPlan memory plan = settlementOps.computeNextAction(
        workflowId,
        et,
        pendingMem,
        timeoutConfig,
        disputeRaisedTimestamp[workflowId]
    );
    
    if (plan.action == 0) return false;
    
    // Clear pending settlement if executing pending settlement
    if (plan.action == 1 || plan.action == 2) {
        if (pending.exists) {
            delete pendingSettlements[workflowId];
        }
    }
    
    // Apply the action plan
    _applyActionPlan(workflowId, plan);
    
    // Emit appropriate events
    if (plan.action == 1) {
        emit TimeoutExecuted(workflowId, 0);
        emit EscrowTransferAutoReleased(workflowId, et.to, et.amountAfterFee);
    } else if (plan.action == 2) {
        emit TimeoutExecuted(workflowId, 1);
        emit EscrowTransferAutoCancelled(workflowId, et.from, et.amountAfterFee);
    } else if (pending.exists) {
        emit PendingSettlementExecuted(workflowId, plan.isRelease);
    }
    
    return true;
}
```

**Impact**: 
- Reduces function from ~62 lines to ~45 lines
- Removes branching logic (moved to SettlementOps)
- Saves ~0.5-1 KB

### Step 5: Replace `executePendingSettlement()` in BaseEscrow.sol

**Location**: Lines ~914-969

**Action**: Replace entire function with:
```solidity
/**
 * @notice Execute pending settlement after appeal window expires
 * @param workflowId The escrow workflow ID
 * @dev Can be called by anyone once appeal window has expired
 *      Executes the pending release or cancel that was stored during resolution
 *      Optionally finalizes the dispute in the resolution module if not already finalized
 */
function executePendingSettlement(uint256 workflowId) external nonReentrant {
    _validateWorkflowId(workflowId);
    EscrowTransfer memory et = escrowTransfers[workflowId];
    PendingSettlement storage pending = pendingSettlements[workflowId];
    
    if (address(settlementOps) == address(0)) {
        revert ZeroSettlementOps();
    }
    
    // Validate pending settlement exists
    if (!pending.exists) {
        revert NoPendingSettlement(workflowId);
    }
    
    SettlementOps.SettlementPendingSettlement memory pendingMem = SettlementOps.SettlementPendingSettlement({
        exists: pending.exists,
        isRelease: pending.isRelease,
        appealDeadline: pending.appealDeadline,
        resolutionHash: pending.resolutionHash
    });
    
    SettlementOps.ActionPlan memory plan = settlementOps.computeNextAction(
        workflowId,
        et,
        pendingMem,
        timeoutConfig,
        disputeRaisedTimestamp[workflowId]
    );
    
    // Validate can execute
    if (plan.action == 0) {
        if (block.timestamp < pending.appealDeadline) {
            revert AppealWindowNotExpired(workflowId, pending.appealDeadline, block.timestamp);
        }
        revert NotInDisputedState(workflowId, et.escrowState);
    }
    
    // Clear pending settlement before execution (prevent reentrancy)
    delete pendingSettlements[workflowId];
    
    // Apply the action plan
    _applyActionPlan(workflowId, plan);
    
    emit PendingSettlementExecuted(workflowId, plan.isRelease);
}
```

**Impact**: 
- Reduces function from ~56 lines to ~45 lines
- Removes branching logic (moved to SettlementOps)
- Saves ~0.3-0.5 KB

### Step 6: Simplify `_executeResolution()` (Optional)

**Location**: Lines ~850-905

**Current State**: Function already uses `SettlementOps.computeResolutionExecution()` and is relatively clean.

**Action**: Minimal changes needed - the function already sets `pendingSettlements` correctly. Consider using `_applyActionPlan()` for consistency, but this is optional.

---

## Verification Steps

### After Phase 3:
1. ✅ Verify `isDisputeTimedOut()` removed from BaseEscrow
2. ✅ Verify `isDisputeTimedOut()` added to EscrowViewContract
3. ✅ Run tests - update any that call `isDisputeTimedOut()` on BaseEscrow
4. ✅ Measure contract size

### After Phase 4:
1. ✅ Verify `ActionPlan` struct added to SettlementOps
2. ✅ Verify `computeNextAction()` added to SettlementOps
3. ✅ Verify `_applyActionPlan()` and `_finalizeDisputeInModule()` added to BaseEscrow
4. ✅ Verify `automateTimedActions()` simplified
5. ✅ Verify `executePendingSettlement()` simplified
6. ✅ Run tests - verify all settlement flows work
7. ✅ Measure contract size

---

## Expected Results

### Phase 3:
- **Removed**: `isDisputeTimedOut()` function (~12 lines)
- **Added**: `isDisputeTimedOut()` to EscrowViewContract
- **Size Reduction**: ~0.3-0.5 KB

### Phase 4:
- **Removed**: Complex branching logic from `automateTimedActions()` and `executePendingSettlement()`
- **Added**: `ActionPlan` struct, `computeNextAction()`, `_applyActionPlan()`, `_finalizeDisputeInModule()`
- **Size Reduction**: ~0.8-1.5 KB

### Total (Phases 3 & 4):
- **Size Reduction**: ~1.1-2.0 KB
- **Combined with Previous**: 6.17-11.17 KB total
- **Final Size**: ~20-25 KB (should be under 24 KB target)

---

## Notes

1. **Backward Compatibility**: The old `computeTimedActions()` and `computePendingSettlementExecution()` functions in SettlementOps can be kept for backward compatibility if needed, or removed in a future cleanup.

2. **Testing**: Thoroughly test all settlement flows:
   - Auto-release
   - Auto-cancel
   - Pending settlement execution
   - Dispute finalization

3. **Frontend Updates**: Update frontend to use `EscrowViewContract.isDisputeTimedOut()` instead of `BaseEscrow.isDisputeTimedOut()`.

4. **Deployment**: These changes are backward compatible for on-chain functionality, but frontend/integrations may need updates.
