// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.37;

import '../shared/interfaces/IResolutionModule.sol';
import '../types/EscrowTypes.sol';
import './EscrowEncodingLibrary.sol';

/**
 * @title EscrowDisputeLogic
 * @notice Compile-time dispute derivation, internalized from the formerly
 *         externally deployed DisputeOps contract.
 *
 * @dev Preserves the DisputeOps separation of concerns:
 *      - derive only: returns a result, never mutates escrow state
 *      - no callbacks, no escrow storage access
 *      - all inputs are explicit
 *
 *      The escrow remains the sole authoritative mutator: it calls these
 *      functions, then applies the derived result to escrow state. This keeps
 *      the derive -> result -> apply boundary while removing the runtime trust
 *      and deployment boundary.
 *
 *      INTENTIONAL SEMANTIC DELTA (2b):
 *      The refactored contract has no "dispute calculator unconfigured" state.
 *      All domain behavior is equivalent when the previous DisputeOps dependency
 *      was correctly configured. Differential tests assert exactly that
 *      equivalence and must not attempt to recreate the obsolete unconfigured
 *      state.
 */
library EscrowDisputeLogic {
    /// @dev Result of dispute opening computation.
    struct DisputeOpeningResult {
        bool success;
        address updatedResolver;
        bool callIncentiveHook;
        address incentiveModule;
        string failureReason;
    }

    /// @dev Result of escalation computation.
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
        address predecessorResolver;
        uint256 appealDeadline;
        bytes32 appealedDecisionRoot;
        bytes32 resolutionQuoteRoot;
        string failureReason; // Reason if escalation not allowed
    }

    /**
     * @notice Compute dispute opening parameters.
     * @dev Compute-only: does not modify escrow state.
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
    ) internal view returns (DisputeOpeningResult memory result) {
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
            bytes memory escrowData = EscrowEncodingLibrary.encodeEscrowTransferData(token, from, to, amountAfterFee, address(0));
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
     * @notice Compute escalation for a disputed escrow.
     * @dev The resolution module owns all dispute-domain facts. This layer only
     *      validates caller/state/module and normalizes the authoritative quote.
     *      Bond scaling and fee/net derivation remain with BaseEscrow.
     *      Compute-only: does not modify escrow state.
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
    ) internal view returns (EscalationResult memory result) {
        // Escrow owns all fee and net-bond derivation. Keep these inputs in the
        // stable helper ABI, but do not compose economics outside BaseEscrow.
        bondFeeBps;
        feeRecipient;
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

        // Encode escrow data for module (5-element format matching EscrowEncodingLibrary)
        bytes memory escrowData = EscrowEncodingLibrary.encodeEscrowTransferData(token, from, to, amountAfterFee, address(0));

        // The resolution module owns all dispute-domain facts. Do not compose
        // independent round/resolver/bond queries in this layer.
        IResolutionModule.ResolutionAppealQuote memory quote;
        try IResolutionModule(resolutionModule).quoteAppealTransition(workflowId, escrowContract, escrowData) returns (
            IResolutionModule.ResolutionAppealQuote memory returnedQuote
        ) {
            quote = returnedQuote;
        } catch {
            result.failureReason = 'Failed to quote appeal transition';
            return result;
        }
        result.currentLevel = quote.predecessorRound;
        result.newLevel = quote.successorRound;
        result.newResolver = quote.successorResolver;
        result.predecessorResolver = quote.predecessorResolver;
        result.appealDeadline = quote.appealDeadline;
        result.appealedDecisionRoot = quote.appealedDecisionRoot;
        result.resolutionQuoteRoot = quote.resolutionQuoteRoot;

        // Validate only the disagreed-with participant can appeal
        if (quote.appealedDecision != ResolutionOutcome.NONE) {
            if (quote.appealedDecision == ResolutionOutcome.RELEASE && caller != from) {
                result.failureReason = 'Only sender can appeal RELEASE decision';
                return result;
            } else if (quote.appealedDecision == ResolutionOutcome.CANCEL && caller != to) {
                result.failureReason = 'Only recipient can appeal CANCEL decision';
                return result;
            }
        } else {
            result.failureReason = 'No decision to appeal';
            return result;
        }

        if (!quote.appealable) {
            result.failureReason = 'Escalation not allowed by module';
            return result;
        }
        if (quote.successorResolver == address(0)) {
            result.failureReason = 'Quote has no successor resolver';
            return result;
        }
        result.bondAmount = quote.baseBondAmount;
        result.bondToken = quote.baseBondAsset;

        // Bond presence still requires the snapshotted incentive module. BaseEscrow
        // applies scaling and calculates fee/net after this authoritative quote.
        if (result.bondAmount > 0) {
            if (incentiveModule == address(0)) {
                result.failureReason = 'Appeals not enabled in V1';
                return result;
            }
            result.incentiveModule = incentiveModule;
        }

        result.success = true;
        return result;
    }
}
