// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.37;

/// @notice Escrow-side callback for an authenticated resolution-module authority transition.
interface IResolverAssignmentCallback {
    /// @dev `resolver == address(0)` clears a timed-out assignment when no replacement exists.
    function updateDisputeResolverFromResolutionModule(uint256 workflowId, address resolver) external;
}
