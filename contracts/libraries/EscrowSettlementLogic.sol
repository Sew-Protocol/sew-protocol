// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.37;

import '../types/EscrowTypes.sol';

/**
 * @title EscrowSettlementLogic
 * @notice Compile-time settlement derivation, internalized from the formerly
 *         externally deployed SettlementOps contract.
 *
 * @dev Preserves the SettlementOps separation of concerns:
 *      - derive only: returns a result/plan, never mutates escrow state
 *      - no callbacks, no escrow storage access
 *      - all inputs are explicit
 *
 *      The escrow remains the sole authoritative mutator: it calls these
 *      functions, then applies the derived result to escrow state. This keeps
 *      the derive -> result -> apply boundary while removing the runtime trust
 *      and deployment boundary.
 *
 *      INTENTIONAL SEMANTIC DELTA (2a):
 *      The refactored contract has no "settlement calculator unconfigured"
 *      state. All domain behavior is equivalent when the previous SettlementOps
 *      dependency was correctly configured. Differential tests assert exactly
 *      that equivalence and must not attempt to recreate the obsolete
 *      unconfigured state.
 */
library EscrowSettlementLogic {
    // PendingSettlement struct (matches BaseEscrow.PendingSettlement)
    struct SettlementPendingSettlement {
        bool exists;
        bool isRelease;
        uint256 appealDeadline;
        bytes32 resolutionHash;
    }

    /// @dev Result of resolution execution computation.
    struct ResolutionResult {
        bool shouldExecute; // Whether resolution should execute immediately
        bool isRelease; // True to release, false to cancel
        uint256 appealDeadline; // Appeal deadline timestamp (0 if immediate)
        bool isFinalRound; // Whether this is the final round (no appeal window)
    }

    /// @notice Action plan for settlement automation.
    struct ActionPlan {
        uint8 action; // 0 = none, 1 = release, 2 = cancel, 3 = set pending
        bool isRelease; // If action == 3 (set pending)
        uint256 appealDeadline; // If action == 3
        bytes32 resolutionHash; // If action == 3
        bool needsFinalization; // Whether to call finalizeDispute on resolution module
    }

    /**
     * @notice Compute resolution execution parameters.
     * @param resolutionModule Address of the resolution module
     * @param workflowId Escrow workflow ID
     * @param isRelease True to release to recipient, false to cancel/refund to sender
     * @param timeoutConfig Timeout configuration (snapshotted by the escrow)
     * @param escrowContract Address reported to the resolution module as the escrow
     * @return result Resolution execution result
     * @dev Compute-only: does not modify escrow state.
     */
    function computeResolutionExecution(
        address resolutionModule,
        uint256 workflowId,
        bool isRelease,
        TimeoutConfig memory timeoutConfig,
        address escrowContract
    ) internal view returns (ResolutionResult memory result) {
        result.isRelease = isRelease;
        result.shouldExecute = false;
        result.appealDeadline = 0;
        result.isFinalRound = false;

        // Query appeal deadline from resolution module
        // For DecentralizedResolutionModule, this is stored in DisputeMetadata.appealDeadline[currentRound]
        // For other modules, fall back to timeoutConfig.appealWindowDuration
        if (resolutionModule == address(0)) {
            // No resolution module - use global appeal window duration
            if (timeoutConfig.appealWindowDuration == 0) {
                result.shouldExecute = true;
            } else {
                result.appealDeadline = block.timestamp + timeoutConfig.appealWindowDuration;
            }
            return result;
        }

        // Validate module is still a valid contract before calling
        if (resolutionModule.code.length == 0) {
            // Module no longer exists - fallback to global appeal window duration
            if (timeoutConfig.appealWindowDuration == 0) {
                result.shouldExecute = true;
            } else {
                result.appealDeadline = block.timestamp + timeoutConfig.appealWindowDuration;
            }
            return result;
        }

        // Try to get appeal deadline and current round from module
        // Use staticcall to query view function
        (bool success, bytes memory data) = resolutionModule.staticcall(
            abi.encodeWithSignature('getAppealDeadlineAndRound(uint256,address)', workflowId, escrowContract)
        );

        if (success && data.length > 0) {
            // Decode return values: (uint256 appealDeadline, uint8 currentRound, bool isFinalRound)
            (result.appealDeadline, , result.isFinalRound) = abi.decode(data, (uint256, uint8, bool));
        } else {
            // Module doesn't support getAppealDeadlineAndRound - fallback to global config
            if (timeoutConfig.appealWindowDuration == 0) {
                result.shouldExecute = true;
            } else {
                result.appealDeadline = block.timestamp + timeoutConfig.appealWindowDuration;
            }
        }

        // If final round (MAX_ROUND), execute immediately (no appeal window)
        if (result.isFinalRound) {
            result.shouldExecute = true;
        } else if (result.appealDeadline == 0 && !result.shouldExecute) {
            // Module returned 0 deadline - check global config as fallback
            if (timeoutConfig.appealWindowDuration == 0) {
                result.shouldExecute = true;
            } else {
                result.appealDeadline = block.timestamp + timeoutConfig.appealWindowDuration;
            }
        }

        return result;
    }

    /**
     * @notice Compute pending settlement execution check.
     * @param workflowId Escrow workflow ID (unused; kept for interface parity)
     * @param pending Pending settlement data
     * @param escrowState Current escrow state
     * @return canExecute Whether settlement can be executed
     * @return isRelease True if pending release, false if pending cancel
     * @dev Compute-only: does not modify escrow state.
     */
    function computePendingSettlementExecution(
        uint256 workflowId,
        SettlementPendingSettlement memory pending,
        EscrowState escrowState
    ) internal view returns (bool canExecute, bool isRelease) {
        // Intentionally unused (kept for interface/telemetry parity with other ops functions)
        workflowId;

        // Verify pending settlement exists
        if (!pending.exists) {
            return (false, false);
        }

        // Verify appeal window has expired
        if (block.timestamp < pending.appealDeadline) {
            return (false, false);
        }

        // Verify state is still DISPUTED (not already executed or escalated)
        if (escrowState != EscrowState.DISPUTED) {
            return (false, false);
        }

        return (true, pending.isRelease);
    }

    /**
     * @notice Compute timed actions (auto-release or auto-cancel).
     * @param et Escrow transfer data
     * @param pending Pending settlement data
     * @param timeoutConfig Snapshotted timeout configuration
     * @param pendingAutoCancelEnabled Snapshotted pending auto-cancel policy
     * @param disputeRaisedTimestamp When the dispute was raised (0 if no dispute)
     * @return actionType 0 = none, 1 = auto-release, 2 = auto-cancel, 3 = pending settlement,
     *         4 = auto-cancel-disputed, 5 = dispute-timeout
     * @return isRelease True if release action, false if cancel
     * @dev Compute-only: does not modify escrow state.
     */
    function computeTimedActions(
        uint256 /* workflowId */,
        EscrowTransfer memory et,
        SettlementPendingSettlement memory pending,
        TimeoutConfig memory timeoutConfig,
        bool pendingAutoCancelEnabled,
        uint256 disputeRaisedTimestamp
    ) internal view returns (uint8 actionType, bool isRelease) {
        // Check for pending settlement execution (appeal window enforcement)
        if (
            pending.exists &&
            block.timestamp >= pending.appealDeadline &&
            et.escrowState == EscrowState.DISPUTED
        ) {
            return (ACTION_EXECUTE_PENDING, pending.isRelease);
        }

        // auto-cancel-time passed on DISPUTED escrow — griefing protection.
        // Without this check a frivolous dispute raised before auto-cancel-time
        // orphans the deadline, forcing escrow into longer max-dispute-duration path.
        if (et.escrowState == EscrowState.DISPUTED && et.autoCancelTime > 0
            && block.timestamp >= et.autoCancelTime && !pending.exists
        ) {
            return (ACTION_AUTO_CANCEL_DISPUTED, false);
        }

        // max-dispute-duration elapsed on DISPUTED escrow — liveness timeout.
        if (
            et.escrowState == EscrowState.DISPUTED &&
            !pending.exists &&
            timeoutConfig.maxDisputeDuration > 0 &&
            disputeRaisedTimestamp > 0 &&
            block.timestamp >= disputeRaisedTimestamp + timeoutConfig.maxDisputeDuration
        ) {
            return (ACTION_DISPUTE_TIMEOUT, false);
        }

        // Check for auto-release/auto-cancel (only for PENDING state)
        if (et.escrowState != EscrowState.PENDING) {
            return (ACTION_NONE, false);
        }

        if (et.autoReleaseTime > 0 && block.timestamp >= et.autoReleaseTime) {
            return (ACTION_AUTO_RELEASE, true);
        } else if ((pendingAutoCancelEnabled || et.autoCancelTime > 0) && et.autoCancelTime > 0 && block.timestamp >= et.autoCancelTime) {
            return (ACTION_AUTO_CANCEL, false);
        }

        return (ACTION_NONE, false);
    }

    /**
     * @notice Backward-compatible overload using timeout config to infer pending auto-cancel policy.
     * @dev Preserves existing call sites while allowing explicit policy calls from upgraded escrow.
     */
    function computeTimedActions(
        uint256 workflowId,
        EscrowTransfer memory et,
        SettlementPendingSettlement memory pending,
        TimeoutConfig memory timeoutConfig
    ) internal view returns (uint8 actionType, bool isRelease) {
        bool pendingAutoCancelEnabled = timeoutConfig.defaultAutoCancelDelay > 0;
        return computeTimedActions(workflowId, et, pending, timeoutConfig, pendingAutoCancelEnabled, 0);
    }
}
