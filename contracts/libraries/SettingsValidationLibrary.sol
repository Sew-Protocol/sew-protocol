// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import '../types/EscrowTypes.sol';

/**
 * @title SettingsValidationLibrary
 * @notice Library for validating escrow settings with bounds enforcement
 * @dev Extracted from BaseEscrow to reduce contract size. Phase 6: Added bounds validation.
 */
library SettingsValidationLibrary {
    // Phase 6: Bounds constants
    uint256 public constant MAX_AUTO_TIME_DAYS = 30 days;
    uint256 public constant MAX_ATTACHMENTS = 20;
    uint256 public constant MAX_FEE_BPS = 200; // 2%
    uint256 public constant MIN_RESOLUTION_DELAY = 48 hours;
    uint256 public constant MAX_RESOLUTION_DELAY = 30 days;
    uint256 public constant MIN_YIELD_RECIPIENTS = 1;
    uint256 public constant MAX_YIELD_RECIPIENTS = 10;
    uint256 public constant BPS_DENOMINATOR = 10_000;
    
    // New constraints
    uint256 public constant MIN_ESCROW_AMOUNT = 1000; // Minimum escrow amount (1000 wei)
    uint256 public constant MAX_ESCROW_DURATION = 365 days; // Maximum escrow duration (1 year)

    // Phase 6: Custom errors (using different names to avoid conflicts with EscrowTypes)
    error InvalidArrayLength(uint256 a, uint256 b);
    error InvalidBpsSum(uint256 sum);
    error TooManyRecipients(uint256 n, uint256 max);
    error DuplicateRecipient(address recipient);

    /**
     * @dev Validate a single auto time value
     * @param autoTime The auto time to validate (0 means no auto time, which is valid)
     * @param currentTime Current block timestamp
     * @dev Reverts if autoTime is in the past or exceeds MAX_ESCROW_DURATION (1 year) from
     *      current block timestamp. A single canonical limit avoids the confusion of having
     *      both a 10-year cap here and a 1-year cap in validateEscrowSettings.
     */
    function validateAutoTime(
        uint256 autoTime,
        uint256 currentTime
    ) internal pure {
        if (autoTime == 0) {
            return; // 0 means no auto time, which is valid
        }

        // Validate time is in the future
        if (autoTime <= currentTime) {
            revert InvalidAutoTime(AUTO_TIME_IN_PAST, autoTime, currentTime);
        }

        // Validate time doesn't exceed maximum duration (1 year — canonical limit)
        uint256 maxAllowedTime = currentTime + MAX_ESCROW_DURATION;
        if (autoTime > maxAllowedTime) {
            revert AutoTimeExceedsMaxLimit(autoTime, maxAllowedTime);
        }

        // Ensure it fits in uint64 (belt and suspenders)
        if (autoTime > type(uint64).max) {
            revert InvalidAutoTime(AUTO_TIME_TOO_LARGE, autoTime, currentTime);
        }
    }

    /**
     * @dev Validate escrow settings
     * @param settings EscrowSettings struct to validate
     * @param currentTime Current block timestamp
     * @param resolverMustBeContract Whether customResolver must be a contract
     * @dev Reverts if settings are invalid (e.g., both auto times set, invalid times, etc.)
     */
    function validateEscrowSettings(
        EscrowSettings memory settings,
        uint256 currentTime,
        bool resolverMustBeContract
    ) internal view {
        // Validate auto times
        if (settings.autoReleaseTime != 0 && settings.autoCancelTime != 0) {
            revert CannotSetBothAutoTimes(settings.autoReleaseTime, settings.autoCancelTime);
        }

        // validateAutoTime already enforces MAX_ESCROW_DURATION (1 year) as the single
        // canonical limit, so no additional cap checks are needed here.
        validateAutoTime(settings.autoReleaseTime, currentTime);
        validateAutoTime(settings.autoCancelTime, currentTime);

        // Validate custom dispute resolver if set
        if (settings.customResolver != address(0)) {
            // Validate resolver is a contract if policy requires it
            if (resolverMustBeContract && settings.customResolver.code.length == 0) {
                revert NotAContract(ADDR_INITIAL_RESOLVER, settings.customResolver);
            }
            // Basic validation: resolver cannot be zero address (already checked)
            // or any other critical protocol address could be added here if needed
        }

        // Validate releaseAddress if set
        if (settings.releaseAddress != address(0)) {
            // releaseAddress cannot be any critical protocol address if needed,
            // but primarily it just shouldn't be the same as recipient (checked in validateRecipient)
        }
    }
    
    /**
     * @notice Validate escrow amount
     * @param amount The escrow amount to validate
     * @dev Reverts if amount is below minimum
     */
    function validateEscrowAmount(uint256 amount) internal pure {
        if (amount < MIN_ESCROW_AMOUNT) {
            revert InvalidAmount(AMOUNT_EMPTY);
        }
    }
    
    /**
     * @notice Validate recipient address
     * @param recipient The recipient address
     * @param sender The sender address
     * @param releaseAddress The release address (if any)
     * @dev Reverts if recipient is zero address, same as sender, or same as releaseAddress
     */
    function validateRecipient(address recipient, address sender, address releaseAddress) internal pure {
        if (recipient == address(0)) {
            revert InvalidAddress(ADDR_RECIPIENT, address(0));
        }
        if (recipient == sender) {
            revert InvalidAddress(ADDR_GENERIC, recipient); // ADDR_GENERIC for same address
        }
        if (releaseAddress != address(0) && recipient == releaseAddress) {
            revert InvalidAddress(ADDR_RECIPIENT, recipient);
        }
    }
    
    /**
     * @notice Validate yield opt-in amount
     * @param amount The amount to validate (amount after fee)
     * @param yieldEnabled Whether yield is enabled
     * @return shouldEnableYield Whether yield should actually be enabled
     * @dev Simplified: No longer uses hardcoded MIN_YIELD_DEPOSIT
     */
    function validateYieldOptIn(uint256 amount, bool yieldEnabled) internal pure returns (bool shouldEnableYield) {
        amount; // Unused
        return yieldEnabled;
    }

    /**
     * @dev Get default escrow settings
     * @return Default settings struct with all fields set to default values
     */
    function getDefaultSettings() internal pure returns (EscrowSettings memory) {
        return
            EscrowSettings({
                customResolver: address(0),
                releaseAddress: address(0),
                yieldPreset: YieldPreset.OFF, // Default: yield off
                autoReleaseTime: 0,
                autoCancelTime: 0
            });
    }

    // ============ Phase 6: Bounds Validation Functions ============

    /**
     * @notice Validate auto cancel delay (default setting)
     * @param d Delay in seconds (0 means disabled, which is valid)
     * @dev Bounds: d must be <= MAX_AUTO_TIME_DAYS
     */
    function validateAutoCancel(uint256 d) internal pure {
        if (d == 0) {
            return; // 0 means disabled, which is valid
        }
        if (d > MAX_AUTO_TIME_DAYS) {
            revert AutoTimeExceedsMaxLimit(d, MAX_AUTO_TIME_DAYS);
        }
    }

    /**
     * @notice Validate auto release delay (default setting)
     * @param d Delay in seconds (0 means disabled, which is valid)
     * @dev Bounds: d must be <= MAX_AUTO_TIME_DAYS
     */
    function validateAutoRelease(uint256 d) internal pure {
        if (d == 0) {
            return; // 0 means disabled, which is valid
        }
        if (d > MAX_AUTO_TIME_DAYS) {
            revert AutoTimeExceedsMaxLimit(d, MAX_AUTO_TIME_DAYS);
        }
    }

    /**
     * @notice Validate max attachments
     * @param n Maximum number of attachments
     * @dev Bounds: 0 <= n <= 20
     */
    function validateMaxAttachments(uint256 n) internal pure {
        if (n > MAX_ATTACHMENTS) {
            revert InvalidAmount(AMOUNT_GENERIC);
        }
    }

    /**
     * @notice Validate fee in basis points
     * @param bps Fee in basis points (100 = 1%)
     * @dev Bounds: 0 <= bps <= 200 (0% to 2%)
     */
    function validateFeeBps(uint256 bps) internal pure {
        if (bps > MAX_FEE_BPS) {
            revert FeeOverflow();
        }
    }

    /**
     * @notice Validate resolution module delay
     * @param d Delay in seconds
     * @dev Bounds: 48h <= d <= 30 days
     */
    function validateResolutionDelay(uint256 d) internal pure {
        if (d < MIN_RESOLUTION_DELAY || d > MAX_RESOLUTION_DELAY) {
            revert InvalidAutoTime(AUTO_TIME_TOO_LARGE, d, 0);
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
        if (length < MIN_YIELD_RECIPIENTS || length > MAX_YIELD_RECIPIENTS) {
            revert TooManyRecipients(length, MAX_YIELD_RECIPIENTS);
        }

        // Check array lengths match
        if (length != bps.length) {
            revert InvalidArrayLength(length, bps.length);
        }

        // Validate recipients and calculate sum
        uint256 sum = 0;
        for (uint256 i = 0; i < length; i++) {
            // Check recipient is non-zero
            if (recipients[i] == address(0)) {
                revert InvalidAddress(ADDR_YIELD_OPS, address(0));
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
     * @param which Key for error message
     */
    function validateNonZero(address a, uint8 which) internal pure {
        if (a == address(0)) {
            revert InvalidAddress(which, address(0));
        }
    }
}
