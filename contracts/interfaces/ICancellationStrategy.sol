// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import "../types/EscrowTypes.sol";

/// @title ICancellationStrategy
/// @notice Pluggable cancellation strategy for per-escrow customization
/// @dev Determines WHO can CANCEL and WHEN
interface ICancellationStrategy is IERC165 {
    /// @notice Determine if a cancellation request can be executed
    /// @dev Called by BaseEscrow.recipientCancel() and senderCancel()
    /// @param workflowId The escrow workflow ID
    /// @param caller The address requesting cancellation (msg.sender)
    /// @param et The EscrowTransfer storage reference
    /// @return canCancel True if cancellation is allowed, false otherwise
    function canCancel(
        uint256 workflowId,
        address caller,
        EscrowTransfer calldata et
    ) external view returns (bool canCancel);

    /// @notice Determine if caller can cancel unilaterally without waiting for other party
    /// @param workflowId The escrow workflow ID
    /// @param caller The address requesting cancellation (msg.sender)
    /// @param et The EscrowTransfer storage reference
    /// @return canCancelUnilaterally True if caller can cancel immediately
    function canCancelUnilaterally(
        uint256 workflowId,
        address caller,
        EscrowTransfer calldata et
    ) external view returns (bool canCancelUnilaterally);

    /// @notice Notify the strategy of a cancellation attempt
    /// @dev Called by BaseEscrow BEFORE executing the cancellation
    /// @dev Allows the strategy to track state (e.g., pending cancel requests)
    /// @param workflowId The escrow workflow ID
    /// @param caller The address requesting cancellation
    /// @param isSuccess Whether the cancellation was successful
    function onCancelAttempt(
        uint256 workflowId,
        address caller,
        bool isSuccess
    ) external;
}
