// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.33;

import "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/**
 * @title IYieldDistributionModule
 * @notice Interface for yield distribution modules
 * @dev Handles distribution of yield to recipients. Generation is handled separately.
 */
interface IYieldDistributionModule is IERC165 {
    /**
     * @notice Distribute yield to recipients
     * @param workflowId The escrow transfer ID
     * @param token Token address
     * @param yieldAmount Amount of yield to distribute
     * @param distributionData Encoded distribution configuration (e.g., recipients and percentages)
     * @return success True if distribution was successful
     * @return distributedAmount Total amount distributed
     */
    function distributeYield(
        uint256 workflowId,
        address token,
        uint256 yieldAmount,
        bytes calldata distributionData
    ) external returns (bool success, uint256 distributedAmount);

    /**
     * @notice Get the module name/identifier
     * @return name The module name
     */
    function moduleName() external pure returns (string memory name);

    /**
     * @notice Get the module version
     * @return version The module version (semantic versioning, e.g., "1.0.0")
     */
    function moduleVersion() external pure returns (string memory version);
}


