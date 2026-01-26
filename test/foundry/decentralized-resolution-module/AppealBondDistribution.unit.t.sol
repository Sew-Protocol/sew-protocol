// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import 'forge-std/Test.sol';
import '../../../contracts/decentralized-resolution-module/ResolverIncentiveModuleV2.sol';
import '../../../contracts/decentralized-resolution-module/PaymentCalculationLibraryV1.sol';
import '../../../contracts/decentralized-resolution-module/DecentralizedResolverStructs.sol';
import '../../../contracts/core/EscrowVault.sol';
import '../../../contracts/mocks/ERC20Mock.sol';
import '../../../contracts/YieldOps.sol';
import '../../../contracts/DisputeOps.sol';
import '../../../contracts/core/ModuleManagementContract.sol';
import '../../../contracts/decentralized-resolution-module/ResolverIncentiveModuleV1.sol';
/**
 * @title AppealBondDistributionTest
 * @notice Unit tests for distributeAppealBond functionality
 * @dev Tests appeal bond distribution on appeal success and failure
 */
contract AppealBondDistributionTest is Test {
    ResolverIncentiveModuleV2 public incentiveModule;
    PaymentCalculationLibraryV1 public paymentLib;
    EscrowVault public escrow;
    ERC20Mock public token;
    YieldOps public yieldOps;
    DisputeOps public disputeOps;
    ModuleManagementContract public moduleManagement;

    address public deployer;
    address public depositor;
    address public resolver1;
    address public resolver2;
    address public timelock;
    address public feeAddress;

    uint256 public constant INITIAL_BALANCE = 10000 ether;
    uint256 public constant WORKFLOW_ID = 0;
    uint256 public constant BOND_AMOUNT = 1 ether;

    function setUp() public {
        deployer = address(this);
        depositor = makeAddr('depositor');
        resolver1 = makeAddr('resolver1');
        resolver2 = makeAddr('resolver2');
        timelock = makeAddr('timelock');
        feeAddress = makeAddr('feeAddress');

        // Deploy contracts
        paymentLib = new PaymentCalculationLibraryV1();
        incentiveModule = new ResolverIncentiveModuleV2(deployer, address(paymentLib));
        token = new ERC20Mock('Test Token', 'TEST', address(this), 0);
        yieldOps = new YieldOps(address(this));
        disputeOps = new DisputeOps(address(this));
        moduleManagement = new ModuleManagementContract(address(this));
        escrow = new EscrowVault(100, feeAddress, address(yieldOps), address(disputeOps), address(moduleManagement));

        // Setup tokens
        token.mint(depositor, INITIAL_BALANCE);

        // Grant roles
        incentiveModule.grantRole(incentiveModule.ROLE_TIMELOCK(), timelock);

        // Register escrow contract
        vm.prank(timelock);
        incentiveModule.registerEscrowContract(address(escrow));
    }

    /**
     * @notice Helper to record a bond
     */
    function _recordBond(uint256 workflowId, uint8 round) internal {
        // Approve incentive module to pull tokens (pull-based pattern)
        vm.prank(depositor);
        token.approve(address(incentiveModule), BOND_AMOUNT);

        // Record bond - incentive module will pull tokens from depositor
        vm.prank(address(escrow));
        incentiveModule.recordAppealBond(workflowId, depositor, depositor, BOND_AMOUNT, address(token), round);
    }

    /**
     * @notice Test appeal succeeds - bond refunded to depositor
     */
    function test_distributeAppealBond_AppealSucceeds_Refund() public {
        _recordBond(WORKFLOW_ID, 1);

        // Record balance before distribution
        uint256 depositBalanceBefore = token.balanceOf(depositor);

        // Distribute bond on successful appeal (outcomeFlipped = true)
        vm.prank(address(escrow));
        incentiveModule.distributeAppealBond(WORKFLOW_ID, 0, true);

        // Verify bond refunded to depositor
        uint256 depositBalanceAfter = token.balanceOf(depositor);
        assertEq(
            depositBalanceAfter - depositBalanceBefore,
            BOND_AMOUNT,
            'Depositor should receive bond'
        );
    }

    /**
     * @notice Test appeal fails - bond paid to resolvers
     */
    function test_distributeAppealBond_AppealFails_PayToResolvers() public {
        _recordBond(WORKFLOW_ID, 1);

        // Record resolvers at round 0 (prior to appeal)
        vm.prank(address(escrow));
        incentiveModule.recordResolver(WORKFLOW_ID, resolver1, 0);

        vm.prank(address(escrow));
        incentiveModule.recordResolver(WORKFLOW_ID, resolver2, 0);

        // Distribute bond on failed appeal (outcomeFlipped = false)
        vm.prank(address(escrow));
        incentiveModule.distributeAppealBond(WORKFLOW_ID, 0, false);

        // Verify resolvers have claimable payments
        uint256 resolver1Payment = incentiveModule.getClaimablePayment(WORKFLOW_ID, resolver1);
        uint256 resolver2Payment = incentiveModule.getClaimablePayment(WORKFLOW_ID, resolver2);

        // Should be split equally (or with proper rounding)
        assertGt(resolver1Payment, 0, 'Resolver1 should have claimable payment');
        assertGt(resolver2Payment, 0, 'Resolver2 should have claimable payment');

        // Total should equal bond amount (with possible rounding)
        uint256 total = resolver1Payment + resolver2Payment;
        assertEq(total, BOND_AMOUNT, 'Total distributed should equal bond amount');
    }

    /**
     * @notice Test no bond recorded - should revert
     */
    function test_distributeAppealBond_NoBondRecorded() public {
        vm.prank(address(escrow));
        vm.expectRevert('No bond recorded');
        incentiveModule.distributeAppealBond(WORKFLOW_ID, 0, true);
    }

    /**
     * @notice Test already distributed - should revert
     * @dev Note: bond.amount is zeroed after distribution, so recheck gets "No bond recorded"
     */
    function test_distributeAppealBond_AlreadyDistributed() public {
        _recordBond(WORKFLOW_ID, 1);

        // Distribute once
        vm.prank(address(escrow));
        incentiveModule.distributeAppealBond(WORKFLOW_ID, 0, true);

        // Try to distribute again
        // Note: The contract zeros bond.amount after distribution, so second call fails on "No bond recorded"
        vm.prank(address(escrow));
        vm.expectRevert('No bond recorded');
        incentiveModule.distributeAppealBond(WORKFLOW_ID, 0, true);
    }

    /**
     * @notice Test no resolvers at prior round - bond forfeited
     */
    function test_distributeAppealBond_NoResolvers_Forfeit() public {
        _recordBond(WORKFLOW_ID, 1);

        // No resolvers recorded at round 0

        // Distribute bond
        vm.prank(address(escrow));
        incentiveModule.distributeAppealBond(WORKFLOW_ID, 0, false);

        // Bond should be forfeited (remains in protocol)
        // Verify no payment to any resolver
        uint256 resolver1Payment = incentiveModule.getClaimablePayment(WORKFLOW_ID, resolver1);
        assertEq(resolver1Payment, 0, 'No payment to unrecorded resolver');
    }

    /**
     * @notice Test event emission on refund
     */
    function test_distributeAppealBond_EventEmittedOnRefund() public {
        _recordBond(WORKFLOW_ID, 1);

        vm.prank(address(escrow));
        vm.expectEmit(true, true, true, true);
        emit AppealBondRefunded(WORKFLOW_ID, 1, depositor, BOND_AMOUNT, address(token));

        incentiveModule.distributeAppealBond(WORKFLOW_ID, 0, true);
    }

    /**
     * @notice Test event emission on payment to resolvers
     */
    function test_distributeAppealBond_EventEmittedOnPayment() public {
        _recordBond(WORKFLOW_ID, 1);

        // Record resolver
        vm.prank(address(escrow));
        incentiveModule.recordResolver(WORKFLOW_ID, resolver1, 0);

        address[] memory resolvers = new address[](1);
        resolvers[0] = resolver1;

        vm.prank(address(escrow));
        vm.expectEmit(true, true, true, true);
        emit AppealBondPaidToResolvers(WORKFLOW_ID, 0, resolvers, BOND_AMOUNT, address(token));

        incentiveModule.distributeAppealBond(WORKFLOW_ID, 0, false);
    }

    // Event declarations for testing (matching ResolverIncentiveModuleV2)
    event AppealBondRefunded(
        uint256 indexed escrowId,
        uint8 round,
        address indexed depositor,
        uint256 amount,
        address token
    );

    event AppealBondPaidToResolvers(
        uint256 indexed escrowId,
        uint8 round,
        address[] resolvers,
        uint256 totalAmount,
        address token
    );
}
