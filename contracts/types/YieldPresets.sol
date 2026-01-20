// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

/**
 * @title YieldPresets
 * @notice Yield configuration presets for escrows
 * @dev Simple enum for yield configuration. Distribution is derived deterministically.
 */
enum YieldPreset {
    OFF,           // No yield (default)
    TO_SENDER      // Yield goes to sender (buyer) - 100%
}
