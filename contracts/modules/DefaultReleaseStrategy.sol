// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import '../interfaces/IReleaseStrategy.sol';
import '@openzeppelin/contracts/utils/introspection/ERC165.sol';

/**
 * @title DefaultReleaseStrategy
 * @notice Default release strategy: buyer-initiated release only
 * @dev Implements: only the sender (buyer) who created the escrow can release it
 * @dev Uses canonical escrowData encoding: abi.encode(token, sender, recipient, amountAfterFee)
 */
contract DefaultReleaseStrategy is IReleaseStrategy, ERC165 {
    // Reason codes (match IReleaseStrategy documentation)
    uint8 private constant REASON_ALLOWED = 0;
    uint8 private constant REASON_NOT_AUTHORIZED = 1;

    /**
     * @notice Check if release is allowed (only sender/buyer can release)
     * @param workflowId The escrow workflow ID
     * @param escrowContract The escrow contract address (unused, for interface compatibility)
     * @param caller The address attempting to release
     * @param escrowData Encoded as: abi.encode(token, sender, recipient, amountAfterFee)
     * @return allowed True if caller is the sender (buyer)
     * @return reasonCode 0 if allowed, 1 if caller is not the sender
     */
    function canRelease(
        uint256 workflowId,
        address escrowContract,
        address caller,
        bytes calldata escrowData
    ) external pure override returns (bool allowed, uint8 reasonCode) {
        // Decode escrowData to get sender address
        // Expected format: abi.encode(token, sender, recipient, amountAfterFee)
        (address token, address sender, address recipient, uint256 amountAfterFee) = abi.decode(
            escrowData,
            (address, address, address, uint256)
        );

        // Only the sender (buyer) can release
        if (caller == sender) {
            return (true, REASON_ALLOWED);
        } else {
            return (false, REASON_NOT_AUTHORIZED);
        }
    }

    /**
     * @notice Execute release (not used in v1, reserved for v2)
     * @dev In v1, BaseEscrow handles all release logic directly
     * @dev Reverts to prevent reliance on unimplemented behavior
     */
    function executeRelease(
        uint256 workflowId,
        address escrowContract,
        bytes calldata escrowData
    ) external pure override returns (bool success) {
        revert('DefaultReleaseStrategy: executeRelease not implemented in v1');
    }

    /**
     * @notice Get strategy name
     */
    function strategyName() external pure override returns (string memory) {
        return 'DefaultBuyerRelease';
    }

    /**
     * @notice Get the module name (alias for strategyName for consistency)
     * @return name The module name
     */
    function moduleName() external pure override returns (string memory name) {
        return 'DefaultBuyerRelease';
    }

    /**
     * @notice Get the module version
     * @return version The module version (semantic versioning)
     */
    function moduleVersion() external pure override returns (string memory version) {
        return '1.0.0';
    }

    /**
     * @notice Check if contract supports an interface
     * @param interfaceId The interface identifier
     * @return supported True if interface is supported
     */
    function supportsInterface(
        bytes4 interfaceId
    ) public view virtual override(ERC165, IERC165) returns (bool) {
        return
            interfaceId == type(IReleaseStrategy).interfaceId ||
            super.supportsInterface(interfaceId);
    }
}
