// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import './DecentralizedResolverStructs.sol';

/**
 * @title EscalationCostLibrary
 * @notice Library for calculating escalation costs using various cost curves (DR v2)
 * @dev Implements linear, quadratic, and geometric cost curves
 *      Quadratic is the recommended default for v2 (strong anti-spam, still OK for 1-2 appeals)
 */
library EscalationCostLibrary {
    /**
     * @notice Calculate escalation cost based on cost curve configuration
     * @param escalationCount Number of escalations (k) for this dispute (0-indexed: 0 = first escalation)
     * @param config Cost curve configuration
     * @return cost Calculated cost for this escalation
     * @dev DR v2: Supports linear, quadratic (recommended), and geometric curves
     *      - Linear: cost(k) = baseCost + stepSize * k
     *      - Quadratic: cost(k) = baseCost + stepSize * k^2 (recommended default)
     *      - Geometric: cost(k) = baseCost * multiplier^k
     */
    function calculateEscalationCost(
        uint8 escalationCount,
        DecentralizedResolverStructs.EscalationCostConfig memory config
    ) internal pure returns (uint256 cost) {
        if (!config.enabled) {
            return 0;
        }

        if (config.curveType == DecentralizedResolverStructs.CostCurveType.LINEAR) {
            // Linear: cost(k) = baseCost + stepSize * k
            return config.baseCost + (config.stepSize * uint256(escalationCount));
        } else if (config.curveType == DecentralizedResolverStructs.CostCurveType.QUADRATIC) {
            // Quadratic: cost(k) = baseCost + stepSize * k^2 (recommended default)
            uint256 kSquared = uint256(escalationCount) * uint256(escalationCount);
            return config.baseCost + (config.stepSize * kSquared);
        } else if (config.curveType == DecentralizedResolverStructs.CostCurveType.GEOMETRIC) {
            // Geometric: cost(k) = baseCost * multiplier^k
            // Note: multiplier should be > 1 (e.g., 2.0 = 20000 in basis points)
            // For safety, we use fixed-point arithmetic
            if (config.multiplier == 0) {
                return config.baseCost;
            }
            if (escalationCount == 0) {
                return config.baseCost;
            }

            // Use repeated multiplication (safer than exponentiation for small k)
            uint256 result = config.baseCost;
            for (uint8 i = 0; i < escalationCount; i++) {
                result = (result * config.multiplier) / 10000; // multiplier is in basis points
            }
            return result;
        }

        // Default: return base cost
        return config.baseCost;
    }

    /**
     * @notice Calculate escalation cost for a specific level
     * @param level Escalation level (0 = first escalation, 1 = second, etc.)
     * @param config Cost curve configuration
     * @return cost Calculated cost for this level
     * @dev Convenience function that maps level to escalation count
     */
    function calculateCostForLevel(
        uint8 level,
        DecentralizedResolverStructs.EscalationCostConfig memory config
    ) internal pure returns (uint256 cost) {
        // Level 0 = no escalation (cost = 0)
        if (level == 0) {
            return 0;
        }

        // Level 1 = first escalation (k=0), Level 2 = second escalation (k=1), etc.
        uint8 escalationCount = level - 1;
        return calculateEscalationCost(escalationCount, config);
    }
}
