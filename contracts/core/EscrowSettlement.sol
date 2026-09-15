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
error NotParticipant(uint256 workflowId, address caller, address sender, address recipient);
error NotCounterparty(uint256 workflowId, address caller);
error SplitProposalBlocked(uint256 workflowId);
error SplitNotFound(uint256 workflowId);
error SplitExpired(uint256 workflowId, uint64 expiry, uint64 currentTime);
error SplitAmountMismatch(uint256 workflowId, uint256 buyerAmount, uint256 sellerAmount, uint256 expected);
error EscrowNotSettleable(uint256 workflowId, EscrowState currentState);

abstract contract EscrowSettlement is EscrowAccounting {
    event PendingSettlementSet(uint256 indexed workflowId, bool isRelease, uint256 appealDeadline);
    event PendingSettlementCancelled(uint256 indexed workflowId);
    event PendingSettlementExecuted(uint256 indexed workflowId, bool isRelease);
    event SplitProposed(uint256 indexed workflowId, address indexed proposer, uint256 buyerAmount, uint256 sellerAmount, uint64 expiry);
    event SplitAccepted(uint256 indexed workflowId, address indexed accepter, uint256 buyerAmount, uint256 sellerAmount);
    event SplitCancelled(uint256 indexed workflowId, address indexed cancelledBy);

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
    function proposeSplit(
        uint256 workflowId,
        uint256 buyerAmount,
        uint256 sellerAmount,
        uint64 expiry
    ) external nonReentrant {
        _validateWorkflowId(workflowId);
        EscrowTransfer storage et = escrowTransfers[workflowId];

        if (_msgSender() != et.from && _msgSender() != et.to)
            revert NotParticipant(workflowId, _msgSender(), et.from, et.to);

        EscrowState state = et.escrowState;
        if (state != EscrowState.PENDING && state != EscrowState.DISPUTED)
            revert EscrowNotSettleable(workflowId, state);

        if (pendingSettlements[workflowId].exists)
            revert SplitProposalBlocked(workflowId);

        if (buyerAmount + sellerAmount != et.amountAfterFee)
            revert SplitAmountMismatch(workflowId, buyerAmount, sellerAmount, et.amountAfterFee);

        uint64 resolvedExpiry = expiry == 0 ? uint64(block.timestamp + 7 days) : expiry;
        if (resolvedExpiry <= block.timestamp) revert InvalidConfig(0, resolvedExpiry);

        // Cancel any existing proposal (new proposal supersedes old one)
        if (splitProposals[workflowId].active) {
            emit SplitCancelled(workflowId, splitProposals[workflowId].proposer);
        }

        splitProposals[workflowId] = SplitProposal({
            proposer: _msgSender(),
            buyerAmount: buyerAmount,
            sellerAmount: sellerAmount,
            expiry: resolvedExpiry,
            active: true
        });

        emit SplitProposed(workflowId, _msgSender(), buyerAmount, sellerAmount, resolvedExpiry);
    }

    /**
     * @notice Cancel an active split proposal.
     * @dev Only the proposer (or guardian) may cancel.
     */
    function cancelSplit(uint256 workflowId) external nonReentrant {
        _validateWorkflowId(workflowId);
        SplitProposal storage proposal = splitProposals[workflowId];

        if (!proposal.active) revert SplitNotFound(workflowId);

        EscrowTransfer storage et = escrowTransfers[workflowId];
        bool isProposer = proposal.proposer == _msgSender();
        bool isGuardian = hasRole(ROLE_GUARDIAN, _msgSender());
        if (!isProposer && !isGuardian)
            revert NotParticipant(workflowId, _msgSender(), et.from, et.to);

        delete splitProposals[workflowId];
        emit SplitCancelled(workflowId, _msgSender());
    }

    /**
     * @notice Accept an active split proposal, executing mutual settlement.
     * @dev Only the counterparty (non-proposer participant) may accept.
     *      If the escrow is DISPUTED, the active DRM dispute is closed by mutual agreement.
     *      Principal is split per the agreed amounts; yield (if any) is split proportionally.
     *      All settlement is pull-only — no automatic token transfers.
     */
    function acceptSplit(uint256 workflowId) external nonReentrant {
        _validateWorkflowId(workflowId);
        EscrowTransfer storage et = escrowTransfers[workflowId];
        SplitProposal storage proposal = splitProposals[workflowId];

        if (!proposal.active) revert SplitNotFound(workflowId);

        // Only the counterparty may accept
        address counterparty = (proposal.proposer == et.from) ? et.to : et.from;
        if (_msgSender() != counterparty)
            revert NotCounterparty(workflowId, _msgSender());

        if (block.timestamp > proposal.expiry)
            revert SplitExpired(workflowId, proposal.expiry, uint64(block.timestamp));

        // Block if resolver ruling is already in settlement pipeline
        if (pendingSettlements[workflowId].exists)
            revert SplitProposalBlocked(workflowId);

        EscrowState state = et.escrowState;
        if (state != EscrowState.PENDING && state != EscrowState.DISPUTED)
            revert EscrowNotSettleable(workflowId, state);

        if (amountReleased[workflowId] > 0) {
            revert SplitProposalBlocked(workflowId); // partial release prevents split
        }
        uint256 principal = et.amountAfterFee;
        if (proposal.buyerAmount + proposal.sellerAmount != principal)
            revert SplitAmountMismatch(workflowId, proposal.buyerAmount, proposal.sellerAmount, principal);

        uint256 buyerAmount = proposal.buyerAmount;
        uint256 sellerAmount = proposal.sellerAmount;
        address token = et.token;
        address buyer = et.from;
        address seller = et.to;

        // CEI: clear proposal before any state changes
        delete splitProposals[workflowId];

        // Close active dispute in the resolution module (ignores failure gracefully)
        if (state == EscrowState.DISPUTED) {
            _closeDisputeByMutualAgreement(workflowId);
        }

        EscrowState oldState = StateManagementLibrary.transitionToResolved(et, workflowId);
        emit EscrowStateChanged(workflowId, oldState, EscrowState.RESOLVED);

        delete disputeRaisedTimestamp[workflowId];

        // Unwind yield module if active; yield is split proportionally to the principal split
        (uint256 principalOut, uint256 yieldOut) = _handleYieldModuleUnwind(workflowId, token, principal);
        uint256 totalOut = principalOut + yieldOut;

        _updateEscrowBalance(token, principal, false);

        if (yieldOut == 0) {
            if (buyerAmount > 0) _creditClaimable(workflowId, buyer, token, buyerAmount, buyerAmount);
            if (sellerAmount > 0) _creditClaimable(workflowId, seller, token, sellerAmount, sellerAmount);
        } else {
            // Proportional yield split: buyer share = yieldOut * buyerAmount / principal
            uint256 yieldToBuyer = principal > 0 ? (yieldOut * buyerAmount) / principal : 0;
            uint256 yieldToSeller = yieldOut - yieldToBuyer;
            uint256 totalBuyer = buyerAmount + yieldToBuyer;
            uint256 totalSeller = sellerAmount + yieldToSeller;
            if (totalBuyer > 0) _creditClaimable(workflowId, buyer, token, totalBuyer, buyerAmount);
            if (totalSeller > 0) _creditClaimable(workflowId, seller, token, totalSeller, sellerAmount);
        }

        // Suppress unused warning for totalOut (used only when yield is active)
        totalOut;

        emit SplitAccepted(workflowId, _msgSender(), buyerAmount, sellerAmount);
    }

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
        uint256 actualAmount = principal + yield;

        // Pull-only settlement: entitlement creation only
        _updateEscrowBalance(token, amount, false);
        _creditClaimable(workflowId, beneficiary, token, actualAmount, amount);
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
