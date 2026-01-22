// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import '../types/EscrowTypes.sol';

/**
 * @title FeeRecordingLibrary
 * @notice Library for recording fees with overflow protection
 * @dev Extracted from EscrowVault to reduce contract size
 */
library FeeRecordingLibrary {

    /**
     * @notice Record a fee with overflow protection
     * @param totalFeesPerToken Storage mapping of token => total fees
     * @param token Token address
     * @param amount Fee amount to record
     */
    function recordFee(
        mapping(address => uint256) storage totalFeesPerToken,
        address token,
        uint256 amount
    ) internal {
        uint256 currentFees = totalFeesPerToken[token];
        if (amount > type(uint256).max - currentFees) revert FeeOverflow();
        totalFeesPerToken[token] = currentFees + amount;
    }
}
