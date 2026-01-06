// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.33;

import "./BaseEscrow.sol";

/**
 * @title EscrowOps
 * @notice External contract for batch escrow operations
 * @dev Extracted from BaseEscrow for contract size reduction
 *      Provides batch release and cancel operations
 *      Note: Batch operations moved here to reduce BaseEscrow size
 */
contract EscrowOps {
    /**
     * @notice Batch release multiple escrow transfers
     * @return success True if all releases were successful
     * @dev Only sender can release their own escrows. Reverts if any escrow fails validation.
     *      Users should call releaseEscrowTransfer() directly on BaseEscrow for each escrow.
     *      This contract is provided for convenience but may be less gas efficient.
     *      Note: Parameters are unused as this function always reverts.
     */
    function batchReleaseEscrow(
        BaseEscrow /* escrowContract */,
        uint256[] memory /* workflowIds */
    ) external pure returns (bool) {
        // Note: BaseEscrow.releaseEscrowTransfer() is internal
        // Users should call releaseEscrowTransfer() directly on BaseEscrow
        // This function is a placeholder - actual implementation would require
        // BaseEscrow to expose a public batch function or use a different pattern
        revert("Use releaseEscrowTransfer() directly on BaseEscrow for each escrow");
    }

    /**
     * @notice Batch cancel multiple escrow transfers (mutual agreement required)
     * @return success True if batch processing completed
     * @dev Both sender and recipient must agree to cancel (via senderCancel/recipientCancel)
     *      Users should call senderCancel()/recipientCancel() directly on BaseEscrow.
     *      This contract is provided for convenience but may be less gas efficient.
     *      Note: Parameters are unused as this function always reverts.
     */
    function batchCancelEscrow(
        BaseEscrow /* escrowContract */,
        uint256[] memory /* workflowIds */
    ) external pure returns (bool) {
        // Note: Batch cancel logic was removed from BaseEscrow for size reduction
        // Users should call senderCancel()/recipientCancel() directly on BaseEscrow
        revert("Use senderCancel()/recipientCancel() directly on BaseEscrow for each escrow");
    }
}

