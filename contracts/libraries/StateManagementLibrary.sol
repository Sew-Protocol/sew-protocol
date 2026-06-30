// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import '../types/EscrowTypes.sol';

/**
 * @title StateManagementLibrary
 * @notice Library for escrow state transitions and event emission
 * @dev Extracted from BaseEscrow to reduce contract size
 */
library StateManagementLibrary {
    /// @dev Revert when attempting to transition from a terminal state.
    error AlreadyTerminal(uint256 workflowId, EscrowState currentState);

    /**
     * @dev Transition escrow to RELEASED state
     * @param et EscrowTransfer storage reference
     * @return oldStatus Previous state
     */
    function transitionToReleased(
        EscrowTransfer storage et,
        uint256 workflowId
    ) internal returns (EscrowState oldStatus) {
        oldStatus = et.escrowState;
        if (oldStatus == EscrowState.RELEASED || oldStatus == EscrowState.REFUNDED) {
            revert AlreadyTerminal(workflowId, oldStatus);
        }
        et.escrowState = EscrowState.RELEASED;
        return oldStatus;
    }

    /**
     * @dev Transition escrow to REFUNDED state
     * @param et EscrowTransfer storage reference
     * @return oldStatus Previous state
     */
    function transitionToRefunded(
        EscrowTransfer storage et,
        uint256 workflowId
    ) internal returns (EscrowState oldStatus) {
        oldStatus = et.escrowState;
        if (oldStatus == EscrowState.RELEASED || oldStatus == EscrowState.REFUNDED) {
            revert AlreadyTerminal(workflowId, oldStatus);
        }
        et.escrowState = EscrowState.REFUNDED;
        return oldStatus;
    }

    /**
     * @dev Transition escrow to RESOLVED state
     * @param et EscrowTransfer storage reference
     * @return oldStatus Previous state
     */
    function transitionToResolved(
        EscrowTransfer storage et,
        uint256 workflowId
    ) internal returns (EscrowState oldStatus) {
        oldStatus = et.escrowState;
        if (oldStatus == EscrowState.RELEASED || oldStatus == EscrowState.REFUNDED) {
            revert AlreadyTerminal(workflowId, oldStatus);
        }
        et.escrowState = EscrowState.RESOLVED;
        return oldStatus;
    }

    /**
     * @dev Transition escrow to DISPUTED state
     * @param et EscrowTransfer storage reference
     * @param isSender True if sender is raising dispute, false if recipient
     * @return oldStatus Previous state
     */
    function transitionToDisputed(
        EscrowTransfer storage et,
        uint256 workflowId,
        bool isSender
    ) internal returns (EscrowState oldStatus) {
        oldStatus = et.escrowState;
        if (oldStatus != EscrowState.PENDING) {
            revert AlreadyTerminal(workflowId, oldStatus);
        }
        et.escrowState = EscrowState.DISPUTED;

        if (isSender) {
            et.senderStatus = SenderStatus.RAISE_DISPUTE;
            et.recipientStatus = RecipientStatus.NONE;
        } else {
            et.recipientStatus = RecipientStatus.RAISE_DISPUTE;
            et.senderStatus = SenderStatus.NONE;
        }

        return oldStatus;
    }
}
