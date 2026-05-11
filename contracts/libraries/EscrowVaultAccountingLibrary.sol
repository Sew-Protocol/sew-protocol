// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import '@openzeppelin/contracts/token/ERC20/IERC20.sol';

library EscrowVaultAccountingLibrary {
    function getAccountingBreakdown(
        mapping(address => uint256) storage totalHeldInEscrowPerToken,
        mapping(address => uint256) storage totalFeesPerToken,
        mapping(address => uint256) storage totalClaimableAssets,
        address vaultAddress,
        address token
    ) external view returns (
        uint256 principalHeld,
        uint256 feesCollected,
        uint256 contractBalance,
        uint256 yieldInBalance
    ) {
        principalHeld = totalHeldInEscrowPerToken[token];
        feesCollected = totalFeesPerToken[token];
        contractBalance = IERC20(token).balanceOf(vaultAddress);
        unchecked {
            uint256 expected = principalHeld + feesCollected + totalClaimableAssets[token];
            yieldInBalance = contractBalance > expected ? contractBalance - expected : 0;
        }
    }
}
