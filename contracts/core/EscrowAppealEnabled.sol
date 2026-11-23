// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.37;

import './EscrowOptionalSplits.sol';
import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '../../packages/sew-core/contracts/shared/interfaces/IResolutionModule.sol';
import '../../packages/sew-core/contracts/interfaces/IEscrowAppeal.sol';
import '../../packages/sew-core/contracts/libraries/EscrowEncodingLibrary.sol';
import '../../packages/sew-core/contracts/libraries/DisputeEscalationLibrary.sol';
import '../../packages/sew-core/contracts/libraries/EscrowDisputeLogic.sol';
import '../../packages/sew-core/contracts/libraries/BondHandlingLibrary.sol';
import '../../packages/sew-core/contracts/libraries/DisputeInitializationLibrary.sol';
import '../../packages/sew-core/contracts/shared/interfaces/IIncentiveModule.sol';
import '../../packages/sew-core/contracts/shared/interfaces/IResolutionModuleTimeout.sol';
import '../../packages/sew-core/contracts/core/BondCollector.sol';
import '../../packages/sew-core/contracts/arbitration/IKlerosArbitrableProxy.sol';
import '../../packages/sew-core/contracts/modules/decentralized-resolution-module/interfaces/IKlerosHandoffResolutionModule.sol';
import '../../packages/sew-core/contracts/types/EscrowTypes.sol';

