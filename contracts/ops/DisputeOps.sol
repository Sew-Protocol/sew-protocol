// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import '@openzeppelin/contracts/access/AccessControl.sol';
import '@openzeppelin/contracts/utils/math/Math.sol';
import '../shared/interfaces/IResolutionModule.sol';
import '../types/EscrowTypes.sol';

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
    using Math for uint256;
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
     * @dev Result of dispute opening computation
     */
    struct DisputeOpeningResult {
        bool success;
        address updatedResolver;
        bool callIncentiveHook;
        address incentiveModule;
        string failureReason;
    }

    /**
     * @notice Compute dispute opening parameters
     * @param resolutionModule Resolution module address
     * @param incentiveModule Snapshotted incentive module address
     * @param workflowId Escrow workflow ID
     * @param caller Address initiating the dispute
     * @param from Escrow sender
     * @param to Escrow recipient
     * @param token Escrow token
     * @param amountAfterFee Amount in escrow
     * @param escrowState Current escrow state
     * @param currentResolver Current resolver address
     * @return result Dispute opening computation result
     */
    function computeDisputeOpening(
        address resolutionModule,
        address escrowContract,
        address incentiveModule,
        uint256 workflowId,
        address caller,
        address from,
        address to,
        address token,
        uint256 amountAfterFee,
        EscrowState escrowState,
        address currentResolver
    ) external view onlyRole(ROLE_ESCROW_CONTRACT) returns (DisputeOpeningResult memory result) {
        result.success = false;

        if (escrowState != EscrowState.PENDING) {
            result.failureReason = 'Transfer not pending';
            return result;
        }

        if (caller != from && caller != to) {
            result.failureReason = 'Caller not participant';
            return result;
        }

        result.updatedResolver = currentResolver;
        if (resolutionModule != address(0) && resolutionModule.code.length > 0) {
            bytes memory escrowData = abi.encode(token, from, to, amountAfterFee);
            try IResolutionModule(resolutionModule).getDisputeResolver(workflowId, escrowContract, escrowData) returns (
                address updated,
                uint8 /* level */
            ) {
                if (updated != address(0)) result.updatedResolver = updated;
            } catch {}
        }

        result.incentiveModule = incentiveModule;
        result.callIncentiveHook = (incentiveModule != address(0));
        result.success = true;
        return result;
    }

    /**
     * @dev Result of escalation computation
     */
    struct EscalationResult {
        bool success; // Whether escalation is allowed
        address newResolver; // New dispute resolver address
        uint8 newLevel; // New escalation level
        uint8 currentLevel; // Current escalation level (for event)
        uint256 bondAmount; // Total bond amount required
        address bondToken; // Token for the bond (address(0) for ETH)
        address incentiveModule; // Incentive module for this escrow
        uint256 bondToRecord; // Net bond amount after fee
        uint256 protocolFeeAmount; // Fee collected by protocol
        string failureReason; // Reason if escalation not allowed
    }

    /**
     * @notice Compute escalation for a disputed escrow
     * @param resolutionModule Address of the resolution module
     * @param incentiveModule Snapshotted incentive module address
     * @param bondFeeBps Snapshotted protocol fee for bonds in basis points
     * @param feeRecipient Protocol fee recipient address
     * @param workflowId Escrow workflow ID
     * @param caller Address initiating the escalation (msg.sender from BaseEscrow)
     * @param from Escrow sender address
     * @param to Escrow recipient address
     * @param token Token address
     * @param amountAfterFee Amount after fee deduction (what's actually held in escrow)
     * @param escrowState Current escrow state
     * @return result Escalation computation result
     */
    function computeEscalation(
        address resolutionModule,
        address escrowContract,
        address incentiveModule,
        uint256 bondFeeBps,
        address feeRecipient,
        uint256 workflowId,
        address caller,
        address from,
        address to,
        address token,
        uint256 amountAfterFee,
        EscrowState escrowState
    ) external view onlyRole(ROLE_ESCROW_CONTRACT) returns (EscalationResult memory result) {
        result.success = false;

        // Validate caller is participant
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
        try IResolutionModule(resolutionModule).getDisputeResolver(workflowId, escrowContract, escrowData) returns (
            address /* currentResolver */,
            uint8 currentLevel
        ) {
            result.currentLevel = currentLevel;
        } catch {
            result.failureReason = 'Failed to get current level';
            return result;
        }

        // Validate only the disagreed-with participant can appeal
        (bool decisionSuccess, bytes memory decisionData) = resolutionModule.staticcall(
            abi.encodeWithSignature('getDecisionAtRound(uint256,address,uint8)', workflowId, escrowContract, result.currentLevel)
        );
        
        if (decisionSuccess && decisionData.length >= 32) {
            uint8 decision;
            assembly {
                decision := and(mload(add(decisionData, 0x20)), 0xff)
            }
            
            if (decision == 1 && caller != from) { // RELEASE -> Recipient wins, Sender must appeal
                result.failureReason = 'Only sender can appeal RELEASE decision';
                return result;
            } else if (decision == 2 && caller != to) { // CANCEL -> Sender wins, Recipient must appeal
                result.failureReason = 'Only recipient can appeal CANCEL decision';
                return result;
            } else if (decision == 0) {
                result.failureReason = 'No decision to appeal';
                return result;
            }
        }

        // Check if escalation is allowed and get next resolver/bond
        try IResolutionModule(resolutionModule).canEscalate(workflowId, escrowContract, result.currentLevel, escrowData)
        returns (bool canEscalate, address nextResolver, uint256 /* dummyFee */) {
            if (!canEscalate) {
                result.failureReason = 'Escalation not allowed by module';
                return result;
            }
            if (nextResolver == address(0)) {
                result.failureReason = 'Escalation not allowed by module';
                return result;
            }
            result.newResolver = nextResolver;
            result.newLevel = result.currentLevel + 1;
        } catch {
            result.failureReason = 'Failed to check escalation eligibility';
            return result;
        }

        // Get required appeal bond
        try IResolutionModule(resolutionModule).getRequiredAppealBond(workflowId, escrowContract, result.currentLevel, escrowData)
        returns (uint256 bondAmount, address bondToken) {
            result.bondAmount = bondAmount;
            result.bondToken = bondToken;
        } catch {
            result.failureReason = 'Failed to query appeal bond';
            return result;
        }

        // Calculate fees if bond is required
        if (result.bondAmount > 0) {
            if (incentiveModule == address(0)) {
                result.failureReason = 'Appeals not enabled in V1';
                return result;
            }
            result.incentiveModule = incentiveModule;
            
            if (bondFeeBps > 0 && feeRecipient != address(0)) {
                result.protocolFeeAmount = Math.mulDiv(result.bondAmount, bondFeeBps, 10000);
                result.bondToRecord = result.bondAmount - result.protocolFeeAmount;
            } else {
                result.bondToRecord = result.bondAmount;
            }
        }

        result.success = true;
        return result;
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
