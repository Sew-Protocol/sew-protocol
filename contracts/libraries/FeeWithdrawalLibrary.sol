// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import '../types/EscrowTypes.sol';
import '../core/BaseEscrow.sol';

/**
 * @title FeeWithdrawalLibrary
 * @notice Library for fee withdrawal logic
 * @dev Extracted from EscrowVault to reduce contract size
 */
library FeeWithdrawalLibrary {
    using SafeERC20 for IERC20;
    
    /**
     * @notice Withdraw fees for a token
     * @param totalFeesPerToken Storage mapping of token => total fees
     * @param token Token address
     * @param feeRecipient Address to receive fees
     * @return feeAmount Amount of fees withdrawn
     */
    function withdrawFees(
        mapping(address => uint256) storage totalFeesPerToken,
        address token,
        address feeRecipient
    ) internal returns (uint256 feeAmount) {
        feeAmount = totalFeesPerToken[token];
        if (feeAmount == 0) revert NoFeesToWithdraw(token, feeAmount);
        uint256 balance = IERC20(token).balanceOf(address(this));
        if (balance < feeAmount) revert InsufficientContractBalance(token, feeAmount, balance);
        IERC20(token).safeTransfer(feeRecipient, feeAmount);
        totalFeesPerToken[token] = 0;
    }
}
