// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/**
 * @title IResolutionModule
 * @notice Interface for dispute resolution modules
 * @dev Handles resolution logic including escalation paths, resolver roles, and dynamic resolution
 *      All resolution modules must implement ERC-165 for interface detection
 */
interface IResolutionModule is IERC165 {
    /**
     * @notice Check if an address is authorized to resolve a dispute
     * @param workflowId The escrow transfer ID
     * @param disputeResolver The address attempting to resolve
     * @param escrowData Encoded escrow data
     * @return authorized True if authorized
     * @return role The dispute resolver role (0 = standard resolver, 1 = senior resolver, etc.)
     */
    function isAuthorizedDisputeResolver(
        uint256 workflowId,
        address disputeResolver,
        bytes calldata escrowData
    ) external view returns (bool authorized, uint8 role);

    /**
     * @notice Get the appropriate dispute resolver for a dispute
     * @param workflowId The escrow transfer ID
     * @param escrowData Encoded escrow data
     * @return disputeResolver The dispute resolver address
     * @return escalationLevel Current escalation level (0 = initial, 1+ = escalated)
     */
    function getDisputeResolver(
        uint256 workflowId,
        bytes calldata escrowData
    ) external view returns (address disputeResolver, uint8 escalationLevel);

    /**
     * @notice Check if escalation is allowed and get next resolver
     * @param workflowId The escrow transfer ID
     * @param currentLevel Current escalation level
     * @param escrowData Encoded escrow data
     * @return canEscalate True if escalation is allowed
     * @return nextDisputeResolver Address of next dispute resolver (address(0) if cannot escalate)
     * @return escalationFee Fee required for escalation (0 if none)
     */
    function canEscalate(
        uint256 workflowId,
        uint8 currentLevel,
        bytes calldata escrowData
    ) external view returns (
        bool canEscalate,
        address nextDisputeResolver,
        uint256 escalationFee
    );

    /**
     * @notice Execute escalation to next level
     * @param workflowId The escrow transfer ID
     * @param escrowData Encoded escrow data
     * @return success True if escalation was successful
     * @return newDisputeResolver Address of new dispute resolver
     * @return newLevel New escalation level
     */
    function executeEscalation(
        uint256 workflowId,
        bytes calldata escrowData
    ) external returns (
        bool success,
        address newDisputeResolver,
        uint8 newLevel
    );

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



