// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import '../types/EscrowTypes.sol';

/**
 * @title IEscrowCore
 * @notice Minimal protocol interface for escrow implementations
 * 
 * @dev IMPORTANT: This is a protocol interface for internal clarity and integrator discovery.
 *      It is NOT a standard (ERC-ESCR) and should not be treated as a long-term stability guarantee.
 *      This interface documents the core surface area of escrow contracts as of v1.
 *
 * Design principles:
 * - Intentionally mirrors current behavior (v1) - NOT a redesign
 * - Additive only: new features in v1.x as additional functions
 * - Breaking changes will bump to v2.0 and require migration
 * - Future disputes/resolution semantics may be split into separate interfaces
 * - No claims of standardization until post-feedback from integrators + Magicians consensus
 *
 * @dev Implementers should provide clear documentation of:
 * - Which token(s) this escrow accepts (single-token vs multi-token)
 * - Dispute handling flow (direct resolution vs module-based)
 * - Settlement mechanics (push vs pull, and under what conditions)
 */
interface IEscrowCore {
    // ============ Core Data Structures ============



    /// @notice Resolution mode for an escrow (how disputes are handled)
    enum ResolutionMode {
        CUSTOM_RESOLVER,     // Uses custom resolver set in EscrowSettings
        RESOLUTION_MODULE,   // Uses default resolution module
        DIRECT               // No resolver configured (fallback)
    }

    // ============ View: Core Queries ============

    /// @notice Total number of escrow transfers created in this contract
    /// @return count Total workflow count
    function getEscrowCount() external view returns (uint256 count);

    /// @notice Query the current state of an escrow workflow
    /// @param workflowId Unique escrow identifier
    /// @return state Current EscrowState (NONE, PENDING, RELEASED, REFUNDED, DISPUTED, RESOLVED)
    function getEscrowState(uint256 workflowId) external view returns (EscrowState state);

    /// @notice Query resolution mode for an escrow (direct vs module-based)
    /// @param workflowId Unique escrow identifier
    /// @return mode ResolutionMode enum describing resolution strategy
    /// @dev Critical for integrators: determines who can resolve disputes
    function getResolutionMode(uint256 workflowId) external view returns (ResolutionMode mode);

    /// @notice Query the active dispute handler for a workflow
    /// @param workflowId Unique escrow identifier
    /// @return handler Address of the resolver/module handling the dispute, or address(0) if not disputed
    /// @dev Returns address(0) if escrow is not in DISPUTED state
    function getActiveDisputeHandler(uint256 workflowId) external view returns (address handler);

    // ============ Core Actions: Creation ============

    /// @notice Create a new escrow (signature varies by implementation)
    /// @dev This is intentionally NOT defined - implementation details differ between single/multi token
    /// @dev Implementing contracts should expose their own createEscrow() variants with proper documentation
    // function createEscrow(...) public;

    // ============ Core Actions: Settlement (Happy Path) ============

    /// @notice Release escrow (core action for settlement)
    /// @param workflowId Unique escrow identifier
    /// @dev Transitions PENDING → RELEASED
    /// @dev May transfer funds immediately (push) or make claimable (fallback)
    /// @dev Only callable by sender (buyer) when escrow is PENDING
    /// @dev Part of IEscrowCore interface for wallet adoption
    function release(uint256 workflowId) external;

    /// @notice Withdraw claimable funds (fallback when push transfer failed)
    /// @param workflowId Unique escrow identifier
    /// @return amount Actual amount withdrawn
    /// @dev Used when release() could not push funds immediately
    /// @dev Requires escrow to be RELEASED, REFUNDED, or RESOLVED
    function withdrawEscrow(uint256 workflowId) external returns (uint256 amount);

    /// @notice Sender cancels pending escrow and recovers funds
    /// @param workflowId Unique escrow identifier
    /// @return success True if cancellation succeeded
    function senderCancel(uint256 workflowId) external returns (bool success);

    /// @notice Recipient cancels pending escrow
    /// @param workflowId Unique escrow identifier
    /// @return success True if cancellation succeeded
    function recipientCancel(uint256 workflowId) external returns (bool success);

