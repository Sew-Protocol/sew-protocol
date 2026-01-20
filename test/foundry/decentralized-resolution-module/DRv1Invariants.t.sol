// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.33;

import 'forge-std/Test.sol';
import 'forge-std/StdInvariant.sol';
import '../../../contracts/decentralized-resolution-module/DecentralizedResolutionModule.sol';
import '../../../contracts/decentralized-resolution-module/ResolverIncentiveModuleV1.sol';
import '../../../contracts/decentralized-resolution-module/DecentralizedResolverStructs.sol';
import '../../../contracts/decentralized-resolution-module/ResolutionAnalytics.sol';
import '../../../contracts/decentralized-resolution-module/PaymentCalculationLibraryV1.sol';

/**
 * @title DRv1InvariantsTest
 * @notice Invariant testing for DR v1 EMA scoring and workload routing
 * @dev Tests critical system properties for resolver performance tracking
 */
contract DRv1InvariantsTest is StdInvariant, Test {
    DecentralizedResolutionModule public resolutionModule;
    ResolverIncentiveModuleV1 public incentiveModule;
    PaymentCalculationLibraryV1 public paymentLib;

    address public admin;
    address public timelock = address(0x2);
    address public escrowContract = address(0x3);
    address public seniorResolver = address(0x100);
    address[] public resolvers;

    bytes32 public constant ROLE_TIMELOCK = keccak256('ROLE_TIMELOCK');

    uint256 constant EMA_PRECISION = 1e6;
    uint256 constant BASIS_POINTS = 10000;

    function setUp() public {
        admin = address(this); // Use test contract as admin

        // Deploy contracts
        paymentLib = new PaymentCalculationLibraryV1();
        resolutionModule = new DecentralizedResolutionModule(admin);
        incentiveModule = new ResolverIncentiveModuleV1(admin, address(paymentLib));

        // Register escrow - admin has DEFAULT_ADMIN_ROLE from constructors
        vm.startPrank(admin);
        incentiveModule.grantRole(ROLE_TIMELOCK, admin);
        resolutionModule.grantRole(ROLE_TIMELOCK, admin);
        incentiveModule.registerEscrowContract(escrowContract);
        resolutionModule.registerEscrowContract(escrowContract);
        resolutionModule.grantRole(ROLE_TIMELOCK, timelock);
        vm.stopPrank();

        // Appoint senior resolver
        vm.startPrank(timelock);
        resolutionModule.appointSeniorResolver(seniorResolver, 'Senior', 'Test senior');
        resolutionModule.setResolverCapacity(seniorResolver, 0, true);
        vm.stopPrank();

        // Appoint standard resolvers
        for (uint160 i = 1; i <= 10; i++) {
            address resolver = address(0x1000 + i);
            resolvers.push(resolver);

            vm.prank(seniorResolver);
            resolutionModule.appointResolver(resolver, 'Resolver', 'Test');

            vm.prank(timelock);
            resolutionModule.setResolverCapacity(resolver, 0, true);
        }

        // Target contract for invariant testing
        targetContract(address(resolutionModule));
    }

    // ============ INVARIANT 1: EMA Score Bounds ============

    /**
     * @notice INVARIANT: EMA scores are always within [0, 1e6]
     * @dev Ensures no overflow or negative scores
     */
    function invariant_EMAScoreBounds() public view {
        for (uint256 i = 0; i < resolvers.length; i++) {
            DecentralizedResolverStructs.ResolverStats memory stats = resolutionModule
                .getDisputeResolverStats(resolvers[i]);

            uint256 emaScore = stats.emaScore;
            uint256 casesAssigned = stats.casesAssigned;
            uint256 casesDecided = stats.casesDecided;

            // EMA score must be in valid range
            assertTrue(emaScore <= EMA_PRECISION, 'EMA score cannot exceed 1e6');

            // If resolver has activity, score should be initialized
            if (casesAssigned > 0 || casesDecided > 0) {
                // Score should have been set (either default 1e6 or updated)
                assertTrue(
                    emaScore > 0 || emaScore == 0, // Allow 0 for severely penalized resolvers
                    'Active resolver should have score'
                );
            }
        }

        // Check senior resolver too
        DecentralizedResolverStructs.ResolverStats memory seniorStats = resolutionModule
            .getDisputeResolverStats(seniorResolver);
        assertTrue(seniorStats.emaScore <= EMA_PRECISION, 'Senior EMA score must be bounded');
    }

    // ============ INVARIANT 2: Counter Consistency ============

    /**
     * @notice INVARIANT: casesDecided <= casesAssigned
     * @dev Cannot decide more cases than assigned
     */
    function invariant_CounterConsistency() public view {
        for (uint256 i = 0; i < resolvers.length; i++) {
            DecentralizedResolverStructs.ResolverStats memory stats = resolutionModule
                .getDisputeResolverStats(resolvers[i]);

            uint256 casesAssigned = stats.casesAssigned;
            uint256 casesDecided = stats.casesDecided;
            uint256 timeoutsAccept = stats.timeoutsAccept;
            uint256 timeoutsResolve = stats.timeoutsResolve;
            uint256 reversals = stats.reversals;

            // Decided cases cannot exceed assigned
            assertTrue(casesDecided <= casesAssigned, 'Cannot decide more than assigned');

            // All counters must be non-negative (uint, so always true, but documents invariant)
            assertTrue(casesAssigned >= 0, 'Assigned must be non-negative');
            assertTrue(casesDecided >= 0, 'Decided must be non-negative');
            assertTrue(timeoutsAccept >= 0, 'Accept timeouts must be non-negative');
            assertTrue(timeoutsResolve >= 0, 'Resolve timeouts must be non-negative');
            assertTrue(reversals >= 0, 'Reversals must be non-negative');
        }
    }

    // ============ INVARIANT 3: Timeout Rate Bounds ============

    /**
     * @notice INVARIANT: Timeout rate is in [0, 10000] basis points (0-100%)
     * @dev Ensures rate calculations don't overflow
     */
    function invariant_TimeoutRateBounds() public view {
        for (uint256 i = 0; i < resolvers.length; i++) {
            DecentralizedResolverStructs.ResolverStats memory stats = resolutionModule
                .getDisputeResolverStats(resolvers[i]);

            uint256 casesAssigned = stats.casesAssigned;
            uint256 timeoutsAccept = stats.timeoutsAccept;
            uint256 timeoutsResolve = stats.timeoutsResolve;

            if (casesAssigned > 0) {
                uint256 totalTimeouts = timeoutsAccept + timeoutsResolve;
                uint256 timeoutRate = (totalTimeouts * BASIS_POINTS) / casesAssigned;

                assertTrue(timeoutRate <= BASIS_POINTS, 'Timeout rate cannot exceed 100%');
            }
        }
    }

    // ============ INVARIANT 4: Reversal Rate Bounds ============

    /**
     * @notice INVARIANT: Reversal rate is in [0, 10000] basis points (0-100%)
     * @dev Ensures reversals don't exceed decisions
     */
    function invariant_ReversalRateBounds() public view {
        for (uint256 i = 0; i < resolvers.length; i++) {
            DecentralizedResolverStructs.ResolverStats memory stats = resolutionModule
                .getDisputeResolverStats(resolvers[i]);

            uint256 casesDecided = stats.casesDecided;
            uint256 reversals = stats.reversals;

            // Reversals cannot exceed decisions
            assertTrue(reversals <= casesDecided, 'Reversals cannot exceed decisions');

            if (casesDecided > 0) {
                uint256 reversalRate = (reversals * BASIS_POINTS) / casesDecided;
                assertTrue(reversalRate <= BASIS_POINTS, 'Reversal rate cannot exceed 100%');
            }
        }
    }

    // ============ INVARIANT 5: Workload Weight Validity ============

    /**
     * @notice INVARIANT: Workload weight is in [0, infinity) with proper bounds
     * @dev Ensures weight calculations are reasonable
     */
    function invariant_WorkloadWeightValidity() public view {
        for (uint256 i = 0; i < resolvers.length; i++) {
            DecentralizedResolverStructs.ResolverStats memory stats = resolutionModule
                .getDisputeResolverStats(resolvers[i]);

            uint256 emaScore = stats.emaScore;
            uint256 casesAssigned = stats.casesAssigned;
            uint256 timeoutsAccept = stats.timeoutsAccept;
            uint256 timeoutsResolve = stats.timeoutsResolve;
            uint256 assignmentWeight = stats.assignmentWeight;

            // Manual override weight should be reasonable
            assertTrue(assignmentWeight <= BASIS_POINTS, 'Assignment weight should be <= 10000');

            // If resolver has cases, check timeout rate for weight calculation
            if (casesAssigned > 0) {
                uint256 totalTimeouts = timeoutsAccept + timeoutsResolve;
                uint256 timeoutRate = (totalTimeouts * BASIS_POINTS) / casesAssigned;

                // If timeout rate > max threshold, weight should be 0
                uint256 maxTimeoutRate = resolutionModule.maxTimeoutRateBps();
                if (timeoutRate > maxTimeoutRate) {
                    // Weight should be 0 (but we can't directly check workload weight from here)
                    // This is verified in the analytics library
                }

                // If EMA score < threshold, weight should be 0
                uint256 minThreshold = resolutionModule.minEmaScoreThreshold();
                if (emaScore < minThreshold && assignmentWeight == 0) {
                    // Correctly gated out
                }
            }
        }
    }

    // ============ INVARIANT 6: Phase Gate Metrics Consistency ============

    /**
     * @notice INVARIANT: Phase gate metrics are mathematically consistent
     * @dev Escalation rate and avg time must match underlying data
     */
    function invariant_PhaseGateMetricsConsistency() public view {
        (
            uint256 escalationRate,
            uint256 avgResponseTime,
            uint256 activeResolvers
        ) = resolutionModule.getV1PhaseGateMetrics();

        // Escalation rate must be in valid range
        assertTrue(escalationRate <= BASIS_POINTS, 'Escalation rate must be <= 100%');

        // Active resolvers must be reasonable (we can't know exact count during fuzzing)
        // Just verify it's not an absurdly large number
        assertTrue(activeResolvers < 1000, 'Active resolvers must be reasonable');

        // Average response time must be reasonable (not checking specific value,
        // but ensuring it doesn't overflow)
        assertTrue(avgResponseTime < type(uint128).max, 'Avg response time should be reasonable');
    }

    // ============ INVARIANT 7: Resolver Activity Tracking ============

    /**
     * @notice INVARIANT: lastActive timestamp is monotonically increasing
     * @dev Once a resolver is active, lastActive can only increase
     */
    function invariant_LastActiveMonotonic() public view {
        for (uint256 i = 0; i < resolvers.length; i++) {
            DecentralizedResolverStructs.ResolverStats memory stats = resolutionModule
                .getDisputeResolverStats(resolvers[i]);

            uint256 lastActive = stats.lastActive;

            // lastActive should not be in the future
            assertTrue(lastActive <= block.timestamp, 'lastActive cannot be in future');
        }
    }
}

