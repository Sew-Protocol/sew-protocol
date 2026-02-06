// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import './EscrowVault.sol';

/**
 * @title EscrowVaultAnalytics
 * @notice Provides analytics and accounting breakdown for EscrowVault
 * @dev This is an optional helper contract for off-chain analysis and reporting.
 *      Core protocol logic remains in EscrowVault.
 *      
 *      Pattern: This follows the same architecture as EscrowViewContract,
 *      separating optional analytics from core escrow state machine.
 */
contract EscrowVaultAnalytics {
    EscrowVault public immutable vault;

    constructor(address vaultAddress) {
        require(vaultAddress != address(0), "Invalid vault address");
        vault = EscrowVault(vaultAddress);
    }

    /**
     * @notice Get accounting breakdown for a specific token in the vault
     * @param token Token address
     * @return principalHeld Amount of principal currently in escrow
     * @return feesCollected Accumulated protocol fees
     * @return contractBalance Current token balance in vault
     * @return yieldInBalance Estimated yield earned (contract balance - principal - fees - claimable)
     */
    function getAccountingBreakdown(address token) external view returns (
        uint256 principalHeld,
        uint256 feesCollected,
        uint256 contractBalance,
        uint256 yieldInBalance
    ) {
        principalHeld = vault.totalHeldInEscrowPerToken(token);
        feesCollected = vault.totalFeesPerToken(token);
        contractBalance = IERC20(token).balanceOf(address(vault));
        unchecked {
            uint256 expected = principalHeld + feesCollected + vault.totalClaimableAssets(token);
            yieldInBalance = contractBalance > expected ? contractBalance - expected : 0;
        }
    }
}
