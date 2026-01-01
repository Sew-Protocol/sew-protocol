// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

/**
 * @title IReleaseStrategy
 * @notice Interface for escrow release strategies
 * @dev Different release strategies can be implemented (buyer release, multi-party, oracle-based, etc.)
 */
interface IReleaseStrategy {
    /**
     * @notice Check if a release is allowed for the given escrow
     * @param workflowId The escrow transfer ID
     * @param caller The address attempting to release
     * @param escrowData Encoded escrow data (struct EscrowTransfer)
     * @return allowed True if release is allowed
     * @return reason Revert reason if not allowed (empty if allowed)
     */
    function canRelease(
        uint256 workflowId,
        address caller,
        bytes calldata escrowData
    ) external view returns (bool allowed, string memory reason);

    /**
     * @notice Execute the release logic
     * @param workflowId The escrow transfer ID
     * @param escrowData Encoded escrow data
     * @return success True if release was successful
     * @return recipient Address to receive the funds
     * @return amount Amount to release
     */
    function executeRelease(
        uint256 workflowId,
        bytes calldata escrowData
    ) external returns (bool success, address recipient, uint256 amount);

    /**
     * @notice Get the strategy name/identifier
     * @return name The strategy name
     */
    function strategyName() external pure returns (string memory name);
}



