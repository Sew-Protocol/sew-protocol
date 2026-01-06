// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.33;

import "../interfaces/IYieldDistributionModule.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/introspection/ERC165.sol";

/**
 * @title DefaultYieldDistributionModule
 * @notice Default yield distribution module: percentage-based distribution to multiple recipients
 * @dev Handles distribution of yield according to encoded distribution data (recipients and percentages).
 *      This module is separate from yield generation, allowing independent swapping of generation modules.
 */
contract DefaultYieldDistributionModule is IYieldDistributionModule, ERC165 {
    using SafeERC20 for IERC20;
    
    // Events
    event YieldDistributed(uint256 indexed workflowId, address indexed recipient, uint256 amount);

    /**
     * @notice Distribute yield according to distribution data
     * @param workflowId The escrow transfer ID
     * @param token Token address
     * @param yieldAmount Amount of yield to distribute
     * @param distributionData Encoded (address[] recipients, uint256[] percentages)
     * @return success True if distribution was successful
     * @return distributedAmount Total amount distributed
     * @dev Decodes distribution data and distributes yield proportionally to recipients.
     *      Percentages must sum to 10000 (100% in basis points).
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
        
        // If distributionData is empty, return success with 0 distributed (yield stays in contract)
        // This allows graceful handling when distribution is not configured
        if (distributionData.length == 0) {
            return (true, 0);
        }
        
        // Decode distribution data
        (address[] memory recipients, uint256[] memory percentages) = 
            abi.decode(distributionData, (address[], uint256[]));
        
        // Validate distribution exists
        if (recipients.length == 0 || recipients.length != percentages.length) {
            return (false, 0);
        }
        
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
        
        // Distribute yield
        uint256 totalDistributed = 0;
        for (uint256 i = 0; i < recipients.length; i++) {
            address recipient = recipients[i];
            if (recipient == address(0)) {
                continue; // Skip zero address
            }
            
            uint256 share = (yieldAmount * percentages[i]) / ESCROW_FEE_DENOMINATOR;
            if (share > 0) {
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
        return "DefaultYieldDistribution";
    }

    /**
     * @notice Get the module version
     * @return version The module version (semantic versioning)
     */
    function moduleVersion() external pure override returns (string memory version) {
        return "1.0.0";
    }

    /**
     * @notice ERC-165 interface support
     */
    function supportsInterface(bytes4 interfaceId) public view virtual override(ERC165, IERC165) returns (bool) {
        return
            interfaceId == type(IYieldDistributionModule).interfaceId ||
            super.supportsInterface(interfaceId);
    }
}


