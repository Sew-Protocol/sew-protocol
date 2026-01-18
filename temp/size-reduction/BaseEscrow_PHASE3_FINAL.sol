// TEMP FILE: Phase 3 - Remove isDisputeTimedOut() from BaseEscrow.sol
// Location: Remove lines ~605-616

// DELETE THIS ENTIRE FUNCTION:
/*
    /**
     * @notice Check if a dispute has timed out
     * @param workflowId The escrow ID
     * @return isTimedOut Whether dispute exceeded maxDisputeDuration
     * @return timeRemaining Seconds remaining until timeout (0 if timed out)
     */
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
*/

// That's it - just delete the function. No replacement needed in BaseEscrow.
// EscrowViewContract will provide this functionality.