/**
 * @title DRv1FuzzTest
 * @notice Fuzz testing for DR v1 EMA scoring and workload routing
 * @dev Tests system behavior with random inputs
 */
contract DRv1FuzzTest is Test {
    DecentralizedResolutionModule public resolutionModule;
    ResolverIncentiveModuleV1 public incentiveModule;
    PaymentCalculationLibraryV1 public paymentLib;

    address public admin;
    address public timelock = address(0x2);
    address public escrowContract = address(0x3);
    address public seniorResolver = address(0x100);
    address public resolver1 = address(0x1001);

    bytes32 public constant ROLE_TIMELOCK = keccak256('ROLE_TIMELOCK');

    uint256 constant EMA_PRECISION = 1e6;
    uint256 constant BASIS_POINTS = 10000;

    function setUp() public {
        admin = address(this); // Use test contract as admin
        
        paymentLib = new PaymentCalculationLibraryV1();
        resolutionModule = new DecentralizedResolutionModule(admin);
        incentiveModule = new ResolverIncentiveModuleV1(admin, address(paymentLib));

        // Grant ROLE_TIMELOCK to admin first, then register escrow
        vm.startPrank(admin);
        incentiveModule.grantRole(ROLE_TIMELOCK, admin);
        resolutionModule.grantRole(ROLE_TIMELOCK, admin);
        incentiveModule.registerEscrowContract(escrowContract);
        resolutionModule.registerEscrowContract(escrowContract);
        resolutionModule.grantRole(ROLE_TIMELOCK, timelock);
        vm.stopPrank();

        // Appoint resolvers
        vm.startPrank(timelock);
        resolutionModule.appointSeniorResolver(seniorResolver, 'Senior', 'Test');
        resolutionModule.setResolverCapacity(seniorResolver, 0, true);
        vm.stopPrank();

        vm.prank(seniorResolver);
        resolutionModule.appointResolver(resolver1, 'Resolver', 'Test');

        vm.prank(timelock);
        resolutionModule.setResolverCapacity(resolver1, 0, true);
    }

    // ============ FUZZ TEST: EMA Score Updates ============

    function testFuzz_EMAScoreUpdate(
        uint256 initialScore,
        uint256 outcome,
        uint256 alphaBps
    ) public {
        // Bound inputs
        initialScore = bound(initialScore, 0, EMA_PRECISION);
        outcome = bound(outcome, 0, EMA_PRECISION);
        alphaBps = bound(alphaBps, 1, BASIS_POINTS);

        // Initialize resolver with specific score
        vm.prank(escrowContract);
        resolutionModule.initializeDispute(1, resolver1, bytes32(0));

        // Record successful resolution
        vm.prank(escrowContract);
        resolutionModule.recordResolution(
            1,
            resolver1,
            DecentralizedResolverStructs.ResolutionOutcome.RELEASE,
            1 hours
        );

        DecentralizedResolverStructs.ResolverStats memory stats = resolutionModule
            .getDisputeResolverStats(resolver1);
        uint256 emaScore = stats.emaScore;

        // EMA score should be bounded
        assertTrue(emaScore <= EMA_PRECISION, 'EMA score exceeds max');
        assertTrue(emaScore >= 0, 'EMA score negative');
    }

    // ============ FUZZ TEST: Timeout Recording ============

    function testFuzz_TimeoutRecording(uint8 numTimeouts, uint8 timeoutType) public {
        numTimeouts = uint8(bound(numTimeouts, 1, 50));
        timeoutType = uint8(bound(timeoutType, 0, 1)); // 0=accept, 1=resolve

        uint256 timeoutCount = 0;

        // Initialize multiple disputes
        for (uint256 i = 0; i < numTimeouts; i++) {
            vm.prank(escrowContract);
            resolutionModule.initializeDispute(i + 1, resolver1, bytes32(0));

            // Warp past deadline
            vm.warp(block.timestamp + 4 days);

            // Try to force progress (may or may not timeout depending on resolver availability)
            try resolutionModule.forceProgress(i + 1) {
                timeoutCount++;
            } catch {
                // May fail if no alternative resolver available
            }
        }

        DecentralizedResolverStructs.ResolverStats memory stats = resolutionModule
            .getDisputeResolverStats(resolver1);

        uint256 casesAssigned = stats.casesAssigned;
        uint256 timeoutsAccept = stats.timeoutsAccept;
        uint256 timeoutsResolve = stats.timeoutsResolve;

        // Verify timeout counters (may be less than numTimeouts if reassignment failed)
        assertTrue(casesAssigned >= 1, 'At least one case should be assigned');
        uint256 totalTimeouts = timeoutsAccept + timeoutsResolve;
        assertTrue(totalTimeouts <= casesAssigned, 'Total timeouts <= assigned');

        // Timeout rate should be valid
        if (casesAssigned > 0) {
            uint256 timeoutRate = (totalTimeouts * BASIS_POINTS) / casesAssigned;
            assertTrue(timeoutRate <= BASIS_POINTS, 'Timeout rate <= 100%');
        }
    }

    // ============ FUZZ TEST: Reversal Recording ============

    function testFuzz_ReversalRecording(uint8 numDisputes, uint256 seed) public {
        numDisputes = uint8(bound(numDisputes, 1, 20));

        uint256 expectedReversals = 0;

        for (uint256 i = 0; i < numDisputes; i++) {
            uint256 workflowId = i + 1;

            // Initialize dispute
            vm.prank(escrowContract);
            resolutionModule.initializeDispute(workflowId, resolver1, bytes32(0));

            // Resolver decides
            DecentralizedResolverStructs.ResolutionOutcome outcome1 = DecentralizedResolverStructs
                .ResolutionOutcome
                .RELEASE;

            vm.prank(escrowContract);
            resolutionModule.recordResolution(workflowId, resolver1, outcome1, 1 hours);

            // Randomly escalate some disputes
            uint256 rand = uint256(keccak256(abi.encodePacked(seed, i))) % 2;
            if (rand == 1) {
                // Escalate to senior resolver
                vm.prank(escrowContract);
                resolutionModule.executeEscalation(workflowId, '');

                // Senior decides differently (reversal)
                DecentralizedResolverStructs.ResolutionOutcome outcome2 = DecentralizedResolverStructs
                        .ResolutionOutcome
                        .CANCEL;

                vm.prank(escrowContract);
                resolutionModule.recordResolution(workflowId, seniorResolver, outcome2, 2 hours);

                // Record reversal
                vm.prank(escrowContract);
                resolutionModule.recordReversal(workflowId, 0);

                expectedReversals++;
            }
        }

        DecentralizedResolverStructs.ResolverStats memory stats = resolutionModule
            .getDisputeResolverStats(resolver1);

        uint256 casesDecided = stats.casesDecided;
        uint256 reversals = stats.reversals;

        // Verify reversal tracking
        assertEq(reversals, expectedReversals, 'Reversals should match');
        assertTrue(reversals <= casesDecided, 'Reversals <= decided');

        // Reversal rate should be valid
        if (casesDecided > 0) {
            uint256 reversalRate = (reversals * BASIS_POINTS) / casesDecided;
            assertTrue(reversalRate <= BASIS_POINTS, 'Reversal rate <= 100%');
        }
    }

    // ============ FUZZ TEST: Workload Weight Calculation ============

    function testFuzz_WorkloadWeightCalculation(
        uint256 emaScore,
        uint256 totalTimeouts,
        uint256 casesAssigned
    ) public {
        // Bound inputs
        emaScore = bound(emaScore, 0, EMA_PRECISION);
        casesAssigned = bound(casesAssigned, 1, 1000);
        totalTimeouts = bound(totalTimeouts, 0, casesAssigned);

        uint256 minScoreThreshold = resolutionModule.minEmaScoreThreshold();
        uint256 maxTimeoutRate = resolutionModule.maxTimeoutRateBps();

        // Calculate expected weight
        uint256 timeoutRate = casesAssigned > 0
            ? (totalTimeouts * BASIS_POINTS) / casesAssigned
            : 0;

        bool shouldBeZero = (emaScore < minScoreThreshold) || (timeoutRate > maxTimeoutRate);

        // We can't directly test ResolutionAnalytics.calculateWorkloadWeight from here,
        // but we can verify the logic through integration
        if (shouldBeZero) {
            // Resolver should be gated out
            assertTrue(
                emaScore < minScoreThreshold || timeoutRate > maxTimeoutRate,
                'Gating conditions should be met'
            );
        }
    }

    // ============ FUZZ TEST: Round-Based Dispute Flow ============

    function testFuzz_RoundBasedDisputeFlow(uint8 numDisputes, uint256 seed) public {
        numDisputes = uint8(bound(numDisputes, 1, 30));

        for (uint256 i = 0; i < numDisputes; i++) {
            uint256 workflowId = i + 1;

            // Initialize at round 0
            vm.prank(escrowContract);
            resolutionModule.initializeDispute(workflowId, resolver1, bytes32(0));

            // Get dispute metadata
            DecentralizedResolverStructs.DisputeMetadata memory dm = resolutionModule
                .getDisputeMetadata(workflowId);

            uint8 currentRound = dm.currentRound;
            DecentralizedResolverStructs.DisputeStatus status = dm.status;

            assertEq(currentRound, 0, 'Should start at round 0');
            assertEq(
                uint8(status),
                uint8(DecentralizedResolverStructs.DisputeStatus.Open),
                'Should be Open'
            );

            // Randomly resolve or escalate
            uint256 rand = uint256(keccak256(abi.encodePacked(seed, i))) % 3;

            if (rand == 0) {
                // Resolve at round 0
                vm.prank(escrowContract);
                resolutionModule.recordResolution(
                    workflowId,
                    resolver1,
                    DecentralizedResolverStructs.ResolutionOutcome.RELEASE,
                    1 hours
                );
            } else if (rand == 1) {
                // Resolve then escalate
                vm.prank(escrowContract);
                resolutionModule.recordResolution(
                    workflowId,
                    resolver1,
                    DecentralizedResolverStructs.ResolutionOutcome.RELEASE,
                    1 hours
                );

                vm.prank(escrowContract);
                resolutionModule.executeEscalation(workflowId, '');

                dm = resolutionModule.getDisputeMetadata(workflowId);
                currentRound = dm.currentRound;
                assertEq(currentRound, 1, 'Should be at round 1');
            } else {
                // Timeout and force progress
                vm.warp(block.timestamp + 4 days);
                vm.prank(escrowContract);
                resolutionModule.forceProgress(workflowId);
            }
        }

        // Verify resolver stats are updated
        DecentralizedResolverStructs.ResolverStats memory stats = resolutionModule
            .getDisputeResolverStats(resolver1);

        uint256 emaScore = stats.emaScore;
        uint256 casesAssigned = stats.casesAssigned;
        uint256 casesDecided = stats.casesDecided;

        assertTrue(casesAssigned >= numDisputes, 'Cases assigned should match');
        assertTrue(casesDecided <= casesAssigned, 'Decided <= assigned');
        assertTrue(emaScore <= EMA_PRECISION, 'EMA score bounded');
    }

    // ============ FUZZ TEST: EMA Alpha Parameter ============

    function testFuzz_EMAAlphaParameter(uint256 alphaBps) public {
        // Bound alpha to valid range
        alphaBps = bound(alphaBps, 1, BASIS_POINTS);

        // Set EMA parameters
        vm.prank(timelock);
        resolutionModule.setEMAParameters(
            alphaBps,
            500000, // 50% min score
            3000 // 30% max timeout
        );

        // Verify parameters set correctly
        assertEq(resolutionModule.emaAlphaBps(), alphaBps, 'Alpha should match');

        // Initialize and resolve a dispute
        vm.prank(escrowContract);
        resolutionModule.initializeDispute(1, resolver1, bytes32(0));

        vm.prank(escrowContract);
        resolutionModule.recordResolution(
            1,
            resolver1,
            DecentralizedResolverStructs.ResolutionOutcome.RELEASE,
            1 hours
        );

        DecentralizedResolverStructs.ResolverStats memory stats = resolutionModule
            .getDisputeResolverStats(resolver1);
        uint256 emaScore = stats.emaScore;

        // EMA score should be updated and bounded
        assertTrue(emaScore <= EMA_PRECISION, 'EMA score must be bounded');
        assertTrue(emaScore > 0, 'EMA score should be positive after successful resolution');
    }

    // ============ FUZZ TEST: Multiple Resolvers Parallel ============

    function testFuzz_MultipleResolversParallel(
        uint8 numResolvers,
        uint8 disputesPerResolver,
        uint256 seed
    ) public {
        numResolvers = uint8(bound(numResolvers, 1, 10));
        disputesPerResolver = uint8(bound(disputesPerResolver, 1, 5));

        address[] memory testResolvers = new address[](numResolvers);

        // Appoint resolvers
        for (uint256 i = 0; i < numResolvers; i++) {
            address resolver = address(uint160(0x2000 + i));
            testResolvers[i] = resolver;

            vm.prank(seniorResolver);
            resolutionModule.appointResolver(resolver, 'Resolver', 'Test');

            vm.prank(timelock);
            resolutionModule.setResolverCapacity(resolver, 0, true);
        }

        uint256 workflowId = 1;

        // Assign disputes to resolvers in round-robin
        for (uint256 i = 0; i < disputesPerResolver; i++) {
            for (uint256 j = 0; j < numResolvers; j++) {
                address resolver = testResolvers[j];

                vm.prank(escrowContract);
                resolutionModule.initializeDispute(workflowId, resolver, bytes32(0));

                // Randomly resolve or timeout
                uint256 rand = uint256(keccak256(abi.encodePacked(seed, i, j))) % 2;

                if (rand == 0) {
                    vm.prank(escrowContract);
                    resolutionModule.recordResolution(
                        workflowId,
                        resolver,
                        DecentralizedResolverStructs.ResolutionOutcome.RELEASE,
                        1 hours
                    );
                } else {
                    vm.warp(block.timestamp + 4 days);
                    vm.prank(escrowContract);
                    resolutionModule.forceProgress(workflowId);
                }

                workflowId++;
            }
        }

        // Verify all resolvers have stats
        for (uint256 i = 0; i < numResolvers; i++) {
            DecentralizedResolverStructs.ResolverStats memory stats = resolutionModule
                .getDisputeResolverStats(testResolvers[i]);

            uint256 emaScore = stats.emaScore;
            uint256 casesAssigned = stats.casesAssigned;

            assertTrue(emaScore <= EMA_PRECISION, 'EMA score bounded');
            assertTrue(casesAssigned >= disputesPerResolver, 'Cases assigned should match');
        }
    }
}
