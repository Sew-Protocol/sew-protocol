// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import "../interfaces/ICancellationStrategy.sol";
import "../types/EscrowTypes.sol";

/// @title DefaultCancellationStrategy
/// @notice Implements mutual consent cancellation (default behavior)
/// @dev Both sender AND recipient must call cancel separately
contract DefaultCancellationStrategy is ICancellationStrategy {
    
    /**
     * @notice ERC-165 interface detection
     * @param interfaceId The interface identifier, as specified in ERC-165
     * @return True if the contract implements interfaceId
     */
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return interfaceId == type(ICancellationStrategy).interfaceId;
    }

    /// @notice Track which party has initiated cancellation for each escrow
    /// @dev address(0) = no pending cancel, otherwise = address of initiating party
    mapping(uint256 => address) public pendingCancel;

    error NotAuthorizedToCancelYet(uint256 workflowId, address caller);

    /// @notice Check if cancellation is allowed
    /// @dev First caller (any participant): can initiate request
    /// @dev Second caller (other participant): can execute
    function canCancel(
        uint256 workflowId,
        address caller,
        EscrowTransfer calldata et
    ) external view returns (bool) {
        // Only sender or recipient can cancel
        if (caller != et.from && caller != et.to) {
            return false;
        }

        address pending = pendingCancel[workflowId];
        
        if (pending == address(0)) {
            // No pending cancel yet - first caller can always initiate
            return true;
        }
        
        // Already have a pending cancel from someone
        // Second caller can proceed only if they're the OTHER party
        return (caller == et.from && pending == et.to) ||
               (caller == et.to && pending == et.from);
    }

    /// @notice Default strategy requires mutual consent - never unilateral
    function canCancelUnilaterally(
        uint256 workflowId,
        address caller,
        EscrowTransfer calldata et
    ) external pure returns (bool) {
        return false;
    }

    /// @notice Track cancellation attempt
    /// @dev Stores initiating party on first call, clears on successful second call
    function onCancelAttempt(
        uint256 workflowId,
        address caller,
        bool isSuccess
    ) external {
        address pending = pendingCancel[workflowId];

        if (pending == address(0)) {
            // First caller - record them if successful
            if (isSuccess) {
                pendingCancel[workflowId] = caller;
            }
        } else {
            // Second caller - clear on success (cancel executed)
            if (isSuccess) {
                delete pendingCancel[workflowId];
            }
            // If unsuccessful, keep pending state (allow retry)
        }
    }
}
