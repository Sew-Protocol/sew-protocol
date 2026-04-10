// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import "../../contracts/core/EscrowVault.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title EscrowVaultHarness
 * @notice Certora verification harness for EscrowVault.
 *
 * Extends EscrowVault with CVL-friendly view helpers that expose individual
 * struct fields as scalar return values.  The Certora Prover cannot easily
 * decompose Solidity struct returns from public array getters; these wrappers
 * eliminate that friction.
 *
 * This file is ONLY used by the Certora Prover.  It is not deployed and must
 * not be imported by production code.
 *
 * Harness invariant: no behavioural changes are introduced — every function
 * here is a pure projection of existing storage.
 */
contract EscrowVaultHarness is EscrowVault {

    // -------------------------------------------------------------------------
    // Constructor mirrors EscrowVault — required so the harness compiles
    // -------------------------------------------------------------------------
    constructor(
        uint256 escrowFeeBps,
        address feeAddress,
        address yieldOpsAddress,
        address disputeOpsAddress,
        address moduleManagementAddress
    ) EscrowVault(escrowFeeBps, feeAddress, yieldOpsAddress, disputeOpsAddress, moduleManagementAddress) {}

    // -------------------------------------------------------------------------
    // EscrowTransfer projections
    // -------------------------------------------------------------------------

    /// @dev Returns the ERC20 token address locked in a workflow.
    function getEscrowToken(uint256 workflowId) external view returns (address) {
        return escrowTransfers[workflowId].token;
    }

    /// @dev Returns the amount held after fee deduction.
    function getAmountAfterFee(uint256 workflowId) external view returns (uint256) {
        return escrowTransfers[workflowId].amountAfterFee;
    }

    /// @dev Returns the sender (buyer) of a workflow.
    function getEscrowFrom(uint256 workflowId) external view returns (address) {
        return escrowTransfers[workflowId].from;
    }

    /// @dev Returns the recipient (seller) of a workflow.
    function getEscrowTo(uint256 workflowId) external view returns (address) {
        return escrowTransfers[workflowId].to;
    }

    /// @dev Returns the EscrowState of a workflow as uint8 for CVL consumption.
    ///      BaseEscrow.getEscrowState returns the EscrowState enum which CVL
    ///      can already consume; this variant makes the uint8 cast explicit.
    function getEscrowStateUint(uint256 workflowId) external view returns (uint8) {
        return uint8(escrowTransfers[workflowId].escrowState);
    }

    // -------------------------------------------------------------------------
    // EscrowSettings projections
    // -------------------------------------------------------------------------

    /// @dev Returns the per-escrow custom resolver override (address(0) if not set).
    function getCustomResolver(uint256 workflowId) external view returns (address) {
        return escrowSettings[workflowId].customResolver;
    }

    // -------------------------------------------------------------------------
    // PendingSettlement projections
    // -------------------------------------------------------------------------

    /// @dev Returns true if a pending settlement exists for the workflow.
    function getPendingSettlementExists(uint256 workflowId) external view returns (bool) {
        return pendingSettlements[workflowId].exists;
    }

    /// @dev Returns the appeal deadline timestamp for a pending settlement.
    function getPendingSettlementDeadline(uint256 workflowId) external view returns (uint256) {
        return pendingSettlements[workflowId].appealDeadline;
    }

    // -------------------------------------------------------------------------
    // Accounting helpers
    // -------------------------------------------------------------------------

    /// @dev Vault's ERC-20 balance of `token`.  Used by solvency rules so the
    ///      spec can reference the balance through a single envfree function
    ///      rather than an external call that CVL must inline.
    function getTokenBalance(address token) external view returns (uint256) {
        return IERC20(token).balanceOf(address(this));
    }

    // Note: getEscrowCount() is already declared in BaseEscrow — use that
    //       directly in CVL rather than adding a duplicate here.

    // -------------------------------------------------------------------------
    // EscrowState uint8 constants for CVL require/assert expressions
    // CVL cannot reference Solidity enums by name; using these named constants
    // in the spec improves readability compared to bare integer literals.
    // -------------------------------------------------------------------------
    uint8 public constant STATE_NONE     = 0; // EscrowState.NONE
    uint8 public constant STATE_PENDING  = 1; // EscrowState.PENDING
    uint8 public constant STATE_RELEASED = 2; // EscrowState.RELEASED
    uint8 public constant STATE_REFUNDED = 3; // EscrowState.REFUNDED
    uint8 public constant STATE_DISPUTED = 4; // EscrowState.DISPUTED
    uint8 public constant STATE_RESOLVED = 5; // EscrowState.RESOLVED
}
