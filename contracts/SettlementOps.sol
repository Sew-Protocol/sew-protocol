// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import '@openzeppelin/contracts/access/AccessControl.sol';
import './shared/interfaces/IResolutionModule.sol';
import './types/EscrowTypes.sol';

/**
 * @title SettlementOps
 * @notice External contract for settlement execution operations
 * @dev Extracted from BaseEscrow to reduce contract size
 *
 *      Key design principles:
 *      - Compute → Apply: Returns settlement result, BaseEscrow applies to state
 *      - No callbacks: Does not write to BaseEscrow state
 *      - View-ish: Could be view functions but may query modules
 *
 *      Pattern:
 *      BaseEscrow calls: executeResolution(...) or executePendingSettlement(...)
 *      SettlementOps returns: (shouldExecute, isRelease, appealDeadline, isFinalRound)
 *      BaseEscrow applies: Updates state and executes transfer
 */
contract SettlementOps is AccessControl {
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
     * @notice Constructor for SettlementOps
     * @param initialOwner Address that will receive DEFAULT_ADMIN_ROLE (for initial setup only)
     */
    constructor(address initialOwner) {
        if (initialOwner == address(0)) revert ZeroOwner();
        _grantRole(DEFAULT_ADMIN_ROLE, initialOwner);
        // ROLE_TIMELOCK gates registerEscrowContract(), so initialOwner must have it for initial setup.
        _grantRole(ROLE_TIMELOCK, initialOwner);
    }

    /**
     * @notice Register an escrow contract (grants it ROLE_ESCROW_CONTRACT)
     * @param escrowContract Address of the escrow contract
     * @dev Only ROLE_TIMELOCK can register escrow contracts (governance-controlled)
     */
    function registerEscrowContract(address escrowContract) external onlyRole(ROLE_TIMELOCK) {
        if (escrowContract == address(0)) revert InvalidAddress(ADDR_ESCROW_CONTRACT, escrowContract);
        _grantRole(ROLE_ESCROW_CONTRACT, escrowContract);
    }

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

    /**
     * @notice Compute resolution execution parameters
     * @param resolutionModule Address of the resolution module
     * @param workflowId Escrow workflow ID
     * @param isRelease True to release to recipient, false to cancel/refund to sender
     * @param timeoutConfig Global timeout configuration
     * @return result Resolution execution result
     * @dev This function is "compute-only" - it does NOT modify BaseEscrow state.
     *      BaseEscrow will apply the result after receiving it.
     *      Only authorized escrow contracts can call this function
     */
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

        // Query appeal deadline from resolution module
        // For DecentralizedResolutionModule, this is stored in DisputeMetadata.appealDeadline[currentRound]
        // For other modules, fall back to timeoutConfig.appealWindowDuration
        if (resolutionModule == address(0)) {
            // No resolution module - use global appeal window duration
            result.appealDeadline = block.timestamp + timeoutConfig.appealWindowDuration;
            return result;
        }

        // Validate module is still a valid contract before calling
        if (resolutionModule.code.length == 0) {
            // Module no longer exists - fallback to global appeal window duration
            result.appealDeadline = block.timestamp + timeoutConfig.appealWindowDuration;
            return result;
        }

        // Try to get appeal deadline and current round from module
        // Use staticcall to query view function
        (bool success, bytes memory data) = resolutionModule.staticcall(
            abi.encodeWithSignature('getAppealDeadlineAndRound(uint256)', workflowId)
        );

        if (success && data.length > 0) {
            // Decode return values: (uint256 appealDeadline, uint8 currentRound, bool isFinalRound)
            (result.appealDeadline, , result.isFinalRound) = abi.decode(data, (uint256, uint8, bool));
        } else {
            // Module doesn't support getAppealDeadlineAndRound - fallback to global config
            result.appealDeadline = block.timestamp + timeoutConfig.appealWindowDuration;
        }

        // If final round (MAX_ROUND), execute immediately (no appeal window)
        if (result.isFinalRound || result.appealDeadline == 0) {
            result.shouldExecute = true;
        }

        return result;
    }

    /**
     * @notice Compute pending settlement execution check
     * @param workflowId Escrow workflow ID
     * @param pending Pending settlement data
     * @param escrowState Current escrow state
     * @return canExecute Whether settlement can be executed
     * @return isRelease True if pending release, false if pending cancel
     * @dev This function is "compute-only" - it does NOT modify BaseEscrow state.
     *      Only authorized escrow contracts can call this function
     */
    function computePendingSettlementExecution(
        uint256 workflowId,
        SettlementPendingSettlement memory pending,
        EscrowState escrowState
    ) external view onlyRole(ROLE_ESCROW_CONTRACT) returns (bool canExecute, bool isRelease) {
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
     * @notice Compute timed actions (auto-release or auto-cancel)
     * @param et Escrow transfer data
     * @param pending Pending settlement data
     * @return actionType 0 = none, 1 = auto-release, 2 = auto-cancel, 3 = pending settlement
     * @return isRelease True if release action, false if cancel
     * @dev This function is "compute-only" - it does NOT modify BaseEscrow state.
     *      Only authorized escrow contracts can call this function
     */
    function computeTimedActions(
        uint256 /* workflowId */,
        EscrowTransfer memory et,
        SettlementPendingSettlement memory pending,
        TimeoutConfig memory /* timeoutConfig */
    ) external view returns (uint8 actionType, bool isRelease) {
        // Check for pending settlement execution (appeal window enforcement)
        if (
            pending.exists &&
            block.timestamp >= pending.appealDeadline &&
            et.escrowState == EscrowState.DISPUTED
        ) {
            return (3, pending.isRelease);
        }

        // Check for auto-release/auto-cancel (only for PENDING state)
        if (et.escrowState != EscrowState.PENDING) {
            return (0, false);
        }

        if (et.autoReleaseTime > 0 && block.timestamp >= et.autoReleaseTime) {
            return (1, true);
        } else if (et.autoCancelTime > 0 && block.timestamp >= et.autoCancelTime) {
            return (2, false);
        }

        return (0, false);
    }
}
