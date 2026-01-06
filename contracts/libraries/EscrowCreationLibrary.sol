// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.33;

import "../types/EscrowTypes.sol";

/**
 * @title EscrowCreationLibrary
 * @notice Library for common escrow creation logic after token transfer
 * @dev Extracted from EscrowVault and EscrowableERC20 to reduce contract size
 *      Handles common post-transfer logic: struct creation, state updates, module snapshotting
 */
library EscrowCreationLibrary {
    /**
     * @dev Create EscrowTransfer struct with common fields
     * @param workflowId The workflow ID
     * @param token Token address
     * @param seller Recipient address
     * @param from Sender address
     * @param amount Original amount (before fee)
     * @param amountAfterFee Amount after fee deduction
     * @param defaultResolver Default dispute resolver address
     * @param resolutionModule Resolution module address
     * @param releaseStrategy Release strategy address
     * @param yieldGenModule Yield generation module address
     * @param yieldDistModule Yield distribution module address
     * @return escrowTransfer The created EscrowTransfer struct
     */
    function createEscrowTransferStruct(
        uint256 workflowId,
        address token,
        address seller,
        address from,
        uint256 amount,
        uint256 amountAfterFee,
        address defaultResolver,
        address resolutionModule,
        address releaseStrategy,
        address yieldGenModule,
        address yieldDistModule
    ) internal pure returns (EscrowTransfer memory escrowTransfer) {
        escrowTransfer = EscrowTransfer({
            workflowId: workflowId,
            token: token,
            to: seller,
            from: from,
            remainingBalance: amountAfterFee,
            totalDeposited: amount,
            escrowState: EscrowState.PENDING,
            senderStatus: SenderStatus.NONE,
            recipientStatus: RecipientStatus.NONE,
            disputeResolver: defaultResolver,
            autoReleaseTime: 0,
            autoCancelTime: 0,
            attachmentURIs: new string[](0),
            attachmentHashes: new bytes32[](0),
            metadata: "",
            snapshotResolutionModule: resolutionModule,
            snapshotReleaseStrategy: releaseStrategy,
            snapshotYieldGenerationModule: yieldGenModule,
            snapshotYieldDistributionModule: yieldDistModule
        });
    }
}
