// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.33;

import "./DecentralizedResolverStructs.sol";

/**
 * @title ResolutionAnalytics
 * @notice Library for tracking resolver reputation and metrics
 */
library ResolutionAnalytics {
    uint256 public constant BASIS_POINTS_DENOMINATOR = 10000;

    event ResolverStatsUpdated(address indexed resolver, uint256 disputesResolved, uint256 disputesEscalated, uint256 resolutionReversals, uint256 qualityScore);
    event ResolutionReversed(uint256 indexed workflowId, address indexed resolver, DecentralizedResolverStructs.ResolutionOutcome originalOutcome, DecentralizedResolverStructs.ResolutionOutcome newOutcome, uint8 originalLevel, uint8 newLevel);

    function recordResolution(
        mapping(address => DecentralizedResolverStructs.ResolverStats) storage resolverStats,
        uint256 workflowId,
        address resolver,
        DecentralizedResolverStructs.ResolutionOutcome outcome,
        bool wasEscalated,
        uint256 resolutionTime,
        uint8 escalationLevel,
        address lastResolver,
        DecentralizedResolverStructs.ResolutionOutcome lastResolutionOutcome
    ) internal {
        if (escalationLevel > 0 && lastResolver != address(0) && lastResolver != resolver) {
            if (lastResolutionOutcome != DecentralizedResolverStructs.ResolutionOutcome.NONE && lastResolutionOutcome != outcome) {
                resolverStats[lastResolver].resolutionReversals++;
                emit ResolutionReversed(workflowId, lastResolver, lastResolutionOutcome, outcome, escalationLevel - 1, escalationLevel);
            }
        }

        DecentralizedResolverStructs.ResolverStats storage stats = resolverStats[resolver];
        if (wasEscalated) stats.disputesEscalated++;
        else {
            stats.disputesResolved++;
            if (resolutionTime > 0) stats.totalResolutionTime += resolutionTime;
            stats.lastResolutionTimestamp = block.timestamp;
        }
        stats.totalDisputes = stats.disputesResolved + stats.disputesEscalated;

        if (stats.totalDisputes > 0) {
            uint256 baseScore = (stats.disputesResolved * BASIS_POINTS_DENOMINATOR) / stats.totalDisputes;
            uint256 penalty = stats.resolutionReversals * 1000;
            stats.qualityScore = penalty > baseScore ? 0 : baseScore - penalty;
        }
        
        emit ResolverStatsUpdated(resolver, stats.disputesResolved, stats.disputesEscalated, stats.resolutionReversals, stats.qualityScore);
    }

    function checkResolverNeedsAttention(
        mapping(address => DecentralizedResolverStructs.ResolverStats) storage resolverStats,
        address resolver,
        bool active
    ) internal view returns (bool needsAttention, uint8 reason) {
        if (!active) return (true, 3);
        DecentralizedResolverStructs.ResolverStats memory stats = resolverStats[resolver];
        if (stats.totalDisputes == 0) return (false, 0);
        if (stats.disputesResolved > 0 && (stats.resolutionReversals * BASIS_POINTS_DENOMINATOR) / stats.disputesResolved > 2000) return (true, 4);
        if (stats.qualityScore < 5000) return (true, 1);
        if ((stats.disputesEscalated * BASIS_POINTS_DENOMINATOR) / stats.totalDisputes > 5000) return (true, 2);
        return (false, 0);
    }
}
