// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import "../interfaces/IYieldModule.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title DefaultYieldModule
 * @notice Default yield module: no yield generation, but handles distribution
 * @dev This provides distribution logic for escrows without yield generation
 */
contract DefaultYieldModule is IYieldModule {
    using SafeERC20 for IERC20;
    
    // Events
    event YieldDistributed(uint256 indexed workflowId, address indexed recipient, uint256 amount);
    /**
     * @notice Deposit for yield (no-op in default implementation)
     */
    function depositForYield(
        uint256 /* workflowId */,
        address /* token */,
        uint256 /* amount */
    ) external pure override returns (bool success, uint256 yieldTokenBalance) {
        return (true, 0);
    }

    /**
     * @notice Withdraw with yield (returns original amount)
     */
    function withdrawWithYield(
        uint256 /* workflowId */,
        address /* token */,
        uint256 originalAmount
    ) external pure override returns (
        bool success,
        uint256 actualAmount,
        uint256 yieldAmount
    ) {
        return (true, originalAmount, 0);
    }

    /**
     * @notice Withdraw proportional (returns requested amount)
     */
    function withdrawProportional(
        uint256 /* workflowId */,
        address /* token */,
        uint256 amount,
        uint256 /* originalDeposit */
    ) external pure override returns (bool success, uint256 actualAmount) {
        return (true, amount);
    }

    /**
     * @notice Calculate yield (returns 0)
     */
    function calculateYield(
        uint256 /* workflowId */,
        address /* token */
    ) external pure override returns (uint256 yieldAmount) {
        return 0;
    }

    /**
     * @notice Distribute yield according to distribution data
     * @param workflowId The escrow transfer ID
     * @param token Token address
     * @param yieldAmount Amount of yield to distribute
     * @param distributionData Encoded (address[] recipients, uint256[] percentages)
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
        
        // Decode distribution data
        (address[] memory recipients, uint256[] memory percentages) = 
            abi.decode(distributionData, (address[], uint256[]));
        
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
     * @notice Check if token is supported (default: none supported)
     */
    function isTokenSupported(address /* token */) external pure override returns (bool supported) {
        return false;
    }

    /**
     * @notice Get module name
     */
    function moduleName() external pure override returns (string memory) {
        return "DefaultNoYield";
    }
}


