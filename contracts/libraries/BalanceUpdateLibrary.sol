// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import '../types/EscrowTypes.sol';
import '../core/BaseEscrow.sol';

/**
 * @title BalanceUpdateLibrary
 * @notice Library for updating escrow balance tracking with validation
 * @dev Extracted from EscrowVault to reduce contract size
 */
library BalanceUpdateLibrary {

    /**
     * @notice Update escrow balance tracking
     * @param totalHeldInEscrowPerToken Storage mapping of token => total held
     * @param token Token address
     * @param amount Amount to add or subtract
     * @param add True to add, false to subtract
     */
    function updateBalance(
        mapping(address => uint256) storage totalHeldInEscrowPerToken,
        address token,
        uint256 amount,
        bool add
    ) internal {
        if (token == address(0)) revert InvalidAddress(ADDR_TOKEN, token);
        if (add) {
            totalHeldInEscrowPerToken[token] += amount;
        } else {
            if (totalHeldInEscrowPerToken[token] < amount) {
                revert BalanceUnderflow(token, totalHeldInEscrowPerToken[token], amount);
            }
            totalHeldInEscrowPerToken[token] -= amount;
        }
    }
}
