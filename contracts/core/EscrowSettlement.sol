// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.37;

import './EscrowAccounting.sol';
import '../libraries/EscrowSettlementLogic.sol';
import '../libraries/StateManagementLibrary.sol';
import '../shared/interfaces/IResolutionModule.sol';
import '../types/EscrowTypes.sol';

// Settlement owns pending-settlement execution and mutual split proposals. It
// declares no storage of its own; EscrowStorage remains the sole state owner.
error NoPendingSettlement(uint256 workflowId);
error AppealWindowNotExpired(uint256 workflowId, uint256 appealDeadline, uint256 currentTime);
error NotInDisputedState(uint256 workflowId, EscrowState currentState);

abstract contract EscrowSettlement is EscrowAccounting {
    event PendingSettlementSet(uint256 indexed workflowId, bool isRelease, uint256 appealDeadline);
    event PendingSettlementCancelled(uint256 indexed workflowId);
    event PendingSettlementExecuted(uint256 indexed workflowId, bool isRelease);
        // Emitted whenever protocol yield fee is realized on settlement. Provides an
    // independent reconstruction source for the 30% protocol share of yield
    // (R = P + B + F conservation; see _computeYieldProtocolFee).
    event YieldProtocolFeeCollected(
        uint256 indexed workflowId,
        address indexed token,
        uint256 grossYield,
        uint256 feeBps,
        uint256 feeAmount
    );

    // SETTLEMENT-REALIZATION SEAM. Local finality today is the stored
    // `PendingSettlement.appealDeadline`; a future adjudication closure would be
    // verified here before the terminal transition. Enforcement stays local: a
    // remote decision message must never itself be settlement authority.
    function executePendingSettlement(uint256 workflowId) external nonReentrant {
        _validateWorkflowId(workflowId);
        EscrowTransfer storage et = escrowTransfers[workflowId];
        _authorizeTimedAction(et);
        PendingSettlement storage pending = pendingSettlements[workflowId];

        EscrowSettlementLogic.SettlementPendingSettlement memory pendingMem = _convertPendingSettlement(pending);
        (bool canExecute, bool isRelease) =
            EscrowSettlementLogic.computePendingSettlementExecution(workflowId, pendingMem, et.escrowState);
        if (!canExecute) {
            if (!pending.exists) revert NoPendingSettlement(workflowId);
            if (block.timestamp < pending.appealDeadline) revert AppealWindowNotExpired(workflowId, pending.appealDeadline, block.timestamp);
            revert NotInDisputedState(workflowId, et.escrowState);
        }
        delete pendingSettlements[workflowId];
        IResolutionModule resolutionModule = _getResolutionModule(workflowId);
        if (address(resolutionModule) != address(0)) _finalizeDisputeInModule(workflowId);
        if (isRelease) _releaseEscrowTransfer(workflowId);
        else _cancelAndRefund(workflowId);

        emit PendingSettlementExecuted(workflowId, isRelease);
    }

    /**
     * @notice Propose a mutual split settlement of an escrow.
     * @dev Either participant may propose. A new proposal replaces any existing one.
     *      Blocked if a resolver ruling is already in the pending settlement pipeline.
     * @param workflowId Escrow ID
     * @param buyerAmount Amount (in escrow token) to credit to the sender (et.from)
     * @param sellerAmount Amount (in escrow token) to credit to the recipient (et.to)
     * @param expiry Unix timestamp after which the proposal lapses; 0 = default 7 days
     */


    /**
     * @notice Cancel an active split proposal.
     * @dev Only the proposer (or guardian) may cancel.
     */


    /**
     * @notice Accept an active split proposal, executing mutual settlement.
     * @dev Only the counterparty (non-proposer participant) may accept.
     *      If the escrow is DISPUTED, the active DRM dispute is closed by mutual agreement.
     *      Principal is split per the agreed amounts; yield (if any) is split proportionally.
     *      All settlement is pull-only — no automatic token transfers.
     */


    function _convertPendingSettlement(PendingSettlement storage pending) internal view returns (EscrowSettlementLogic.SettlementPendingSettlement memory pendingMem) {
        return EscrowSettlementLogic.SettlementPendingSettlement({
            exists: pending.exists,
            isRelease: pending.isRelease,
            appealDeadline: pending.appealDeadline,
            resolutionHash: pending.resolutionHash
        });
    }

    function _finalizeClaimableSettlement(
        uint256 workflowId,
        address token,
        uint256 amount,
        address beneficiary
    ) internal {
        (uint256 principal, uint256 yield) = _handleYieldModuleUnwind(workflowId, token, amount);
        // Charge the snapshotted protocol yield fee on realized positive yield only.
        // Fee is credited to the pull-based totalFeesPerToken bucket (withdrawn via
        // withdrawFees by the fee recipient), never taken from principal, and never
        // negative: principal + (yield - fee) + fee == principal + yield (conservation).
        uint256 feeAmount = _computeYieldProtocolFee(workflowId, token, yield);
        uint256 beneficiaryYield = yield - feeAmount;
        uint256 actualAmount = principal + beneficiaryYield;

        // Pull-only settlement: entitlement creation only
        _updateEscrowBalance(token, amount, false);
        _creditClaimable(workflowId, beneficiary, token, actualAmount, amount);
    }

    /**
     * @notice Compute and record the protocol yield fee on realized positive yield.
     * @param workflowId Escrow ID whose snapshotted fee rate applies
     * @param token Underlying token of the yield
     * @param grossYield Realized gross yield (R - P), already 0 or positive
     * @return feeAmount Protocol fee in underlying token units
     *
     * Economic model:
     *   P = principal deposited, R = assets recovered from Aave
     *   Y = max(R - P, 0)               realized positive yield
     *   F = floor(Y * feeBps / 10_000)  protocol yield fee
     *   B = Y - F                       beneficiary yield
     *   conservation: R = P + B + F (exact, only F is floored)
     *
     * The fee is NEVER charged against principal: if R <= P then Y = 0 and F = 0, so a
     * loss never becomes a fee obligation. The rate is snapshotted at escrow creation
     * (moduleSnapshots[workflowId].yieldProtocolFeeBps), so a later governance change to
     * yieldProtocolFeeBps does not retroactively alter in-flight escrows. Proceeds are
     * credited to the pull-based totalFeesPerToken bucket (reclassifying part of the
     * escrow's yieldInBalance into feesCollected) with no external treasury call.
     * The position is deleted by the module on unwind, so the same yield cannot be
     * realized/charged twice.
     */
    function _computeYieldProtocolFee(
        uint256 workflowId,
        address token,
        uint256 grossYield
    ) internal returns (uint256 feeAmount) {
        if (grossYield == 0) return 0;
        uint256 feeBps = moduleSnapshots[workflowId].yieldProtocolFeeBps;
        if (feeBps == 0) return 0;
        feeAmount = (grossYield * feeBps) / ESCROW_FEE_DENOMINATOR;
        if (feeAmount > 0) {
            _recordFee(token, feeAmount);
            emit YieldProtocolFeeCollected(workflowId, token, grossYield, feeBps, feeAmount);
        }
    }

    function _clearPendingSettlementIfExists(uint256 workflowId) internal {
        if (pendingSettlements[workflowId].exists) {
            delete pendingSettlements[workflowId];
            emit PendingSettlementCancelled(workflowId);
        }
    }

    // Implemented by downstream responsibility components / the composition root.
    function _authorizeTimedAction(EscrowTransfer storage et) internal view virtual;
    function _finalizeDisputeInModule(uint256 workflowId) internal virtual;
    function _closeDisputeByMutualAgreement(uint256 workflowId) internal virtual;
    function _releaseEscrowTransfer(uint256 workflowId) internal virtual;
    function _cancelAndRefund(uint256 workflowId) internal virtual;
}
