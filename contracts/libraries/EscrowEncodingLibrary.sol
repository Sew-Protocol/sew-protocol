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
     * @param from Sender address
     * @param to Recipient address
     * @param amount Current amount
     * @param originalAmount Original amount
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
     * @return from Sender address
     * @return to Recipient address
     * @return amount Current amount
     * @return originalAmount Original amount
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