    // ============ Core Actions: Dispute Resolution ============

    /// @notice Raise a dispute on a pending escrow
    /// @param workflowId Unique escrow identifier
    /// @dev Moves escrow from PENDING -> DISPUTED
    /// @dev Caller must be participant (sender or recipient)
    function raiseDispute(uint256 workflowId) external;

    /// @notice Execute settlement after dispute resolution
    /// @param workflowId Unique escrow identifier
    /// @dev Requires escrow to be in RESOLVED state
    function executePendingSettlement(uint256 workflowId) external;

    // ============ Wallet Helpers: Action Eligibility ============

    /// @notice Get wallet-friendly action status for an escrow
    /// @param workflowId Unique escrow identifier
    /// @return actionMask Bitmask of available actions (see note below)
    /// @return nextUpdateTime When this status may change (0 = no timed changes)
    /// @dev Bitmask bits (append-only in future versions):
    ///   bit 0: can call release()
    ///   bit 1: can call senderCancel()
    ///   bit 2: can call recipientCancel()
    ///   bit 3: can call raiseDispute()
    ///   bit 4: can call withdrawEscrow() (claimable fallback)
    /// @dev Caller should check caller's role (sender/recipient/resolver)
    /// @dev Returns actions that MAY succeed; authorization still enforced
    function getActionStatus(uint256 workflowId) external view returns (uint256 actionMask, uint256 nextUpdateTime);

    /// @notice Get escrow data for wallet rendering (without needing logs)
    /// @param workflowId Unique escrow identifier
    /// @return sender Sender address
    /// @return recipient Recipient address
    /// @return amount Amount at stake (after fee deduction)
    /// @return token Token address (or address(this) for ERC20 escrow)
    /// @return state Current EscrowState
    function getEscrowData(uint256 workflowId) external view returns (
        address sender,
        address recipient,
        uint256 amount,
        address token,
        EscrowState state
    );

    /// @notice Get claimable balance for a recipient (if push settlement failed)
    /// @param workflowId Unique escrow identifier
    /// @param account Address to check balance for
    /// @return claimable Amount available to withdraw via withdrawEscrow()
    /// @dev Used by wallets to show "You have X to withdraw"
    function getClaimableBalance(uint256 workflowId, address account) external view returns (uint256 claimable);

    /// @notice Check if a release is allowed for the given escrow and caller
    /// @param workflowId The escrow transfer ID
    /// @param caller The address attempting to release
    /// @return allowed True if release is allowed
    function canRelease(uint256 workflowId, address caller) external view returns (bool allowed);

    // ============ Events: Core Lifecycle ============

    /// @notice Emitted when new escrow is created
    /// @param workflowId Unique escrow identifier
    /// @param from Sender address
    /// @param to Recipient address
    /// @param amount Principal amount (before fee deduction)
    event EscrowCreated(uint256 indexed workflowId, address indexed from, address indexed to, uint256 amount);

    /// @notice Emitted when escrow is released/withdrawn
    /// @param workflowId Unique escrow identifier
    /// @param to Recipient who received funds
    /// @param amount Amount transferred
    event EscrowReleased(uint256 indexed workflowId, address indexed to, uint256 amount);

    /// @notice Emitted when escrow is cancelled
    /// @param workflowId Unique escrow identifier
    /// @param from Sender who received refund
    /// @param amount Amount refunded
    event EscrowCancelled(uint256 indexed workflowId, address indexed from, uint256 amount);

    /// @notice Emitted when dispute is raised
    /// @param workflowId Unique escrow identifier
    /// @param raiser Address that initiated the dispute
    event DisputeRaised(uint256 indexed workflowId, address indexed raiser);

    /// @notice Emitted when dispute is resolved
    /// @param workflowId Unique escrow identifier
    /// @param winner Address receiving settlement (sender or recipient)
    /// @param amount Settlement amount
    event DisputeResolved(uint256 indexed workflowId, address indexed winner, uint256 amount);
}
