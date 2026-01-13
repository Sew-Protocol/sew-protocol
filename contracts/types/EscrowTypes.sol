// SPDX-License-Identifier: UNLICENSED
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
struct EscrowTransfer {
    uint256 workflowId;
    address token; // ERC20 token address (for EscrowVault) or address(this) for EscrowableERC20
    address to;
    address from;
    uint256 remainingBalance; // remaining balance held in escrow (may be less than totalDeposited if partially released/cancelled)
    uint256 totalDeposited; // total amount originally deposited (before any releases/cancellations)
    EscrowState escrowState;
    SenderStatus senderStatus;
    RecipientStatus recipientStatus;
    address disputeResolver;
    uint256 autoReleaseTime;
    uint256 autoCancelTime;
}


