// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import "../types/EscrowTypes.sol";

/**
 * @title SettingsValidationLibrary
 * @notice Library for validating escrow settings
 * @dev Extracted from BaseEscrow to reduce contract size
 */
library SettingsValidationLibrary {
    /// @notice Maximum auto time duration (10 years in seconds)
    uint256 public constant MAX_AUTO_TIME_DURATION = 10 * 365 * 24 * 60 * 60;

    /**
     * @dev Validate a single auto time value
     * @param autoTime The auto time to validate (0 means no auto time, which is valid)
     * @param currentTime Current block timestamp
     * @param timeType Description of the time type for error messages
     * @dev Reverts if autoTime is in the past or exceeds MAX_AUTO_TIME_DURATION from current block timestamp
     */
    function validateAutoTime(
        uint256 autoTime,
        uint256 currentTime,
        string memory timeType
    ) internal pure {
        if (autoTime == 0) {
            return; // 0 means no auto time, which is valid
        }
        
        // Validate time is in the future
        if (autoTime <= currentTime) {
            revert InvalidAutoTime(
                string.concat(timeType, " must be in the future"),
                autoTime,
                currentTime
            );
        }
        
        // Validate time doesn't exceed maximum duration
        uint256 maxAllowedTime = currentTime + MAX_AUTO_TIME_DURATION;
        if (autoTime > maxAllowedTime) {
            revert AutoTimeExceedsMaxLimit(autoTime, maxAllowedTime);
        }
    }

    /**
     * @dev Validate escrow settings
     * @param settings EscrowSettings struct to validate
     * @param currentTime Current block timestamp
     * @dev Reverts if settings are invalid (e.g., both auto times set, invalid times, etc.)
     */
    function validateEscrowSettings(
        EscrowSettings memory settings,
        uint256 currentTime
    ) internal pure {
        // Validate auto times
        if (settings.autoReleaseTime != 0 && settings.autoCancelTime != 0) {
            revert CannotSetBothAutoTimes(settings.autoReleaseTime, settings.autoCancelTime);
        }
        
        // Validate auto times using helper function
        validateAutoTime(settings.autoReleaseTime, currentTime, "Auto release time");
        validateAutoTime(settings.autoCancelTime, currentTime, "Auto cancel time");
        
        // Validate custom resolver if set
        if (settings.customResolver != address(0)) {
            // Could add additional validation here (e.g., isContract check)
            // For now, just ensure it's not zero address (already checked above)
        }
    }

    /**
     * @dev Get default escrow settings
     * @return Default settings struct with all fields set to default values
     */
    function getDefaultSettings() internal pure returns (EscrowSettings memory) {
        return EscrowSettings({
            customResolver: address(0),
            yieldEnabled: false,
            autoReleaseTime: 0,
            autoCancelTime: 0,
            escrowType: EscrowType.STANDARD
        });
    }
}

