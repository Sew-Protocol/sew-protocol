// TEMP FILE: Phase 3 - Add isDisputeTimedOut() to EscrowViewContract.sol
// Location: Add after getTimeoutConfig() function (around line 165)

// ADD THIS IMPORT (if not already present):
import '../libraries/DisputeManagementLibrary.sol';

// ADD THIS FUNCTION:
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
