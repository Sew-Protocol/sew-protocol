// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

/**
 * @title SlowLaneQueueActivate
 * @notice Abstract contract providing two-step queue/activate pattern for Slow lane governance
 * @dev Enforces 7-day delay for high-risk changes (module swaps, fee recipient, etc.)
 *
 * Usage:
 * 1. Inherit this contract
 * 2. Add storage for pending values (PendingAddress or PendingUint)
 * 3. Implement queueX() function calling _queueAddress() or _queueUint()
 * 4. Implement activateX() function calling _activateAddress() or _activateUint()
 *
 * Pattern:
 * - queueX() stores pending value and ETA (now + 7 days)
 * - activateX() checks ETA has passed, then applies the change
 * - This enforces 7-day delay on top of Timelock's 48h delay
 *
 * Example:
 * ```solidity
 * PendingAddress private _pendingFeeRecipient;
 *
 * function queueFeeRecipient(address newAddr) external onlyRole(ROLE_TIMELOCK) {
 *     _queueAddress(_pendingFeeRecipient, newAddr);
 *     emit FeeRecipientQueued(feeRecipient, newAddr, _pendingFeeRecipient.eta);
 * }
 *
 * function activateFeeRecipient() external onlyRole(ROLE_TIMELOCK) {
 *     address old = feeRecipient;
 *     feeRecipient = _activateAddress(_pendingFeeRecipient);
 *     emit FeeRecipientActivated(old, feeRecipient);
 * }
 * ```
 */
abstract contract SlowLaneQueueActivate {
    /// @notice Slow lane delay: 7 days
    uint256 public constant SLOW_DELAY = 7 days;

    /// @notice Pending address change with ETA
    struct PendingAddress {
        address value;
        uint64 eta; // Unix timestamp when activation is allowed
        bool exists;
    }

    /// @notice Pending uint256 change with ETA
    struct PendingUint {
        uint256 value;
        uint64 eta; // Unix timestamp when activation is allowed
        bool exists;
    }

    /// @notice Error thrown when trying to activate before ETA
    error NotReady(uint64 eta);

    /// @notice Error thrown when no pending change exists
    error NoPending();

    /// @notice Error thrown when value is invalid (e.g., zero address)
    error InvalidValue();

    /**
     * @notice Queue an address change
     * @param pending Storage reference to PendingAddress
     * @param newValue New address value to queue
     * @dev Sets pending value and ETA = now + SLOW_DELAY
     */
    function _queueAddress(PendingAddress storage pending, address newValue) internal {
        if (newValue == address(0)) {
            revert InvalidValue();
        }
        pending.value = newValue;
        pending.eta = uint64(block.timestamp + SLOW_DELAY); // forge-lint: disable-line(unsafe-typecast)
        pending.exists = true;
    }

    /**
     * @notice Activate a queued address change
     * @param pending Storage reference to PendingAddress
     * @return activatedValue The activated address value
     * @dev Reverts if no pending change or ETA not reached
     */
    function _activateAddress(PendingAddress storage pending) internal returns (address) {
        if (!pending.exists) {
            revert NoPending();
        }
        if (block.timestamp < pending.eta) {
            revert NotReady(pending.eta);
        }
        address value = pending.value;
        // Clear all fields
        pending.value = address(0);
        pending.eta = 0;
        pending.exists = false;
        return value;
    }

    /**
     * @notice Queue a uint256 change
     * @param pending Storage reference to PendingUint
     * @param newValue New uint256 value to queue
     * @dev Sets pending value and ETA = now + SLOW_DELAY
     */
    function _queueUint(PendingUint storage pending, uint256 newValue) internal {
        pending.value = newValue;
        pending.eta = uint64(block.timestamp + SLOW_DELAY); // forge-lint: disable-line(unsafe-typecast)
        pending.exists = true;
    }

    /**
     * @notice Activate a queued uint256 change
     * @param pending Storage reference to PendingUint
     * @return activatedValue The activated uint256 value
     * @dev Reverts if no pending change or ETA not reached
     */
    function _activateUint(PendingUint storage pending) internal returns (uint256) {
        if (!pending.exists) {
            revert NoPending();
        }
        if (block.timestamp < pending.eta) {
            revert NotReady(pending.eta);
        }
        uint256 value = pending.value;
        // Clear all fields
        pending.value = 0;
        pending.eta = 0;
        pending.exists = false;
        return value;
    }

    /**
     * @notice Get pending address value (if exists)
     * @param pending Storage reference to PendingAddress
     * @return value Pending address value
     * @return eta Timestamp when activation is allowed
     * @return exists Whether a pending change exists
     */
    function getPendingAddress(
        PendingAddress storage pending
    ) internal view returns (address value, uint64 eta, bool exists) {
        return (pending.value, pending.eta, pending.exists);
    }

    /**
     * @notice Get pending uint256 value (if exists)
     * @param pending Storage reference to PendingUint
     * @return value Pending uint256 value
     * @return eta Timestamp when activation is allowed
     * @return exists Whether a pending change exists
     */
    function getPendingUint(
        PendingUint storage pending
    ) internal view returns (uint256 value, uint64 eta, bool exists) {
        return (pending.value, pending.eta, pending.exists);
    }
}
