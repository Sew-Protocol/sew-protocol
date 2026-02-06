// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import 'forge-std/Test.sol';
import '../../../contracts/modules/decentralized-resolution-module/ResolverIncentiveModuleV1.sol';
import '../../../contracts/modules/decentralized-resolution-module/PaymentCalculationLibraryV1.sol';
import '../../../contracts/modules/decentralized-resolution-module/IPaymentCalculationLibrary.sol';
import '../../../contracts/mocks/ERC20Mock.sol';
import '../../../contracts/types/EscrowTypes.sol';

contract PaymentBoundsCheckingTest is Test {
    ResolverIncentiveModuleV1 public incentiveModule;
    PaymentCalculationLibraryV1 public paymentLib;
    ERC20Mock public token;

    address public owner;
    address public timelock;
    address public escrow;
    address public resolver1;
    address public resolver2;
    address public resolver3;

    bytes32 public constant ROLE_TIMELOCK = keccak256('ROLE_TIMELOCK');
    uint256 public constant BASIS_POINTS_DENOMINATOR = 10000;

    function setUp() public {
        owner = address(this);
        timelock = makeAddr('timelock');
        escrow = makeAddr('escrow');
        resolver1 = makeAddr('resolver1');
        resolver2 = makeAddr('resolver2');
        resolver3 = makeAddr('resolver3');

        // Deploy token
        token = new ERC20Mock('Test Token', 'TEST', address(this), 0);

        // Deploy Payment Library
        paymentLib = new PaymentCalculationLibraryV1();

        // Deploy ResolverIncentiveModuleV1 directly (immutable pattern)
        incentiveModule = new ResolverIncentiveModuleV1(owner, address(paymentLib));

        // Grant roles
        incentiveModule.grantRole(ROLE_TIMELOCK, address(this));
        incentiveModule.grantRole(ROLE_TIMELOCK, timelock);
        incentiveModule.registerEscrowContract(escrow);
    }

    function test_ValidPaymentCalculation() public {
        uint256 workflowId = 1;
        uint256 escrowFee = 1000 ether;
        uint256 escalationFees = 500 ether;

        // Record resolvers
        vm.prank(escrow);
        incentiveModule.recordResolver(workflowId, escrow, resolver1, 0);
        vm.prank(escrow);
        incentiveModule.recordResolver(workflowId, escrow, resolver2, 1);

        // Record fees
        vm.prank(escrow);
        incentiveModule.recordEscrowFee(workflowId, escrow, address(token), escrowFee);
        vm.prank(escrow);
        incentiveModule.recordEscalationFee(workflowId, escrow, address(token), escalationFees);

        // Transfer tokens to incentive module
        token.mint(address(incentiveModule), escrowFee + escalationFees);

        // Calculate payments - should succeed
        vm.prank(escrow);
        incentiveModule.onDisputeResolved(workflowId, escrow, address(token));

        // Verify payments were calculated
        assertTrue(incentiveModule.arePaymentsCalculated(workflowId, escrow));
        assertTrue(incentiveModule.getClaimablePayment(workflowId, escrow, resolver1) > 0);
        assertTrue(incentiveModule.getClaimablePayment(workflowId, escrow, resolver2) > 0);
    }

    function test_RejectsPaymentExceedingTotalFees() public {
        uint256 workflowId = 2;

        // Record resolvers
        vm.prank(escrow);
        incentiveModule.recordResolver(workflowId, escrow, resolver1, 0);

        // Record fees
        vm.prank(escrow);
        incentiveModule.recordEscrowFee(workflowId, escrow, address(token), 1000 ether);
        vm.prank(escrow);
        incentiveModule.recordEscalationFee(workflowId, escrow, address(token), 500 ether);

        // Transfer tokens
        token.mint(address(incentiveModule), 1500 ether);

        // Create malicious library that returns excessive payment
        MaliciousPaymentLibrary maliciousLib = new MaliciousPaymentLibrary();

        // Queue and activate malicious library
        vm.prank(timelock);
        incentiveModule.queuePaymentCalculationLibrary(address(maliciousLib));
        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(timelock);
        incentiveModule.activatePaymentCalculationLibrary();

        // Should revert because payment exceeds total fees
        vm.prank(escrow);
        vm.expectRevert(abi.encodeWithSignature("ResolverShareExceedsTotalFees(uint256,uint256)", 3000 ether, 1500 ether));
        incentiveModule.onDisputeResolved(workflowId, escrow, address(token));
    }

    function test_RejectsPaymentSumMismatch() public {
        uint256 workflowId = 3;

        // Record resolvers
        vm.prank(escrow);
        incentiveModule.recordResolver(workflowId, escrow, resolver1, 0);
        vm.prank(escrow);
        incentiveModule.recordResolver(workflowId, escrow, resolver2, 1);

        // Record fees
        vm.prank(escrow);
        incentiveModule.recordEscrowFee(workflowId, escrow, address(token), 1000 ether);

        token.mint(address(incentiveModule), 1000 ether);

        // Create library that returns mismatched sum
        MismatchedSumLibrary mismatchedLib = new MismatchedSumLibrary();

        vm.prank(timelock);
        incentiveModule.queuePaymentCalculationLibrary(address(mismatchedLib));
        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(timelock);
        incentiveModule.activatePaymentCalculationLibrary();

        // Should revert because sum doesn't match total
        vm.prank(escrow);
        vm.expectRevert(abi.encodeWithSignature("PaymentSumMismatch(uint256,uint256)", 500 ether, 500 ether + 1));
        incentiveModule.onDisputeResolved(workflowId, escrow, address(token));
    }

    function test_RejectsZeroResolverAddress() public {
        uint256 workflowId = 4;
        ZeroAddressLibrary zeroLib = new ZeroAddressLibrary();

        vm.prank(timelock);
        incentiveModule.queuePaymentCalculationLibrary(address(zeroLib));
        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(timelock);
        incentiveModule.activatePaymentCalculationLibrary();

        vm.prank(escrow);
        incentiveModule.recordResolver(workflowId, escrow, resolver1, 0);
        vm.prank(escrow);
        incentiveModule.recordEscrowFee(workflowId, escrow, address(token), 1000 ether);
        token.mint(address(incentiveModule), 1000 ether);

        vm.prank(escrow);
        vm.expectRevert(abi.encodeWithSignature("ZeroResolverAddress(uint256)", 0));
        incentiveModule.onDisputeResolved(workflowId, escrow, address(token));
    }

    function test_RejectsPaymentExceedingMaximumSinglePayment() public {
        uint256 workflowId = 5;

        // Record resolvers
        vm.prank(escrow);
        incentiveModule.recordResolver(workflowId, escrow, resolver1, 0);
        vm.prank(escrow);
        incentiveModule.recordResolver(workflowId, escrow, resolver2, 1);

        vm.prank(escrow);
        incentiveModule.recordEscrowFee(workflowId, escrow, address(token), 1000 ether);
        token.mint(address(incentiveModule), 1000 ether);

        // Create library that gives one resolver >90% of total
        ExcessiveSinglePaymentLibrary excessiveLib = new ExcessiveSinglePaymentLibrary();

        vm.prank(timelock);
        incentiveModule.queuePaymentCalculationLibrary(address(excessiveLib));
        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(timelock);
        incentiveModule.activatePaymentCalculationLibrary();

        vm.prank(escrow);
        vm.expectRevert(abi.encodeWithSignature("PaymentExceedsMaximumAllowed(uint256,uint256)", 475 ether, 450 ether));
        incentiveModule.onDisputeResolved(workflowId, escrow, address(token));
    }

    function test_RejectsArrayLengthMismatch() public {
        uint256 workflowId = 6;

        vm.prank(escrow);
        incentiveModule.recordResolver(workflowId, escrow, resolver1, 0);
        vm.prank(escrow);
        incentiveModule.recordEscrowFee(workflowId, escrow, address(token), 1000 ether);
        token.mint(address(incentiveModule), 1000 ether);

        ArrayMismatchLibrary arrayLib = new ArrayMismatchLibrary();

        vm.prank(timelock);
        incentiveModule.queuePaymentCalculationLibrary(address(arrayLib));
        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(timelock);
        incentiveModule.activatePaymentCalculationLibrary();

        // ArrayMismatchLibrary returns resolvers.length=1, payments.length=2
        vm.prank(escrow);
        vm.expectRevert(abi.encodeWithSelector(ArrayLengthMismatch.selector, 1, 2));
        incentiveModule.onDisputeResolved(workflowId, escrow, address(token));
    }
}

