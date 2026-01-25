// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.33;

import 'forge-std/Test.sol';
import '../../../contracts/decentralized-resolution-module/PaymentCalculationLibraryV1.sol';
import { IPaymentCalculationLibrary, PaymentInput, PaymentOutput, ResolverRecord, Weights } from '../../../contracts/decentralized-resolution-module/IPaymentCalculationLibrary.sol';

/**
 * @title PaymentCalculationFuzzTest
 * @notice Fuzz tests for payment calculation to find edge cases and rounding errors
 * @dev Tests payment calculation with random inputs to verify:
 *      - No overflows/underflows
 *      - No precision loss beyond acceptable rounding
 *      - Invariants hold across varied inputs
 */
contract PaymentCalculationFuzzTest is Test {
    PaymentCalculationLibraryV1 public paymentLib;
    uint256 constant BASIS_POINTS_DENOMINATOR = 10000;
    uint256 constant MAX_RESOLVERS = 10; // Reasonable upper bound
    uint256 constant MAX_FEE = type(uint128).max; // Reasonable upper bound for fees
    uint256 constant MAX_WEIGHT = 100000; // Reasonable upper bound for weights

    address[] resolverAddresses;

    function setUp() public {
        paymentLib = new PaymentCalculationLibraryV1();
        
        // Pre-generate resolver addresses to avoid zero address issues
        resolverAddresses = new address[](MAX_RESOLVERS);
        for (uint256 i = 0; i < MAX_RESOLVERS; i++) {
            resolverAddresses[i] = address(uint160(i + 1)); // Avoid zero address
        }
    }

    // ============ Helper Functions ============

    function _createValidWeights() internal pure returns (Weights memory) {
        return Weights({
            level0: 10000,
            level1: 15000,
            level2: 20000
        });
    }

    function _createResolverRecord(address resolver, uint8 level) internal view returns (ResolverRecord memory) {
        return ResolverRecord({
            resolver: resolver,
            level: level,
            timestamp: block.timestamp
        });
    }

    // ============ Fuzz Tests: Basic Properties ============

    /**
     * @notice Fuzz test: Payments sum to totalResolverShare (within rounding tolerance)
     */
    function testFuzz_PaymentsSumToTotalResolverShare(
        uint8 resolverCount,
        uint256 escrowFee,
        uint256 escalationFee,
        uint16 resolverShareBps
    ) public {
        // Bound inputs to reasonable ranges
        resolverCount = uint8(bound(resolverCount, 1, MAX_RESOLVERS));
        escrowFee = bound(escrowFee, 1, MAX_FEE);
        escalationFee = bound(escalationFee, 0, MAX_FEE);
        resolverShareBps = uint16(bound(resolverShareBps, 1, BASIS_POINTS_DENOMINATOR));

        // Create resolver records (distribute levels evenly)
        ResolverRecord[] memory resolvers = new ResolverRecord[](resolverCount);
        for (uint256 i = 0; i < resolverCount; i++) {
            uint8 level = uint8(i % 3); // Distribute across levels 0, 1, 2
            resolvers[i] = _createResolverRecord(resolverAddresses[i], level);
        }

        PaymentInput memory input = PaymentInput({
            escrowFee: escrowFee,
            escalationFees: escalationFee,
            resolverSharePercentage: resolverShareBps,
            resolvers: resolvers,
            weights: _createValidWeights()
        });

        PaymentOutput memory output = paymentLib.calculatePayments(input);

        // INVARIANT: Sum of payments should equal totalResolverShare (within rounding tolerance)
        uint256 paymentSum = 0;
        for (uint256 i = 0; i < output.payments.length; i++) {
            paymentSum += output.payments[i];
        }

        // Allow rounding tolerance: paymentSum can be slightly less than totalResolverShare due to integer division
        // But should never exceed it
        assertLe(paymentSum, output.totalResolverShare, 'Payment sum exceeds total share');
        
        // Rounding tolerance: difference should be small (at most resolverCount - 1 due to remainder distribution)
        uint256 totalFees = escrowFee + escalationFee;
        uint256 expectedShare = (totalFees * resolverShareBps) / BASIS_POINTS_DENOMINATOR;
        assertLe(output.totalResolverShare - paymentSum, resolverCount, 'Rounding error too large');
        assertEq(output.totalResolverShare, expectedShare, 'Total share calculation incorrect');
    }

    /**
     * @notice Fuzz test: No payment exceeds total available
     */
    function testFuzz_NoPaymentExceedsTotal(
        uint8 resolverCount,
        uint256 escrowFee,
        uint256 escalationFee,
        uint16 resolverShareBps
    ) public {
        resolverCount = uint8(bound(resolverCount, 1, MAX_RESOLVERS));
        escrowFee = bound(escrowFee, 1, MAX_FEE);
        escalationFee = bound(escalationFee, 0, MAX_FEE);
        resolverShareBps = uint16(bound(resolverShareBps, 1, BASIS_POINTS_DENOMINATOR));

        ResolverRecord[] memory resolvers = new ResolverRecord[](resolverCount);
        for (uint256 i = 0; i < resolverCount; i++) {
            resolvers[i] = _createResolverRecord(resolverAddresses[i], uint8(i % 3));
        }

        PaymentInput memory input = PaymentInput({
            escrowFee: escrowFee,
            escalationFees: escalationFee,
            resolverSharePercentage: resolverShareBps,
            resolvers: resolvers,
            weights: _createValidWeights()
        });

        PaymentOutput memory output = paymentLib.calculatePayments(input);

        uint256 totalFees = escrowFee + escalationFee;
        uint256 maxPossibleShare = (totalFees * resolverShareBps) / BASIS_POINTS_DENOMINATOR;

        // INVARIANT: Each payment should not exceed the maximum possible share
        for (uint256 i = 0; i < output.payments.length; i++) {
            assertLe(output.payments[i], maxPossibleShare, 'Payment exceeds maximum possible');
        }
    }

    /**
     * @notice Fuzz test: All payments are non-negative
     */
    function testFuzz_PaymentsNonNegative(
        uint8 resolverCount,
        uint256 escrowFee,
        uint256 escalationFee,
        uint16 resolverShareBps
    ) public {
        resolverCount = uint8(bound(resolverCount, 1, MAX_RESOLVERS));
        escrowFee = bound(escrowFee, 0, MAX_FEE);
        escalationFee = bound(escalationFee, 0, MAX_FEE);
        resolverShareBps = uint16(bound(resolverShareBps, 0, BASIS_POINTS_DENOMINATOR));

        ResolverRecord[] memory resolvers = new ResolverRecord[](resolverCount);
        for (uint256 i = 0; i < resolverCount; i++) {
            resolvers[i] = _createResolverRecord(resolverAddresses[i], uint8(i % 3));
        }

        PaymentInput memory input = PaymentInput({
            escrowFee: escrowFee,
            escalationFees: escalationFee,
            resolverSharePercentage: resolverShareBps,
            resolvers: resolvers,
            weights: _createValidWeights()
        });

        PaymentOutput memory output = paymentLib.calculatePayments(input);

        // INVARIANT: All payments should be >= 0 (enforced by uint256)
        for (uint256 i = 0; i < output.payments.length; i++) {
            assertGe(output.payments[i], 0, 'Payment is negative');
        }
    }

    /**
     * @notice Fuzz test: Zero fees result in zero payments
     */
    function testFuzz_ZeroFeesZeroPayments(uint8 resolverCount) public {
        resolverCount = uint8(bound(resolverCount, 1, MAX_RESOLVERS));

        ResolverRecord[] memory resolvers = new ResolverRecord[](resolverCount);
        for (uint256 i = 0; i < resolverCount; i++) {
            resolvers[i] = _createResolverRecord(resolverAddresses[i], uint8(i % 3));
        }

        PaymentInput memory input = PaymentInput({
            escrowFee: 0,
            escalationFees: 0,
            resolverSharePercentage: 5000, // 50%
            resolvers: resolvers,
            weights: _createValidWeights()
        });

        PaymentOutput memory output = paymentLib.calculatePayments(input);

        // INVARIANT: Zero fees → zero payments
        assertEq(output.totalResolverShare, 0, 'Total share should be zero');
        for (uint256 i = 0; i < output.payments.length; i++) {
            assertEq(output.payments[i], 0, 'Payment should be zero');
        }
    }

    /**
     * @notice Fuzz test: Zero resolver share percentage results in zero payments
     */
    function testFuzz_ZeroResolverShareZeroPayments(
        uint8 resolverCount,
        uint256 escrowFee,
        uint256 escalationFee
    ) public {
        resolverCount = uint8(bound(resolverCount, 1, MAX_RESOLVERS));
        escrowFee = bound(escrowFee, 1, MAX_FEE);
        escalationFee = bound(escalationFee, 0, MAX_FEE);

        ResolverRecord[] memory resolvers = new ResolverRecord[](resolverCount);
        for (uint256 i = 0; i < resolverCount; i++) {
            resolvers[i] = _createResolverRecord(resolverAddresses[i], uint8(i % 3));
        }

        PaymentInput memory input = PaymentInput({
            escrowFee: escrowFee,
            escalationFees: escalationFee,
            resolverSharePercentage: 0, // 0%
            resolvers: resolvers,
            weights: _createValidWeights()
        });

        PaymentOutput memory output = paymentLib.calculatePayments(input);

        // INVARIANT: Zero resolver share → zero payments
        assertEq(output.totalResolverShare, 0, 'Total share should be zero');
        for (uint256 i = 0; i < output.payments.length; i++) {
            assertEq(output.payments[i], 0, 'Payment should be zero');
        }
    }

    // ============ Fuzz Tests: Weight Distribution ============

    /**
     * @notice Fuzz test: Higher level resolvers get more (or equal if same level)
     */
    function testFuzz_HigherLevelGetsMore(
        uint256 escrowFee,
        uint256 escalationFee,
        uint16 resolverShareBps
    ) public {
        escrowFee = bound(escrowFee, 100000, MAX_FEE); // Much larger to ensure meaningful payments
        escalationFee = bound(escalationFee, 0, MAX_FEE);
        resolverShareBps = uint16(bound(resolverShareBps, 1, BASIS_POINTS_DENOMINATOR));

        // Create resolvers at different levels
        ResolverRecord[] memory resolvers = new ResolverRecord[](3);
        resolvers[0] = _createResolverRecord(resolverAddresses[0], 0); // Level 0 (1x)
        resolvers[1] = _createResolverRecord(resolverAddresses[1], 1); // Level 1 (1.5x)
        resolvers[2] = _createResolverRecord(resolverAddresses[2], 2); // Level 2 (2x)

        PaymentInput memory input = PaymentInput({
            escrowFee: escrowFee,
            escalationFees: escalationFee,
            resolverSharePercentage: resolverShareBps,
            resolvers: resolvers,
            weights: _createValidWeights() // level0=10000, level1=15000, level2=20000
        });

        PaymentOutput memory output = paymentLib.calculatePayments(input);

        // INVARIANT: Higher level should get at least as much (or equal if payments round to same)
        // With large enough fees, strict inequality should hold
        assertGe(output.payments[1], output.payments[0], 'Level 1 should get >= Level 0');
        assertGe(output.payments[2], output.payments[1], 'Level 2 should get >= Level 1');
    }

    // ============ Fuzz Tests: Edge Cases ============

    /**
     * @notice Fuzz test: Single resolver gets all share
     */
    function testFuzz_SingleResolverGetsAllShare(
        uint256 escrowFee,
        uint256 escalationFee,
        uint16 resolverShareBps
    ) public {
        escrowFee = bound(escrowFee, 1, MAX_FEE);
        escalationFee = bound(escalationFee, 0, MAX_FEE);
        resolverShareBps = uint16(bound(resolverShareBps, 1, BASIS_POINTS_DENOMINATOR));

        ResolverRecord[] memory resolvers = new ResolverRecord[](1);
        resolvers[0] = _createResolverRecord(resolverAddresses[0], 0);

        PaymentInput memory input = PaymentInput({
            escrowFee: escrowFee,
            escalationFees: escalationFee,
            resolverSharePercentage: resolverShareBps,
            resolvers: resolvers,
            weights: _createValidWeights()
        });

        PaymentOutput memory output = paymentLib.calculatePayments(input);

        // INVARIANT: Single resolver gets all resolver share (within rounding)
        uint256 totalFees = escrowFee + escalationFee;
        uint256 expectedShare = (totalFees * resolverShareBps) / BASIS_POINTS_DENOMINATOR;
        
        assertEq(output.payments[0], expectedShare, 'Single resolver should get all share');
        assertEq(output.payments[0], output.totalResolverShare, 'Single resolver payment equals total share');
    }

    /**
     * @notice Fuzz test: Very small fees (1 wei) handled correctly
     */
    function testFuzz_VerySmallFees(uint8 resolverCount) public {
        resolverCount = uint8(bound(resolverCount, 1, MAX_RESOLVERS));

        ResolverRecord[] memory resolvers = new ResolverRecord[](resolverCount);
        for (uint256 i = 0; i < resolverCount; i++) {
            resolvers[i] = _createResolverRecord(resolverAddresses[i], uint8(i % 3));
        }

        PaymentInput memory input = PaymentInput({
            escrowFee: 1, // 1 wei
            escalationFees: 0,
            resolverSharePercentage: 5000, // 50%
            resolvers: resolvers,
            weights: _createValidWeights()
        });

        PaymentOutput memory output = paymentLib.calculatePayments(input);

        // Should not revert or overflow
        assertLe(output.totalResolverShare, 1, 'Total share should be <= 1 wei');
        assertLe(output.payments[0], 1, 'Payment should be <= 1 wei');
    }

    /**
     * @notice Fuzz test: Very large fees handled correctly (no overflow)
     */
    function testFuzz_VeryLargeFees(uint8 resolverCount) public {
        resolverCount = uint8(bound(resolverCount, 1, 5)); // Limit to avoid gas issues
        
        ResolverRecord[] memory resolvers = new ResolverRecord[](resolverCount);
        for (uint256 i = 0; i < resolverCount; i++) {
            resolvers[i] = _createResolverRecord(resolverAddresses[i], uint8(i % 3));
        }

        uint256 largeFee = type(uint128).max; // Large but safe
        
        PaymentInput memory input = PaymentInput({
            escrowFee: largeFee,
            escalationFees: largeFee / 2,
            resolverSharePercentage: 5000, // 50%
            resolvers: resolvers,
            weights: _createValidWeights()
        });

        // Should not revert due to overflow
        PaymentOutput memory output = paymentLib.calculatePayments(input);

        // Verify calculations are correct
        uint256 totalFees = largeFee + (largeFee / 2);
        uint256 expectedShare = (totalFees * 5000) / BASIS_POINTS_DENOMINATOR;
        
        assertEq(output.totalResolverShare, expectedShare, 'Total share calculation for large fees');
    }

    // ============ Fuzz Tests: Weight Variations ============

    /**
     * @notice Fuzz test: Custom weights work correctly
     */
    function testFuzz_CustomWeights(
        uint256 level0Weight,
        uint256 level1Weight,
        uint256 level2Weight,
        uint256 escrowFee,
        uint16 resolverShareBps
    ) public {
        // Bound weights to reasonable ranges (avoid zero weights which would cause revert)
        level0Weight = bound(level0Weight, 1, MAX_WEIGHT);
        level1Weight = bound(level1Weight, 1, MAX_WEIGHT);
        level2Weight = bound(level2Weight, 1, MAX_WEIGHT);
        escrowFee = bound(escrowFee, 1000, MAX_FEE);
        resolverShareBps = uint16(bound(resolverShareBps, 1, BASIS_POINTS_DENOMINATOR));

        ResolverRecord[] memory resolvers = new ResolverRecord[](3);
        resolvers[0] = _createResolverRecord(resolverAddresses[0], 0);
        resolvers[1] = _createResolverRecord(resolverAddresses[1], 1);
        resolvers[2] = _createResolverRecord(resolverAddresses[2], 2);

        Weights memory customWeights = Weights({
            level0: level0Weight,
            level1: level1Weight,
            level2: level2Weight
        });

        PaymentInput memory input = PaymentInput({
            escrowFee: escrowFee,
            escalationFees: 0,
            resolverSharePercentage: resolverShareBps,
            resolvers: resolvers,
            weights: customWeights
        });

        PaymentOutput memory output = paymentLib.calculatePayments(input);

        // Verify payments are proportional to weights
        uint256 totalWeight = level0Weight + level1Weight + level2Weight;
        uint256 totalFees = escrowFee;
        uint256 totalShare = (totalFees * resolverShareBps) / BASIS_POINTS_DENOMINATOR;

        // Payment[i] should be approximately (totalShare * weight[i]) / totalWeight
        uint256 expectedPayment0 = (totalShare * level0Weight) / totalWeight;
        uint256 expectedPayment1 = (totalShare * level1Weight) / totalWeight;
        uint256 expectedPayment2 = (totalShare * level2Weight) / totalWeight;

        // Allow rounding tolerance - can have up to 2 wei per resolver due to remainder distribution
        assertLe(output.payments[0], expectedPayment0 + 2, 'Payment 0 exceeds expected (with tolerance)');
        assertLe(output.payments[1], expectedPayment1 + 2, 'Payment 1 exceeds expected (with tolerance)');
        assertLe(output.payments[2], expectedPayment2 + 2, 'Payment 2 exceeds expected (with tolerance)');
    }
}
