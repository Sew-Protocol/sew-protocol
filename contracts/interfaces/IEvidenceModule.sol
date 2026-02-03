// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import '@openzeppelin/contracts/utils/introspection/IERC165.sol';

/**
 * @title IEvidenceModule
 * @notice Interface for evidence storage modules
 * @dev Provides on-chain evidence commitment (hashes) for dispute resolution
 *      Aligns with threat model TB1: UI independence via on-chain evidence hashes
 *      All evidence modules must implement ERC-165 for interface detection
 */
interface IEvidenceModule is IERC165 {
    /**
     * @notice Submit evidence for a dispute
     * @param workflowId The escrow workflow ID
     * @param evidenceHash Hash of evidence content (keccak256)
     * @param metadata Additional metadata (IPFS hash, document type, etc.) - emitted only
     * @return evidenceId Unique evidence ID for this dispute (0-indexed)
     * @dev Evidence hash is stored on-chain; metadata is emitted in event only
     *      Access control: participants, resolvers, or anyone (configurable)
     */
    function submitEvidence(
        uint256 workflowId,
        address escrowContract,
        bytes32 evidenceHash,
        string calldata metadata
    ) external returns (uint256 evidenceId);

    /**
     * @notice Get all evidence hashes for a dispute
     * @param workflowId The escrow workflow ID
     * @param escrowContract Address of the vault
     * @return hashes Array of evidence hashes
     * @return submitters Array of submitter addresses
     * @return timestamps Array of submission timestamps
     * @return metadata Array of metadata strings (if stored, otherwise empty)
     */
    function getEvidence(
        uint256 workflowId,
        address escrowContract
    )
        external
        view
        returns (
            bytes32[] memory hashes,
            address[] memory submitters,
            uint256[] memory timestamps,
            string[] memory metadata
        );

    /**
     * @notice Get evidence count for a dispute
     * @param workflowId The escrow workflow ID
     * @param escrowContract Address of the vault
     * @return count Number of evidence submissions
     */
    function getEvidenceCount(uint256 workflowId, address escrowContract) external view returns (uint256 count);

    /**
     * @notice Get a specific evidence record
     * @param workflowId The escrow workflow ID
     * @param escrowContract Address of the vault
     * @param evidenceId The evidence ID (0-indexed)
     * @return hash Evidence hash
     * @return submitter Address that submitted
     * @return submittedAt Timestamp of submission
     * @return metadata Metadata string (if stored)
     */
    function getEvidenceRecord(
        uint256 workflowId,
        address escrowContract,
        uint256 evidenceId
    )
        external
        view
        returns (bytes32 hash, address submitter, uint256 submittedAt, string memory metadata);

    /**
     * @notice Check if evidence submission is allowed
     * @param workflowId The escrow workflow ID
     * @param escrowContract Address of the vault
     * @param submitter Address attempting to submit
     * @param escrowData Encoded escrow data (from, to, etc.)
     * @return allowed True if submission allowed
     * @return reason Reason if not allowed (empty if allowed)
     */
    function canSubmitEvidence(
        uint256 workflowId,
        address escrowContract,
        address submitter,
        bytes calldata escrowData
    ) external view returns (bool allowed, string memory reason);

    /**
     * @notice Callback when dispute is opened (optional)
     * @param workflowId The escrow workflow ID
     * @param escrowContract Address of the vault
     * @dev Called by escrow contract when dispute is raised
     *      Allows evidence module to initialize dispute-specific state
     */
    function onDisputeOpened(uint256 workflowId, address escrowContract) external;

    /**
     * @notice Get the module name/identifier
     * @return name The module name
     */
    function moduleName() external pure returns (string memory name);

    /**
     * @notice Get the module version
     * @return version The module version (semantic versioning)
     */
    function moduleVersion() external pure returns (string memory version);
}
