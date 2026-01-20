// TEMP FILE: Phase 4 - Add ActionPlan and computeNextAction() to SettlementOps.sol
// Location: Add after ResolutionResult struct (around line 39) and after computeTimedActions() (around line 167)

// ADD THIS STRUCT (after ResolutionResult struct, around line 39):
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

// ADD THIS FUNCTION (after computeTimedActions(), around line 167):
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
