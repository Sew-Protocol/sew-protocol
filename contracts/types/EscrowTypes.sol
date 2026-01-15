// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

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

// Escrow state and status enums (shared across contracts)
enum EscrowState {
    NONE,
    PENDING,
    RELEASED,
    REFUNDED,
    DISPUTED,
    RESOLVED
}

enum SenderStatus {
    NONE,
    AGREE_TO_CANCEL,
    RAISE_DISPUTE
}

enum RecipientStatus {
    NONE,
    AGREE_TO_CANCEL,
    RAISE_DISPUTE
}

// EscrowTransfer struct (shared across contracts)
// Note: workflowId is redundant - use array index (escrowTransfers[index]) instead
// Optimized packing: 4 addresses (80 bytes = 3 slots), 3 uint256 (96 bytes = 3 slots), 3 enums (3 bytes = 1 slot)
struct EscrowTransfer {
    address token; // ERC20 token address (for EscrowVault) or address(this) for EscrowableERC20
    address to;
    address from;
    address disputeResolver; // Pack 4 addresses together (80 bytes = 3 slots)
    uint256 amountAfterFee; // amount after fee deduction (what's actually held in escrow)
    uint256 autoReleaseTime;
    uint256 autoCancelTime;
    EscrowState escrowState; // Pack 3 enums together (3 bytes + 29 padding = 1 slot)
    SenderStatus senderStatus;
    RecipientStatus recipientStatus;
}

struct TimeoutConfig {
    // Auto-execution defaults (0 = disabled, absolute timestamps)
    uint256 defaultAutoReleaseTime;    // Default auto-release timestamp (0 = disabled)
    uint256 defaultAutoCancelTime;     // Default auto-cancel timestamp (0 = disabled)
    
    // Safety timeouts (durations in seconds)
    uint256 maxDisputeDuration;        // Max time for disputes (7-365 days)
    uint256 appealWindowDuration;      // Time to appeal resolution (1-7 days)
}


