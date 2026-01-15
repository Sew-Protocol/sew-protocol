// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import './DecentralizedResolverStructs.sol';

/**
 * @title ResolutionAnalytics
 * @notice Library for EMA-based resolver performance tracking (DR v1)
 * @dev Implements exponential moving average (EMA) reputation scoring
 *      - EMA score: 0-1e6 fixed point (1e6 = perfect performance)
 *      - Objective signals: timeliness, reversals, timeouts
 *      - Workload weight derived from EMA score
 */
library ResolutionAnalytics {
    uint256 public constant BASIS_POINTS_DENOMINATOR = 10000;
    uint256 public constant EMA_PRECISION = 1e6; // 1 million = 100% score

    // Default EMA parameters (governance can override)
    uint256 public constant DEFAULT_ALPHA_BPS = 1000; // 10% (alphaBps / 10000)
    uint256 public constant MIN_SCORE_THRESHOLD = 500000; // 50% of EMA_PRECISION

    // Outcome values for EMA calculation (as ratio of EMA_PRECISION)
    uint256 public constant OUTCOME_UPHELD = EMA_PRECISION; // 1.0 = decision upheld
    uint256 public constant OUTCOME_REVERSED = EMA_PRECISION / 2; // 0.5 = decision reversed
    uint256 public constant OUTCOME_TIMEOUT = 0; // 0.0 = timeout/no response

    // Events
    event ResolverStatsUpdated(
        address indexed resolver,
        uint256 emaScore,
        uint256 casesDecided,
        uint256 timeouts,
        uint256 reversals
    );

    event EMAScoreUpdated(
        address indexed resolver,
        uint256 oldScore,
        uint256 newScore,
        uint256 outcome,
        uint256 alphaBps
    );

    event ResolutionReversed(
        uint256 indexed escrowId,
        address indexed resolver,
        DecentralizedResolverStructs.ResolutionOutcome originalOutcome,
        DecentralizedResolverStructs.ResolutionOutcome newOutcome,
        uint8 fromRound,
        uint8 toRound
    );

    event ResolverTimeout(
        uint256 indexed escrowId,
        address indexed resolver,
        uint8 round,
        uint8 timeoutType // 0=accept, 1=resolve
    );

    /**
     * @notice Initialize resolver stats with default EMA score
     * @param stats Resolver stats storage reference
     */
    function initializeResolver(DecentralizedResolverStructs.ResolverStats storage stats) internal {
        if (stats.emaScore == 0) {
            // New resolvers start with perfect score (benefit of the doubt)
            stats.emaScore = EMA_PRECISION;
            stats.lastScoreUpdate = block.timestamp;
            stats.assignmentWeight = BASIS_POINTS_DENOMINATOR; // Full weight
        }
    }

    /**
     * @notice Update EMA score based on outcome
     * @dev score_new = score_old * (1 - α) + outcome * α
     * @param stats Resolver stats storage reference
     * @param resolver Resolver address (for event emission)
     * @param outcome Outcome value (OUTCOME_UPHELD, OUTCOME_REVERSED, or OUTCOME_TIMEOUT)
     * @param alphaBps EMA step parameter in basis points (e.g., 1000 = 10%)
     */
    function updateEMAScore(
        DecentralizedResolverStructs.ResolverStats storage stats,
        address resolver,
        uint256 outcome,
        uint256 alphaBps
    ) internal {
        require(outcome <= EMA_PRECISION, 'Invalid outcome');
        require(alphaBps <= BASIS_POINTS_DENOMINATOR, 'Invalid alpha');

        uint256 oldScore = stats.emaScore;

        // EMA formula: score_new = score_old * (1 - α) + outcome * α
        // Implementation: score_new = (score_old * (10000 - alphaBps) + outcome * alphaBps) / 10000
        uint256 newScore = (oldScore * (BASIS_POINTS_DENOMINATOR - alphaBps) + outcome * alphaBps) /
            BASIS_POINTS_DENOMINATOR;

        stats.emaScore = newScore;
        stats.lastScoreUpdate = block.timestamp;

        emit EMAScoreUpdated(resolver, oldScore, newScore, outcome, alphaBps);
    }

    /**
     * @notice Record a successful resolution
     * @param stats Resolver stats storage reference
     * @param resolver Resolver address
     * @param resolutionTime Time taken to resolve (seconds)
     * @param alphaBps EMA alpha parameter
     */
    function recordSuccessfulResolution(
        DecentralizedResolverStructs.ResolverStats storage stats,
        address resolver,
        uint256 resolutionTime,
        uint256 alphaBps
    ) internal {
        stats.casesDecided++;
        stats.totalResolutionTime += resolutionTime;
        stats.lastActive = block.timestamp;

        // Decision made on time = positive signal
        updateEMAScore(stats, resolver, OUTCOME_UPHELD, alphaBps);

        // Update legacy fields
        stats.disputesResolved++;

        emit ResolverStatsUpdated(
            resolver,
            stats.emaScore,
            stats.casesDecided,
            stats.timeoutsResolve + stats.timeoutsAccept,
            stats.reversals
        );
    }

    /**
     * @notice Record a resolution that was reversed on appeal
     * @param stats Resolver stats storage reference
     * @param resolver Resolver address
     * @param workflowId Dispute ID
     * @param originalOutcome Original decision
     * @param newOutcome New decision after appeal
     * @param fromRound Round where original decision was made
     * @param toRound Round where reversal happened
     * @param alphaBps EMA alpha parameter
     */
    function recordReversal(
        DecentralizedResolverStructs.ResolverStats storage stats,
        address resolver,
        uint256 workflowId,
        DecentralizedResolverStructs.ResolutionOutcome originalOutcome,
        DecentralizedResolverStructs.ResolutionOutcome newOutcome,
        uint8 fromRound,
        uint8 toRound,
        uint256 alphaBps
    ) internal {
        stats.reversals++;

        // Reversal = negative signal (0.5 outcome)
        updateEMAScore(stats, resolver, OUTCOME_REVERSED, alphaBps);

        emit ResolutionReversed(
            workflowId,
            resolver,
            originalOutcome,
            newOutcome,
            fromRound,
            toRound
        );

        emit ResolverStatsUpdated(
            resolver,
            stats.emaScore,
            stats.casesDecided,
            stats.timeoutsResolve + stats.timeoutsAccept,
            stats.reversals
        );
    }

    /**
     * @notice Record a timeout (accept or resolve)
     * @param stats Resolver stats storage reference
     * @param resolver Resolver address
     * @param workflowId Dispute ID
     * @param round Round where timeout occurred
     * @param timeoutType 0=accept timeout, 1=resolve timeout
     * @param alphaBps EMA alpha parameter
     */
    function recordTimeout(
        DecentralizedResolverStructs.ResolverStats storage stats,
        address resolver,
        uint256 workflowId,
        uint8 round,
        uint8 timeoutType,
        uint256 alphaBps
    ) internal {
        if (timeoutType == 0) {
            stats.timeoutsAccept++;
        } else {
            stats.timeoutsResolve++;
        }

        // Timeout = worst signal (0 outcome)
        updateEMAScore(stats, resolver, OUTCOME_TIMEOUT, alphaBps);

        emit ResolverTimeout(workflowId, resolver, round, timeoutType);

        emit ResolverStatsUpdated(
            resolver,
            stats.emaScore,
            stats.casesDecided,
            stats.timeoutsResolve + stats.timeoutsAccept,
            stats.reversals
        );
    }

    /**
     * @notice Calculate workload weight from EMA score
     * @dev Weight = 0 if score below threshold or manual override, otherwise scaled to 0-10000
     * @param stats Resolver stats
     * @param minScoreThreshold Minimum score to receive work
     * @return weight Workload weight (0-10000 basis points)
     */
    function calculateWorkloadWeight(
        DecentralizedResolverStructs.ResolverStats memory stats,
        uint256 minScoreThreshold
    ) internal pure returns (uint256 weight) {
        // Manual override: 0 = excluded
        if (stats.assignmentWeight == 0) return 0;

        // Below threshold → weight to 0
        if (stats.emaScore < minScoreThreshold) return 0;

        // Scale EMA score (0-1e6) to basis points (0-10000)
        // weight = (emaScore * 10000) / 1e6 = emaScore / 100
        return stats.emaScore / 100;
    }

    /**
     * @notice Get recent timeout rate for a resolver
     * @dev Calculates timeout rate from total cases assigned
     * @param stats Resolver stats
     * @return timeoutRate Timeout rate in basis points (0-10000)
     */
    function getTimeoutRate(
        DecentralizedResolverStructs.ResolverStats memory stats
    ) internal pure returns (uint256 timeoutRate) {
        if (stats.casesAssigned == 0) return 0;

        uint256 totalTimeouts = stats.timeoutsAccept + stats.timeoutsResolve;
        return (totalTimeouts * BASIS_POINTS_DENOMINATOR) / stats.casesAssigned;
    }

    /**
     * @notice Get reversal rate for a resolver
     * @param stats Resolver stats
     * @return reversalRate Reversal rate in basis points (0-10000)
     */
    function getReversalRate(
        DecentralizedResolverStructs.ResolverStats memory stats
    ) internal pure returns (uint256 reversalRate) {
        if (stats.casesDecided == 0) return 0;

        return (stats.reversals * BASIS_POINTS_DENOMINATOR) / stats.casesDecided;
    }

    /**
     * @notice Get average resolution time for a resolver
     * @param stats Resolver stats
     * @return avgTime Average resolution time in seconds
     */
    function getAverageResolutionTime(
        DecentralizedResolverStructs.ResolverStats memory stats
    ) internal pure returns (uint256 avgTime) {
        if (stats.casesDecided == 0) return 0;

        return stats.totalResolutionTime / stats.casesDecided;
    }

    /**
     * @notice Check if resolver needs attention (legacy function for compatibility)
     * @param stats Resolver stats
     * @param active Whether resolver is active
     * @return needsAttention Whether resolver needs governance attention
     * @return reason Reason code (1=low score, 2=high timeout rate, 3=inactive, 4=high reversal rate)
     */
    function checkResolverNeedsAttention(
        DecentralizedResolverStructs.ResolverStats memory stats,
        bool active
    ) internal pure returns (bool needsAttention, uint8 reason) {
        if (!active) return (true, 3);
        if (stats.casesAssigned == 0) return (false, 0);

        // Check EMA score
        if (stats.emaScore < MIN_SCORE_THRESHOLD) return (true, 1);

        // Check timeout rate (>30%)
        if (getTimeoutRate(stats) > 3000) return (true, 2);

        // Check reversal rate (>20%)
        if (getReversalRate(stats) > 2000) return (true, 4);

        return (false, 0);
    }
}
