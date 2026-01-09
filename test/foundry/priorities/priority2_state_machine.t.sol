// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.33;

import "forge-std/Test.sol";
import "forge-std/StdInvariant.sol";
import "../../../contracts/core/EscrowVault.sol";
import "../../../contracts/mocks/ERC20Mock.sol";
import "../../../contracts/core/modules/DefaultResolutionModule.sol";
import "../../../contracts/modules/DefaultReleaseStrategy.sol";
import "../../../contracts/types/EscrowTypes.sol";

/**
 * @title Priority2_StateMachine
 * @notice Tests for state machine correctness
 * @dev Priority #2: Verify valid state transitions and prevent double-spending
 */
contract Priority2_StateMachine is StdInvariant, Test {
    EscrowVault public vault;
    ERC20Mock public token;
    DefaultResolutionModule public resolutionModule;
    DefaultReleaseStrategy public releaseStrategy;
    
    address public feeAddress;
    address public resolver;
    address public owner;
    
    uint256 public constant ESCROW_FEE = 100;
    
    function setUp() public {
        owner = address(this);
        feeAddress = address(0xFEE);
        resolver = address(0x1234);
        
        resolutionModule = new DefaultResolutionModule(owner, resolver);
        releaseStrategy = new DefaultReleaseStrategy();
        
        token = new ERC20Mock("Test Token", "TEST", owner, 10000000e18);
        vault = new EscrowVault(ESCROW_FEE, feeAddress, address(0));
        
        bytes32 ROLE_TIMELOCK = vault.ROLE_TIMELOCK();
        vault.grantRole(ROLE_TIMELOCK, owner);
        
        vault.queueDefaultResolutionModule(address(resolutionModule));
        vault.queueDefaultReleaseStrategy(address(releaseStrategy));
        
        vm.warp(block.timestamp + 7 days + 1);
        vault.activateDefaultResolutionModule();
        vault.activateDefaultReleaseStrategy();
    }
    
    /**
     * @notice Test: Valid state transitions
     */
    function test_validStateTransitions() public {
        address buyer = address(0x1001);
        address seller = address(0x1002);
        uint256 amount = 1000e18;
        
        token.mint(buyer, amount);
        vm.prank(buyer);
        token.approve(address(vault), amount);
        
        // NONE → PENDING
        vm.prank(buyer);
        uint256 workflowId = vault.createEscrow(address(token), seller, amount);
        
        EscrowTransfer memory et = vault.getEscrowTransfer(workflowId);
        assertEq(uint256(et.escrowState), uint256(EscrowState.PENDING), "Should be PENDING");
        
        // PENDING → RELEASED
        vm.prank(buyer);
        vault.releaseEscrowTransfer(workflowId);
        
        et = vault.getEscrowTransfer(workflowId);
        assertEq(uint256(et.escrowState), uint256(EscrowState.RELEASED), "Should be RELEASED");
        assertEq(et.remainingBalance, 0, "Balance should be zero");
    }
    
    /**
     * @notice Test: Invalid transitions revert
     */
    function test_invalidTransitionsRevert() public {
        address buyer = address(0x1001);
        address seller = address(0x1002);
        uint256 amount = 1000e18;
        
        token.mint(buyer, amount);
        vm.prank(buyer);
        token.approve(address(vault), amount);
        
        vm.prank(buyer);
        uint256 workflowId = vault.createEscrow(address(token), seller, amount);
        
        // Release escrow
        vm.prank(buyer);
        vault.releaseEscrowTransfer(workflowId);
        
        // Attempt invalid transition: RELEASED → PENDING
        vm.prank(buyer);
        vm.expectRevert();
        vault.releaseEscrowTransfer(workflowId);
        
        // Attempt invalid transition: RELEASED → DISPUTED
        vm.prank(buyer);
        vm.expectRevert();
        vault.raiseDispute(workflowId);
    }
    
    /**
     * @notice Test: No double-spending
     */
    function test_noDoubleSpending() public {
        address buyer = address(0x1001);
        address seller = address(0x1002);
        uint256 amount = 1000e18;
        
        token.mint(buyer, amount);
        vm.prank(buyer);
        token.approve(address(vault), amount);
        
        vm.prank(buyer);
        uint256 workflowId = vault.createEscrow(address(token), seller, amount);
        
        uint256 balanceBefore = token.balanceOf(seller);
        
        // Calculate expected amount after fee deduction
        uint256 fee = amount * ESCROW_FEE / 10000;
        uint256 expectedAmount = amount - fee;
        
        // Release once
        vm.prank(buyer);
        vault.releaseEscrowTransfer(workflowId);
        
        uint256 balanceAfter = token.balanceOf(seller);
        assertEq(balanceAfter - balanceBefore, expectedAmount, "Incorrect release amount");
        
        // Attempt second release
        vm.prank(buyer);
        vm.expectRevert();
        vault.releaseEscrowTransfer(workflowId);
        
        // Verify balance unchanged
        assertEq(token.balanceOf(seller), balanceAfter, "Double-spend occurred");
    }
    
    /**
     * @notice Test: Remaining balance never exceeds total deposited
     */
    function test_remainingBalanceNeverExceedsTotal() public {
        address buyer = address(0x1001);
        address seller = address(0x1002);
        uint256 amount = 1000e18;
        
        token.mint(buyer, amount);
        vm.prank(buyer);
        token.approve(address(vault), amount);
        
        vm.prank(buyer);
        uint256 workflowId = vault.createEscrow(address(token), seller, amount);
        
        EscrowTransfer memory et = vault.getEscrowTransfer(workflowId);
        assertLe(et.remainingBalance, et.totalDeposited, "Remaining balance exceeds total");
        
        // Fees are deducted, so remainingBalance = totalDeposited - fee
        uint256 fee = amount * ESCROW_FEE / 10000;
        uint256 expectedRemaining = amount - fee;
        assertEq(et.remainingBalance, expectedRemaining, "Initial balance should equal total minus fee");
    }
    
    /**
     * @notice Test: Completed escrows have zero balance
     */
    function test_completedEscrowsZeroBalance() public {
        address buyer = address(0x1001);
        address seller = address(0x1002);
        uint256 amount = 1000e18;
        
        token.mint(buyer, amount);
        vm.prank(buyer);
        token.approve(address(vault), amount);
        
        vm.prank(buyer);
        uint256 workflowId = vault.createEscrow(address(token), seller, amount);
        
        // Release
        vm.prank(buyer);
        vault.releaseEscrowTransfer(workflowId);
        
        EscrowTransfer memory et = vault.getEscrowTransfer(workflowId);
        assertEq(et.remainingBalance, 0, "Released escrow should have zero balance");
        assertEq(uint256(et.escrowState), uint256(EscrowState.RELEASED), "Should be RELEASED");
    }
    
    /**
     * @notice Test: Workflow ID consistency
     */
    function test_workflowIdConsistency() public {
        address buyer = address(0x1001);
        address seller = address(0x1002);
        uint256 amount = 1000e18;
        
        token.mint(buyer, amount * 3);
        vm.prank(buyer);
        token.approve(address(vault), amount * 3);
        
        // Create multiple escrows
        vm.prank(buyer);
        uint256 id1 = vault.createEscrow(address(token), seller, amount);
        
        vm.prank(buyer);
        uint256 id2 = vault.createEscrow(address(token), seller, amount);
        
        vm.prank(buyer);
        uint256 id3 = vault.createEscrow(address(token), seller, amount);
        
        // Verify IDs are sequential
        assertEq(id1, 0, "First ID should be 0");
        assertEq(id2, 1, "Second ID should be 1");
        assertEq(id3, 2, "Third ID should be 2");
        
        // Verify nextWorkflowId matches count
        assertEq(vault.nextWorkflowId(), vault.getEscrowCount(), "Workflow ID mismatch");
    }
    
    /**
     * @notice Fuzz test: State transitions
     */
    function testFuzz_stateTransitions(uint8 action) public {
        address buyer = address(0x1001);
        address seller = address(0x1002);
        uint256 amount = 1000e18;
        
        token.mint(buyer, amount);
        vm.prank(buyer);
        token.approve(address(vault), amount);
        
        vm.prank(buyer);
        uint256 workflowId = vault.createEscrow(address(token), seller, amount);
        
        action = uint8(bound(action, 0, 2));
        
        if (action == 0) {
            // Release
            vm.prank(buyer);
            vault.releaseEscrowTransfer(workflowId);
        } else if (action == 1) {
            // Cancel - senderCancel sets senderStatus but doesn't immediately change escrowState
            // Need both parties to agree or resolver to cancel for REFUNDED state
            vm.prank(buyer);
            vault.senderCancel(workflowId);
            // Also cancel from seller side to complete the cancellation
            vm.prank(seller);
            vault.recipientCancel(workflowId);
        } else {
            // Dispute
            vm.prank(buyer);
            vault.raiseDispute(workflowId);
        }
        
        EscrowTransfer memory et = vault.getEscrowTransfer(workflowId);
        assertTrue(
            et.escrowState == EscrowState.RELEASED ||
            et.escrowState == EscrowState.REFUNDED ||
            et.escrowState == EscrowState.DISPUTED ||
            (et.escrowState == EscrowState.PENDING && (et.senderStatus == SenderStatus.AGREE_TO_CANCEL || et.recipientStatus == RecipientStatus.AGREE_TO_CANCEL)),
            "Invalid final state"
        );
    }
    
    /**
     * @notice Invariant: Valid states only
     */
    function invariant_validStatesOnly() public view {
        uint256 count = vault.getEscrowCount();
        for (uint256 i = 0; i < count; i++) {
            EscrowTransfer memory et = vault.getEscrowTransfer(i);
            
            assertTrue(
                et.escrowState == EscrowState.NONE ||
                et.escrowState == EscrowState.PENDING ||
                et.escrowState == EscrowState.RELEASED ||
                et.escrowState == EscrowState.REFUNDED ||
                et.escrowState == EscrowState.DISPUTED ||
                et.escrowState == EscrowState.RESOLVED,
                "Invalid escrow state"
            );
        }
    }
    
    /**
     * @notice Invariant: No double-spending
     */
    function invariant_noDoubleSpending() public view {
        uint256 count = vault.getEscrowCount();
        for (uint256 i = 0; i < count; i++) {
            EscrowTransfer memory et = vault.getEscrowTransfer(i);
            
            // Remaining balance never exceeds total deposited
            assertLe(et.remainingBalance, et.totalDeposited, "Double-spend detected");
            
            // Completed escrows have zero balance
            if (et.escrowState == EscrowState.RELEASED ||
                et.escrowState == EscrowState.REFUNDED ||
                et.escrowState == EscrowState.RESOLVED) {
                assertEq(et.remainingBalance, 0, "Completed escrow has non-zero balance");
            }
        }
    }
    
    /**
     * @notice Invariant: Workflow ID consistency
     */
    function invariant_workflowIdConsistency() public view {
        assertEq(vault.nextWorkflowId(), vault.getEscrowCount(), "Workflow ID mismatch");
        
        uint256 count = vault.getEscrowCount();
        for (uint256 i = 0; i < count; i++) {
            EscrowTransfer memory et = vault.getEscrowTransfer(i);
            assertEq(et.workflowId, i, "Workflow ID doesn't match index");
        }
    }
}

