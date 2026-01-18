// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import '../types/YieldPresets.sol';

/**
 * @title YieldPresetLibrary
 * @notice Library for deriving yield distribution data from presets
 * @dev Pure functions for deterministic distribution data derivation.
 *      Presets are simple abstractions - distribution data is derived from preset + addresses.
 */
library YieldPresetLibrary {
    /// @notice Error thrown when an invalid preset is used
    error InvalidYieldPreset();

    /// @notice Error thrown when preset parameters are invalid
    error InvalidAddress(string reason, address addr);

    /**
     * @notice Derive distribution data from preset
     * @param preset The yield preset enum value
     * @param sender The sender address (buyer)
     * @param recipient The recipient address (seller)
     * @return distributionData Encoded (address[] recipients, uint256[] percentages)
     * @dev Returns empty bytes for OFF preset. Returns encoded arrays for enabled presets.
     */
    function deriveDistributionData(
        YieldPreset preset,
        address sender,
        address recipient
    ) internal pure returns (bytes memory distributionData) {
        if (preset == YieldPreset.OFF) {
            return ''; // Empty = no distribution
        }

        if (preset == YieldPreset.TO_SENDER) {
            // Validate sender
            if (sender == address(0)) revert InvalidAddress('Sender cannot be zero', sender);

            // Deterministic: 100% to sender
            address[] memory recipients = new address[](1);
            uint256[] memory percentages = new uint256[](1);
            recipients[0] = sender;
            percentages[0] = 10000; // 100% in basis points

            return abi.encode(recipients, percentages);
        }

        // Unknown preset
        revert InvalidYieldPreset();
    }

    /**
     * @notice Check if yield is enabled for preset
     * @param preset The yield preset enum value
     * @return enabled True if yield should be enabled
     */
    function isYieldEnabled(YieldPreset preset) internal pure returns (bool enabled) {
        return preset != YieldPreset.OFF;
    }

    /**
     * @notice Validate preset parameters
     * @param preset The yield preset enum value
     * @param sender The sender address
     * @param recipient The recipient address
     * @dev Reverts if preset requires addresses that are invalid
     */
    function validatePresetParams(
        YieldPreset preset,
        address sender,
        address recipient
    ) internal pure {
        if (preset == YieldPreset.TO_SENDER) {
            if (sender == address(0)) revert InvalidAddress('Sender cannot be zero', sender);
        }
        // OFF preset requires no addresses
        // Future presets (e.g., YIELD_BOTH) can add their validation here
    }
}
