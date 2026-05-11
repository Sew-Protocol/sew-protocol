// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import './EscrowVault.sol';

/**
 * @title EscrowVaultHelper
 * @notice View and administrative helper functions extracted from EscrowVault to reduce contract size.
 */
contract EscrowVaultHelper {
    EscrowVault public immutable vault;

    constructor(address _vault) {
        vault = EscrowVault(_vault);
    }

    function getAccountingBreakdown(address token) external view returns (
        uint256 principalHeld,
        uint256 feesCollected,
        uint256 contractBalance,
        uint256 yieldInBalance
    ) {
        return vault.getAccountingBreakdown(token);
    }

    function withdrawFees(address token) external {
        vault.withdrawFees(token);
    }
}
