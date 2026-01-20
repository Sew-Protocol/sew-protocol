// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import '../interfaces/IYieldDistributionModule.sol';
import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import '@openzeppelin/contracts/utils/introspection/ERC165.sol';

/**
 * @title TestYieldDistributionModule
 * @notice Test-only yield distribution module with configurable default distribution
 * @dev For testing purposes only - allows setting default distribution recipients
 */
contract TestYieldDistributionModule is IYieldDistributionModule, ERC165 {
    using SafeERC20 for IERC20;

    address[] public defaultRecipients;
    uint256[] public defaultPercentages;

    // Events
    event YieldDistributed(uint256 indexed workflowId, address indexed recipient, uint256 amount);
    event DefaultDistributionSet(address[] recipients, uint256[] percentages);

    /**
     * @notice Set default distribution recipients and percentages
     * @param recipients Array of recipient addresses
     * @param percentages Array of percentages in basis points (must sum to 10000)
     */
    function setDefaultDistribution(
        address[] memory recipients,
        uint256[] memory percentages
    ) external {
        require(recipients.length == percentages.length, 'Array length mismatch');
        require(recipients.length > 0, 'Must have at least one recipient');

        uint256 total = 0;
        for (uint256 i = 0; i < percentages.length; i++) {
            total += percentages[i];
        }
        require(total == 10000, 'Percentages must sum to 10000');

        defaultRecipients = recipients;
        defaultPercentages = percentages;
        emit DefaultDistributionSet(recipients, percentages);
    }

    /**
     * @notice Distribute yield according to distribution data or default
     * @param workflowId The escrow transfer ID
     * @param token Token address
     * @param yieldAmount Amount of yield to distribute
     * @param distributionData Encoded (address[] recipients, uint256[] percentages) or empty for default
     * @return success True if distribution was successful
     * @return distributedAmount Total amount distributed
     */
    function distributeYield(
        uint256 workflowId,
        address token,
        uint256 yieldAmount,
        bytes calldata distributionData
    ) external override returns (bool success, uint256 distributedAmount) {
        if (yieldAmount == 0) {
            return (true, 0);
        }

        address[] memory recipients;
        uint256[] memory percentages;

        // Use provided distribution data, or fall back to default
        if (distributionData.length > 0) {
            (recipients, percentages) = abi.decode(distributionData, (address[], uint256[]));
        } else {
            // Use default distribution if configured
            if (defaultRecipients.length == 0) {
                return (true, 0); // No distribution configured
            }
            recipients = defaultRecipients;
            percentages = defaultPercentages;
        }

        // Validate distribution
        if (recipients.length == 0 || recipients.length != percentages.length) {
            return (false, 0);
        }

        // Validate percentages sum to 100% (10000 basis points)
        uint256 totalPercentage = 0;
        for (uint256 i = 0; i < percentages.length; i++) {
            totalPercentage += percentages[i];
        }
        if (totalPercentage != 10000) {
            return (false, 0);
        }

        // Distribute yield
        // Transfer from msg.sender (the escrow contract) to recipients
        uint256 totalDistributed = 0;
        for (uint256 i = 0; i < recipients.length; i++) {
            address recipient = recipients[i];
            if (recipient == address(0)) {
                continue; // Skip zero address
            }

            uint256 share = (yieldAmount * percentages[i]) / 10000;
            if (share > 0) {
                // Transfer from this module (tokens were transferred here by escrow contract) to recipient
                IERC20(token).safeTransfer(recipient, share);
                totalDistributed += share;
                emit YieldDistributed(workflowId, recipient, share);
            }
        }

        return (true, totalDistributed);
    }

    /**
     * @notice Get the module name/identifier
     * @return name The module name
     */
    function moduleName() external pure override returns (string memory name) {
        return 'TestYieldDistribution';
    }

    /**
     * @notice Get the module version
     * @return version The module version
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
