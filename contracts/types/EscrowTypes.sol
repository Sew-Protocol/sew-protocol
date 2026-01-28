// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import './YieldPresets.sol';

// Custom errors for better user experience
// Error code constants (uint8)
// InvalidAutoTime codes
uint8 constant AUTO_TIME_IN_PAST = 1;
uint8 constant AUTO_TIME_TOO_LARGE = 2;
// InvalidAmount codes
uint8 constant AMOUNT_GENERIC = 1;
uint8 constant AMOUNT_OVERFLOW = 2;
uint8 constant AMOUNT_EMPTY = 3;
// InvalidAddress "which" codes
uint8 constant ADDR_GENERIC = 1;
uint8 constant ADDR_ESCROW_CONTRACT = 2;
uint8 constant ADDR_TOKEN = 3;
uint8 constant ADDR_RECIPIENT = 4;
uint8 constant ADDR_FEE_RECIPIENT = 5;
uint8 constant ADDR_YIELD_OPS = 6;
uint8 constant ADDR_DISPUTE_OPS = 7;
uint8 constant ADDR_INITIAL_ADMIN = 8;
uint8 constant ADDR_INITIAL_OWNER = 9;
uint8 constant ADDR_INITIAL_RESOLVER = 10;
uint8 constant ADDR_PROVIDER = 11;
uint8 constant ADDR_ATOKEN = 12;

error InvalidAutoTime(uint8 code, uint256 providedTime, uint256 currentTime);
error CannotSetBothAutoTimes(uint256 autoReleaseTime, uint256 autoCancelTime);
error AutoTimeExceedsMaxLimit(uint256 providedTime, uint256 maxTime);
error InvalidAddress(uint8 which, address addr);
error InvalidAmount(uint8 code);
error ArrayLengthMismatch(uint256 expectedLength, uint256 actualLength);

// Specific errors without string parameters (saves bytecode)
error ZeroDisputeOps();
error ZeroSettlementOps();
error ZeroCreateOps();
error InvalidResolutionModule(address module);
error ModuleNotContract(address module);
error NotAContract(uint8 which, address addr); // which: 1=resolutionModule, 2=yieldOps, etc.
error AmountZero();
error FeeOverflow();
error NoTokensToRecover();
error AmountExceedsBalance(uint256 requested, uint256 available);

struct EscrowSettings {
    address customResolver; // Override default resolver (address(0) = use default)
    YieldPreset yieldPreset; // Yield configuration preset (OFF, TO_SENDER, etc.)
    uint256 autoReleaseTime; // Custom release time (0 = use default)
    uint256 autoCancelTime; // Custom cancel time (0 = use default)
}

// DEPRECATED: YieldDistribution struct removed - distribution now derived from preset
// struct YieldDistribution {
//     address[] recipients; // Addresses to receive yield
//     uint256[] percentages; // Percentage per recipient (basis points, sum to 10000)
//     bool isSet; // Whether distribution is configured
// }

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
struct EscrowTransfer {
    address token; // ERC20 token address (for EscrowVault) or address(this) for EscrowableERC20
    address to;
    address from;
    address disputeResolver;
    uint256 amountAfterFee; // amount after fee deduction (what's actually held in escrow)
    uint64 autoReleaseTime;
    uint64 autoCancelTime;
    EscrowState escrowState;
    SenderStatus senderStatus;
    RecipientStatus recipientStatus;
}

// ============ Wallet UX & Actionability Types ============

enum ExecutionSource { USER, KEEPER, GOVERNANCE }

enum UrgencyLevel { NONE, LOW, MEDIUM, HIGH, CRITICAL }

enum ActionableStatus {
    NONE,
    AWAITING_CONDITION, // Pending, time/condition not yet met
    AWAITING_CONSENSUS, // One party agreed to cancel, waiting for other
    TIME_CONDITION_MET, // Ready for trigger (automateTimedActions)
    DISPUTED_WAITING,   // In dispute, awaiting resolver
    APPEAL_WINDOW,      // Resolved, awaiting appeal expiry
    APPEAL_READY,       // Appeal window met, call executePending()
    FINALIZED           // Closed
}

uint8 constant ACTION_NONE = 0;
uint8 constant ACTION_AUTO_RELEASE = 1;
uint8 constant ACTION_AUTO_CANCEL = 2;
uint8 constant ACTION_EXECUTE_PENDING = 3;

enum UserRole { BUYER, SELLER, RESOLVER }

struct EscrowTimeline {
    uint64 createdAt;
    uint64 nextDeadline;
    uint64 finalDeadline; // Irreversible settlement timestamp
    ActionableStatus status;
    UrgencyLevel urgency;
    bool userCanExecute;
}

/**
 * Consensus status for multi-party agreement flows (e.g., cancel)
 */
struct CollaborationStatus {
    bool senderAgreed;
    bool recipientAgreed;
    bool canFinalize;
}

/**
 * Real-time yield metrics for transparency
 */
struct YieldMetrics {
    uint256 principal;
    uint256 accruedInterest;
    address yieldToken;
}

/**
 * Contextual information about the assigned resolver
 */
struct ResolverContext {
    address resolver;
    bool isContract;
    bytes4 interfaceId;
    string label;
}

struct TimeoutConfig {
    // Auto-execution defaults (0 = disabled, relative delays in seconds)
    uint256 defaultAutoReleaseDelay; // Default auto-release delay (0 = disabled)
    uint256 defaultAutoCancelDelay; // Default auto-cancel delay (0 = disabled)
    // Safety timeouts (durations in seconds)
    uint256 maxDisputeDuration; // Max time for disputes (7-365 days)
    uint256 appealWindowDuration; // Time to appeal resolution (1-7 days)
}
