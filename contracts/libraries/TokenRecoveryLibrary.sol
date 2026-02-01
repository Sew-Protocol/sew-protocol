// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import '../types/EscrowTypes.sol';

/**
 * @title TokenRecoveryLibrary
 * @notice Library for token recovery logic extraction
 * @dev Extracted from EscrowVault to reduce contract size
 */
library TokenRecoveryLibrary {
    using SafeERC20 for IERC20;

    /**
     * @notice Calculate and execute token recovery
     * @param totalHeldInEscrowPerToken Storage mapping for held amounts
     * @param totalFeesPerToken Storage mapping for fee amounts
     * @param token Token address to recover
     * @param recipient Recipient address
     * @param amount Amount to recover (0 = recover all available)
     * @return success True if recovery succeeded
     * @return recoveryAmount Actual amount recovered (0 if failed)
     * @return available Available amount for recovery
     * @dev Caller should revert with AmountExceedsAvailable if success is false
     */
    function recoverERC20(
        mapping(address => uint256) storage totalHeldInEscrowPerToken,
        mapping(address => uint256) storage totalFeesPerToken,
        mapping(address => uint256) storage totalClaimablePerToken,
        address token,
        address recipient,
        uint256 amount
    ) internal returns (bool success, uint256 recoveryAmount, uint256 available) {
        uint256 balance = IERC20(token).balanceOf(address(this));
        uint256 protected = totalHeldInEscrowPerToken[token] + totalFeesPerToken[token] + totalClaimablePerToken[token];
        available = balance > protected ? balance - protected : 0;
        recoveryAmount = amount == 0 ? available : amount;
        if (recoveryAmount == 0 || recoveryAmount > available) {
            return (false, 0, available);
        }
        IERC20(token).safeTransfer(recipient, recoveryAmount);
        return (true, recoveryAmount, available);
    }
}
