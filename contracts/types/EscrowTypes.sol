// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

// Custom errors for better user experience
error InvalidAutoTime(string reason, uint256 providedTime, uint256 currentTime);
error CannotSetBothAutoTimes(uint256 autoReleaseTime, uint256 autoCancelTime);
error AutoTimeExceedsMaxLimit(uint256 providedTime, uint256 maxTime);
error InvalidAddress(string reason, address addr);
error InvalidAmount(string reason);
error ArrayLengthMismatch(uint256 expectedLength, uint256 actualLength);

enum EscrowType {
    STANDARD,      // Default escrow
    MILESTONE,     // Future: milestone-based releases
    RECURRING,     // Future: recurring payments
    CUSTOM         // Future: custom logic
}

struct EscrowSettings {
    address customResolver;     // Override default resolver (address(0) = use default)
    bool yieldEnabled;          // Opt-in for yield generation (future: Aave integration)
    uint256 autoReleaseTime;    // Custom release time (0 = use default)
    uint256 autoCancelTime;     // Custom cancel time (0 = use default)
    EscrowType escrowType;      // For future extensibility
}

struct YieldDistribution {
    address[] recipients;      // Addresses to receive yield
    uint256[] percentages;     // Percentage per recipient (basis points, sum to 10000)
    bool isSet;               // Whether distribution is configured
}


