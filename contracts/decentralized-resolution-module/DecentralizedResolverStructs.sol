// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

/**
 * @title DecentralizedResolverStructs
 * @notice Shared structs and enums for Decentralized Resolution Module
 */
interface DecentralizedResolverStructs {
    // ============ Enums ============

    enum ResolverRole {
        NONE, // 0 - Not a resolver
        RESOLVER, // 1 - Standard resolver (appointed by senior resolver)
        SENIOR_RESOLVER, // 2 - Senior resolver (appointed by DAO/owner)
        EXTERNAL // 3 - External resolver (e.g., Kleros)
    }

    enum ResolutionOutcome {
        NONE, // 0 - No resolution yet
        RELEASE, // 1 - Funds released to recipient
        CANCEL // 2 - Funds refunded to sender
    }

    enum DisputeStatus {
        Open, // 0 - Awaiting resolver decision
        Decided, // 1 - Decision submitted, appeal window open
        Escalated, // 2 - Escalated to next round
        Final // 3 - No further appeals possible
    }

    // ============ Structs ============

    struct ResolverMetadata {
        string name;
        string description;
        uint256 appointedAt;
        address appointedBy;
        bool active;
    }

    struct DisputeMetadata {
        // Round-based tracking (DR v1)
        uint8 currentRound; // 0=initial resolver, 1=senior resolver, 2=external (Kleros)
        DisputeStatus status; // Open, Decided, Escalated, Final
        // Per-round data (fixed 3 rounds: 0, 1, 2)
        address[3] resolverAtRound; // Resolver assigned for each round
        ResolutionOutcome[3] decisionAtRound; // Decision submitted for each round
        uint256[3] decidedAtRound; // Timestamp when decision was submitted
        uint256[3] appealDeadline; // Deadline to appeal each round's decision
        // DR v2: Appeal bond tracking per round
        address[3] bondDepositorAtRound; // Who deposited appeal bond for this round
        uint256[3] bondAmountAtRound; // Appeal bond amount for this round
        address[3] bondTokenAtRound; // Token used for appeal bond
        bool[3] bondRefundedAtRound; // Whether bond was refunded (vs paid to resolvers)
        // Current state
        address escalatedBy; // Who initiated current escalation
        uint256 escalationTimestamp; // When current escalation happened
        uint256 assignedAt; // When current resolver was assigned
        uint256 resolveBy; // Deadline for current resolver to submit decision
        bytes resolutionData; // Additional resolution data
    }

    struct EscalationConfig {
        address resolver; // Resolver for this level (or address(0) for dynamic)
        uint256 fee; // Fee required to escalate to this level
        bool enabled; // Whether this level is enabled
    }

    struct PendingEscalationConfig {
        uint8 level;
        EscalationConfig config;
        uint64 eta;
        bool exists;
    }

    struct ResolutionTableEntry {
        uint8 maxRound; // Maximum round (0-2: 0=resolver only, 1=+senior, 2=+Kleros)
        uint256 escalationFee; // Fee required for escalation (legacy, use cost curves in v2)
        bool enabled; // Whether this entry is active
        string categoryName; // Human-readable category name
    }

    struct ResolverCapacity {
        uint256 maxConcurrentDisputes; // Maximum disputes resolver can handle
        uint256 currentDisputes; // Current number of active disputes
        bool acceptsNewDisputes; // Whether resolver accepts new disputes
    }

    struct ResolverStats {
        // EMA-based performance score (DR v1)
        uint256 emaScore; // EMA performance score (0-1e6 fixed point, 1e6 = perfect)
        uint256 lastScoreUpdate; // Timestamp of last EMA update
        // Objective counters
        uint256 casesAssigned; // Total cases assigned
        uint256 casesDecided; // Cases decided on time
        uint256 timeoutsAccept; // Failed to accept assignment (DR v1)
        uint256 timeoutsResolve; // Failed to resolve on time (DR v1)
        uint256 reversals; // Decisions reversed on escalation
        // Timing metrics
        uint256 totalResolutionTime; // Cumulative resolution time (for average)
        uint256 lastActive; // Last activity timestamp
        // Legacy fields (kept for backward compatibility during migration)
        uint256 disputesResolved; // Deprecated: use casesDecided
        uint256 disputesEscalated; // Deprecated: tracked separately
        uint256 qualityScore; // Deprecated: use emaScore
        // Manual controls
        uint256 assignmentWeight; // Manual override (0-10000 bps, 0=excluded)
    }

    // ============ DR v2 Structures ============

    enum CostCurveType {
        LINEAR, // cost(k) = baseCost + stepSize * k
        QUADRATIC, // cost(k) = baseCost + stepSize * k^2 (recommended default)
        GEOMETRIC // cost(k) = baseCost * multiplier^k
    }

    struct EscalationCostConfig {
        CostCurveType curveType; // Type of cost curve (DR v2)
        uint256 baseCost; // Base cost for escalation (in wei or token units)
        uint256 stepSize; // Step size for cost curve calculation
        uint256 multiplier; // Multiplier for geometric curves (r > 1, scaled by 1e18)
        address bondToken; // Token address for bond (address(0) = ETH)
        bool enabled; // Whether this cost config is enabled
    }

    struct AppealBond {
        address depositor; // Address that deposited the bond
        uint256 amount; // Bond amount
        address token; // Token address
        uint256 depositedAt; // Timestamp when bond was deposited
        bool refunded; // Whether bond has been refunded
    }
}
