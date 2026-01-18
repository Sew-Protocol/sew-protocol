// TEMP FILE: Phase 4 - Replace automateTimedActions() and executePendingSettlement() in BaseEscrow.sol
// Also add _applyActionPlan() and _finalizeDisputeInModule() helper functions

// ============ ADD THESE HELPER FUNCTIONS (after _executeResolution(), around line 905) ============

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

// ============ REPLACE automateTimedActions() (lines ~464-525) ============

// REPLACE ENTIRE FUNCTION WITH:
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

// ============ REPLACE executePendingSettlement() (lines ~914-969) ============

// REPLACE ENTIRE FUNCTION WITH:
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
