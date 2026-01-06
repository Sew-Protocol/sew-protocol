// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.33;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../types/EscrowTypes.sol";

/**
 * @title RecoveryLibrary
 * @notice Library for recovering native ETH and ERC20 tokens sent directly to contracts
 * @dev Extracted from BaseEscrow for contract size reduction
 */
library RecoveryLibrary {
    using SafeERC20 for IERC20;

    /**
     * @notice Recover native ETH
     * @param recipient Address to receive the recovered ETH
     * @param amount Amount of ETH to recover (0 = recover all)
     * @param contractBalance Current contract balance
     * @return recoverAmount Amount actually recovered
     * @dev Reverts if recipient is zero address or amount exceeds balance
     */
    function recoverNativeETH(
        address recipient,
        uint256 amount,
        uint256 contractBalance
    ) internal returns (uint256 recoverAmount) {
        if (recipient == address(0)) {
            revert InvalidAddress("Recipient cannot be zero address", recipient);
        }
        
        recoverAmount = amount == 0 ? contractBalance : amount;
        
        if (recoverAmount == 0) {
            revert InvalidAmount("No ETH to recover");
        }
        
        if (recoverAmount > contractBalance) {
            revert InvalidAmount("Amount exceeds contract balance");
        }
        
        // Use call instead of transfer to avoid 2300 gas limit
        (bool success, ) = payable(recipient).call{value: recoverAmount}("");
        require(success, "ETH transfer failed");
    }

    /**
     * @notice Recover ERC20 tokens
     * @param token ERC20 token address
     * @param recipient Address to receive the recovered tokens
     * @param amount Amount of tokens to recover (0 = recover all)
     * @param contractBalance Current contract balance of the token
     * @return recoverAmount Amount actually recovered
     * @dev Reverts if token or recipient is zero address, or amount exceeds balance
     */
    function recoverERC20(
        address token,
        address recipient,
        uint256 amount,
        uint256 contractBalance
    ) internal returns (uint256 recoverAmount) {
        if (token == address(0)) {
            revert InvalidAddress("Token address cannot be zero", token);
        }
        if (recipient == address(0)) {
            revert InvalidAddress("Recipient cannot be zero address", recipient);
        }
        
        recoverAmount = amount == 0 ? contractBalance : amount;
        
        if (recoverAmount == 0) {
            revert InvalidAmount("No tokens to recover");
        }
        
        if (recoverAmount > contractBalance) {
            revert InvalidAmount("Amount exceeds contract balance");
        }
        
        IERC20(token).safeTransfer(recipient, recoverAmount);
    }
}


