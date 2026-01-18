// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import 'forge-std/Test.sol';
import '../../../contracts/decentralized-resolution-module/ResolverIncentiveModuleV1.sol';
import '../../../contracts/decentralized-resolution-module/ResolverIncentiveModuleV2.sol';
import '../../../contracts/decentralized-resolution-module/DecentralizedResolutionModule.sol';
import '../../../contracts/decentralized-resolution-module/PaymentCalculationLibraryV1.sol';
import '../../../contracts/core/EscrowVault.sol';
import '../../../contracts/mocks/ERC20Mock.sol';
import '../../../contracts/decentralized-resolution-module/DecentralizedResolverStructs.sol';
import '../../../contracts/types/EscrowTypes.sol';
import '../../../contracts/YieldOps.sol';
import '../../../contracts/DisputeOps.sol';
import '../../../contracts/core/ModuleManagementContract.sol';
import '../../../contracts/admin/EscrowAdminContract.sol';
/**
 * @title IncentiveModuleIntegrationTest
 * @notice Comprehensive integration tests for incentive module lifecycle hooks
 * @dev Tests the integration between BaseEscrow, DecentralizedResolutionModule, and IncentiveModule
 */
contract IncentiveModuleIntegrationTest is Test {
    EscrowVault public escrow;
    DecentralizedResolutionModule public resolutionModule;
    ResolverIncentiveModuleV1 public incentiveModuleV1;
    ResolverIncentiveModuleV2 public incentiveModuleV2;
    PaymentCalculationLibraryV1 public paymentLib;
    ERC20Mock public token;
    YieldOps public yieldOps;
    DisputeOps public disputeOps;
    ModuleManagementContract public moduleManagement;
    EscrowAdminContract public adminContract;

    address public deployer;
    address public timelock;
    address public resolver1;
    address public resolver2;
    address public seniorResolver;
    address public user1;
    address public user2;

    uint256 public constant INITIAL_BALANCE = 10000 ether;

    function setUp() public {
        deployer = address(this);
        timelock = makeAddr('timelock');
        resolver1 = makeAddr('resolver1');
        resolver2 = makeAddr('resolver2');
        seniorResolver = makeAddr('seniorResolver');
        user1 = makeAddr('user1');
        user2 = makeAddr('user2');

        // Deploy token
        token = new ERC20Mock('Test Token', 'TEST', address(this), 0);
        token.mint(user1, INITIAL_BALANCE);
        token.mint(user2, INITIAL_BALANCE);

        // Deploy payment library
        paymentLib = new PaymentCalculationLibraryV1();

        // Deploy incentive modules
        incentiveModuleV1 = new ResolverIncentiveModuleV1(deployer, address(paymentLib));
        incentiveModuleV2 = new ResolverIncentiveModuleV2(deployer, address(paymentLib));

        // Deploy resolution module
        resolutionModule = new DecentralizedResolutionModule(deployer);

        // Deploy escrow
        YieldOps yOps = new YieldOps(address(this));
        DisputeOps dOps = new DisputeOps(address(this));
        // Assign to state variables if they exist, but here we just need address
        moduleManagement = new ModuleManagementContract(address(this));
        adminContract = new EscrowAdminContract(address(this));
        escrow = new EscrowVault(100, makeAddr('feeAddress'), address(yOps), address(dOps), address(moduleManagement));

        // Setup roles
        bytes32 ROLE_TIMELOCK = resolutionModule.ROLE_TIMELOCK();
        resolutionModule.grantRole(ROLE_TIMELOCK, timelock);

        bytes32 INCENTIVE_ROLE_TIMELOCK = incentiveModuleV1.ROLE_TIMELOCK();
        incentiveModuleV1.grantRole(INCENTIVE_ROLE_TIMELOCK, timelock);
        incentiveModuleV2.grantRole(INCENTIVE_ROLE_TIMELOCK, timelock);

        // Register escrow contract in resolution module
        vm.prank(timelock);
        resolutionModule.registerEscrowContract(address(escrow));

        // Register escrow contract in incentive modules
        vm.prank(timelock);
        incentiveModuleV1.registerEscrowContract(address(escrow));
        vm.prank(timelock);
        incentiveModuleV2.registerEscrowContract(address(escrow));

        // Also register resolution module in incentive modules (it calls hooks)
        vm.prank(timelock);
        incentiveModuleV1.registerEscrowContract(address(resolutionModule));
        vm.prank(timelock);
        incentiveModuleV2.registerEscrowContract(address(resolutionModule));

        // Set incentive module in resolution module
        vm.prank(timelock);
        resolutionModule.setIncentiveModule(address(incentiveModuleV1));

        // Set resolution module in escrow
        // Grant TIMELOCK to this contract to queue/activate
        bytes32 ESCROW_ROLE_TIMELOCK = escrow.ROLE_TIMELOCK();
        escrow.grantRole(ESCROW_ROLE_TIMELOCK, address(this));
        adminContract.grantRole(adminContract.ROLE_TIMELOCK(), address(this));

        adminContract.queueResolutionModule(address(escrow), address(resolutionModule));
        vm.warp(block.timestamp + 7 days + 1);
        adminContract.activateResolutionModule(address(escrow));

        // Appoint resolvers
        vm.prank(timelock);
        resolutionModule.appointSeniorResolver(seniorResolver, 'Senior Resolver', 'Test senior');

        vm.prank(seniorResolver);
        resolutionModule.appointResolver(resolver1, 'Resolver 1', 'Test resolver');
        vm.prank(seniorResolver);
        resolutionModule.appointResolver(resolver2, 'Resolver 2', 'Test resolver');

        // Activate resolvers (needed for assignment)
        vm.startPrank(timelock);
        resolutionModule.setResolverActive(seniorResolver, true);
        resolutionModule.setResolverActive(resolver1, true);
        resolutionModule.setResolverActive(resolver2, true);
        resolutionModule.setResolverCapacity(seniorResolver, 0, true);
        resolutionModule.setResolverCapacity(resolver1, 0, true);
        resolutionModule.setResolverCapacity(resolver2, 0, true);
        vm.stopPrank();
    }

    // ============ onDisputeOpened Integration Tests ============

    /**
     * @notice Test that onDisputeOpened is called when dispute is raised
     * @dev This is a complex integration test that verifies the full flow
     */
    function test_onDisputeOpened_Integration() public {
        // Create escrow
        vm.startPrank(user1);
        token.approve(address(escrow), 1000 ether);
        uint256 workflowId = escrow.createEscrow(
            address(token),
            user2,
            1000 ether,
            EscrowSettings({
                customResolver: address(0),
                yieldPreset: YieldPreset.OFF,
                autoReleaseTime: 0,
                autoCancelTime: 0
            })
        );
        vm.stopPrank();

        // Raise dispute
        vm.prank(user1);
        escrow.raiseDispute(workflowId);

        // Verify onDisputeOpened was called by checking if escrow fee was recorded
        // Note: We can't directly verify the hook was called, but we can verify side effects
        // In a real scenario, the incentive module would record the fee

        // For V2, we can check if the dispute was tracked
        // Switch to V2
        vm.prank(timelock);
        resolutionModule.setIncentiveModule(address(incentiveModuleV2));

        // Create another escrow and dispute
        vm.startPrank(user1);
        token.approve(address(escrow), 1000 ether);
        uint256 workflowId2 = escrow.createEscrow(
            address(token),
            user2,
            1000 ether,
            EscrowSettings({
                customResolver: address(0),
                yieldPreset: YieldPreset.OFF,
                autoReleaseTime: 0,
                autoCancelTime: 0
            })
        );
        vm.stopPrank();

        // Raise dispute - should call onDisputeOpened
        vm.prank(user1);
        escrow.raiseDispute(workflowId2);

        // Verify dispute was opened (check resolution module state)
        (address currentResolver, uint8 currentRound) = resolutionModule.getDisputeResolver(
            workflowId2,
            abi.encode(
                address(token),
                user1,
                user2,
                1000 ether - ((1000 ether * escrow.escrowFee()) / escrow.ESCROW_FEE_DENOMINATOR())
            )
        );
        assertTrue(currentResolver != address(0), 'Resolver should be assigned');
        assertEq(currentRound, 0, 'Should be at round 0');
    }

    // ============ recordAppealBond Integration Tests ============

    /**
     * @notice Test that recordAppealBond is called during escalation
     * @dev Complex test that verifies bond recording in escalation flow
     */
    function test_recordAppealBond_Integration() public {
        // Switch to V2 for bond support
        vm.prank(timelock);
        resolutionModule.setIncentiveModule(address(incentiveModuleV2));

        // Configure escalation cost (bonds)
        DecentralizedResolverStructs.EscalationCostConfig
            memory costConfig = DecentralizedResolverStructs.EscalationCostConfig({
                enabled: true,
                curveType: DecentralizedResolverStructs.CostCurveType.QUADRATIC,
                baseCost: 0.01 ether,
                stepSize: 0.01 ether,
                multiplier: 0,
                bondToken: address(0) // ETH
            });
        vm.prank(timelock);
        resolutionModule.queueEscalationCostConfig(costConfig);

        vm.warp(block.timestamp + 7 days + 1); // Bypassing SLOW_DELAY
        vm.prank(timelock);
        resolutionModule.activateEscalationCostConfig();
        vm.warp(block.timestamp + 1); // Move beyond activation

        // Create escrow and raise dispute
        vm.startPrank(user1);
        token.approve(address(escrow), 1000 ether);
        uint256 workflowId = escrow.createEscrow(
            address(token),
            user2,
            1000 ether,
            EscrowSettings({
                customResolver: address(0),
                yieldPreset: YieldPreset.OFF,
                autoReleaseTime: 0,
                autoCancelTime: 0
            })
        );
        escrow.raiseDispute(workflowId);
        vm.stopPrank();

        // Get required bond amount
        (uint256 bondAmount, address bondToken) = resolutionModule.getRequiredAppealBond(
            workflowId,
            0,
            abi.encode(
                address(token),
                user1,
                user2,
                1000 ether - ((1000 ether * escrow.escrowFee()) / escrow.ESCROW_FEE_DENOMINATOR())
            )
        );
        assertTrue(bondAmount > 0, 'Bond amount should be > 0');

        // Escalate with bond payment
        vm.deal(user1, 10 ether);
        vm.prank(user1);
        escrow.escalateDispute{value: bondAmount}(workflowId);

        // Verify bond was recorded
        ResolverIncentiveModuleV2.AppealBondRecord memory bond = incentiveModuleV2.getAppealBond(
            workflowId,
            1
        );
        assertEq(bond.amount, bondAmount, 'Bond amount should match');
        assertEq(bond.depositor, user1, 'Depositor should be user1');
        assertEq(bond.token, bondToken, 'Token should match');
        assertFalse(bond.distributed, 'Bond should not be distributed yet');
    }

    /**
     * @notice Test that bond cannot be recorded twice
     */
    function test_recordAppealBond_PreventDuplicate() public {
        // Switch to V2
        vm.prank(timelock);
        resolutionModule.setIncentiveModule(address(incentiveModuleV2));

        // Setup escalation config
        DecentralizedResolverStructs.EscalationCostConfig
            memory costConfig = DecentralizedResolverStructs.EscalationCostConfig({
                enabled: true,
                curveType: DecentralizedResolverStructs.CostCurveType.QUADRATIC,
                baseCost: 0.01 ether,
                stepSize: 0.01 ether,
                multiplier: 0,
                bondToken: address(0)
            });
        vm.prank(timelock);
        resolutionModule.queueEscalationCostConfig(costConfig);

        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(timelock);
        resolutionModule.activateEscalationCostConfig();
        vm.warp(block.timestamp + 1);

        // Create escrow and dispute
        vm.startPrank(user1);
        token.approve(address(escrow), 1000 ether);
        uint256 workflowId = escrow.createEscrow(
            address(token),
            user2,
            1000 ether,
            EscrowSettings({
                customResolver: address(0),
                yieldPreset: YieldPreset.OFF,
                autoReleaseTime: 0,
                autoCancelTime: 0
            })
        );
        escrow.raiseDispute(workflowId);
        vm.stopPrank();

        // Record bond first time - send ETH with call
        vm.deal(address(escrow), 0.01 ether);
        vm.prank(address(escrow));
        incentiveModuleV2.recordAppealBond{value: 0.01 ether}(
            workflowId,
            user1,
            user1,
            0.01 ether,
            address(0),
            1
        );

        // Try to record again - should fail
        vm.deal(address(escrow), 0.01 ether);
        vm.prank(address(escrow));
        vm.expectRevert('Bond already exists');
        incentiveModuleV2.recordAppealBond{value: 0.01 ether}(
            workflowId,
            user1,
            user1,
            0.01 ether,
            address(0),
            1
        );
    }

    // ============ distributeAppealBond Integration Tests ============

    /**
     * @notice Test bond distribution when appeal succeeds (reversal)
     * @dev Complex test verifying bond refund on successful appeal
     */
    function test_distributeAppealBond_AppealSucceeds() public {
        // Switch to V2
        vm.prank(timelock);
        resolutionModule.setIncentiveModule(address(incentiveModuleV2));

        // Configure escalation cost
        DecentralizedResolverStructs.EscalationCostConfig
            memory costConfig = DecentralizedResolverStructs.EscalationCostConfig({
                enabled: true,
                curveType: DecentralizedResolverStructs.CostCurveType.QUADRATIC,
                baseCost: 0.01 ether,
                stepSize: 0.01 ether,
                multiplier: 0,
                bondToken: address(0)
            });
        vm.prank(timelock);
        resolutionModule.queueEscalationCostConfig(costConfig);
        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(timelock);
        resolutionModule.activateEscalationCostConfig();
        vm.warp(block.timestamp + 1);

        // Create escrow and dispute
        vm.startPrank(user1);
        token.approve(address(escrow), 1000 ether);
        uint256 workflowId = escrow.createEscrow(
            address(token),
            user2,
            1000 ether,
            EscrowSettings({
                customResolver: address(0),
                yieldPreset: YieldPreset.OFF,
                autoReleaseTime: 0,
                autoCancelTime: 0
            })
        );
        escrow.raiseDispute(workflowId);
        vm.stopPrank();

        // Record bond for round 1 - send ETH with call
        vm.deal(address(escrow), 0.01 ether);
        vm.prank(address(escrow));
        incentiveModuleV2.recordAppealBond{value: 0.01 ether}(
            workflowId,
            user1,
            user1,
            0.01 ether,
            address(0),
            1
        );

        // Simulate decision at round 0 (CANCEL)
        vm.prank(address(escrow));
        resolutionModule.recordResolution(
            workflowId,
            resolver1,
            DecentralizedResolverStructs.ResolutionOutcome.CANCEL,
            1 days
        );

        // Escalate to round 1 (requires 0.01 ether bond)
        vm.deal(user1, 1 ether);
        vm.prank(user1);
        escrow.escalateDispute{value: 0.01 ether}(workflowId);

        // Simulate decision at round 1 (RELEASE) - reversal!
        vm.prank(address(escrow));
        resolutionModule.recordResolution(
            workflowId,
            seniorResolver,
            DecentralizedResolverStructs.ResolutionOutcome.RELEASE,
            1 days
        );

        // Record reversal - should trigger bond distribution
        uint256 balanceBefore = user1.balance;
        vm.prank(address(escrow));
        resolutionModule.recordReversal(workflowId, 0);

        // Verify bond was refunded (outcomeFlipped = true)
        ResolverIncentiveModuleV2.AppealBondRecord memory bond = incentiveModuleV2.getAppealBond(
            workflowId,
            1
        );
        assertTrue(bond.distributed, 'Bond should be distributed');
        assertTrue(bond.refunded, 'Bond should be refunded');

        // Note: In actual implementation, refund happens via transfer
        // This test verifies the state change
    }

    /**
     * @notice Test bond distribution when appeal fails (decision upheld)
     * @dev Complex test verifying bond payment to resolvers
     */
    function test_distributeAppealBond_AppealFails() public {
        // Switch to V2
        vm.prank(timelock);
        resolutionModule.setIncentiveModule(address(incentiveModuleV2));

        // Configure escalation cost
        DecentralizedResolverStructs.EscalationCostConfig
            memory costConfig = DecentralizedResolverStructs.EscalationCostConfig({
                enabled: true,
                curveType: DecentralizedResolverStructs.CostCurveType.QUADRATIC,
                baseCost: 0.01 ether,
                stepSize: 0.01 ether,
                multiplier: 0,
                bondToken: address(0)
            });
        vm.prank(timelock);
        resolutionModule.queueEscalationCostConfig(costConfig);
        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(timelock);
        resolutionModule.activateEscalationCostConfig();
        vm.warp(block.timestamp + 1);

        // Create escrow and dispute
        vm.startPrank(user1);
        token.approve(address(escrow), 1000 ether);
        uint256 workflowId = escrow.createEscrow(
            address(token),
            user2,
            1000 ether,
            EscrowSettings({
                customResolver: address(0),
                yieldPreset: YieldPreset.OFF,
                autoReleaseTime: 0,
                autoCancelTime: 0
            })
        );
        escrow.raiseDispute(workflowId);
        vm.stopPrank();

        // Record resolver at round 0
        vm.prank(address(escrow));
        incentiveModuleV2.recordResolver(workflowId, resolver1, 0);

        // Record bond for round 1 - send ETH with call
        vm.deal(address(escrow), 0.01 ether);
        vm.prank(address(escrow));
        incentiveModuleV2.recordAppealBond{value: 0.01 ether}(
            workflowId,
            user1,
            user1,
            0.01 ether,
            address(0),
            1
        );

        // Simulate decision at round 0 (CANCEL)
        vm.prank(address(escrow));
        resolutionModule.recordResolution(
            workflowId,
            resolver1,
            DecentralizedResolverStructs.ResolutionOutcome.CANCEL,
            1 days
        );

        // Escalate to round 1 with bond payment
        vm.deal(user1, 1 ether);
        vm.prank(user1);
        escrow.escalateDispute{value: 0.01 ether}(workflowId);

        // Simulate decision at round 1 (CANCEL) - same as round 0, appeal failed
        vm.prank(address(escrow));
        resolutionModule.recordResolution(
            workflowId,
            seniorResolver,
            DecentralizedResolverStructs.ResolutionOutcome.CANCEL,
            1 days
        );

        // Distribute bond directly (appeal failed)
        vm.prank(address(escrow));
        incentiveModuleV2.distributeAppealBond(workflowId, 0, false);

        // Verify bond was paid to resolvers (not refunded)
        ResolverIncentiveModuleV2.AppealBondRecord memory bond = incentiveModuleV2.getAppealBond(
            workflowId,
            1
        );
        assertTrue(bond.distributed, 'Bond should be distributed');
        assertFalse(bond.refunded, 'Bond should not be refunded');

        // Verify resolver can claim payment
        uint256 claimable = incentiveModuleV2.getClaimablePayment(workflowId, resolver1);
        assertTrue(claimable > 0, 'Resolver should have claimable payment from bond');
    }

    // ============ Rounding Error Fix Tests ============

    /**
     * @notice Test that rounding error is handled correctly in bond distribution
     * @dev Tests the fix for remainder distribution
     */
    function test_BondDistribution_RoundingError() public {
        // Switch to V2
        vm.prank(timelock);
        resolutionModule.setIncentiveModule(address(incentiveModuleV2));

        // Configure escalation cost with small amounts for testing
        DecentralizedResolverStructs.EscalationCostConfig
            memory costConfig = DecentralizedResolverStructs.EscalationCostConfig({
                enabled: true,
                curveType: DecentralizedResolverStructs.CostCurveType.QUADRATIC,
                baseCost: 100 wei,
                stepSize: 0 wei,
                multiplier: 0,
                bondToken: address(0)
            });
        vm.prank(timelock);
        resolutionModule.queueEscalationCostConfig(costConfig);
        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(timelock);
        resolutionModule.activateEscalationCostConfig();
        vm.warp(block.timestamp + 1);

        // Create escrow and dispute
        vm.startPrank(user1);
        token.approve(address(escrow), 1000 ether);
        uint256 workflowId = escrow.createEscrow(
            address(token),
            user2,
            1000 ether,
            EscrowSettings({
                customResolver: address(0),
                yieldPreset: YieldPreset.OFF,
                autoReleaseTime: 0,
                autoCancelTime: 0
            })
        );
        escrow.raiseDispute(workflowId);
        vm.stopPrank();

        // Record 3 resolvers at round 0
        vm.prank(address(escrow));
        incentiveModuleV2.recordResolver(workflowId, resolver1, 0);
        vm.prank(address(escrow));
        incentiveModuleV2.recordResolver(workflowId, resolver2, 0);
        address resolver3 = makeAddr('resolver3');
        vm.prank(address(escrow));
        incentiveModuleV2.recordResolver(workflowId, resolver3, 0);

        // Record bond that doesn't divide evenly: 100 wei / 3 = 33 remainder 1
        // Send ETH with call
        vm.deal(address(escrow), 100);
        vm.prank(address(escrow));
        incentiveModuleV2.recordAppealBond{value: 100}(workflowId, user1, user1, 100, address(0), 1);

        // Simulate decision and escalation
        vm.prank(address(escrow));
        resolutionModule.recordResolution(
            workflowId,
            resolver1,
            DecentralizedResolverStructs.ResolutionOutcome.CANCEL,
            1 days
        );
        vm.deal(user1, 100);
        vm.prank(user1);
        escrow.escalateDispute{value: 100}(workflowId);
        vm.prank(address(escrow));
        resolutionModule.recordResolution(
            workflowId,
            seniorResolver,
            DecentralizedResolverStructs.ResolutionOutcome.CANCEL,
            1 days
        );

        // Distribute bond (appeal failed)
        vm.prank(address(escrow));
        incentiveModuleV2.distributeAppealBond(workflowId, 0, false);

        // Verify all 100 wei is distributed (no remainder lost)
        uint256 totalClaimable = incentiveModuleV2.getClaimablePayment(workflowId, resolver1) +
            incentiveModuleV2.getClaimablePayment(workflowId, resolver2) +
            incentiveModuleV2.getClaimablePayment(workflowId, resolver3);
        assertEq(totalClaimable, 100, 'Total claimable should equal bond amount');

        // Verify remainder distributed to first resolver(s)
        uint256 claimable1 = incentiveModuleV2.getClaimablePayment(workflowId, resolver1);
        uint256 claimable2 = incentiveModuleV2.getClaimablePayment(workflowId, resolver2);
        uint256 claimable3 = incentiveModuleV2.getClaimablePayment(workflowId, resolver3);

        // One resolver should get 34, others get 33 (or similar distribution)
        assertTrue(claimable1 >= 33 && claimable1 <= 34, 'Resolver1 should get 33-34');
        assertTrue(claimable2 >= 33 && claimable2 <= 34, 'Resolver2 should get 33-34');
        assertTrue(claimable3 >= 33 && claimable3 <= 34, 'Resolver3 should get 33-34');
    }

    // ============ distributePayments Interface Tests ============

    /**
     * @notice Test that distributePayments interface method works
     */
    function test_distributePayments_InterfaceMethod() public {
        // Create escrow and dispute
        vm.startPrank(user1);
        token.approve(address(escrow), 1000 ether);
        uint256 workflowId = escrow.createEscrow(
            address(token),
            user2,
            1000 ether,
            EscrowSettings({
                customResolver: address(0),
                yieldPreset: YieldPreset.OFF,
                autoReleaseTime: 0,
                autoCancelTime: 0
            })
        );
        escrow.raiseDispute(workflowId);
        vm.stopPrank();

        // Record resolver and fees
        vm.prank(address(escrow));
        incentiveModuleV1.recordResolver(workflowId, resolver1, 0);
        vm.prank(address(escrow));
        incentiveModuleV1.recordEscrowFee(workflowId, address(token), 50 ether);

        // Transfer tokens to incentive module
        token.mint(address(incentiveModuleV1), 100 ether);

        // Call distributePayments via interface
        vm.prank(address(escrow));
        incentiveModuleV1.distributePayments(workflowId, address(token), 50 ether);

        // Verify payments were calculated
        assertTrue(
            incentiveModuleV1.arePaymentsCalculated(workflowId),
            'Payments should be calculated'
        );

        // Verify resolver can claim
        uint256 claimable = incentiveModuleV1.getClaimablePayment(workflowId, resolver1);
        assertTrue(claimable > 0, 'Resolver should have claimable payment');
    }
}
