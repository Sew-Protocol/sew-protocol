// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.37;

import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '../../../contracts/core/EscrowVault.sol';

/**
 * @title EscrowVaultAnalytics
 * @notice Provides analytics and accounting breakdown for EscrowVault
 * @dev This is a test/off-chain helper contract for accounting analysis and reporting.
 *      It is not a deployed production contract; it is used by the test suite as a
 *      cast-based reader over an existing EscrowVault.
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
