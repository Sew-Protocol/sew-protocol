// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

/**
 * @title IResolver
 * @notice Standard interface for dispute resolution (ERC-ESCR-DISPUTE)
 * @dev Enables pluggable dispute resolution systems
 */
interface IResolver {
    /**
     * @notice Called when a dispute is opened for an escrow
     * @param workflowId The workflow ID
     * @param disputeMetadata Additional dispute metadata (optional)
     * @dev Optional callback - resolver can choose to implement or ignore
     */
    function onDisputeOpened(uint256 workflowId, bytes calldata disputeMetadata) external;

    /**
     * @notice Resolve a disputed escrow with flexible payouts
     * @param workflowId The workflow ID
     * @param payouts Array of payouts (recipient, amount)
     * @param resolutionMetadata Additional resolution metadata (optional)
     * @dev Must be called by the escrow contract's resolve function
     * @dev Payouts must sum to available escrow balance
     */
    function resolve(
        uint256 workflowId,
        Payout[] calldata payouts,
        bytes calldata resolutionMetadata
    ) external;

    /**
     * @notice Get resolver metadata
     * @return name Resolver name/identifier
     * @return version Resolver version
     */
    function resolverMetadata() external view returns (string memory name, string memory version);
}

/**
 * @title Payout
 * @notice Structure for escrow resolution payouts
 */
struct Payout {
    address recipient; // Address to receive payout
    uint256 amount; // Amount to payout
}
