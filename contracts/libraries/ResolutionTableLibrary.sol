// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

/**
 * @title ResolutionTableLibrary
 * @notice Library for escrow categorization and table management
 */
library ResolutionTableLibrary {
    function getAmountTier(uint256 amount) internal pure returns (string memory) {
        if (amount < 1e18) return 'SMALL';
        if (amount < 10e18) return 'MEDIUM';
        if (amount < 100e18) return 'LARGE';
        return 'VERY_LARGE';
    }

    function autoCategorize(bytes calldata escrowData) internal pure returns (bytes32) {
        if (escrowData.length < 128) return bytes32(0);
        (address token, , , uint256 amount) = abi.decode(
            escrowData,
            (address, address, address, uint256)
        );
        return keccak256(abi.encode(token, getAmountTier(amount)));
    }
}
