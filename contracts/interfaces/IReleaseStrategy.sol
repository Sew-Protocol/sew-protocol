// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import '@openzeppelin/contracts/utils/introspection/IERC165.sol';

/**
 * @title IReleaseStrategy
 * @notice Interface for escrow release strategies
 * @dev Different release strategies can be implemented (buyer release, multi-party, oracle-based, etc.)
 *      All release strategies must implement ERC-165 for interface detection
 */
interface IReleaseStrategy is IERC165 {
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
        address escrowContract,
        address caller,
        bytes calldata escrowData
    ) external view returns (bool allowed, string memory reason);

    /**
     * @notice Execute the release logic
     * @param workflowId The escrow transfer ID
     * @param escrowContract Address of the vault
     * @param escrowData Encoded escrow data
     * @return success True if release was successful
     * @return recipient Address to receive the funds
     * @return amount Amount to release
     */
    function executeRelease(
        uint256 workflowId,
        address escrowContract,
        bytes calldata escrowData
    ) external returns (bool success, address recipient, uint256 amount);

    /**
     * @notice Get the strategy name/identifier
     * @return name The strategy name
     * @dev Kept for backward compatibility. Use moduleName() for consistency.
     */
    function strategyName() external pure returns (string memory name);

    /**
     * @notice Get the module name/identifier (alias for strategyName for consistency)
     * @return name The module name
     * @dev Provides consistent naming across all module types
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
