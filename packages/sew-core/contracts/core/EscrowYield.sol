// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.37;

import './EscrowCreation.sol';
import '../interfaces/IYieldModule.sol';
import '../types/YieldPresets.sol';

// Yield owns escrow-level yield-module orchestration: depositing principal on
// creation and unwinding it on release/cancel. It declares no storage of its
// own; EscrowStorage remains the sole state owner.
error PartialRecoveryNotAllowed();
error YieldUnwindUnavailable(uint256 workflowId, address token, address module, uint256 principal);

abstract contract EscrowYield is EscrowCreation {
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
                // FEE TREATMENT (policy): emergency recovery returns an UNDIFFERENTIATED
                // recovered amount, which core does not classify as principal vs yield and so
                // does not subject to the protocol yield fee (yieldOut = 0 below => zero fee).
                // This is intentionally asymmetric with the normal unwind path (which splits
                // principal/yield and taxes realized positive yield) and applies even when the
                // recovered amount exceeds the recorded principal. Recovery operators are
                // privileged incident actors; choosing the recovery path may waive yield fees.
                return (recovered, 0);
            } catch {
                // Preserve the escrow's recovery identity and unwind the entire
                // settlement transaction. No ordinary claim may be created until
                // the yield position has actually returned assets to this vault.
                revert YieldUnwindUnavailable(workflowId, token, module, yieldPrincipal);
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
