// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import '../interfaces/IYieldDistributionModule.sol';
import '@openzeppelin/contracts/utils/introspection/ERC165.sol';

/**
 * @title DefaultYieldDistributionModule
 * @notice Default yield distribution module: percentage-based distribution to multiple recipients
 * @dev Handles distribution of yield according to encoded distribution data (recipients and percentages).
 *      This module is separate from yield generation, allowing independent swapping of generation modules.
 */
contract DefaultYieldDistributionModule is IYieldDistributionModule, ERC165 {
    // Event retained for compatibility; no recipient-level push transfers are performed.
    event YieldDistributionDeferred(uint256 indexed workflowId, address indexed token, uint256 amount);

    /**
     * @notice Validate distribution settings and defer delivery to escrow pull paths.
     * @param workflowId The escrow transfer ID
     * @param token Token address
     * @param yieldAmount Amount of yield to distribute
     * @param distributionData Encoded (address[] recipients, uint256[] percentages)
     * @return success True if distribution was successful
     * @return distributedAmount Always 0 in pull-only mode
     * @dev Decodes and validates distribution data but does not transfer to recipients.
     *      Yield remains in escrow-controlled accounting for explicit withdrawal delivery.
     */
    function distributeYield(
        uint256 workflowId,
        address /* escrowContract */,
        address token,
        uint256 yieldAmount,
        bytes calldata distributionData
    ) external override returns (bool success, uint256 distributedAmount) {
        if (yieldAmount == 0) {
            return (true, 0);
        }

        // If distributionData is empty, return success with 0 distributed (yield stays in contract)
        // This allows graceful handling when distribution is not configured
        if (distributionData.length == 0) {
            return (true, 0);
        }

        // Decode distribution data
        (address[] memory recipients, uint256[] memory percentages) = abi.decode(
            distributionData,
            (address[], uint256[])
        );

        // Validate distribution exists
        if (recipients.length == 0 || recipients.length != percentages.length) {
            return (false, 0);
        }

        // Validate percentages sum to 100% (10000 basis points)
        uint256 ESCROW_FEE_DENOMINATOR = 10000;
        uint256 totalPercentage = 0;
        for (uint256 i = 0; i < percentages.length; i++) {
            totalPercentage += percentages[i];
        }
        if (totalPercentage != ESCROW_FEE_DENOMINATOR) {
            return (false, 0); // Invalid distribution
        }

        emit YieldDistributionDeferred(workflowId, token, yieldAmount);
        return (true, 0);
    }

    /**
     * @notice Get the module name/identifier
     * @return name The module name
     */
    function moduleName() external pure override returns (string memory name) {
        return 'DefaultYieldDistribution';
    }

    /**
     * @notice Get the module version
     * @return version The module version (semantic versioning)
     */
    function moduleVersion() external pure override returns (string memory version) {
        return '1.0.0';
    }

    /**
     * @notice ERC-165 interface support
     */
    function supportsInterface(
        bytes4 interfaceId
    ) public view virtual override(ERC165, IERC165) returns (bool) {
        return
            interfaceId == type(IYieldDistributionModule).interfaceId ||
            super.supportsInterface(interfaceId);
    }
}
