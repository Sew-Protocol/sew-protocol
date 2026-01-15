// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import "./shared/interfaces/IResolutionModule.sol";
import "./types/EscrowTypes.sol";

/**
 * @title DisputeOps
 * @notice External contract for dispute escalation orchestration
 * @dev Extracted from BaseEscrow to reduce contract size (Phase 2 size optimization)
 *      
 *      Key design principles (from updated plan):
 *      - Compute → Apply: Returns escalation result, BaseEscrow applies to state
 *      - No callbacks: Does not write to BaseEscrow state
 *      - Atomic: Single call computes all escalation logic
 *      - View-ish: Could be view function but module may update counters
 *      
 *      Pattern:
 *      BaseEscrow calls: computeEscalation(workflowId, caller, escrowData)
 *      DisputeOps returns: (newResolver, newLevel, escalationFee)
 *      BaseEscrow applies: Updates state and collects fees
 */
contract DisputeOps {
    
    /**
     * @dev Result of escalation computation
     */
    struct EscalationResult {
        bool success;                  // Whether escalation is allowed
        address newResolver;           // New dispute resolver address
        uint8 newLevel;                // New escalation level
        uint8 currentLevel;            // Current escalation level (for event)
        uint256 escalationFee;         // Fee required for escalation
        string failureReason;          // Reason if escalation not allowed
    }
    
    /**
     * @notice Compute escalation for a disputed escrow
     * @param resolutionModule Address of the resolution module
     * @param workflowId Escrow workflow ID
     * @param caller Address initiating the escalation (msg.sender from BaseEscrow)
     * @param from Escrow sender address
     * @param to Escrow recipient address
     * @param token Token address
     * @param amountAfterFee Amount after fee deduction (what's actually held in escrow)
     * @param escrowState Current escrow state
     * @return result Escalation computation result
     * @dev This function is "compute-only" - it does NOT modify BaseEscrow state.
     *      It may call the resolution module which might update its own counters.
     *      BaseEscrow will apply the result after receiving it.
     */
    function computeEscalation(
        address resolutionModule,
        uint256 workflowId,
        address caller,
        address from,
        address to,
        address token,
        uint256 amountAfterFee,
        EscrowState escrowState
    ) external returns (EscalationResult memory result) {
        result.success = false;
        
        // Validate caller is participant (BaseEscrow should have checked this, but double-check)
        if (caller != from && caller != to) {
            result.failureReason = "Caller not participant";
            return result;
        }
        
        // Validate state is DISPUTED
        if (escrowState != EscrowState.DISPUTED) {
            result.failureReason = "Not in disputed state";
            return result;
        }
        
        // Validate module exists
        if (resolutionModule == address(0)) {
            result.failureReason = "Resolution module not configured";
            return result;
        }
        
        // Encode escrow data for module
        bytes memory escrowData = abi.encode(token, from, to, amountAfterFee);
        
        // Get current level from module
        try IResolutionModule(resolutionModule).getDisputeResolver(workflowId, escrowData) 
            returns (address /* currentResolver */, uint8 currentLevel) {
            result.currentLevel = currentLevel;
        } catch {
            result.failureReason = "Failed to get current level";
            return result;
        }
        
        // Check if escalation is allowed and get fee
        try IResolutionModule(resolutionModule).canEscalate(
            workflowId, 
            result.currentLevel, 
            escrowData
        ) returns (bool canEscalate, address /* nextResolver */, uint256 fee) {
            if (!canEscalate) {
                result.failureReason = "Escalation not allowed";
                return result;
            }
            result.escalationFee = fee;
        } catch {
            result.failureReason = "Failed to check escalation eligibility";
            return result;
        }
        
        // Execute escalation in module (module may update its state)
        try IResolutionModule(resolutionModule).executeEscalation(workflowId, escrowData) 
            returns (bool escalationSuccess, address newResolver, uint8 newLevel) {
            if (!escalationSuccess) {
                result.failureReason = "Module rejected escalation";
                return result;
            }
            
            // Validate returned values
            if (newResolver == address(0)) {
                result.failureReason = "Module returned zero address";
                return result;
            }
            
            result.success = true;
            result.newResolver = newResolver;
            result.newLevel = newLevel;
            return result;
        } catch {
            result.failureReason = "Module escalation call failed";
            return result;
        }
    }
    
    /**
     * @notice Validate escalation fee payment
     * @param requiredFee Fee required by escalation
     * @param paidFee Fee actually paid (msg.value)
     * @return valid Whether payment is sufficient
     * @return excessRefund Amount to refund to caller
     * @dev Helper function for BaseEscrow to validate fee payment
     */
    function validateEscalationFee(
        uint256 requiredFee,
        uint256 paidFee
    ) external pure returns (bool valid, uint256 excessRefund) {
        if (requiredFee > 0 && paidFee < requiredFee) {
            return (false, 0);
        }
        
        valid = true;
        if (paidFee > requiredFee) {
            excessRefund = paidFee - requiredFee;
        }
        return (valid, excessRefund);
    }
    
    /**
     * @notice Encode escrow data for resolution module
     * @param token Token address
     * @param from Sender address
     * @param to Recipient address
     * @param amountAfterFee Amount after fee deduction (what's actually held in escrow)
     * @return Encoded escrow data
     * @dev Public helper for encoding - can be used by BaseEscrow or externally
     */
    function encodeEscrowData(
        address token,
        address from,
        address to,
        uint256 amountAfterFee
    ) external pure returns (bytes memory) {
        return abi.encode(token, from, to, amountAfterFee);
    }
}
