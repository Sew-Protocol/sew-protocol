// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

// TEMP FILE: Implementation for Phase 4 - Settlement Automation Extraction
// This file shows the changes needed to BaseEscrow.sol

// ============ REMOVE THESE FUNCTIONS ============

// 1. Remove automateTimedActions() (lines ~464-525)
//    - Entire function body removed
//    - Replaced with call to SettlementOps.computeNextAction() + _applyActionPlan()

// 2. Remove executePendingSettlement() (lines ~914-969)
//    - Entire function body removed
//    - Replaced with call to SettlementOps.computeNextAction() + _applyActionPlan()

// ============ ADD THIS FUNCTION ============

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

// ============ REPLACE automateTimedActions() CALLERS ============

// Replace external calls to automateTimedActions() with:
function automateTimedActions(uint256 workflowId) external nonReentrant returns (bool) {
    _validateWorkflowId(workflowId);
    EscrowTransfer memory et = escrowTransfers[workflowId];
    PendingSettlement memory pending = pendingSettlements[workflowId];
    
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
    if (plan.action == 3 || (plan.action == 1 || plan.action == 2) && pending.exists) {
        delete pendingSettlements[workflowId];
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
    } else if (plan.action == 3 || (plan.action == 1 || plan.action == 2) && pending.exists) {
        emit PendingSettlementExecuted(workflowId, plan.isRelease);
    }
    
    return true;
}

// ============ REPLACE executePendingSettlement() CALLERS ============

// Replace external calls to executePendingSettlement() with:
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

// ============ SIMPLIFY _executeResolution() ============

// The _executeResolution() function (lines ~850-905) can be simplified:
// - Keep the resolution module validation
// - Keep the SettlementOps.computeResolutionExecution() call
// - Replace the branching logic with _applyActionPlan() if needed
// - The function already sets pendingSettlements correctly, so minimal changes needed