// ============ Malicious Test Libraries ============

uint256 constant BASIS_POINTS = 10000;

contract MaliciousPaymentLibrary is IPaymentCalculationLibrary {
    function calculatePayments(
        PaymentInput memory input
    ) external pure override returns (PaymentOutput memory) {
        uint256[] memory payments = new uint256[](input.resolvers.length);
        address[] memory resolvers = new address[](input.resolvers.length);

        for (uint256 i = 0; i < input.resolvers.length; i++) {
            resolvers[i] = input.resolvers[i].resolver;
            payments[i] = (input.escrowFee + input.escalationFees) * 2;
        }

        return
            PaymentOutput({
                totalResolverShare: (input.escrowFee + input.escalationFees) * 2,
                resolvers: resolvers,
                payments: payments
            });
    }

    function version() external pure override returns (string memory) {
        return '1.0.0';
    }

    function validate() external pure override returns (bool) {
        return true;
    }
}

contract MismatchedSumLibrary is IPaymentCalculationLibrary {
    function calculatePayments(
        PaymentInput memory input
    ) external pure override returns (PaymentOutput memory) {
        uint256[] memory payments = new uint256[](input.resolvers.length);
        address[] memory resolvers = new address[](input.resolvers.length);

        uint256 totalFees = input.escrowFee + input.escalationFees;
        uint256 resolverShare = (totalFees * input.resolverSharePercentage) / BASIS_POINTS;

        for (uint256 i = 0; i < input.resolvers.length; i++) {
            resolvers[i] = input.resolvers[i].resolver;
            payments[i] = resolverShare / input.resolvers.length;
        }

        return
            PaymentOutput({
                totalResolverShare: resolverShare + 1,
                resolvers: resolvers,
                payments: payments
            });
    }

    function version() external pure override returns (string memory) {
        return '1.0.0';
    }

    function validate() external pure override returns (bool) {
        return true;
    }
}

