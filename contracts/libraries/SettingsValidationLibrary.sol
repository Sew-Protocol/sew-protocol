// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import "../types/EscrowTypes.sol";

/**
 * @title SettingsValidationLibrary
 * @notice Library for validating escrow settings with bounds enforcement
 * @dev Extracted from BaseEscrow to reduce contract size. Phase 6: Added bounds validation.
 */
library SettingsValidationLibrary {
    /// @notice Maximum auto time duration (10 years in seconds)
    uint256 public constant MAX_AUTO_TIME_DURATION = 10 * 365 * 24 * 60 * 60;
    
    // Phase 6: Bounds constants
    uint256 public constant MAX_AUTO_TIME_DAYS = 30 days;
    uint256 public constant MAX_ATTACHMENTS = 20;
    uint256 public constant MAX_FEE_BPS = 200; // 2%
    uint256 public constant MIN_RESOLUTION_DELAY = 48 hours;
    uint256 public constant MAX_RESOLUTION_DELAY = 30 days;
    uint256 public constant MIN_YIELD_RECIPIENTS = 1;
    uint256 public constant MAX_YIELD_RECIPIENTS = 10;
    uint256 public constant BPS_DENOMINATOR = 10_000;
    
    // Phase 6: Custom errors (using different names to avoid conflicts with EscrowTypes)
    error OutOfBounds(bytes32 key, uint256 value, uint256 min, uint256 max);
    error InvalidAddressKey(bytes32 key);
    error InvalidArrayLength(bytes32 key, uint256 a, uint256 b);
    error InvalidBpsSum(uint256 sum);
    error TooManyRecipients(uint256 n, uint256 max);
    error DuplicateRecipient(address recipient);

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
        
        // Validate custom dispute resolver if set
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

    // ============ Phase 6: Bounds Validation Functions ============

    /**
     * @notice Validate auto cancel time (default setting)
     * @param t Absolute timestamp (0 means disabled, which is valid)
     * @dev Bounds: t must be within 30 days from current block timestamp
     */
    function validateAutoCancel(uint256 t) internal view {
        if (t == 0) {
            return; // 0 means disabled, which is valid
        }
        uint256 currentTime = block.timestamp;
        if (t <= currentTime) {
            revert OutOfBounds("autoCancelTime", t, currentTime + 1, currentTime + MAX_AUTO_TIME_DAYS);
        }
        if (t > currentTime + MAX_AUTO_TIME_DAYS) {
            revert OutOfBounds("autoCancelTime", t, currentTime + 1, currentTime + MAX_AUTO_TIME_DAYS);
        }
    }

    /**
     * @notice Validate auto release time (default setting)
     * @param t Absolute timestamp (0 means disabled, which is valid)
     * @dev Bounds: t must be within 30 days from current block timestamp
     */
    function validateAutoRelease(uint256 t) internal view {
        if (t == 0) {
            return; // 0 means disabled, which is valid
        }
        uint256 currentTime = block.timestamp;
        if (t <= currentTime) {
            revert OutOfBounds("autoReleaseTime", t, currentTime + 1, currentTime + MAX_AUTO_TIME_DAYS);
        }
        if (t > currentTime + MAX_AUTO_TIME_DAYS) {
            revert OutOfBounds("autoReleaseTime", t, currentTime + 1, currentTime + MAX_AUTO_TIME_DAYS);
        }
    }

    /**
     * @notice Validate max attachments
     * @param n Maximum number of attachments
     * @dev Bounds: 0 <= n <= 20
     */
    function validateMaxAttachments(uint256 n) internal pure {
        if (n > MAX_ATTACHMENTS) {
            revert OutOfBounds("maxAttachments", n, 0, MAX_ATTACHMENTS);
        }
    }

    /**
     * @notice Validate fee in basis points
     * @param bps Fee in basis points (100 = 1%)
     * @dev Bounds: 0 <= bps <= 200 (0% to 2%)
     */
    function validateFeeBps(uint256 bps) internal pure {
        if (bps > MAX_FEE_BPS) {
            revert OutOfBounds("escrowFee", bps, 0, MAX_FEE_BPS);
        }
    }

    /**
     * @notice Validate resolution module delay
     * @param d Delay in seconds
     * @dev Bounds: 48h <= d <= 30 days
     */
    function validateResolutionDelay(uint256 d) internal pure {
        if (d < MIN_RESOLUTION_DELAY) {
            revert OutOfBounds("resolutionDelay", d, MIN_RESOLUTION_DELAY, MAX_RESOLUTION_DELAY);
        }
        if (d > MAX_RESOLUTION_DELAY) {
            revert OutOfBounds("resolutionDelay", d, MIN_RESOLUTION_DELAY, MAX_RESOLUTION_DELAY);
        }
    }

    /**
     * @notice Validate yield distribution configuration
     * @param recipients Array of recipient addresses
     * @param bps Array of basis points for each recipient
     * @dev Validates:
     *      - 1 <= recipients.length <= 10
     *      - recipients.length == bps.length
     *      - Sum of bps == 10_000
     *      - All recipients non-zero
     *      - No duplicate recipients
     */
    function validateYieldDistribution(
        address[] memory recipients,
        uint256[] memory bps
    ) internal pure {
        uint256 length = recipients.length;
        
        // Check recipient count bounds
        if (length < MIN_YIELD_RECIPIENTS) {
            revert OutOfBounds("yieldRecipients", length, MIN_YIELD_RECIPIENTS, MAX_YIELD_RECIPIENTS);
        }
        if (length > MAX_YIELD_RECIPIENTS) {
            revert TooManyRecipients(length, MAX_YIELD_RECIPIENTS);
        }
        
        // Check array lengths match
        if (length != bps.length) {
            revert InvalidArrayLength("yieldDistribution", length, bps.length);
        }
        
        // Validate recipients and calculate sum
        uint256 sum = 0;
        for (uint256 i = 0; i < length; i++) {
            // Check recipient is non-zero
            if (recipients[i] == address(0)) {
                revert InvalidAddressKey("yieldRecipient");
            }
            
            // Check for duplicates
            for (uint256 j = i + 1; j < length; j++) {
                if (recipients[i] == recipients[j]) {
                    revert DuplicateRecipient(recipients[i]);
                }
            }
            
            sum += bps[i];
        }
        
        // Check sum equals 100%
        if (sum != BPS_DENOMINATOR) {
            revert InvalidBpsSum(sum);
        }
    }

    /**
     * @notice Validate address is non-zero
     * @param a Address to validate
     * @param key Key for error message
     */
    function validateNonZero(address a, bytes32 key) internal pure {
        if (a == address(0)) {
            revert InvalidAddressKey(key);
        }
    }
}

