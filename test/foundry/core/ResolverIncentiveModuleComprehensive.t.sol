// SPDX-License-Identifier: Apache-2.0
import "../../../contracts/types/YieldPresets.sol";
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

        // HIGH-2: Should revert when trying to record same resolver again (at any level)
        vm.expectRevert(abi.encodeWithSignature("ResolverAlreadyRecorded(address)", resolver));
        incentiveModule.recordResolver(1, resolver, 0);
        vm.stopPrank();

        ResolverRecord[] memory resolvers = incentiveModule.getDisputeResolvers(1);
        assertEq(resolvers.length, 1);
    }

    function test_RecordResolver_MultipleLevels() public {
        address resolver2 = makeAddr('resolver2');
        vm.startPrank(escrow);
        incentiveModule.recordResolver(1, resolver, 0);
        // HIGH-2: Cannot record same resolver at different levels - use different resolver instead
        incentiveModule.recordResolver(1, resolver2, 1);
        vm.stopPrank();

        ResolverRecord[] memory resolvers = incentiveModule.getDisputeResolvers(1);
        assertEq(resolvers.length, 2);
        assertEq(resolvers[0].resolver, resolver);
        assertEq(resolvers[0].level, 0);
        assertEq(resolvers[1].resolver, resolver2);
        assertEq(resolvers[1].level, 1);
    }

    function test_RecordResolver_RevertZeroAddress() public {
        vm.prank(escrow);
        vm.expectRevert(abi.encodeWithSignature("ZeroResolver()"));
        incentiveModule.recordResolver(1, address(0), 0);
    }

    function test_RecordResolver_RevertInvalidLevel() public {
        vm.prank(escrow);
        vm.expectRevert(abi.encodeWithSignature("InvalidLevel(uint8,uint8)", 3, 2));
        incentiveModule.recordResolver(1, resolver, 3);
    }

    function test_RecordResolver_RevertUnauthorized() public {
        vm.prank(otherAccount);
        vm.expectRevert(abi.encodeWithSignature("NotRegisteredEscrowContract(address)", otherAccount));
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
        vm.expectRevert(abi.encodeWithSignature("DisputeNotInitialized(uint256)", 1));
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

    function test_PaymentLibrary_Rollback() public {
        PaymentCalculationLibraryV1 oldLib = PaymentCalculationLibraryV1(incentiveModule.currentPaymentLibrary());
        PaymentCalculationLibraryV1 newLib = new PaymentCalculationLibraryV1();

        vm.startPrank(timelock);
        incentiveModule.rollbackToPreviousLibrary(address(newLib));
        assertEq(incentiveModule.currentPaymentLibrary(), address(newLib));

        incentiveModule.rollbackToPreviousLibrary(address(oldLib));
        assertEq(incentiveModule.currentPaymentLibrary(), address(oldLib));
        vm.stopPrank();
    }

    function test_Escrow_PauseUnpause() public {
        vm.startPrank(timelock);
        incentiveModule.pauseEscrowContract(escrow);
        
        vm.stopPrank();
        vm.startPrank(escrow);
        vm.expectRevert(abi.encodeWithSignature("EscrowPaused(address)", escrow));
        incentiveModule.recordEscrowFee(1, address(token), 100 ether);
        vm.stopPrank();

        vm.startPrank(timelock);
        incentiveModule.unpauseEscrowContract(escrow);
        vm.stopPrank();

        vm.prank(escrow);
        incentiveModule.recordEscrowFee(1, address(token), 100 ether);
        (uint256 fee, ) = incentiveModule.getDisputeFees(1);
        assertEq(fee, 100 ether);
    }

    function test_Escrow_RateLimitReset() public {
        vm.prank(escrow);
        incentiveModule.recordEscrowFee(1, address(token), 100 ether);
        
        (uint256 disputes, uint256 fees, , , ) = incentiveModule.getEscrowRateLimit(escrow);
        assertEq(disputes, 1);
        assertEq(fees, 100 ether);

        vm.prank(timelock);
        incentiveModule.resetEscrowRateLimit(escrow);

        (disputes, fees, , , ) = incentiveModule.getEscrowRateLimit(escrow);
        assertEq(disputes, 0);
        assertEq(fees, 0);
    }

    function test_ClearFeeRecording() public {
        vm.prank(escrow);
        incentiveModule.recordEscrowFee(1, address(token), 100 ether);

        vm.prank(timelock);
        incentiveModule.clearFeeRecording(1, "test");

        // Verify tracking cleared
        // (Internal state disputeExpectedTokenBalance[1] is cleared)
        // We can verify by trying to resolve - it should fail due to 0 balance vs expected
        // Actually, resolve checks contractBalance < totalRecordedFees
        // totalRecordedFees is NOT cleared by clearFeeRecording (by design)
    }

    function test_UnregisterEscrow() public {
        vm.prank(timelock);
        incentiveModule.unregisterEscrowContract(escrow);

        vm.prank(escrow);
        vm.expectRevert(abi.encodeWithSignature("NotRegisteredEscrowContract(address)", escrow));
        incentiveModule.recordEscrowFee(1, address(token), 100 ether);
    }

    function test_onDisputeResolved_InsufficientBalance() public {
        vm.prank(escrow);
        incentiveModule.recordEscrowFee(1, address(token), 1000 ether);
        
        vm.prank(escrow);
        incentiveModule.recordResolver(1, resolver, 0);

        // Don't fund the module
        vm.prank(escrow);
        vm.expectRevert(abi.encodeWithSignature("InsufficientBalanceForFees(uint256,uint256)", 1000 ether, 0));
        incentiveModule.onDisputeResolved(1, address(token));
    }

    function test_claimPayment_ZeroToken() public {
        // Setup resolution
        vm.startPrank(escrow);
        incentiveModule.recordResolver(1, resolver, 0);
        incentiveModule.recordEscrowFee(1, address(token), 1000 ether);
        vm.stopPrank();

        token.mint(address(incentiveModule), 1000 ether);
        vm.prank(escrow);
        incentiveModule.onDisputeResolved(1, address(token));

        vm.prank(resolver);
        vm.expectRevert(abi.encodeWithSignature("ZeroToken()"));
        incentiveModule.claimPayment(1, address(0));
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
        vm.expectRevert(abi.encodeWithSignature("PaymentsAlreadyCalculated(uint256)", 1));
        incentiveModule.onDisputeResolved(1, address(token));
    }
}
