// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

// TEMP FILE: Implementation for Phase 3 - Add isDisputeTimedOut to EscrowViewContract
// This file shows the changes needed to EscrowViewContract.sol

import './BaseEscrow.sol';
import './types/EscrowTypes.sol';
import './libraries/DisputeManagementLibrary.sol';

contract EscrowViewContract {
    // ... existing code ...

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

    // ... rest of existing code ...
}
