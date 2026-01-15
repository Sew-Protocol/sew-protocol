// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import '../types/EscrowTypes.sol';

/**
 * @title DisputeManagementLibrary
 * @notice Library for dispute management logic to reduce BaseEscrow size
 */
library DisputeManagementLibrary {
    /**
     * @dev Check if a dispute has timed out
     * @param workflowId Escrow ID
     * @param escrowState Current escrow state
     * @param raisedTimestamp Timestamp when dispute was raised
     * @param maxDuration Maximum allowed dispute duration
     * @return timedOut True if timed out
     * @return timeRemaining Seconds until timeout
     */
    function isTimedOut(
        uint256 workflowId,
        EscrowState escrowState,
        uint256 raisedTimestamp,
        uint256 maxDuration
    ) internal view returns (bool timedOut, uint256 timeRemaining) {
        if (escrowState != EscrowState.DISPUTED || raisedTimestamp == 0) {
            return (false, 0);
        }

        uint256 elapsed = block.timestamp - raisedTimestamp;
        if (elapsed >= maxDuration) {
            return (true, 0);
        }

        return (false, maxDuration - elapsed);
    }
}
