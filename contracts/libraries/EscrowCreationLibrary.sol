// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import "../types/EscrowTypes.sol";

library EscrowCreationLibrary {
    function createEscrowTransferStruct(
        address token,
        address seller,
        address from,
        uint256 amountAfterFee,
        address defaultResolver
    ) internal pure returns (EscrowTransfer memory) {
        return EscrowTransfer({
            token: token,
            to: seller,
            from: from,
            amountAfterFee: amountAfterFee,
            escrowState: EscrowState.PENDING,
            senderStatus: SenderStatus.NONE,
            recipientStatus: RecipientStatus.NONE,
            disputeResolver: defaultResolver,
            autoReleaseTime: 0,
            autoCancelTime: 0
        });
    }
}