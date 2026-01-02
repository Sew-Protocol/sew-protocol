// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

/**
 * @title EscrowEncodingLibrary
 * @notice Library for encoding/decoding escrow-related data
 * @dev Extracted from BaseEscrow to reduce contract size
 */
library EscrowEncodingLibrary {
    /**
     * @dev Encode escrow transfer data
     * @param token Token address
     * @param from Sender address (buyer)
     * @param to Recipient address (seller)
     * @param amount Remaining balance (current amount in escrow)
     * @param originalAmount Total deposited (original amount)
     * @return Encoded data as bytes
     */
    function encodeEscrowTransferData(
        address token,
        address from,
        address to,
        uint256 amount,
        uint256 originalAmount
    ) internal pure returns (bytes memory) {
        return abi.encode(token, from, to, amount, originalAmount);
    }

    /**
     * @dev Decode escrow transfer data
     * @param data Encoded data
     * @return token Token address
     * @return from Sender address (buyer)
     * @return to Recipient address (seller)
     * @return amount Remaining balance (current amount in escrow)
     * @return originalAmount Total deposited (original amount)
     */
    function decodeEscrowTransferData(
        bytes memory data
    ) internal pure returns (
        address token,
        address from,
        address to,
        uint256 amount,
        uint256 originalAmount
    ) {
        return abi.decode(data, (address, address, address, uint256, uint256));
    }
}

