// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import '@openzeppelin/contracts/access/AccessControl.sol';
import './shared/interfaces/IResolutionModule.sol';
import './types/EscrowTypes.sol';

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
contract DisputeOps is AccessControl {
    // ============ Role Constants ============
    bytes32 public constant ROLE_ESCROW_CONTRACT = keccak256('ROLE_ESCROW_CONTRACT');
    bytes32 public constant ROLE_TIMELOCK = keccak256('ROLE_TIMELOCK');

    // ============ Custom Errors ============
    error ZeroOwner();
    /**
     * @notice Constructor for DisputeOps
     * @param initialOwner Address that will receive DEFAULT_ADMIN_ROLE (for initial setup only)
     */
    constructor(address initialOwner) {
        if (initialOwner == address(0)) revert ZeroOwner();
        _grantRole(DEFAULT_ADMIN_ROLE, initialOwner);
        // ROLE_TIMELOCK gates registerEscrowContract(), so initialOwner must have it for initial setup.
        _grantRole(ROLE_TIMELOCK, initialOwner);
    }

    /**
     * @notice Register an escrow contract (grants it ROLE_ESCROW_CONTRACT)
     * @param escrowContract Address of the escrow contract
     * @dev Only ROLE_TIMELOCK can register escrow contracts (governance-controlled)
     */
    function registerEscrowContract(address escrowContract) external onlyRole(ROLE_TIMELOCK) {
        if (escrowContract == address(0)) revert InvalidAddress(ADDR_ESCROW_CONTRACT, escrowContract);
        _grantRole(ROLE_ESCROW_CONTRACT, escrowContract);
    }

    /**
     * @dev Result of escalation computation
     */
    struct EscalationResult {
        bool success; // Whether escalation is allowed
        address newResolver; // New dispute resolver address
        uint8 newLevel; // New escalation level
        uint8 currentLevel; // Current escalation level (for event)
        uint256 escalationFee; // Fee required for escalation
        string failureReason; // Reason if escalation not allowed
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
     *      Only authorized escrow contracts can call this function
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
    ) external onlyRole(ROLE_ESCROW_CONTRACT) returns (EscalationResult memory result) {
        result.success = false;

        // Validate caller is participant (BaseEscrow should have checked this, but double-check)
        if (caller != from && caller != to) {
            result.failureReason = 'Caller not participant';
            return result;
        }

        // Validate state is DISPUTED
        if (escrowState != EscrowState.DISPUTED) {
            result.failureReason = 'Not in disputed state';
            return result;
        }

        // Validate module exists
        if (resolutionModule == address(0)) {
            result.failureReason = 'Resolution module not configured';
            return result;
        }

        // Encode escrow data for module
        bytes memory escrowData = abi.encode(token, from, to, amountAfterFee);

        // Get current level from module
        try IResolutionModule(resolutionModule).getDisputeResolver(workflowId, _msgSender(), escrowData) returns (
            address /* currentResolver */,
            uint8 currentLevel
        ) {
            result.currentLevel = currentLevel;
        } catch {
            result.failureReason = 'Failed to get current level';
            return result;
        }

        // Validate only the disagreed-with participant can appeal
        // Try to get decision at current round from module (if supported)
        // For DecentralizedResolutionModule, we can call getDecisionAtRound
        // Use low-level call since this function is not in IResolutionModule interface
        (bool decisionSuccess, bytes memory decisionData) = resolutionModule.staticcall(
            abi.encodeWithSignature('getDecisionAtRound(uint256,address,uint8)', workflowId, _msgSender(), result.currentLevel)
        );
        
        if (decisionSuccess && decisionData.length >= 32) {
            // Decode the uint8 return value
            uint8 decision;
            assembly {
                decision := mload(add(decisionData, 0x20))
                // Mask to get only the first byte (uint8)
                decision := and(decision, 0xff)
            }
            
            // decision: 0 = NONE, 1 = RELEASE, 2 = CANCEL (matching ResolutionOutcome enum)
            if (decision == 1) {
                // RELEASE means recipient wins, so only sender (from) can appeal
                if (caller != from) {
                    result.failureReason = 'Only sender can appeal RELEASE decision';
                    return result;
                }
            } else if (decision == 2) {
                // CANCEL means sender wins, so only recipient (to) can appeal
                if (caller != to) {
                    result.failureReason = 'Only recipient can appeal CANCEL decision';
                    return result;
                }
            } else if (decision == 0) {
                // NONE - no decision yet, can't appeal
                result.failureReason = 'No decision to appeal';
                return result;
            }
            // If decision is valid and caller matches, continue
        }
        // If we can't get decision (e.g., module doesn't support it), allow escalation
        // This maintains backward compatibility with modules that don't track decisions

        // Check if escalation is allowed and get fee
        try
            IResolutionModule(resolutionModule).canEscalate(
                workflowId,
                _msgSender(),
                result.currentLevel,
                escrowData
            )
        returns (bool canEscalate, address /* nextResolver */, uint256 fee) {
            if (!canEscalate) {
                result.failureReason = 'Escalation not allowed';
                return result;
            }
            result.escalationFee = fee;
        } catch {
            result.failureReason = 'Failed to check escalation eligibility';
            return result;
        }

        // Execute escalation in module (module may update its state)
        try IResolutionModule(resolutionModule).executeEscalation(workflowId, _msgSender(), escrowData) returns (
            bool escalationSuccess,
            address newResolver,
            uint8 newLevel
        ) {
            if (!escalationSuccess) {
                result.failureReason = 'Module rejected escalation';
                return result;
            }

            // Validate returned values
            if (newResolver == address(0)) {
                result.failureReason = 'Module returned zero address';
                return result;
            }

            result.success = true;
            result.newResolver = newResolver;
            result.newLevel = newLevel;
            return result;
        } catch {
            result.failureReason = 'Module escalation call failed';
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
