// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.33;

import "../types/EscrowTypes.sol";

library EscrowCreationLibrary {
    function createEscrowTransferStruct(
        uint256 workflowId,
        address token,
        address seller,
        address from,
        uint256 amount,
        uint256 amountAfterFee,
        address defaultResolver
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
                        attachmentHashes: new bytes32[](0)
                    });
                }
            }
            