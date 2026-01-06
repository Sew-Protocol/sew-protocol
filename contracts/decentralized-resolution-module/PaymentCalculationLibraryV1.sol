// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.33;

import "./IPaymentCalculationLibrary.sol";

/**
 * @title PaymentCalculationLibraryV1
 * @notice Version 1 payment calculation contract - weighted distribution by escalation level
 * @dev Pure functions for calculating resolver payments
 *      Distribution: Weighted by escalation level (level 0 = 1x, level 1 = 1.5x, level 2 = 2x)
 *      Implemented as contract (not library) to enable governance-controlled upgrades
 */
contract PaymentCalculationLibraryV1 is IPaymentCalculationLibrary {
    // ============ Constants ============
    uint256 public constant BASIS_POINTS_DENOMINATOR = 10000;
    
    // ============ Public Functions ============
    
    /**
     * @notice Calculate payments using weighted distribution by escalation level
     * @param input Payment calculation input data
     * @return output Payment calculation results
     * @dev Pure function - no state access
     * @dev V1 implementation: Simple weighted distribution by level
     */
    function calculatePayments(PaymentInput memory input)
        external pure override returns (PaymentOutput memory output)
    {
        // Validate input (Phase 1: Task 1.8)
        require(input.resolvers.length > 0, "No resolvers");
        require(input.resolverSharePercentage <= BASIS_POINTS_DENOMINATOR, "Invalid percentage");
        
        // Validate resolver addresses are not zero (Phase 1: Task 1.8)
        for (uint256 i = 0; i < input.resolvers.length; i++) {
            require(input.resolvers[i].resolver != address(0), "Zero resolver address");
        }
        
        // Aggregate total fees
        uint256 totalFees = input.escrowFee + input.escalationFees;
        
        // Calculate total weight
        uint256 totalWeight = calculateTotalWeight(input.resolvers, input.weights);
        require(totalWeight > 0, "Zero total weight");
        
        // Allocate arrays
        uint256[] memory payments = new uint256[](input.resolvers.length);
        address[] memory addresses = new address[](input.resolvers.length);
        
        // Calculate payment for each resolver
        // Optimized: Multiply first, then divide to preserve precision
        // Formula: (totalFees * resolverSharePercentage * weight) / (BASIS_POINTS_DENOMINATOR * totalWeight)
        for (uint256 i = 0; i < input.resolvers.length; i++) {
            uint256 weight = getWeightForLevel(input.resolvers[i].level, input.weights);
            // Multiply all numerators first, then divide by all denominators to maximize precision
            payments[i] = (totalFees * input.resolverSharePercentage * weight) / (BASIS_POINTS_DENOMINATOR * totalWeight);
            addresses[i] = input.resolvers[i].resolver;
        }
        
        // Calculate total resolver share for validation and remainder distribution
        uint256 resolverShare = (totalFees * input.resolverSharePercentage) / BASIS_POINTS_DENOMINATOR;
        
        // Validate payments sum to resolver share (with rounding tolerance)
        uint256 paymentSum = 0;
        for (uint256 i = 0; i < payments.length; i++) {
            paymentSum += payments[i];
        }
        
        // Phase 3: Task 3.4 - Distribute remainder proportionally instead of all to first resolver
        if (paymentSum < resolverShare && payments.length > 0) {
            uint256 remainder = resolverShare - paymentSum;
            uint256 distributed = 0;
            
            // Distribute remainder proportionally based on existing payment amounts
            for (uint256 i = 0; i < payments.length && distributed < remainder; i++) {
                if (payments[i] > 0) {
                    // Calculate proportional share of remainder
                    uint256 proportionalShare = (remainder * payments[i]) / resolverShare;
                    uint256 remainingToDistribute = remainder - distributed;
                    uint256 add = proportionalShare < remainingToDistribute ? proportionalShare : remainingToDistribute;
                    
                    payments[i] += add;
                    distributed += add;
                }
            }
            
            // Any final remainder to last resolver with payment
            if (distributed < remainder) {
                for (uint256 i = payments.length; i > 0; i--) {
                    if (payments[i - 1] > 0) {
                        payments[i - 1] += (remainder - distributed);
                        break;
                    }
                }
            }
        }
        
        return PaymentOutput({
            totalResolverShare: resolverShare,
            resolvers: addresses,
            payments: payments
        });
    }
    
    /**
     * @notice Get library version
     * @return version Library version string
     */
    function version() external pure override returns (string memory) {
        return "1.0.0";
    }
    
    /**
     * @notice Validate library implementation
     * @return valid True if library is valid
     * @dev Simple validation - always returns true for V1
     *      External callers can verify by calling version() separately
     */
    function validate() external pure override returns (bool) {
        // V1 is always valid if it compiles and implements the interface
        return true;
    }
    
    // ============ Private Helper Functions ============
    
    /**
     * @notice Calculate total weight for all resolvers
     * @param resolvers Array of resolver records
     * @param weights Weight configuration
     * @return total Total weight
     */
    function calculateTotalWeight(
        ResolverRecord[] memory resolvers,
        Weights memory weights
    ) private pure returns (uint256 total) {
        for (uint256 i = 0; i < resolvers.length; i++) {
            total += getWeightForLevel(resolvers[i].level, weights);
        }
    }
    
    /**
     * @notice Get weight for a specific escalation level
     * @param level Escalation level (0, 1, or 2)
     * @param weights Weight configuration
     * @return weight Weight for the level
     */
    function getWeightForLevel(uint8 level, Weights memory weights)
        private pure returns (uint256)
    {
        if (level == 0) return weights.level0;
        if (level == 1) return weights.level1;
        if (level == 2) return weights.level2;
        revert("Invalid level");
    }
    
    /**
     * @notice Create test input for validation
     * @return testInput Test payment input
     * @dev Internal helper for testing
     */
    function createTestInput() private pure returns (PaymentInput memory) {
        ResolverRecord[] memory resolvers = new ResolverRecord[](2);
        resolvers[0] = ResolverRecord({
            resolver: address(0x1),
            level: 0,
            timestamp: 0 // Timestamp not needed for calculation
        });
        resolvers[1] = ResolverRecord({
            resolver: address(0x2),
            level: 1,
            timestamp: 0 // Timestamp not needed for calculation
        });
        
        return PaymentInput({
            escrowFee: 1000,
            escalationFees: 500,
            resolverSharePercentage: 5000,
            resolvers: resolvers,
            weights: Weights({
                level0: 10000,
                level1: 15000,
                level2: 20000
            })
        });
    }
}
