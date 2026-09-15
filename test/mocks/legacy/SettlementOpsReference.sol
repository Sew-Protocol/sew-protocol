// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.37;

// ============================================================================
// TEST-ONLY REFERENCE IMPLEMENTATION.
// Preserved solely for differential testing of EscrowSettlementLogic.
// Not part of the protocol architecture or deployment.
// ============================================================================

import '@openzeppelin/contracts/access/AccessControl.sol';
import '../../../contracts/shared/interfaces/IResolutionModule.sol';
import '../../../contracts/types/EscrowTypes.sol';

/**
 * @title SettlementOpsReference
 * @notice Formerly the externally deployed SettlementOps contract, retained as a
 *         test oracle only. Its compute semantics are the reference against which
 *         EscrowSettlementLogic is differentially fuzzed.
 *
 *      Key design principles:
 *      - Compute → Apply: Returns settlement result, BaseEscrow applies to state
 *      - No callbacks: Does not write to BaseEscrow state
 *      - View-ish: Could be view functions but may query modules
 */
contract SettlementOpsReference is AccessControl {
    // ============ Role Constants ============
    bytes32 public constant ROLE_ESCROW_CONTRACT = keccak256('ROLE_ESCROW_CONTRACT');
    bytes32 public constant ROLE_TIMELOCK = keccak256('ROLE_TIMELOCK');

    // ============ Custom Errors ============
    error ZeroOwner();
    // PendingSettlement struct (matches BaseEscrow.PendingSettlement)
    // Note: This must match BaseEscrow.PendingSettlement exactly
    struct SettlementPendingSettlement {
        bool exists;
        bool isRelease;
        uint256 appealDeadline;
        bytes32 resolutionHash;
    }
    /**
     * @dev Result of resolution execution computation
     */
    struct ResolutionResult {
        bool shouldExecute; // Whether resolution should execute immediately
        bool isRelease; // True to release, false to cancel
        uint256 appealDeadline; // Appeal deadline timestamp (0 if immediate)
        bool isFinalRound; // Whether this is the final round (no appeal window)
    }

    /**
     * @notice Constructor for SettlementOpsReference
     * @param initialOwner Address that will receive DEFAULT_ADMIN_ROLE (for initial setup only)
     */
    constructor(address initialOwner) {
        if (initialOwner == address(0)) revert ZeroOwner();
        _grantRole(DEFAULT_ADMIN_ROLE, initialOwner);
        _grantRole(ROLE_TIMELOCK, initialOwner);
    }

    /**
     * @notice Register an escrow contract (grants it ROLE_ESCROW_CONTRACT)
     * @param escrowContract Address of the escrow contract
     */
    function registerEscrowContract(address escrowContract) external onlyRole(ROLE_TIMELOCK) {
        if (escrowContract == address(0)) revert InvalidAddress(ADDR_ESCROW_CONTRACT, escrowContract);
        _grantRole(ROLE_ESCROW_CONTRACT, escrowContract);
    }

    /**
     * @notice Action plan for settlement automation
     */
    struct ActionPlan {
        uint8 action; // 0 = none, 1 = release, 2 = cancel, 3 = set pending
        bool isRelease; // If action == 3 (set pending)
        uint256 appealDeadline; // If action == 3
        bytes32 resolutionHash; // If action == 3
        bool needsFinalization; // Whether to call finalizeDispute on resolution module
    }

    function computeResolutionExecution(
        address resolutionModule,
        uint256 workflowId,
        bool isRelease,
        TimeoutConfig memory timeoutConfig
    ) external view onlyRole(ROLE_ESCROW_CONTRACT) returns (ResolutionResult memory result) {
        result.isRelease = isRelease;
        result.shouldExecute = false;
        result.appealDeadline = 0;
        result.isFinalRound = false;

        if (resolutionModule == address(0)) {
            if (timeoutConfig.appealWindowDuration == 0) {
                result.shouldExecute = true;
            } else {
                result.appealDeadline = block.timestamp + timeoutConfig.appealWindowDuration;
            }
            return result;
        }

        if (resolutionModule.code.length == 0) {
            if (timeoutConfig.appealWindowDuration == 0) {
                result.shouldExecute = true;
            } else {
                result.appealDeadline = block.timestamp + timeoutConfig.appealWindowDuration;
            }
            return result;
        }

        (bool success, bytes memory data) = resolutionModule.staticcall(
            abi.encodeWithSignature('getAppealDeadlineAndRound(uint256,address)', workflowId, _msgSender())
        );

        if (success && data.length > 0) {
            (result.appealDeadline, , result.isFinalRound) = abi.decode(data, (uint256, uint8, bool));
        } else {
            if (timeoutConfig.appealWindowDuration == 0) {
                result.shouldExecute = true;
            } else {
                result.appealDeadline = block.timestamp + timeoutConfig.appealWindowDuration;
            }
        }

        if (result.isFinalRound) {
            result.shouldExecute = true;
        } else if (result.appealDeadline == 0 && !result.shouldExecute) {
            if (timeoutConfig.appealWindowDuration == 0) {
                result.shouldExecute = true;
            } else {
                result.appealDeadline = block.timestamp + timeoutConfig.appealWindowDuration;
            }
        }

        return result;
    }

    function computePendingSettlementExecution(
        uint256 workflowId,
        SettlementPendingSettlement memory pending,
        EscrowState escrowState
    ) external view onlyRole(ROLE_ESCROW_CONTRACT) returns (bool canExecute, bool isRelease) {
        workflowId;

        if (!pending.exists) {
            return (false, false);
        }

        if (block.timestamp < pending.appealDeadline) {
            return (false, false);
        }

        if (escrowState != EscrowState.DISPUTED) {
            return (false, false);
        }

        return (true, pending.isRelease);
    }

    function computeTimedActions(
        uint256 /* workflowId */,
        EscrowTransfer memory et,
        SettlementPendingSettlement memory pending,
        TimeoutConfig memory timeoutConfig,
        bool pendingAutoCancelEnabled,
        uint256 disputeRaisedTimestamp
    ) external view returns (uint8 actionType, bool isRelease) {
        if (
            pending.exists &&
            block.timestamp >= pending.appealDeadline &&
            et.escrowState == EscrowState.DISPUTED
        ) {
            return (3, pending.isRelease);
        }

        if (et.escrowState == EscrowState.DISPUTED && et.autoCancelTime > 0
            && block.timestamp >= et.autoCancelTime && !pending.exists
        ) {
            return (ACTION_AUTO_CANCEL_DISPUTED, false);
        }

        if (
            et.escrowState == EscrowState.DISPUTED &&
            !pending.exists &&
            timeoutConfig.maxDisputeDuration > 0 &&
            disputeRaisedTimestamp > 0 &&
            block.timestamp >= disputeRaisedTimestamp + timeoutConfig.maxDisputeDuration
        ) {
            return (ACTION_DISPUTE_TIMEOUT, false);
        }

        if (et.escrowState != EscrowState.PENDING) {
            return (0, false);
        }

        if (et.autoReleaseTime > 0 && block.timestamp >= et.autoReleaseTime) {
            return (1, true);
        } else if ((pendingAutoCancelEnabled || et.autoCancelTime > 0) && et.autoCancelTime > 0 && block.timestamp >= et.autoCancelTime) {
            return (2, false);
        }

        return (0, false);
    }

    function computeTimedActions(
        uint256 workflowId,
        EscrowTransfer memory et,
        SettlementPendingSettlement memory pending,
        TimeoutConfig memory timeoutConfig
    ) external view returns (uint8 actionType, bool isRelease) {
        bool pendingAutoCancelEnabled = timeoutConfig.defaultAutoCancelDelay > 0;
        return this.computeTimedActions(workflowId, et, pending, timeoutConfig, pendingAutoCancelEnabled, 0);
    }
}
