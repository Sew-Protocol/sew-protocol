// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.37;

import '../../packages/sew-core/contracts/core/BaseEscrow.sol';
import '../../packages/sew-core/contracts/types/EscrowTypes.sol';
import '../../packages/sew-core/contracts/libraries/StateManagementLibrary.sol';

error NotParticipant(uint256 workflowId, address caller, address sender, address recipient);
error NotCounterparty(uint256 workflowId, address caller);
error SplitProposalBlocked(uint256 workflowId);
error SplitNotFound(uint256 workflowId);
error SplitExpired(uint256 workflowId, uint64 expiry, uint64 currentTime);
error SplitAmountMismatch(uint256 workflowId, uint256 buyerAmount, uint256 sellerAmount, uint256 expected);
error EscrowNotSettleable(uint256 workflowId, EscrowState currentState);

abstract contract EscrowOptionalSplits is BaseEscrow {
    event SplitProposed(uint256 indexed workflowId, address indexed proposer, uint256 buyerAmount, uint256 sellerAmount, uint64 expiry);
    event SplitAccepted(uint256 indexed workflowId, address indexed accepter, uint256 buyerAmount, uint256 sellerAmount);
    event SplitCancelled(uint256 indexed workflowId, address indexed cancelledBy);

    function proposeSplit(
        uint256 workflowId,
        uint256 buyerAmount,
        uint256 sellerAmount,
        uint64 expiry
    ) external virtual nonReentrant {
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

    function cancelSplit(uint256 workflowId) external virtual nonReentrant {
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

    function acceptSplit(uint256 workflowId) external virtual nonReentrant {
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

        // Unwind yield module if active; yield is split proportionally to the principal split.
        // The protocol yield fee (snapshotted at escrow creation) is charged first on gross
        // yield and credited to totalFeesPerToken; the remaining yield is split pro-rata so
        // conservation holds exactly: principalOut + yieldOut == principal + beneficiary + fee.
        (, uint256 yieldOut) = _handleYieldModuleUnwind(workflowId, token, principal);
        uint256 feeAmount = _computeYieldProtocolFee(workflowId, token, yieldOut);
        uint256 yieldAfterFee = yieldOut - feeAmount;

        _updateEscrowBalance(token, principal, false);

        if (yieldAfterFee == 0) {
            if (buyerAmount > 0) _creditClaimable(workflowId, buyer, token, buyerAmount, buyerAmount);
            if (sellerAmount > 0) _creditClaimable(workflowId, seller, token, sellerAmount, sellerAmount);
        } else {
            // Proportional yield split: buyer share = yieldAfterFee * buyerAmount / principal
            uint256 yieldToBuyer = principal > 0 ? (yieldAfterFee * buyerAmount) / principal : 0;
            uint256 yieldToSeller = yieldAfterFee - yieldToBuyer;
            uint256 totalBuyer = buyerAmount + yieldToBuyer;
            uint256 totalSeller = sellerAmount + yieldToSeller;
            if (totalBuyer > 0) _creditClaimable(workflowId, buyer, token, totalBuyer, buyerAmount);
            if (totalSeller > 0) _creditClaimable(workflowId, seller, token, totalSeller, sellerAmount);
        }

        emit SplitAccepted(workflowId, _msgSender(), buyerAmount, sellerAmount);
    }
}
