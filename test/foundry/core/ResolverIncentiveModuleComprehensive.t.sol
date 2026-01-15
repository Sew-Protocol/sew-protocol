// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import 'forge-std/Test.sol';
import '../../../contracts/decentralized-resolution-module/ResolverIncentiveModuleV1.sol';
import '../../../contracts/decentralized-resolution-module/PaymentCalculationLibraryV1.sol';
import '../../../contracts/mocks/ERC20Mock.sol';

contract ResolverIncentiveModuleComprehensiveTest is Test {
    ResolverIncentiveModuleV1 public incentiveModule;
    PaymentCalculationLibraryV1 public paymentLib;
    ERC20Mock public token;

    address public owner;
    address public timelock;
    address public escrow;
    address public resolver;
    address public otherAccount;

    bytes32 public constant ROLE_TIMELOCK = keccak256('ROLE_TIMELOCK');
    bytes32 public constant ROLE_ESCROW_CONTRACT = keccak256('ROLE_ESCROW_CONTRACT');

    event ResolverRecorded(
        uint256 indexed workflowId,
        address indexed resolver,
        uint8 level,
        uint256 timestamp
    );
    event EscrowFeeRecorded(uint256 indexed workflowId, address indexed token, uint256 amount);
    event EscalationFeeRecorded(uint256 indexed workflowId, address indexed token, uint256 amount);
    event PaymentsDistributed(
        uint256 indexed workflowId,
        address indexed token,
        uint256 totalResolverShare,
        address[] resolvers,
        uint256[] payments
    );

    function setUp() public {
        owner = address(this);
        timelock = makeAddr('timelock');
        escrow = makeAddr('escrow');
        resolver = makeAddr('resolver');
        otherAccount = makeAddr('other');

        // Deploy Payment Library
        paymentLib = new PaymentCalculationLibraryV1();

        // Deploy ResolverIncentiveModuleV1 directly (immutable pattern)
        incentiveModule = new ResolverIncentiveModuleV1(owner, address(paymentLib));

        // Setup Roles
        incentiveModule.grantRole(ROLE_TIMELOCK, timelock);
        incentiveModule.grantRole(ROLE_TIMELOCK, address(this));
        incentiveModule.registerEscrowContract(escrow);

        // Deploy Mock Token
        token = new ERC20Mock('Test Token', 'TEST', owner, 1000000 ether);
    }

    // ============ Resolver Recording Tests ============

    function test_RecordResolver() public {
        vm.prank(escrow);

        vm.expectEmit(true, true, false, true);
        emit ResolverRecorded(1, resolver, 0, block.timestamp);

        incentiveModule.recordResolver(1, resolver, 0);

        ResolverRecord[] memory resolvers = incentiveModule.getDisputeResolvers(1);
        assertEq(resolvers.length, 1);
        assertEq(resolvers[0].resolver, resolver);
        assertEq(resolvers[0].level, 0);
        assertEq(resolvers[0].timestamp, block.timestamp);
    }

    function test_RecordResolver_Duplicate() public {
        vm.startPrank(escrow);
        incentiveModule.recordResolver(1, resolver, 0);

        // Should not record again
        incentiveModule.recordResolver(1, resolver, 0);
        vm.stopPrank();

        ResolverRecord[] memory resolvers = incentiveModule.getDisputeResolvers(1);
        assertEq(resolvers.length, 1);
    }

    function test_RecordResolver_MultipleLevels() public {
        vm.startPrank(escrow);
        incentiveModule.recordResolver(1, resolver, 0);
        incentiveModule.recordResolver(1, resolver, 1);
        vm.stopPrank();

        ResolverRecord[] memory resolvers = incentiveModule.getDisputeResolvers(1);
        assertEq(resolvers.length, 2);
    }

    function test_RecordResolver_RevertZeroAddress() public {
        vm.prank(escrow);
        vm.expectRevert('Zero resolver');
        incentiveModule.recordResolver(1, address(0), 0);
    }

    function test_RecordResolver_RevertInvalidLevel() public {
        vm.prank(escrow);
        vm.expectRevert('Invalid level');
        incentiveModule.recordResolver(1, resolver, 3);
    }

    function test_RecordResolver_RevertUnauthorized() public {
        vm.prank(otherAccount);
        vm.expectRevert('Not registered escrow contract');
        incentiveModule.recordResolver(1, resolver, 0);
    }

    // ============ Fee Recording Tests ============

    function test_RecordEscrowFee() public {
        uint256 fee = 100 ether;
        vm.prank(escrow);

        vm.expectEmit(true, true, false, true);
        emit EscrowFeeRecorded(1, address(token), fee);

        incentiveModule.recordEscrowFee(1, address(token), fee);

        (uint256 recordedFee, ) = incentiveModule.getDisputeFees(1);
        assertEq(recordedFee, fee);
    }

    function test_RecordEscalationFee() public {
        // Must record a resolver first to initialize dispute
        vm.prank(escrow);
        incentiveModule.recordResolver(1, resolver, 0);

        uint256 fee = 50 ether;
        vm.prank(escrow);

        vm.expectEmit(true, true, false, true);
        emit EscalationFeeRecorded(1, address(token), fee);

        incentiveModule.recordEscalationFee(1, address(token), fee);

        (, uint256 recordedEscalation) = incentiveModule.getDisputeFees(1);
        assertEq(recordedEscalation, fee);
    }

    function test_RecordEscalationFee_Accumulate() public {
        vm.startPrank(escrow);
        incentiveModule.recordResolver(1, resolver, 0);
        incentiveModule.recordEscalationFee(1, address(token), 50 ether);
        incentiveModule.recordEscalationFee(1, address(token), 25 ether);
        vm.stopPrank();

        (, uint256 recordedEscalation) = incentiveModule.getDisputeFees(1);
        assertEq(recordedEscalation, 75 ether);
    }

    function test_RecordEscalationFee_RevertNoDispute() public {
        vm.prank(escrow);
        vm.expectRevert('Dispute not initialized');
        incentiveModule.recordEscalationFee(1, address(token), 50 ether);
    }

    // ============ Governance Tests ============

    function test_SharePercentage_Governance() public {
        uint256 newShare = 6000;

        vm.startPrank(timelock);
        incentiveModule.queueResolverSharePercentage(newShare);

        // Fast forward
        vm.warp(block.timestamp + 7 days + 1);

        incentiveModule.activateResolverSharePercentage();
        vm.stopPrank();

        assertEq(incentiveModule.resolverSharePercentage(), newShare);
    }

    function test_PaymentLibrary_Update() public {
        PaymentCalculationLibraryV1 newLib = new PaymentCalculationLibraryV1();

        vm.startPrank(timelock);
        incentiveModule.queuePaymentCalculationLibrary(address(newLib));

        vm.warp(block.timestamp + 7 days + 1);

        incentiveModule.activatePaymentCalculationLibrary();
        vm.stopPrank();

        assertEq(incentiveModule.currentPaymentLibrary(), address(newLib));
    }

    // ============ Distribution Tests ============

    function test_DistributePayments() public {
        // Setup Dispute
        vm.startPrank(escrow);
        incentiveModule.recordResolver(1, resolver, 0);
        incentiveModule.recordEscrowFee(1, address(token), 1000 ether);
        vm.stopPrank();

        // Fund Incentive Module
        token.mint(address(incentiveModule), 10000 ether);

        // Calculate payments (pull pattern)
        vm.prank(escrow);
        incentiveModule.onDisputeResolved(1, address(token));

        assertTrue(incentiveModule.arePaymentsDistributed(1));

        // Claim payment (pull pattern - resolver claims their payment)
        vm.prank(resolver);
        incentiveModule.claimPayment(1, address(token));

        // Verify resolver received funds
        // Default share is 50% (5000 bps)
        // Total fees = 1000 ether
        // Resolver share = 500 ether
        // Only 1 resolver, so they get 500 ether
        assertEq(token.balanceOf(resolver), 500 ether);
    }

    function test_DistributePayments_MultipleResolvers() public {
        address resolver2 = makeAddr('resolver2');

        // Setup Dispute
        vm.startPrank(escrow);
        incentiveModule.recordResolver(1, resolver, 0); // Level 0 (1x)
        incentiveModule.recordResolver(1, resolver2, 1); // Level 1 (1.5x)
        incentiveModule.recordEscrowFee(1, address(token), 1000 ether);
        vm.stopPrank();

        token.mint(address(incentiveModule), 10000 ether);

        // Calculate payments (pull pattern)
        vm.prank(escrow);
        incentiveModule.onDisputeResolved(1, address(token));

        // Claim payments (pull pattern - resolvers claim their payments)
        vm.prank(resolver);
        incentiveModule.claimPayment(1, address(token));

        vm.prank(resolver2);
        incentiveModule.claimPayment(1, address(token));

        // Total Share: 500 ether
        // Weights: 10000 (1x) + 15000 (1.5x) = 25000
        // R1: 500 * (10000/25000) = 200 ether
        // R2: 500 * (15000/25000) = 300 ether

        assertEq(token.balanceOf(resolver), 200 ether);
        assertEq(token.balanceOf(resolver2), 300 ether);
    }

    function test_DistributePayments_RevertAlreadyDistributed() public {
        vm.startPrank(escrow);
        incentiveModule.recordResolver(1, resolver, 0);
        incentiveModule.recordEscrowFee(1, address(token), 1000 ether);
        vm.stopPrank();

        token.mint(address(incentiveModule), 10000 ether);

        // Calculate payments (pull pattern)
        vm.prank(escrow);
        incentiveModule.onDisputeResolved(1, address(token));

        // Try to calculate again - should revert
        vm.prank(escrow);
        vm.expectRevert('Payments already calculated');
        incentiveModule.onDisputeResolved(1, address(token));
    }
}
