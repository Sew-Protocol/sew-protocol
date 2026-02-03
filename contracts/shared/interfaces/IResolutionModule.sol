// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import '@openzeppelin/contracts/utils/introspection/IERC165.sol';
import '../../types/EscrowTypes.sol';

/**
 * @title IResolutionModule
 * @notice Interface for dispute resolution modules
 * @dev Handles resolution logic including escalation paths, resolver roles, and dynamic resolution
 *      All resolution modules must implement ERC-165 for interface detection
 */
interface IResolutionModule is IERC165 {
    /**
     * @notice Initialize a new dispute in the module
     * @param workflowId The escrow transfer ID
     * @param escrowContract Address of the vault
     * @param initialResolver Address of initial resolver
     * @param categoryKey Category identifier for round-robin assignment
     */
    function initializeDispute(
        uint256 workflowId,
        address escrowContract,
        address initialResolver,
        bytes32 categoryKey
    ) external;

    /**
     * @notice Record a resolution outcome
     * @param workflowId The escrow transfer ID
     * @param escrowContract Address of the vault
     * @param resolver Address of resolver who made the decision
     * @param outcome The resolution outcome (RELEASE or CANCEL)
     * @param resolutionTime Time taken to resolve
     */
    function recordResolution(
        uint256 workflowId,
        address escrowContract,
        address resolver,
        ResolutionOutcome outcome,
        uint256 resolutionTime
    ) external;

    /**
     * @notice Check if an address is authorized to resolve a dispute
     * @param workflowId The escrow transfer ID
     * @param escrowContract Address of the vault
     * @param disputeResolver The address attempting to resolve
     * @param escrowData Encoded escrow data
     * @return authorized True if authorized
     * @return role The dispute resolver role (0 = standard resolver, 1 = senior resolver, etc.)
     */
    function isAuthorizedDisputeResolver(
        uint256 workflowId,
        address escrowContract,
        address disputeResolver,
        bytes calldata escrowData
    ) external view returns (bool authorized, uint8 role);

    /**
     * @notice Get the appropriate dispute resolver for a dispute
     * @param workflowId The escrow transfer ID
     * @param escrowContract Address of the vault
     * @param escrowData Encoded escrow data
     * @return disputeResolver The dispute resolver address
     * @return escalationLevel Current escalation level (0 = initial, 1+ = escalated)
     */
    function getDisputeResolver(
        uint256 workflowId,
        address escrowContract,
        bytes calldata escrowData
    ) external view returns (address disputeResolver, uint8 escalationLevel);

    /**
     * @notice Check if escalation is allowed and get next resolver
     * @param workflowId The escrow transfer ID
     * @param escrowContract Address of the vault
     * @param currentLevel Current escalation level
     * @param escrowData Encoded escrow data
     * @return canEscalate True if escalation is allowed
     * @return nextDisputeResolver Address of next dispute resolver (address(0) if cannot escalate)
     * @return escalationFee Fee required for escalation (0 if none)
     */
    function canEscalate(
        uint256 workflowId,
        address escrowContract,
        uint8 currentLevel,
        bytes calldata escrowData
    ) external view returns (bool canEscalate, address nextDisputeResolver, uint256 escalationFee);

    /**
     * @notice Execute escalation to next level
     * @param workflowId The escrow transfer ID
     * @param escrowContract Address of the vault
     * @param escrowData Encoded escrow data
     * @return success True if escalation was successful
     * @return newDisputeResolver Address of new dispute resolver
     * @return newLevel New escalation level
     */
    function executeEscalation(
        uint256 workflowId,
        address escrowContract,
        bytes calldata escrowData
    ) external returns (bool success, address newDisputeResolver, uint8 newLevel);

    /**
     * @notice Get required appeal bond for escalation (DR v2)
     * @param workflowId The escrow transfer ID
     * @param escrowContract Address of the vault
     * @param currentLevel Current escalation level
     * @param escrowData Encoded escrow data
     * @return amount Bond amount required (0 if bonds not enabled)
     * @return token Token address for bond (address(0) if native token)
     */
    function getRequiredAppealBond(
        uint256 workflowId,
        address escrowContract,
        uint8 currentLevel,
        bytes calldata escrowData
    ) external view returns (uint256 amount, address token);

    /**
     * @notice Get decision at a specific round
     * @param workflowId Dispute ID
     * @param escrowContract Address of the vault
     * @param round Round to check
     * @return decision ResolutionOutcome enum value
     */
    function getDecisionAtRound(uint256 workflowId, address escrowContract, uint8 round) external view returns (uint8 decision);

    /**
     * @notice Get appeal deadline and current round
     * @param workflowId Dispute ID
     * @param escrowContract Address of the vault
     * @return appealDeadline Appeal deadline for current round
     * @return currentRound Current round
     * @return isFinalRound True if this is the final round
     */
    function getAppealDeadlineAndRound(
        uint256 workflowId,
        address escrowContract
    ) external view returns (uint256 appealDeadline, uint8 currentRound, bool isFinalRound);

    /**
     * @notice Record a reversal
     * @param workflowId Dispute ID
     * @param escrowContract Address of the vault
     * @param priorRound Round where original decision was made
     */
    function recordReversal(uint256 workflowId, address escrowContract, uint8 priorRound) external;

    /**
     * @notice Finalize a dispute
     * @param workflowId Dispute ID
     * @param escrowContract Address of the vault
     */
    function finalizeDispute(uint256 workflowId, address escrowContract) external;

    /**
     * @notice Get the module name/identifier
     * @return name The module name
     */
    function moduleName() external pure returns (string memory name);

    /**
     * @notice Get the module version
     * @return version The module version (semantic versioning, e.g., "1.0.0")
     * @dev Must follow semantic versioning: MAJOR.MINOR.PATCH
     *      Major version changes indicate breaking changes
     */
    function moduleVersion() external pure returns (string memory version);
}