// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.37;

import './EscrowCreation.sol';
import '../interfaces/IYieldModule.sol';
import '../types/YieldPresets.sol';

// Yield owns escrow-level yield-module orchestration: depositing principal on
// creation and unwinding it on release/cancel. It declares no storage of its
// own; EscrowStorage remains the sole state owner.
error PartialRecoveryNotAllowed();

abstract contract EscrowYield is EscrowCreation {
    event YieldUnwindFailed(
        uint256 indexed workflowId,
        address indexed token,
        uint256 principal
    );

    /**
     * @notice Handle v2.5 yield module unwind on release/cancel
     * @dev If no module or no initialized yield, returns original amount
     * @dev Otherwise delegates to module for unwind (which handles all recovery)
     * @dev If unwind reverts, tries emergencyUnwind as fallback
     */
    function _handleYieldModuleUnwind(
        uint256 workflowId,
        address token,
        uint256 amount
    ) internal virtual returns (uint256 principalOut, uint256 yieldOut) {
        address module = v25YieldModules[workflowId];
        if (module == address(0)) return (amount, 0);

        uint256 yieldPrincipal = v25YieldPrincipals[workflowId];
        if (yieldPrincipal == 0) return (amount, 0);

        // Try normal unwind first
        try IYieldModule(module).unwindToEscrow(workflowId, token, yieldPrincipal) returns (uint256 principal, uint256 yield) {
            delete v25YieldModules[workflowId];
            delete v25YieldPrincipals[workflowId];
            return (principal, yield);
        } catch {
            // Unwind failed - try emergency unwind
            try IYieldModule(module).emergencyUnwind(workflowId, token, yieldPrincipal) returns (uint256 recovered) {
                // INVARIANT: Reject partial recovery - must recover full principal or revert
                if (recovered < yieldPrincipal) revert PartialRecoveryNotAllowed();
                delete v25YieldModules[workflowId];
                delete v25YieldPrincipals[workflowId];
                return (recovered, 0);
            } catch {
                // Both unwind paths failed — tokens are stuck in yield module.
                // Complete the release lifecycle using the remaining escrow balance so
                // the escrow is not permanently frozen; admin must recover tokens from
                // the yield module.  Using yieldPrincipal here would inflate claimable
                // when partial release occurred (yieldPrincipal > remaining amount).
                // Settlement remains claimable-only; admin must recover assets separately.
                emit YieldUnwindFailed(workflowId, token, yieldPrincipal);
                delete v25YieldModules[workflowId];
                delete v25YieldPrincipals[workflowId];
                return (amount, 0);
            }
        }
    }

    function _depositYieldForEscrow(uint256 workflowId, address token, uint256 amount) internal virtual override {
        IYieldModule genModule = _getYieldGenerationModule(workflowId);
        if (address(genModule) != address(0)) {
            (bool supported, ) = genModule.canHandle(token, YieldPreset.OFF, amount);
            if (supported) {
                // Call _depositForYield which is overridden in child contracts (EscrowVault/EscrowableERC20)
                // This allows child contracts to set approvals before calling the module
                _depositForYield(genModule, workflowId, token, amount);
            }
        }
    }

    // Implemented by concrete escrow products to set approvals and deposit.
    function _depositForYield(
        IYieldModule genModule,
        uint256 workflowId,
        address token,
        uint256 amount
    ) internal virtual;
}
