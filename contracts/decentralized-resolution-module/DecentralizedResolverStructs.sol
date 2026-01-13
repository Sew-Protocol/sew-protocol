// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.33;

/**
 * @title DecentralizedResolverStructs
 * @notice Shared structs and enums for Decentralized Resolution Module
 */
interface DecentralizedResolverStructs {
    // ============ Enums ============
    
    enum ResolverRole {
        NONE,           // 0 - Not a resolver
        RESOLVER,       // 1 - Standard resolver (appointed by senior resolver)
        SENIOR_RESOLVER,// 2 - Senior resolver (appointed by DAO/owner)
        EXTERNAL        // 3 - External resolver (e.g., Kleros)
    }

    enum ResolutionOutcome {
        NONE,      // 0 - No resolution yet
        RELEASE,   // 1 - Funds released to recipient
        CANCEL     // 2 - Funds refunded to sender
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
        address currentResolver;      // Current resolver assigned
        uint8 escalationLevel;        // Current escalation level (0 = initial, 1 = senior, 2 = external)
        address escalatedBy;          // Who escalated (if escalated)
        uint256 escalationTimestamp;  // When escalated
        uint256 timeoutTimestamp;     // When dispute should auto-escalate
        bytes resolutionData;         // Additional resolution data
        ResolutionOutcome lastResolutionOutcome; // Last resolution decision (for reversal tracking)
        address lastResolver;          // Resolver who made last decision
    }
    
    struct EscalationConfig {
        address resolver;        // Resolver for this level (or address(0) for dynamic)
        uint256 fee;            // Fee required to escalate to this level
        bool enabled;           // Whether this level is enabled
    }
    
    struct PendingEscalationConfig {
        uint8 level;
        EscalationConfig config;
        uint64 eta;
        bool exists;
    }
    
    struct ResolutionTableEntry {
        uint8 maxEscalationLevel;     // Maximum escalation level (0-2)
        uint256 escalationFee;        // Fee required for escalation
        bool enabled;                 // Whether this entry is active
        string categoryName;          // Human-readable category name
    }
    
    struct ResolverCapacity {
        uint256 maxConcurrentDisputes;  // Maximum disputes resolver can handle
        uint256 currentDisputes;        // Current number of active disputes
        bool acceptsNewDisputes;        // Whether resolver accepts new disputes
    }
    
    struct ResolverStats {
        uint256 disputesResolved;           // Number of disputes successfully resolved
        uint256 disputesEscalated;          // Number of disputes escalated away from this resolver
        uint256 resolutionReversals;        // Number of resolutions reversed by higher-level resolver
        uint256 totalResolutionTime;        // Cumulative resolution time (for average calculation)
        uint256 lastResolutionTimestamp;    // Timestamp of last resolution
        uint256 qualityScore;               // Quality score (0-10000 basis points)
        uint256 totalDisputes;             // Total disputes handled (resolved + escalated)
    }
}
