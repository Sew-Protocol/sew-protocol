// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.37;

import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import './EscrowYield.sol';
import '../types/EscrowTypes.sol';

// Accounting owns claimable entitlements and pull-based withdrawals. It declares
// no storage of its own; EscrowStorage remains the sole state owner.
error NoClaimableBalance(uint256 workflowId, address recipient, address token);
error TransferNotFinalized(uint256 workflowId, EscrowState currentState);
error NoClaimableBondProtocolFee(address token, address recipient);
error ExcessRefundTransferFailed(uint256 workflowId, address recipient, uint256 amount);
error EscrowInsufficientBalance();

abstract contract EscrowAccounting is EscrowYield {
    event ClaimableBalanceSet(
        uint256 indexed workflowId,
        address indexed recipient,
        address indexed token,
        uint256 amount
    );
    event EscrowWithdrawn(
        uint256 indexed workflowId,
        address indexed recipient,
        address indexed token,
        uint256 amount
    );
    event BondProtocolFeeClaimed(
        address indexed token,
        address indexed feeRecipient,
        uint256 amount
    );
    event ExcessEthRefundClaimed(address indexed account, uint256 amount);

    function _validateWorkflowId(uint256 workflowId) internal view virtual;

    /**
     * @notice Claim accrued bond protocol fees via explicit pull.
     * @param token Token address (address(0) for ETH)
     * @param recipient Recipient to receive claimed amount
     * @return claimed Amount claimed
     * @dev CEI + nonReentrant + transfer-last.
     */
    function claimBondProtocolFees(address token, address recipient) external nonReentrant returns (uint256 claimed) {
        if (recipient != _msgSender()) revert InvalidAddress(ADDR_RECIPIENT, recipient);

        uint256 amount = claimableBondProtocolFees[token][recipient];
        if (amount == 0) revert NoClaimableBondProtocolFee(token, recipient);

        // Effects first
        claimableBondProtocolFees[token][recipient] = 0;

        // Interactions last
        if (token == address(0)) {
            (bool success, ) = payable(recipient).call{value: amount}("");
            if (!success) {
                // Restore state on failed transfer
                claimableBondProtocolFees[token][recipient] = amount;
                revert InvalidAddress(ADDR_RECIPIENT, recipient);
            }
        } else {
            _transferTokens(token, recipient, amount);
        }

        emit BondProtocolFeeClaimed(token, recipient, amount);
        return amount;
    }

    function claimExcessEthRefund() external nonReentrant returns (uint256 claimed) {
        uint256 amount = claimableExcessEthRefunds[_msgSender()];
        if (amount == 0) revert NoClaimableBondProtocolFee(address(0), _msgSender());
        claimableExcessEthRefunds[_msgSender()] = 0;
        (bool success, ) = payable(_msgSender()).call{value: amount}("");
        if (!success) {
            claimableExcessEthRefunds[_msgSender()] = amount;
            revert ExcessRefundTransferFailed(0, _msgSender(), amount);
        }
        emit ExcessEthRefundClaimed(_msgSender(), amount);
        return amount;
    }

    function _creditClaimable(
        uint256 workflowId,
        address recipient,
        address token,
        uint256 amount,
        uint256 principalExpected
    ) internal {
        if (amount == 0) return;

        // If module reports yield (amount > principal), escrow must hold it.
        if (amount > principalExpected) {
            uint256 bal = IERC20(token).balanceOf(address(this));
            if (bal < amount) revert EscrowInsufficientBalance();
        }

        claimableBalances[workflowId][recipient] += amount;
        totalClaimableAssets[token] += amount;
        emit ClaimableBalanceSet(workflowId, recipient, token, amount);
    }

    function withdrawEscrow(uint256 workflowId) external nonReentrant returns (uint256) {
        _validateWorkflowId(workflowId);
        EscrowTransfer storage et = escrowTransfers[workflowId];

        if (et.escrowState != EscrowState.PENDING &&
            et.escrowState != EscrowState.RESOLVED &&
            et.escrowState != EscrowState.RELEASED &&
            et.escrowState != EscrowState.REFUNDED) {
            revert TransferNotFinalized(workflowId, et.escrowState);
        }

        address token = et.token; // Single token per escrow
        uint256 amount = claimableBalances[workflowId][_msgSender()];
        if (amount == 0) revert NoClaimableBalance(workflowId, _msgSender(), token);

        claimableBalances[workflowId][_msgSender()] = 0;
        totalClaimableAssets[token] -= amount;

        _transferTokens(token, _msgSender(), amount);

        emit EscrowWithdrawn(workflowId, _msgSender(), token, amount);
        return amount;
    }

    function _transferTokens(address token, address to, uint256 amount) internal virtual;
    function _updateEscrowBalance(address token, uint256 amount, bool add) internal virtual override;
}