contract ZeroAddressLibrary is IPaymentCalculationLibrary {
    function calculatePayments(
        PaymentInput memory input
    ) external pure override returns (PaymentOutput memory) {
        uint256[] memory payments = new uint256[](input.resolvers.length);
        address[] memory resolvers = new address[](input.resolvers.length);

        uint256 totalFees = input.escrowFee + input.escalationFees;
        uint256 resolverShare = (totalFees * input.resolverSharePercentage) / BASIS_POINTS;

        for (uint256 i = 0; i < input.resolvers.length; i++) {
            resolvers[i] = address(0);
            payments[i] = resolverShare / input.resolvers.length;
        }

        return
            PaymentOutput({
                totalResolverShare: resolverShare,
                resolvers: resolvers,
                payments: payments
            });
    }

    function version() external pure override returns (string memory) {
        return '1.0.0';
    }

    function validate() external pure override returns (bool) {
        return true;
    }
}

contract ExcessiveSinglePaymentLibrary is IPaymentCalculationLibrary {
    function calculatePayments(
        PaymentInput memory input
    ) external pure override returns (PaymentOutput memory) {
        uint256[] memory payments = new uint256[](input.resolvers.length);
        address[] memory resolvers = new address[](input.resolvers.length);

        uint256 totalFees = input.escrowFee + input.escalationFees;
        uint256 resolverShare = (totalFees * input.resolverSharePercentage) / BASIS_POINTS;

        payments[0] = (resolverShare * 9500) / BASIS_POINTS;
        resolvers[0] = input.resolvers[0].resolver;

        for (uint256 i = 1; i < input.resolvers.length; i++) {
            resolvers[i] = input.resolvers[i].resolver;
            payments[i] = (resolverShare - payments[0]) / (input.resolvers.length - 1);
        }

        return
            PaymentOutput({
                totalResolverShare: resolverShare,
                resolvers: resolvers,
                payments: payments
            });
    }

    function version() external pure override returns (string memory) {
        return '1.0.0';
    }

    function validate() external pure override returns (bool) {
        return true;
    }
}

contract ArrayMismatchLibrary is IPaymentCalculationLibrary {
    function calculatePayments(
        PaymentInput memory input
    ) external pure override returns (PaymentOutput memory) {
        address[] memory resolvers = new address[](input.resolvers.length);
        uint256[] memory payments = new uint256[](input.resolvers.length + 1);

        uint256 totalFees = input.escrowFee + input.escalationFees;
        uint256 resolverShare = (totalFees * input.resolverSharePercentage) / BASIS_POINTS;

        for (uint256 i = 0; i < input.resolvers.length; i++) {
            resolvers[i] = input.resolvers[i].resolver;
            payments[i] = resolverShare / input.resolvers.length;
        }
        payments[input.resolvers.length] = 1;

        return
            PaymentOutput({
                totalResolverShare: resolverShare,
                resolvers: resolvers,
                payments: payments
            });
    }

    function version() external pure override returns (string memory) {
        return '1.0.0';
    }

    function validate() external pure override returns (bool) {
        return true;
    }
}
