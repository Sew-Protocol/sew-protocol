// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import 'forge-std/Test.sol';
import '../../../contracts/decentralized-resolution-module/ResolverIncentiveModuleV2.sol';
import '../../../contracts/decentralized-resolution-module/DecentralizedResolutionModule.sol';
import '../../../contracts/decentralized-resolution-module/PaymentCalculationLibraryV1.sol';
import '../../../contracts/core/EscrowVault.sol';
import '../../../contracts/mocks/ERC20Mock.sol';
import '../../../contracts/decentralized-resolution-module/DecentralizedResolverStructs.sol';
import '../../../contracts/YieldOps.sol';
import '../../../contracts/DisputeOps.sol';

/**
 * @title EscalationDepthHistogram Integration Tests
 * @notice Integration tests for histogram updates during actual dispute escalation flows
 * @dev Tests histogram updates as disputes escalate through the resolution system
 */
contract EscalationDepthHistogramIntegrationTest is Test {
    EscrowVault public escrow;
    DecentralizedResolutionModule public resolutionModule;
    ResolverIncentiveModuleV2 public incentiveModule;
    PaymentCalculationLibraryV1 public paymentLib;
    ERC20Mock public token;
    YieldOps public yieldOps;
    DisputeOps public disputeOps;

    address public deployer;
    address public timelock;
    address public resolver1;
    address public seniorResolver;
    address public user1;
    address public user2;

    uint256 public constant INITIAL_BALANCE = 10000 ether;
    uint256 public constant ESCROW_AMOUNT = 1000 ether;
    uint256 public constant BOND_AMOUNT = 0.01 ether;

    function setUp() public {
        deployer = address(this);
        timelock = makeAddr('timelock');
        resolver1 = makeAddr('resolver1');
        seniorResolver = makeAddr('seniorResolver');
        user1 = makeAddr('user1');
        user2 = makeAddr('user2');

        // Deploy token
        token = new ERC20Mock('Test Token', 'TEST', address(this), 0);
        token.mint(user1, INITIAL_BALANCE);
        token.mint(user2, INITIAL_BALANCE);

        // Deploy payment library
        paymentLib = new PaymentCalculationLibraryV1();

        // Deploy incentive module
        incentiveModule = new ResolverIncentiveModuleV2(deployer, address(paymentLib));

        // Deploy resolution module
        resolutionModule = new DecentralizedResolutionModule(deployer);

        // Deploy escrow
        yieldOps = new YieldOps();
        disputeOps = new DisputeOps();
        escrow = new EscrowVault(100, makeAddr('feeAddress'), address(yieldOps), address(disputeOps));

        // Setup roles - deployer has DEFAULT_ADMIN_ROLE from constructors
        bytes32 ROLE_TIMELOCK = resolutionModule.ROLE_TIMELOCK();
        bytes32 INCENTIVE_ROLE_TIMELOCK = incentiveModule.ROLE_TIMELOCK();
        bytes32 ESCROW_ROLE_TIMELOCK = escrow.ROLE_TIMELOCK();
        
        vm.startPrank(deployer);
        resolutionModule.grantRole(ROLE_TIMELOCK, timelock);
        resolutionModule.grantRole(ROLE_TIMELOCK, deployer);
        incentiveModule.grantRole(INCENTIVE_ROLE_TIMELOCK, timelock);
        incentiveModule.grantRole(INCENTIVE_ROLE_TIMELOCK, deployer);
        escrow.grantRole(ESCROW_ROLE_TIMELOCK, deployer);
        vm.stopPrank();

        // Register contracts
        vm.startPrank(timelock);
        resolutionModule.registerEscrowContract(address(escrow));
        incentiveModule.registerEscrowContract(address(escrow));
        resolutionModule.setIncentiveModule(address(incentiveModule));
        vm.stopPrank();
        
        // Configure resolution module in escrow (required for dispute operations)
        vm.startPrank(deployer);
        escrow.queueResolutionModule(address(resolutionModule));
        vm.warp(block.timestamp + 7 days + 1);
        escrow.activateResolutionModule();
        vm.stopPrank();

        // Setup resolvers - first appoint seniorResolver via timelock, then it can appoint others
        vm.prank(timelock);
        resolutionModule.appointSeniorResolver(seniorResolver, 'Senior Resolver', 'Test senior resolver');
        
        vm.prank(seniorResolver);
        resolutionModule.appointResolver(resolver1, 'Resolver 1', 'Test resolver');
        
        // Activate resolvers
        vm.startPrank(timelock);
        resolutionModule.setResolverActive(resolver1, true);
        resolutionModule.setResolverActive(seniorResolver, true);
        resolutionModule.setResolverCapacity(resolver1, 0, true);
        resolutionModule.setResolverCapacity(seniorResolver, 0, true);
        vm.stopPrank();

        // Configure escalation cost config (must be activated for bonds)
        DecentralizedResolverStructs.EscalationCostConfig
            memory costConfig = DecentralizedResolverStructs.EscalationCostConfig({
                curveType: DecentralizedResolverStructs.CostCurveType.QUADRATIC,
                baseCost: BOND_AMOUNT,
                stepSize: BOND_AMOUNT,
                multiplier: 0,
                bondToken: address(0), // ETH
                enabled: true
            });

        vm.startPrank(timelock);
        resolutionModule.queueEscalationCostConfig(costConfig);
        vm.stopPrank();
        
        // Get the ETA and warp past it
        (, uint64 eta, bool exists) = resolutionModule.getPendingEscalationCostConfig();
        require(exists, "Config should be queued");
        vm.warp(eta + 1);
        
        vm.startPrank(timelock);
        resolutionModule.activateEscalationCostConfig();
        vm.stopPrank();
    }

    // ============ Integration Tests: Full Escalation Flow ============

    /**
     * @notice Test histogram updates when escalating dispute from round 0 to 1
     */
    function test_histogramUpdatesOnEscalation_Round0To1() public {
        // Create escrow
        token.mint(user1, ESCROW_AMOUNT);
        vm.prank(user1);
        token.approve(address(escrow), ESCROW_AMOUNT);
        
        vm.prank(user1);
        uint256 workflowId = escrow.createEscrow(address(token), user2, ESCROW_AMOUNT);

        // Verify initial histogram state
        (uint256 round0, uint256 round1, uint256 round2) = incentiveModule.getEscalationDepthHistogram();
        assertEq(round0, 0, "Round 0 should start at 0");
        assertEq(round1, 0, "Round 1 should start at 0");
        assertEq(round2, 0, "Round 2 should start at 0");

        // Raise dispute
        vm.prank(user1);
        escrow.raiseDispute(workflowId);

        // Wait for resolver decision, then escalate (this is simplified - actual flow requires resolver decision)
        // Note: Full escalation flow test would require more complex setup
        // For now, we test that when a bond is recorded during escalation, histogram updates

        // Simulate escalation by recording bond directly (in real flow, BaseEscrow does this)
        vm.deal(address(escrow), BOND_AMOUNT);
        vm.prank(address(escrow));
        incentiveModule.recordAppealBond{value: BOND_AMOUNT}(
            workflowId,
            user1,
            BOND_AMOUNT,
            address(0),
            1 // Round 1
        );

        // Verify histogram updated
        (round0, round1, round2) = incentiveModule.getEscalationDepthHistogram();
        assertEq(round0, 0, "Round 0 should remain 0");
        assertEq(round1, 1, "Round 1 should increment to 1");
        assertEq(round2, 0, "Round 2 should remain 0");
    }

    /**
     * @notice Test histogram updates when escalating dispute from round 1 to 2
     */
    function test_histogramUpdatesOnEscalation_Round1To2() public {
        // Create escrow and escalate to round 1 first
        token.mint(user1, ESCROW_AMOUNT);
        vm.prank(user1);
        token.approve(address(escrow), ESCROW_AMOUNT);
        
        vm.prank(user1);
        uint256 workflowId = escrow.createEscrow(address(token), user2, ESCROW_AMOUNT);

        // Record bond at round 1
        vm.deal(address(escrow), BOND_AMOUNT * 2); // Enough for both rounds
        vm.prank(address(escrow));
        incentiveModule.recordAppealBond{value: BOND_AMOUNT}(
            workflowId,
            user1,
            BOND_AMOUNT,
            address(0),
            1
        );

        // Verify round 1 incremented
        (uint256 round0, uint256 round1, uint256 round2) = incentiveModule.getEscalationDepthHistogram();
        assertEq(round1, 1, "Round 1 should be 1");

        // Record bond at round 2 (escalate from round 1)
        vm.prank(address(escrow));
        incentiveModule.recordAppealBond{value: BOND_AMOUNT}(
            workflowId,
            user1,
            BOND_AMOUNT,
            address(0),
            2
        );

        // Verify histogram updated
        (round0, round1, round2) = incentiveModule.getEscalationDepthHistogram();
        assertEq(round0, 0, "Round 0 should remain 0");
        assertEq(round1, 1, "Round 1 should remain 1");
        assertEq(round2, 1, "Round 2 should increment to 1");
    }

    /**
     * @notice Test histogram accumulates correctly across multiple disputes
     */
    function test_histogramAccumulatesAcrossMultipleDisputes() public {
        uint256 numDisputes = 3;
        
        // Create multiple escrows and escalate them
        for (uint256 i = 0; i < numDisputes; i++) {
            token.mint(user1, ESCROW_AMOUNT);
            vm.prank(user1);
            token.approve(address(escrow), ESCROW_AMOUNT);
            
            vm.prank(user1);
            uint256 workflowId = escrow.createEscrow(address(token), user2, ESCROW_AMOUNT);

            // Record bond at round 1 for each
            vm.deal(address(escrow), BOND_AMOUNT * (i + 1));
            vm.prank(address(escrow));
            incentiveModule.recordAppealBond{value: BOND_AMOUNT}(
                workflowId,
                user1,
                BOND_AMOUNT,
                address(0),
                1
            );
        }

        // Verify histogram accumulated
        (uint256 round0, uint256 round1, uint256 round2) = incentiveModule.getEscalationDepthHistogram();
        assertEq(round0, 0, "Round 0 should remain 0");
        assertEq(round1, numDisputes, "Round 1 should equal number of disputes");
        assertEq(round2, 0, "Round 2 should remain 0");

        // Escalate second dispute to round 2
        vm.deal(address(escrow), BOND_AMOUNT);
        vm.prank(address(escrow));
        incentiveModule.recordAppealBond{value: BOND_AMOUNT}(
            1, // workflowId 1
            user1,
            BOND_AMOUNT,
            address(0),
            2
        );

        // Verify histogram updated
        (round0, round1, round2) = incentiveModule.getEscalationDepthHistogram();
        assertEq(round1, numDisputes, "Round 1 should remain 3");
        assertEq(round2, 1, "Round 2 should increment to 1");
    }

    /**
     * @notice Test histogram not affected by failed bond recording attempts
     */
    function test_histogramNoUpdateOnFailedBondRecording() public {
        // Verify initial state
        (uint256 round0, uint256 round1, uint256 round2) = incentiveModule.getEscalationDepthHistogram();
        uint256 initialRound1 = round1;

        // Attempt to record bond with zero amount (should revert)
        vm.prank(address(escrow));
        vm.expectRevert();
        incentiveModule.recordAppealBond{value: 0}(
            1,
            user1,
            0,
            address(0),
            1
        );

        // Verify histogram unchanged
        (round0, round1, round2) = incentiveModule.getEscalationDepthHistogram();
        assertEq(round1, initialRound1, "Round 1 should remain unchanged");

        // Attempt to record bond with invalid round (should revert)
        vm.deal(address(escrow), BOND_AMOUNT);
        vm.prank(address(escrow));
        vm.expectRevert();
        incentiveModule.recordAppealBond{value: BOND_AMOUNT}(
            1,
            user1,
            BOND_AMOUNT,
            address(0),
            0 // Invalid round
        );

        // Verify histogram unchanged
        (round0, round1, round2) = incentiveModule.getEscalationDepthHistogram();
        assertEq(round1, initialRound1, "Round 1 should remain unchanged");
    }

    /**
     * @notice Test histogram matches actual bond count across all workflow IDs
     */
    function test_histogramMatchesActualBondCount() public {
        // Record bonds at various rounds
        uint256[] memory workflowIds = new uint256[](10);
        
        vm.deal(address(escrow), BOND_AMOUNT * 15); // Enough for all bonds
        
        vm.startPrank(address(escrow));
        // Record 5 bonds at round 1
        for (uint256 i = 0; i < 5; i++) {
            workflowIds[i] = i;
            incentiveModule.recordAppealBond{value: BOND_AMOUNT}(
                i,
                user1,
                BOND_AMOUNT,
                address(0),
                1
            );
        }

        // Record 3 bonds at round 2
        for (uint256 i = 5; i < 8; i++) {
            workflowIds[i] = i;
            incentiveModule.recordAppealBond{value: BOND_AMOUNT}(
                i,
                user1,
                BOND_AMOUNT,
                address(0),
                2
            );
        }

        // Record 2 more bonds at round 1
        for (uint256 i = 8; i < 10; i++) {
            workflowIds[i] = i;
            incentiveModule.recordAppealBond{value: BOND_AMOUNT}(
                i,
                user1,
                BOND_AMOUNT,
                address(0),
                1
            );
        }
        vm.stopPrank();

        // Get histogram
        (uint256 round0, uint256 round1, uint256 round2) = incentiveModule.getEscalationDepthHistogram();

        // Count actual bonds
        uint256 actualRound1 = 0;
        uint256 actualRound2 = 0;

        for (uint256 i = 0; i < 100; i++) { // Scan reasonable range
            if (incentiveModule.hasAppealBond(i, 1)) actualRound1++;
            if (incentiveModule.hasAppealBond(i, 2)) actualRound2++;
        }

        // Verify histogram matches actual counts
        assertEq(round1, actualRound1, "Round 1 histogram should match actual bonds");
        assertEq(round2, actualRound2, "Round 2 histogram should match actual bonds");
        assertEq(round0, 0, "Round 0 should always be 0");

        // Verify expected counts
        assertEq(round1, 7, "Round 1 should have 7 bonds (5 + 2)");
        assertEq(round2, 3, "Round 2 should have 3 bonds");
    }
}
