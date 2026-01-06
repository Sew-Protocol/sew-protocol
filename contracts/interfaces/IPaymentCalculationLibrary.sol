// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.33;

/**
 * @title IPaymentCalculationLibrary
 * @notice Standard interface for payment calculation libraries
 * @dev All functions must be pure (no state access)
 *      Libraries implementing this interface can be upgraded via governance
 */
interface IPaymentCalculationLibrary {
    /**
     * @notice Calculate resolver payments for a dispute
     * @param input Payment calculation input data
     * @return output Payment calculation results
     * @dev Must be pure function (no state access)
     * @dev Must implement this exact interface for compatibility
     */
    function calculatePayments(PaymentInput memory input)
        external pure returns (PaymentOutput memory output);
    
    /**
     * @notice Get library version
     * @return version Library version string (e.g., "1.0.0")
     */
    function version() external pure returns (string memory);
    
    /**
     * @notice Validate library implementation
     * @return valid True if library is valid
     * @dev Can check for required functions, interface compliance
     */
    function validate() external pure returns (bool valid);
}

/**
 * @title PaymentInput
 * @notice Input structure for payment calculations
 * @dev Extensible design - future versions can add optional fields
 *      Libraries should ignore unknown fields for backward compatibility
 */
struct PaymentInput {
    // Core fields (required for all versions)
    uint256 escrowFee;              // Escrow fee collected
    uint256 escalationFees;         // Total escalation fees collected
    uint256 resolverSharePercentage; // Percentage of fees to resolvers (basis points, e.g., 5000 = 50%)
    ResolverRecord[] resolvers;      // All resolvers involved in the dispute
    Weights weights;                 // Weight configuration for different levels
    
    // Extensible fields (optional, for future versions)
    // V2+ may add:
    // QualityScore[] qualityScores;  // Quality scores for each resolver
    // StakingInfo[] stakingInfo;     // Staking information
    // ReputationScore[] reputationScores; // Reputation scores
}

/**
 * @title PaymentOutput
 * @notice Output structure for payment calculations
 * @dev Extensible design - future versions can add optional fields
 */
struct PaymentOutput {
    // Core fields (required for all versions)
    uint256 totalResolverShare;     // Total amount to be distributed to resolvers
    address[] resolvers;             // Resolver addresses (same order as payments)
    uint256[] payments;              // Payment amounts per resolver
    
    // Extensible fields (optional, for future versions)
    // V2+ may add:
    // uint256[] basePayments;        // Base payments before multipliers
    // uint256[] multipliers;         // Applied multipliers
}

/**
 * @title ResolverRecord
 * @notice Record of a resolver's involvement in a dispute
 */
struct ResolverRecord {
    address resolver;    // Resolver address
    uint8 level;         // Escalation level (0 = standard, 1 = senior, 2 = external)
    uint256 timestamp;   // When resolver was involved
}

/**
 * @title Weights
 * @notice Weight configuration for different escalation levels
 * @dev Used for weighted distribution of payments
 */
struct Weights {
    uint256 level0;  // Weight for level 0 (standard resolvers)
    uint256 level1;  // Weight for level 1 (senior resolvers)
    uint256 level2;  // Weight for level 2 (external resolvers)
}


