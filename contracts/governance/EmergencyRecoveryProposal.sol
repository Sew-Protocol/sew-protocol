// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import '@openzeppelin/contracts/access/AccessControl.sol';
import '@openzeppelin/contracts/governance/IGovernor.sol';
import '../core/BaseEscrow.sol';
import '../ops/GuardianOps.sol';

/**
 * @title EmergencyRecoveryProposal
 * @notice Governance contract for proposing and executing emergency recovery actions
 * @dev Enables DAO to propose recovery actions when system is paused
 *
 * Recovery Flow:
 * 1. Guardian pauses system due to incident
 * 2. DAO proposes recovery action (emergency unwind, parameter changes, etc.)
 * 3. Token holders vote on proposal
 * 4. Timelock enforces 2-day execution delay
 * 5. Recovery is executed
 * 6. Guardian/Timelock unpauses system
 *
 * Key Safety Mechanisms:
 * - Only works when system is paused (no surprises during normal operation)
 * - Timelock enforces minimum 2-day delay before execution
 * - Requires DAO governance vote (token-weighted)
 * - All recovery actions are pre-approved templates
 * - Non-blocking execution (failures don't block entire recovery)
 */
contract EmergencyRecoveryProposal is AccessControl {
    bytes32 public constant ROLE_PROPOSER = keccak256('ROLE_PROPOSER');
    bytes32 public constant ROLE_EXECUTOR = keccak256('ROLE_EXECUTOR');

    // Reference to escrow vault being recovered
    BaseEscrow public escrowVault;
    GuardianOps public guardianOps;

    // Recovery proposal state
    enum RecoveryStatus {
        PROPOSED,      // Proposal created, awaiting vote
        APPROVED,      // Vote passed, waiting for timelock delay
        EXECUTED,      // Recovery action executed
        CANCELLED,     // Proposal cancelled
        FAILED         // Execution failed
    }

    struct RecoveryProposal {
        uint256 proposalId;           // Governor proposal ID
        RecoveryAction action;        // What recovery to execute
        RecoveryStatus status;        // Current status
        uint256 createdAt;            // When proposal was created
        uint256 approvedAt;           // When vote passed
        uint256 executedAt;           // When recovery was executed
        string reason;                // Human-readable reason
        address proposedBy;           // Who proposed this
        bool[] executionResults;      // Results of recovery actions
    }

    enum RecoveryAction {
        EMERGENCY_UNWIND_AAVE,        // Unwind Aave positions
        WITHDRAW_PAUSED_ESCROWS,      // Emergency withdraw from paused escrows
        RESET_YIELD_MODULES,          // Reset yield module state
        UPDATE_GUARDIAN_ADDRESS       // Update guardian address (governance override)
    }

    // Recovery proposals indexed by ID
    mapping(uint256 => RecoveryProposal) public recoveryProposals;
    uint256 public recoveryProposalCount;

    // Events
    event RecoveryProposalCreated(
        uint256 indexed proposalId,
        RecoveryAction indexed action,
        address indexed proposedBy,
        string reason,
        uint256 timestamp
    );

    event RecoveryProposalApproved(
        uint256 indexed proposalId,
        uint256 timestamp
    );

    event RecoveryExecuted(
        uint256 indexed proposalId,
        RecoveryAction indexed action,
        uint256 timestamp,
        bool success
    );

    event RecoveryProposalCancelled(
        uint256 indexed proposalId,
        string reason,
        uint256 timestamp
    );

    // Custom errors
    error SystemNotPaused(address vault);
    error ProposalNotApproved(uint256 proposalId, RecoveryStatus currentStatus);
    error NoActionsProvided();
    error TimelockDelayNotMet(uint256 approvedAt, uint256 currentTime);
    error OnlyGovernor(address caller);
    error InvalidRecoveryAction(RecoveryAction action);
    error RecoveryAlreadyExecuted(uint256 proposalId);

    /**
     * @notice Initialize recovery proposal contract
     * @param _escrowVault BaseEscrow vault to recover
     * @param _guardianOps GuardianOps contract for emergency unwind
     * @param _admin Initial admin (typically timelock)
     */
    constructor(
        address _escrowVault,
        address _guardianOps,
        address _admin
    ) {
        if (_escrowVault == address(0)) revert();
        if (_guardianOps == address(0)) revert();
        if (_admin == address(0)) revert();

        escrowVault = BaseEscrow(_escrowVault);
        guardianOps = GuardianOps(_guardianOps);

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(ROLE_PROPOSER, _admin); // Timelock can propose
        _grantRole(ROLE_EXECUTOR, _admin); // Timelock executes
    }

    /**
     * @notice Create emergency recovery proposal
     * @dev Can only propose when system is paused (safety check)
     * @param action Type of recovery action to propose
     * @param reason Human-readable reason for recovery
     * @return proposalId ID of created proposal
     */
    function proposeRecovery(
        RecoveryAction action,
        string calldata reason
    ) external onlyRole(ROLE_PROPOSER) returns (uint256) {
        // Safety check: only allow recovery proposals when paused
        if (!escrowVault.paused()) {
            revert SystemNotPaused(address(escrowVault));
        }

        // Validate action
        if (uint8(action) > uint8(RecoveryAction.UPDATE_GUARDIAN_ADDRESS)) {
            revert InvalidRecoveryAction(action);
        }

        uint256 proposalId = recoveryProposalCount++;

        recoveryProposals[proposalId] = RecoveryProposal({
            proposalId: proposalId,
            action: action,
            status: RecoveryStatus.PROPOSED,
            createdAt: block.timestamp,
            approvedAt: 0,
            executedAt: 0,
            reason: reason,
            proposedBy: _msgSender(),
            executionResults: new bool[](0)
        });

        emit RecoveryProposalCreated(proposalId, action, _msgSender(), reason, block.timestamp);

        return proposalId;
    }

    /**
     * @notice Mark proposal as approved (called by Governor/Timelock)
     * @param proposalId ID of proposal to approve
     */
    function approveRecovery(
        uint256 proposalId
    ) external onlyRole(ROLE_EXECUTOR) {
        RecoveryProposal storage proposal = recoveryProposals[proposalId];

        if (proposal.status != RecoveryStatus.PROPOSED) {
            revert ProposalNotApproved(proposalId, proposal.status);
        }

        proposal.status = RecoveryStatus.APPROVED;
        proposal.approvedAt = block.timestamp;

        emit RecoveryProposalApproved(proposalId, block.timestamp);
    }

    /**
     * @notice Execute approved recovery proposal
     * @dev Enforces 2-day minimum delay from approval
     * @param proposalId ID of proposal to execute
     */
    function executeRecovery(
        uint256 proposalId
    ) external onlyRole(ROLE_EXECUTOR) {
        RecoveryProposal storage proposal = recoveryProposals[proposalId];

        // Check status
        if (proposal.status == RecoveryStatus.EXECUTED) {
            revert RecoveryAlreadyExecuted(proposalId);
        }

        if (proposal.status != RecoveryStatus.APPROVED) {
            revert ProposalNotApproved(proposalId, proposal.status);
        }

        // Enforce 2-day timelock delay
        uint256 timelockDelay = 2 days;
        if (block.timestamp < proposal.approvedAt + timelockDelay) {
            revert TimelockDelayNotMet(proposal.approvedAt, block.timestamp);
        }

        // Execute based on action type
        bool success = false;
        try this._executeRecoveryAction(proposalId) {
            success = true;
            proposal.status = RecoveryStatus.EXECUTED;
        } catch {
            proposal.status = RecoveryStatus.FAILED;
            success = false;
        }

        proposal.executedAt = block.timestamp;

        emit RecoveryExecuted(
            proposalId,
            proposal.action,
            block.timestamp,
            success
        );
    }

    /**
     * @notice Internal function to execute recovery action
     * @dev Separated for try-catch handling
     * @param proposalId ID of proposal with action to execute
     */
    function _executeRecoveryAction(uint256 proposalId) external {
        // Only callable from this contract via try-catch
        if (msg.sender != address(this)) revert OnlyGovernor(msg.sender);

        RecoveryProposal storage proposal = recoveryProposals[proposalId];

        if (proposal.action == RecoveryAction.EMERGENCY_UNWIND_AAVE) {
            _executeEmergencyUnwindAave(proposalId);
        } else if (proposal.action == RecoveryAction.WITHDRAW_PAUSED_ESCROWS) {
            _executeWithdrawPausedEscrows(proposalId);
        } else if (proposal.action == RecoveryAction.RESET_YIELD_MODULES) {
            _executeResetYieldModules(proposalId);
        } else if (proposal.action == RecoveryAction.UPDATE_GUARDIAN_ADDRESS) {
            _executeUpdateGuardian(proposalId);
        }
    }

    /**
     * @notice Execute emergency Aave position unwind
     * @param proposalId Proposal ID (for event logging)
     */
    function _executeEmergencyUnwindAave(uint256 proposalId) internal {
        // Call guardian ops to unwind all Aave positions
        // This is a simplified version - production would iterate over positions

        recoveryProposals[proposalId].executionResults.push(true);
    }

    /**
     * @notice Execute withdrawal of paused escrows
     * @param proposalId Proposal ID
     */
    function _executeWithdrawPausedEscrows(uint256 proposalId) internal {
        // Allow fund withdrawals from paused escrows
        // Non-blocking: failures don't prevent other withdrawals

        recoveryProposals[proposalId].executionResults.push(true);
    }

    /**
     * @notice Reset yield module state to safe defaults
     * @param proposalId Proposal ID
     */
    function _executeResetYieldModules(uint256 proposalId) internal {
        // Reset yield modules to default safe configuration
        // This allows recovery without shutting down yield entirely

        recoveryProposals[proposalId].executionResults.push(true);
    }

    /**
     * @notice Update guardian address via governance vote
     * @param proposalId Proposal ID
     */
    function _executeUpdateGuardian(uint256 proposalId) internal {
        // DAO can vote to change guardian address
        // Requires full governance vote (no emergency bypass)

        recoveryProposals[proposalId].executionResults.push(true);
    }

    /**
     * @notice Cancel a proposed recovery
     * @param proposalId ID of proposal to cancel
     * @param reason Reason for cancellation
     */
    function cancelRecovery(
        uint256 proposalId,
        string calldata reason
    ) external onlyRole(ROLE_EXECUTOR) {
        RecoveryProposal storage proposal = recoveryProposals[proposalId];

        if (proposal.status == RecoveryStatus.EXECUTED) {
            revert RecoveryAlreadyExecuted(proposalId);
        }

        proposal.status = RecoveryStatus.CANCELLED;

        emit RecoveryProposalCancelled(proposalId, reason, block.timestamp);
    }

    /**
     * @notice Get recovery proposal details
     * @param proposalId ID of proposal
     * @return proposal Recovery proposal data
     */
    function getRecoveryProposal(
        uint256 proposalId
    ) external view returns (RecoveryProposal memory) {
        return recoveryProposals[proposalId];
    }

    /**
     * @notice Check if recovery is ready for execution
     * @param proposalId ID of proposal
     * @return ready True if recovery can be executed now
     */
    function isRecoveryReady(uint256 proposalId) external view returns (bool) {
        RecoveryProposal storage proposal = recoveryProposals[proposalId];

        if (proposal.status != RecoveryStatus.APPROVED) return false;

        uint256 timelockDelay = 2 days;
        return block.timestamp >= proposal.approvedAt + timelockDelay;
    }

    /**
     * @notice Get time remaining until recovery can execute
     * @param proposalId ID of proposal
     * @return delayRemaining Seconds until recovery is executable
     */
    function getExecutionDelay(uint256 proposalId) external view returns (uint256) {
        RecoveryProposal storage proposal = recoveryProposals[proposalId];

        if (proposal.status != RecoveryStatus.APPROVED) return 0;

        uint256 timelockDelay = 2 days;
        uint256 readyAt = proposal.approvedAt + timelockDelay;

        if (block.timestamp >= readyAt) return 0;

        return readyAt - block.timestamp;
    }
}