/// @notice Optional appeal and Kleros authority transition extension.
/// @dev The Sew core profile inherits BaseEscrow directly and omits this extension.
abstract contract EscrowAppealEnabled is EscrowOptionalSplits {
    error InvalidAppealRequestRole(uint8 role, address provided, address expected);

    function _supportsAppealInterface() internal pure override returns (bool) { return true; }

    function _hasCommittedKlerosHandoff(uint256 workflowId) internal view override returns (bool committed) {
        (committed,) = DisputeInitializationLibrary.committedKlerosHandoff(
            address(_getResolutionModule(workflowId)), address(this), workflowId
        );
    }

    function _prepareDisputeTimeout(
        uint256 workflowId,
        ExecutionSource source,
        ModuleSnapshot storage snap
    ) internal view override {
        (bool committed, uint256 disputeId) = DisputeInitializationLibrary.committedKlerosHandoff(
            address(_getResolutionModule(workflowId)), address(this), workflowId
        );
        if (!committed) {
            super._prepareDisputeTimeout(workflowId, source, snap);
            return;
        }
        if (source != ExecutionSource.GOVERNANCE) {
            revert KlerosArbitrationPending(workflowId, disputeId);
        }
        IResolutionModule resolutionModule = _getResolutionModule(workflowId);
        if (!resolutionModule.supportsInterface(type(IResolutionModuleTimeout).interfaceId)) {
            revert KlerosArbitrationPending(workflowId, disputeId);
        }
    }

    /**
     * @notice Validate and prepare escalation, canceling any pending settlement
     * @param workflowId The escrow ID
     * @return et EscrowTransfer storage reference
     * @return resolutionModule Resolution module for this escrow
     */
    // =====================================================================
    // APPEALS & AUTHORITY TRANSITIONS
    // Appeal quote, payment, and the atomic Kleros handoff / resolver mutation.
    // =====================================================================

    function _validateAndPrepareEscalation(
        uint256 workflowId
    ) internal returns (EscrowTransfer storage et, IResolutionModule resolutionModule) {
        _validateWorkflowId(workflowId);
        et = escrowTransfers[workflowId];
        resolutionModule = _getResolutionModule(workflowId);

        if (pendingSettlements[workflowId].exists) {
            delete pendingSettlements[workflowId];
            emit PendingSettlementCancelled(workflowId);
        }
    }

    // DEPRECATED: _collectEscalationBond removed - use BondCollector instead


    /**
     * @notice Escalate a dispute to the next resolution level
     * @dev V1: Appeals are disabled. This function will revert if called for v1 escrows
     *      (incentiveModule snapshot is null).
     *      resolution module + incentive module swap through governance.
     *
     *      Requires payment of an appeal bond (amount/token determined by resolution module).
     *      Bonds are recorded in the snapshotted incentive module for later distribution.
     *
     * @param workflowId The escrow workflow ID to escalate
     * @return success True if escalation succeeded
     * @return newDisputeResolver Address of the resolver assigned to the next level
     * @return newLevel New escalation level
     */

    function escalateDispute(uint256 workflowId)
        external payable virtual nonReentrant returns (bool success, address newDisputeResolver, uint8 newLevel)
    {
        BaseEscrow.AppealRequest memory request = AppealRequest({
            funder: _msgSender(), operator: _msgSender(), refundRecipient: _msgSender()
        });
        return _appealDispute(workflowId, request);
    }

    function appealDispute(uint256 workflowId, BaseEscrow.AppealRequest calldata request)
        external payable virtual nonReentrant returns (bool success, address newDisputeResolver, uint8 newLevel)
    {
        return _appealDispute(workflowId, request);
    }

    function _appealDispute(uint256 workflowId, BaseEscrow.AppealRequest memory request)
        internal returns (bool success, address newDisputeResolver, uint8 newLevel)
    {
        // Emergency pause gates new escrow intake only. Existing participants
        // retain the right to seek a higher-level review while paused; the
        // configured appeal deadline continues to run.
        address caller = _msgSender();
        if (request.operator != caller) revert InvalidAppealRequestRole(1, request.operator, caller);
        if (request.funder != caller) revert InvalidAppealRequestRole(2, request.funder, caller);
        if (request.refundRecipient == address(0)) revert InvalidAppealRequestRole(3, request.refundRecipient, address(1));
        if (request.refundRecipient != request.operator) revert InvalidAppealRequestRole(3, request.refundRecipient, request.operator);
        (EscrowTransfer storage et, IResolutionModule resolutionModule) = _validateAndPrepareEscalation(workflowId);
        if (escrowSettings[workflowId].customResolver != address(0)) {
            revert AppealsUnsupportedForCustomResolver(workflowId, escrowSettings[workflowId].customResolver);
        }
        ModuleSnapshot storage snap = moduleSnapshots[workflowId];
        address feeRecipient = appealBondFeeRecipients[workflowId];
        if (feeRecipient == address(0)) feeRecipient = escrowFeeAddress;

        EscrowDisputeLogic.EscalationResult memory result = EscrowDisputeLogic.computeEscalation(
            address(resolutionModule),
            address(this),
            snap.incentiveModule,
            snap.appealBondProtocolFeeBps,
            feeRecipient,
            workflowId,
            request.operator,
            et.from,
            et.to,
            et.token,
            et.amountAfterFee,
            et.escrowState
        );
        if (!result.success) revert EscalationNotAllowed();
        bytes32 requestRoot = keccak256(abi.encode(
            "APPEAL_REQUEST_V1",
            block.chainid,
            address(this),
            workflowId,
            result.appealedDecisionRoot,
            request.operator,
            request.funder,
            request.refundRecipient
        ));

        // Deadline safety: do not hard-block escalation with a global cooldown.
        // Keep per-address tracking and linear bond scaling, but allow valid
        // within-window appeals to progress across rounds.
        address escalator = request.operator;
        uint32 priorEscCount = addressEscalationCount[escalator];
        uint32 escCount = priorEscCount + 1;
        addressEscalationCount[escalator] = escCount;
        lastEscalationTimestamp[escalator] = uint64(block.timestamp);
        if (result.bondAmount > 0) {
            if (escCount > 1) {
                uint256 scale100 = 100 + 10 * uint256(escCount - 1);
                result.bondAmount = result.bondAmount * scale100 / 100;
            }
            result.protocolFeeAmount =
                (result.bondAmount * snap.appealBondProtocolFeeBps) / ESCROW_FEE_DENOMINATOR;
            result.bondToRecord = result.bondAmount - result.protocolFeeAmount;
        }
        bytes32 policyRoot = keccak256(abi.encode(
            "ESCROW_APPEAL_POLICY_V1", snap.appealBondProtocolFeeBps, feeRecipient, priorEscCount
        ));
        bytes32 transitionRoot = keccak256(abi.encode(
            "APPEAL_TRANSITION_V1", requestRoot, result.resolutionQuoteRoot,
            result.currentLevel, result.newLevel, result.predecessorResolver, result.newResolver,
            result.bondToken, result.bondAmount, result.protocolFeeAmount, result.bondToRecord, policyRoot
        ));

        // Kleros is an external execution cost, not appeal-bond principal. Requote
        // immediately before invoking it so a fee change cannot leave a phantom round.
        bytes memory escrowData = EscrowEncodingLibrary.encodeEscrowTransferData(
            et.token, et.from, et.to, et.amountAfterFee, escrowSettings[workflowId].releaseAddress
        );
        uint256 klerosCost;
        bytes32 klerosConfigRoot;
        if (result.newLevel == 2) {
            try IKlerosArbitrableProxy(result.newResolver).getArbitrationCost('') returns (uint256 cost) {
                klerosCost = cost;
            } catch {
                revert EscalationNotAllowed();
            }
            klerosConfigRoot = IKlerosArbitrableProxy(result.newResolver).getKlerosHandoffConfigRoot();
        }

        // Validate independent bond and external arbitration payments.
        uint256 bondValue = result.bondToken == address(0) ? result.bondAmount : 0;
        if (msg.value < bondValue + klerosCost) {
            uint256 suppliedKlerosCost = msg.value > bondValue ? msg.value - bondValue : 0;
            revert InvalidKlerosArbitrationFee(workflowId, klerosCost, suppliedKlerosCost);
        }
        (bool msgValueValid, ) = DisputeEscalationLibrary.validateBondMsgValue(
            result.bondToken, result.bondAmount, result.bondToken == address(0) ? msg.value : 0
        );
        if (!msgValueValid) revert InvalidBondMsgValue(workflowId, result.bondAmount, msg.value);

        if (result.bondAmount > 0) {
            if (result.protocolFeeAmount > 0) {
                // Pull-only protocol fee handling: credit claimable ledger instead of auto-push.
                claimableBondProtocolFees[result.bondToken][feeRecipient] += result.protocolFeeAmount;
                emit BondProtocolFeeClaimableCredited(result.bondToken, feeRecipient, result.protocolFeeAmount, workflowId);
                emit ProtocolFeeCollected(1, workflowId, result.bondToken, result.bondAmount, snap.appealBondProtocolFeeBps, result.protocolFeeAmount);
            }

            IIncentiveModule incentiveMod = IIncentiveModule(result.incentiveModule);
            if (result.bondToken == address(0)) {
                BondHandlingLibrary.handleETHBond(incentiveMod, workflowId, request.operator,
                    result.bondToRecord, result.bondToken, result.newLevel,
                    feeRecipient, result.protocolFeeAmount);
            } else {
                if (address(bondCollector) == address(0)) revert ZeroBondCollector();
                uint256 balBefore = IERC20(result.bondToken).balanceOf(address(this));
                _pullTokens(result.bondToken, request.funder, result.bondAmount);
                uint256 received = IERC20(result.bondToken).balanceOf(address(this)) - balBefore;
                if (received < result.bondAmount) revert AccountingDeficit(result.bondToken, result.bondAmount - received);
                BondHandlingLibrary.handleERC20BondAfterPull(incentiveMod, bondCollector, workflowId,
                    request.operator, result.bondToken, result.bondToRecord, result.newLevel,
                    feeRecipient, result.protocolFeeAmount);
            }
        }

        bytes32 handoffRoot;
        if (result.newLevel == 2) {
            handoffRoot = IKlerosHandoffResolutionModule(address(resolutionModule)).prepareKlerosHandoff(
                workflowId, address(this), escrowData, result.resolutionQuoteRoot, klerosConfigRoot
            );
        }

        // Kleros remains only a prepared successor while this call runs. A failure
        // anywhere below rolls back both the preparation and external dispute.
        uint256 klerosDisputeId;
        if (klerosCost > 0 || result.newLevel == 2) {
            klerosDisputeId = IKlerosArbitrableProxy(result.newResolver).createDispute{value: klerosCost}(
                workflowId, address(this), 2, '', escrowData
            );
        }

        (bool modSuccess, address newRes, uint8 newLvl) = result.newLevel == 2
            ? IKlerosHandoffResolutionModule(address(resolutionModule)).commitKlerosHandoff(
                workflowId, address(this), escrowData, result.resolutionQuoteRoot, handoffRoot, klerosConfigRoot, klerosDisputeId
            )
            : resolutionModule.executeEscalationWithQuote(workflowId, address(this), escrowData, result.resolutionQuoteRoot);
        if (!modSuccess || newRes == address(0)) revert EscalationNotAllowed();
        if (newLvl != result.newLevel || newRes != result.newResolver) {
            revert EscalationResultMismatch(result.newLevel, newLvl, result.newResolver, newRes);
        }

        et.disputeResolver = newRes;

        if (msg.value > bondValue + klerosCost) {
            uint256 excess = msg.value - bondValue - klerosCost;
            claimableExcessEthRefunds[_msgSender()] += excess;
            emit ExcessEthRefundCredited(workflowId, _msgSender(), excess);
        }

        emit DisputeEscalated(workflowId, result.currentLevel, newLvl, newRes, _msgSender());
        emit AppealRequested(workflowId, requestRoot, request.operator, request.funder, request.refundRecipient);
        emit AppealTransitionDerived(
            workflowId, requestRoot, transitionRoot, result.resolutionQuoteRoot, result.appealedDecisionRoot,
            result.bondAmount, result.protocolFeeAmount, result.bondToRecord, feeRecipient
        );
        return (true, newRes, newLvl);
    }

    /// @notice Return module-authoritative appeal facts with the frozen escrow economics.
    /// @dev The quote deliberately does not pre-authorize a caller: authorization and
    ///      module quote revalidation remain part of appeal execution.
    function getAppealQuote(uint256 workflowId, address operator)
        external view virtual returns (IEscrowAppeal.AppealQuote memory quote)
    {
        _validateWorkflowId(workflowId);
        if (escrowSettings[workflowId].customResolver != address(0)) return quote;

        IResolutionModule resolutionModule = _getResolutionModule(workflowId);
        if (address(resolutionModule) == address(0)) return quote;

        EscrowTransfer storage et = escrowTransfers[workflowId];
        bytes memory escrowData = EscrowEncodingLibrary.encodeEscrowTransferData(
            et.token, et.from, et.to, et.amountAfterFee, escrowSettings[workflowId].releaseAddress
        );
        IResolutionModule.ResolutionAppealQuote memory resolutionQuote =
            resolutionModule.quoteAppealTransition(workflowId, address(this), escrowData);
        ModuleSnapshot storage snap = moduleSnapshots[workflowId];
        uint256 bondAmount = resolutionQuote.baseBondAmount;
        uint32 priorEscalationCount = addressEscalationCount[operator];

        // Execution increments the operator's count before applying this same scale.
        if (bondAmount > 0 && priorEscalationCount > 0) {
            bondAmount = bondAmount * (100 + 10 * uint256(priorEscalationCount)) / 100;
        }

        address feeRecipient = appealBondFeeRecipients[workflowId];
        if (feeRecipient == address(0)) feeRecipient = escrowFeeAddress;
        uint256 protocolFeeAmount = bondAmount * snap.appealBondProtocolFeeBps / ESCROW_FEE_DENOMINATOR;

        quote = IEscrowAppeal.AppealQuote({
            supported: true,
            appealable: resolutionQuote.appealable,
            predecessorRound: resolutionQuote.predecessorRound,
            successorRound: resolutionQuote.successorRound,
            predecessorResolver: resolutionQuote.predecessorResolver,
            successorResolver: resolutionQuote.successorResolver,
            appealedDecision: resolutionQuote.appealedDecision,
            appealDeadline: resolutionQuote.appealDeadline,
            finalRound: resolutionQuote.finalRound,
            bondAsset: resolutionQuote.baseBondAsset,
            baseBondAmount: resolutionQuote.baseBondAmount,
            bondAmount: bondAmount,
            protocolFeeAmount: protocolFeeAmount,
            bondToRecord: bondAmount - protocolFeeAmount,
            protocolFeeBps: snap.appealBondProtocolFeeBps,
            protocolFeeRecipient: feeRecipient,
            appealedDecisionRoot: resolutionQuote.appealedDecisionRoot,
            resolutionQuoteRoot: resolutionQuote.resolutionQuoteRoot
        });
    }


}
