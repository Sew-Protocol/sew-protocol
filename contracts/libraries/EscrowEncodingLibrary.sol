// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

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
     * @param amountAfterFee Amount after fee deduction (what's actually held in escrow)
     * @return Encoded data as bytes
     */
    function encodeEscrowTransferData(
        address token,
        address from,
        address to,
        uint256 amountAfterFee
    ) internal pure returns (bytes memory) {
        return abi.encode(token, from, to, amountAfterFee);
    }

    /**
     * @dev Decode escrow transfer data
     * @param data Encoded data
     * @return token Token address
     * @return from Sender address (buyer)
     * @return to Recipient address (seller)
     * @return amountAfterFee Amount after fee deduction
     */
    function decodeEscrowTransferData(
        bytes memory data
    ) internal pure returns (address token, address from, address to, uint256 amountAfterFee) {
        return abi.decode(data, (address, address, address, uint256));
    }
}
