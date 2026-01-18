# Phase 4: Settlement Automation Extraction

## Current Functions in BaseEscrow

1. `automateTimedActions(uint256)` - Line ~464
   - Checks auto-release/cancel times
   - Calls `_releaseEscrowTransfer` or `_cancelAndRefund`
   - Returns bool

2. `executePendingSettlement(uint256)` - Line ~914
   - Executes pending settlement after appeal window
   - Calls `_releaseEscrowTransfer` or `_cancelAndRefund`
   - Returns bool

3. `_executeResolution()` - Line ~850+
   - Complex branching logic for resolution execution
   - Sets pending settlements
   - Calls release/cancel functions

## Target Design

### SettlementOps.computeNextAction()
```solidity
struct ActionPlan {
    uint8 action; // 0 = none, 1 = release, 2 = cancel, 3 = set pending
    bool isRelease; // If action == 3 (set pending)
    uint256 appealDeadline; // If action == 3
    bytes32 resolutionHash; // If action == 3
}

function computeNextAction(
    uint256 workflowId,
    EscrowTransfer memory et,
    PendingSettlement memory pending,
    TimeoutConfig memory timeoutConfig,
    uint256 disputeRaisedTimestamp
) external view returns (ActionPlan memory);
```

### BaseEscrow._applyActionPlan()
```solidity
function _applyActionPlan(uint256 workflowId, ActionPlan memory plan) internal {
    if (plan.action == 1) {
        _releaseEscrowTransfer(workflowId);
    } else if (plan.action == 2) {
        _cancelAndRefund(workflowId);
    } else if (plan.action == 3) {
        pendingSettlements[workflowId] = PendingSettlement({
            exists: true,
            isRelease: plan.isRelease,
            appealDeadline: plan.appealDeadline,
            resolutionHash: plan.resolutionHash
        });
        emit PendingSettlementSet(workflowId, plan.isRelease, plan.appealDeadline);
    }
}
```

## Changes Required

### SettlementOps.sol
- Add `ActionPlan` struct
- Add `computeNextAction()` function
- Move logic from `automateTimedActions()` and `executePendingSettlement()`

### BaseEscrow.sol
- Remove `automateTimedActions()` function
- Remove `executePendingSettlement()` function
- Simplify `_executeResolution()` to use `SettlementOps.computeNextAction()`
- Add `_applyActionPlan()` function
- Update callers of removed functions
