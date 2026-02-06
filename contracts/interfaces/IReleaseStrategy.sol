// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import '@openzeppelin/contracts/utils/introspection/IERC165.sol';

/**
 * @title IReleaseStrategy
 * @notice Interface for escrow release strategies
 * @dev Different release strategies can be implemented (buyer release, multi-party, oracle-based, etc.)
 *      All release strategies must implement ERC-165 for interface detection
 * 
 * @dev Reason codes (append-only):
 *      0 = allowed
 *      1 = not authorized (caller not eligible)
 *      2 = wrong state
 *      3 = missing data
 *      4-255 = reserved for future use
 */
interface IReleaseStrategy is IERC165 {
    /**
     * @notice Check if a release is allowed for the given escrow
     * @param workflowId The escrow transfer ID
     * @param escrowContract Address of the escrow contract
     * @param caller The address attempting to release
     * @param escrowData Encoded escrow data (token, sender, recipient, amountAfterFee)
     * @return allowed True if release is allowed
     * @return reasonCode Compact reason code if not allowed (0 = allowed, see contract for codes)
     * @dev escrowData MUST be encoded as: abi.encode(token, sender, recipient, amountAfterFee)
     * @dev reasonCode is append-only; implementers should document their codes
     */
    function canRelease(
        uint256 workflowId,
        address escrowContract,
        address caller,
        bytes calldata escrowData
    ) external view returns (bool allowed, uint8 reasonCode);

    /**
     * @notice Execute the release logic (reserved for future use in v2)
     * @dev For v1, release() is handled entirely by BaseEscrow
     * @dev Implementers should revert to prevent reliance on this unimplemented method
     */
    function executeRelease(
        uint256 workflowId,
        address escrowContract,
        bytes calldata escrowData
    ) external view returns (bool success);

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
