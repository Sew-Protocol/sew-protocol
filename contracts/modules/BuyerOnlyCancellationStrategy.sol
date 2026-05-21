// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import "../interfaces/ICancellationStrategy.sol";
import "../types/EscrowTypes.sol";

/// @title BuyerOnlyCancellationStrategy
/// @notice Allows buyer (recipient) to cancel anytime without seller consent
/// @dev Useful for scenarios where buyer has unilateral cancel rights
contract BuyerOnlyCancellationStrategy is ICancellationStrategy {
    
    /**
     * @notice ERC-165 interface detection
     * @param interfaceId The interface identifier, as specified in ERC-165
     * @return True if the contract implements interfaceId
     */
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return interfaceId == type(ICancellationStrategy).interfaceId;
    }

    /// @notice Check if cancellation is allowed
    /// @dev Only buyer (recipient) can cancel at any time
    function canCancel(
        uint256 workflowId,
        address caller,
        EscrowTransfer calldata et
    ) external pure returns (bool) {
        // Only recipient can cancel
        return caller == et.to;
    }

    /// @notice Buyer-only strategy allows unilateral cancellation
    function canCancelUnilaterally(
        uint256 workflowId,
        address caller,
        EscrowTransfer calldata et
    ) external pure returns (bool) {
        return caller == et.to;
    }

    /// @notice No tracking needed for buyer-only cancellation
    function onCancelAttempt(
        uint256 workflowId,
        address caller,
        bool isSuccess
    ) external pure {
        // No state to track - buyer can cancel anytime
    }
}
