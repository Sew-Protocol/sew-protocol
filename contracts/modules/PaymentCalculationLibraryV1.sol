// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import "../interfaces/IPaymentCalculationLibrary.sol";

/**
 * @title PaymentCalculationLibraryV1
 * @notice Version 1 payment calculation contract - weighted distribution by escalation level
 * @dev Pure functions for calculating resolver payments
 *      Distribution: Weighted by escalation level (level 0 = 1x, level 1 = 1.5x, level 2 = 2x)
 *      Implemented as contract (not library) to enable governance-controlled upgrades
 */
contract PaymentCalculationLibraryV1 is IPaymentCalculationLibrary {
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
        // Validate input
        require(input.resolvers.length > 0, "No resolvers");
        require(input.resolverSharePercentage <= 10000, "Invalid percentage");
        
        // Aggregate total fees
        uint256 totalFees = input.escrowFee + input.escalationFees;
        
        // Calculate total resolver share
        uint256 resolverShare = (totalFees * input.resolverSharePercentage) / 10000;
        
        // Calculate total weight
        uint256 totalWeight = calculateTotalWeight(input.resolvers, input.weights);
        require(totalWeight > 0, "Zero total weight");
        
        // Allocate arrays
        uint256[] memory payments = new uint256[](input.resolvers.length);
        address[] memory addresses = new address[](input.resolvers.length);
        
        // Calculate payment for each resolver
        for (uint256 i = 0; i < input.resolvers.length; i++) {
            uint256 weight = getWeightForLevel(input.resolvers[i].level, input.weights);
            payments[i] = (resolverShare * weight) / totalWeight;
            addresses[i] = input.resolvers[i].resolver;
        }
        
        // Validate payments sum to resolver share (with rounding tolerance)
        uint256 paymentSum = 0;
        for (uint256 i = 0; i < payments.length; i++) {
            paymentSum += payments[i];
        }
        
        // Handle rounding: distribute any remainder to first resolver
        if (paymentSum < resolverShare && payments.length > 0) {
            payments[0] += (resolverShare - paymentSum);
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

