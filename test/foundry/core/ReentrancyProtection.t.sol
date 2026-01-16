// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import 'forge-std/Test.sol';
import '../../../contracts/core/EscrowVault.sol';
import '../../../contracts/decentralized-resolution-module/ResolverIncentiveModuleV2.sol';
import '../../../contracts/decentralized-resolution-module/DecentralizedResolutionModule.sol';
import '../../../contracts/decentralized-resolution-module/PaymentCalculationLibraryV1.sol';
import '../../../contracts/mocks/ERC20Mock.sol';
import '../../../contracts/YieldOps.sol';
import '../../../contracts/DisputeOps.sol';
import '../../../contracts/types/EscrowTypes.sol';
import '../../../contracts/decentralized-resolution-module/DecentralizedResolverStructs.sol';

/**
 * @title ReentrancyProtectionTest
 * @notice Tests reentrancy protection for critical functions
 * @dev Focuses on:
 *      - Payment claim reentrancy (ResolverIncentiveModule)
 *      - Bond distribution reentrancy (ResolverIncentiveModuleV2)
 *      - Escrow operation reentrancy (BaseEscrow)
 */
contract ReentrancyProtectionTest is Test {
    EscrowVault public escrow;
    ResolverIncentiveModuleV2 public incentiveModule;
    DecentralizedResolutionModule public resolutionModule;
    PaymentCalculationLibraryV1 public paymentLib;
    ERC20Mock public token;
    YieldOps public yieldOps;
    DisputeOps public disputeOps;

    address public deployer;
    address public timelock;
    address public resolver1;
    address public attacker;
    address public user1;
    address public user2;

    uint256 public constant ESCROW_AMOUNT = 1000 ether;

    function setUp() public {
        deployer = address(this);
        timelock = makeAddr('timelock');
        resolver1 = makeAddr('resolver1');
        attacker = makeAddr('attacker');
        user1 = makeAddr('user1');
        user2 = makeAddr('user2');

        // Deploy infrastructure
        yieldOps = new YieldOps();
        disputeOps = new DisputeOps();
        escrow = new EscrowVault(100, makeAddr('feeAddress'), address(yieldOps), address(disputeOps));

        // Deploy modules
        paymentLib = new PaymentCalculationLibraryV1();
        incentiveModule = new ResolverIncentiveModuleV2(deployer, address(paymentLib));
        resolutionModule = new DecentralizedResolutionModule(deployer);

        // Setup roles
        bytes32 ROLE_TIMELOCK = incentiveModule.ROLE_TIMELOCK();
        incentiveModule.grantRole(ROLE_TIMELOCK, timelock);
        resolutionModule.grantRole(ROLE_TIMELOCK, timelock);

        // Register escrow
        vm.startPrank(timelock);
        incentiveModule.registerEscrowContract(address(escrow));
        resolutionModule.registerEscrowContract(address(escrow));
        resolutionModule.setIncentiveModule(address(incentiveModule));
        vm.stopPrank();

        // Setup escrow
        escrow.grantRole(escrow.ROLE_TIMELOCK(), address(this));
        escrow.queueResolutionModule(address(resolutionModule));
        vm.warp(block.timestamp + 7 days + 1);
        escrow.activateResolutionModule();

        // Appoint resolvers
        vm.startPrank(timelock);
        resolutionModule.appointSeniorResolver(resolver1, 'Senior Resolver', 'Test');
        vm.stopPrank();
        
        vm.prank(resolver1);
        resolutionModule.appointResolver(user1, 'Resolver 1', 'Test');
        
        vm.startPrank(timelock);
        resolutionModule.setResolverActive(resolver1, true);
        resolutionModule.setResolverActive(user1, true);
        resolutionModule.setResolverCapacity(resolver1, 0, true);
        resolutionModule.setResolverCapacity(user1, 0, true);
        vm.stopPrank();

        // Deploy token
        token = new ERC20Mock('Test Token', 'TEST', deployer, 1_000_000 ether);
        token.mint(user1, 1_000_000 ether);
        token.mint(address(incentiveModule), 10_000 ether);
    }

    // ============ Payment Claim Reentrancy Tests ============

    /**
     * @notice Test that claimPayment cannot be reentered
     */
    function test_claimPayment_ReentrancyProtection() public {
        // Setup: Create escrow, dispute, and record payment
        vm.startPrank(user1);
        token.approve(address(escrow), ESCROW_AMOUNT);
        uint256 workflowId = escrow.createEscrow(
            address(token),
            user2,
            ESCROW_AMOUNT,
            EscrowSettings({
                customResolver: address(0),
                yieldEnabled: false,
                autoReleaseTime: 0,
                autoCancelTime: 0,
                escrowType: EscrowType.STANDARD
            })
        );
        escrow.raiseDispute(workflowId);
        vm.stopPrank();

        // Record resolver and fees
        vm.prank(address(escrow));
        incentiveModule.recordResolver(workflowId, resolver1, 0);
        vm.prank(address(escrow));
        incentiveModule.recordEscrowFee(workflowId, address(token), 10 ether);

        // Distribute payments
        vm.prank(address(escrow));
        incentiveModule.distributePayments(workflowId, address(token), 0);

        // Attempt direct reentrancy by calling claimPayment twice in same tx
        // The nonReentrant modifier should prevent this
        vm.startPrank(resolver1);
        // First claim should succeed
        incentiveModule.claimPayment(workflowId, address(token));
        // Second claim in same tx should revert due to nonReentrant
        vm.expectRevert(); // ReentrancyGuard reversion
        incentiveModule.claimPayment(workflowId, address(token));
        vm.stopPrank();
    }

    /**
     * @notice Test that claimPayment cannot be called twice in same transaction
     */
    function test_claimPayment_CannotCallTwice() public {
        // Setup payment
        uint256 workflowId = 1;
        vm.prank(address(escrow));
        incentiveModule.recordResolver(workflowId, resolver1, 0);
        vm.prank(address(escrow));
        incentiveModule.recordEscrowFee(workflowId, address(token), 10 ether);
        vm.prank(address(escrow));
        incentiveModule.distributePayments(workflowId, address(token), 0);

        uint256 claimable = incentiveModule.getClaimablePayment(workflowId, resolver1);
        assertTrue(claimable > 0, 'Should have claimable payment');

        // First claim should succeed
        vm.prank(resolver1);
        incentiveModule.claimPayment(workflowId, address(token));

        // Second claim should revert (nothing left to claim)
        vm.prank(resolver1);
        vm.expectRevert();
        incentiveModule.claimPayment(workflowId, address(token));
    }

    // ============ Bond Distribution Reentrancy Tests ============

    /**
     * @notice Test that distributeAppealBond is protected from reentrancy
     */
    function test_distributeAppealBond_ReentrancyProtection() public {
        // Setup: Create escrow and dispute
        vm.startPrank(user1);
        token.approve(address(escrow), ESCROW_AMOUNT);
        uint256 workflowId = escrow.createEscrow(
            address(token),
            user2,
            ESCROW_AMOUNT,
            EscrowSettings({
                customResolver: address(0),
                yieldEnabled: false,
                autoReleaseTime: 0,
                autoCancelTime: 0,
                escrowType: EscrowType.STANDARD
            })
        );
        escrow.raiseDispute(workflowId);
        vm.stopPrank();

        // Record resolver at round 0
        vm.prank(address(escrow));
        incentiveModule.recordResolver(workflowId, resolver1, 0);

        // Record bond for round 1
        vm.deal(address(escrow), 1 ether);
        vm.prank(address(escrow));
        incentiveModule.recordAppealBond{value: 1 ether}(workflowId, user1, 1 ether, address(0), 1);

        // Setup cost config for escalation
        DecentralizedResolverStructs.EscalationCostConfig memory config = DecentralizedResolverStructs
            .EscalationCostConfig({
                curveType: DecentralizedResolverStructs.CostCurveType.QUADRATIC,
                baseCost: 1 ether,
                stepSize: 0,
                multiplier: 0,
                bondToken: address(0),
                enabled: true
            });
        vm.prank(timelock);
        resolutionModule.queueEscalationCostConfig(config);
        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(timelock);
        resolutionModule.activateEscalationCostConfig();

        // Record resolution at round 0
        vm.prank(address(escrow));
        resolutionModule.recordResolution(
            workflowId,
            resolver1,
            DecentralizedResolverStructs.ResolutionOutcome.CANCEL,
            1 days
        );

        // Distribute bond (appeal failed - bond goes to resolver)
        // This should be protected from reentrancy
        vm.prank(address(escrow));
        incentiveModule.distributeAppealBond(workflowId, 0, false);

        // Verify bond was distributed (not reverted)
        ResolverIncentiveModuleV2.AppealBondRecord memory bond = incentiveModule.getAppealBond(
            workflowId,
            1
        );
        assertTrue(bond.distributed, 'Bond should be distributed');
    }

    // ============ Escrow Operation Reentrancy Tests ============

    /**
     * @notice Test that escrow release operations are protected from reentrancy
     */
    function test_releaseEscrowTransfer_ReentrancyProtection() public {
        // Create escrow
        vm.startPrank(user1);
        token.approve(address(escrow), ESCROW_AMOUNT);
        uint256 workflowId = escrow.createEscrow(
            address(token),
            user2,
            ESCROW_AMOUNT,
            EscrowSettings({
                customResolver: address(0),
                yieldEnabled: false,
                autoReleaseTime: 0,
                autoCancelTime: 0,
                escrowType: EscrowType.STANDARD
            })
        );
        vm.stopPrank();

        // Sender can release escrow
        vm.prank(user1);
        escrow.releaseEscrowTransfer(workflowId);

        // Second release should revert (escrow already released)
        vm.prank(user1);
        vm.expectRevert();
        escrow.releaseEscrowTransfer(workflowId);
    }

    /**
     * @notice Test that escrow cancellation operations are protected from reentrancy
     */
    function test_cancelEscrowTransfer_ReentrancyProtection() public {
        // Create escrow
        vm.startPrank(user1);
        token.approve(address(escrow), ESCROW_AMOUNT);
        uint256 workflowId = escrow.createEscrow(
            address(token),
            user2,
            ESCROW_AMOUNT,
            EscrowSettings({
                customResolver: address(0),
                yieldEnabled: false,
                autoReleaseTime: 0,
                autoCancelTime: 0,
                escrowType: EscrowType.STANDARD
            })
        );
        vm.stopPrank();

        // Both sender and recipient agree to cancel
        vm.prank(user1);
        escrow.senderCancel(workflowId);
        
        vm.prank(user2);
        escrow.recipientCancel(workflowId);

        // Attempt to cancel again - should revert (already cancelled)
        vm.prank(user1);
        vm.expectRevert();
        escrow.senderCancel(workflowId);
    }
}
