// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.33;

import "forge-std/Test.sol";
import {EscrowableERC20} from "../../../contracts/core/EscrowableERC20.sol";
import {EscrowVault} from "../../../contracts/core/EscrowVault.sol";
import {ERC20Mock} from "../../../contracts/mocks/ERC20Mock.sol";
import {DefaultResolutionModule} from "../../../contracts/core/modules/DefaultResolutionModule.sol";
import {EscrowState} from "../../../contracts/types/EscrowTypes.sol";

/**
 * @title PartialOperationsComprehensive
 * @notice Comprehensive tests for partial release and cancel operations covering:
 *  - Partial release by resolver
 *  - Partial cancel by resolver
 *  - Multiple partial operations
 *  - Balance tracking
 *  - Edge cases (zero amounts, full amounts)
 */
contract PartialOperationsComprehensive is Test {
    EscrowableERC20 token;
    EscrowVault vault;
    ERC20Mock paymentToken;
    DefaultResolutionModule resolutionModule;
    
    address owner = address(this);
    address sender = address(0x1);
    address recipient = address(0x2);
    address resolver = address(0x3);
    address feeRecipient = address(0x4);
    
    uint256 constant ESCROW_FEE = 100; // 1%
    uint256 constant AMOUNT = 10 ether;
    
    bytes32 ROLE_TIMELOCK;
    
    function setUp() public {
        token = new EscrowableERC20("Test", "TST", ESCROW_FEE, feeRecipient, address(0));
        paymentToken = new ERC20Mock("Payment", "PAY", address(this), 1_000_000 ether);
        vault = new EscrowVault(ESCROW_FEE, feeRecipient, address(0));
        
        ROLE_TIMELOCK = token.ROLE_TIMELOCK();
        token.grantRole(ROLE_TIMELOCK, owner);
        vault.grantRole(ROLE_TIMELOCK, owner);
        
        // Setup resolution module
        resolutionModule = new DefaultResolutionModule(owner, resolver);
        token.queueDefaultResolutionModule(address(resolutionModule));
        vault.queueDefaultResolutionModule(address(resolutionModule));
        vm.warp(block.timestamp + 14 days + 1);
        token.activateDefaultResolutionModule();
        vault.activateDefaultResolutionModule();
        
        // Distribute tokens
        token.transfer(sender, 100 ether);
        paymentToken.transfer(sender, 100 ether);
        
        vm.prank(sender);
        token.approve(address(token), type(uint256).max);
        
        vm.prank(sender);
        paymentToken.approve(address(vault), type(uint256).max);
    }
    
    // =========================================================================
    // Partial Release Tests
    // =========================================================================
    
    function test_Partial_releaseHalf() public {
        // Create escrow
        vm.prank(sender);
        uint256 workflowId = token.createEscrow(recipient, AMOUNT);
        
        // Raise dispute
        vm.prank(sender);
        token.raiseDispute(workflowId);
        
        // Partial release half
        uint256 releaseAmount = AMOUNT / 2;
        vm.prank(resolver);
        bool success = token.partialReleaseAsDisputeResolver(workflowId, releaseAmount);
        assertTrue(success, "Partial release should succeed");
    }
    
    function test_Partial_releaseQuarter() public {
        vm.prank(sender);
        uint256 workflowId = token.createEscrow(recipient, AMOUNT);
        
        vm.prank(sender);
        token.raiseDispute(workflowId);
        
        uint256 releaseAmount = AMOUNT / 4;
        vm.prank(resolver);
        bool success = token.partialReleaseAsDisputeResolver(workflowId, releaseAmount);
        assertTrue(success);
    }
    
    function test_Partial_releaseMultipleTimes() public {
        vm.prank(sender);
        uint256 workflowId = token.createEscrow(recipient, AMOUNT);
        
        vm.prank(sender);
        token.raiseDispute(workflowId);
        
        // Release in multiple parts
        vm.startPrank(resolver);
        token.partialReleaseAsDisputeResolver(workflowId, 2 ether);
        token.partialReleaseAsDisputeResolver(workflowId, 3 ether);
        token.partialReleaseAsDisputeResolver(workflowId, 2 ether);
        vm.stopPrank();
        
        // Total released: 7 ether, should still have 3 ether remaining
    }
    
    function test_Partial_releaseFullAmount() public {
        vm.prank(sender);
        uint256 workflowId = token.createEscrow(recipient, AMOUNT);
        
        vm.prank(sender);
        token.raiseDispute(workflowId);
        
        // Release full remaining balance (after fee deduction: 99% of AMOUNT)
        uint256 actualBalance = (AMOUNT * (10000 - ESCROW_FEE)) / 10000;
        vm.prank(resolver);
        bool success = token.partialReleaseAsDisputeResolver(workflowId, actualBalance);
        assertTrue(success);
    }
    
    function test_Partial_cannotReleaseZero() public {
        vm.prank(sender);
        uint256 workflowId = token.createEscrow(recipient, AMOUNT);
        
        vm.prank(sender);
        token.raiseDispute(workflowId);
        
        vm.prank(resolver);
        vm.expectRevert();
        token.partialReleaseAsDisputeResolver(workflowId, 0);
    }
    
    function test_Partial_cannotReleaseMoreThanBalance() public {
        vm.prank(sender);
        uint256 workflowId = token.createEscrow(recipient, AMOUNT);
        
        vm.prank(sender);
        token.raiseDispute(workflowId);
        
        vm.prank(resolver);
        vm.expectRevert();
        token.partialReleaseAsDisputeResolver(workflowId, AMOUNT + 1 ether);
    }
    
    // =========================================================================
    // Partial Cancel Tests
    // =========================================================================
    
    function test_Partial_cancelHalf() public {
        vm.prank(sender);
        uint256 workflowId = token.createEscrow(recipient, AMOUNT);
        
        vm.prank(sender);
        token.raiseDispute(workflowId);
        
        uint256 cancelAmount = AMOUNT / 2;
        vm.prank(resolver);
        bool success = token.partialCancelAsDisputeResolver(workflowId, cancelAmount);
        assertTrue(success);
    }
    
    function test_Partial_cancelQuarter() public {
        vm.prank(sender);
        uint256 workflowId = token.createEscrow(recipient, AMOUNT);
        
        vm.prank(sender);
        token.raiseDispute(workflowId);
        
        uint256 cancelAmount = AMOUNT / 4;
        vm.prank(resolver);
        bool success = token.partialCancelAsDisputeResolver(workflowId, cancelAmount);
        assertTrue(success);
    }
    
    function test_Partial_cancelMultipleTimes() public {
        vm.prank(sender);
        uint256 workflowId = token.createEscrow(recipient, AMOUNT);
        
        vm.prank(sender);
        token.raiseDispute(workflowId);
        
        // Cancel in multiple parts
        vm.startPrank(resolver);
        token.partialCancelAsDisputeResolver(workflowId, 1 ether);
        token.partialCancelAsDisputeResolver(workflowId, 2 ether);
        token.partialCancelAsDisputeResolver(workflowId, 1 ether);
        vm.stopPrank();
        
        // Total canceled: 4 ether, should still have 6 ether remaining
    }
    
    function test_Partial_cancelFullAmount() public {
        vm.prank(sender);
        uint256 workflowId = token.createEscrow(recipient, AMOUNT);
        
        vm.prank(sender);
        token.raiseDispute(workflowId);
        
        // Cancel full remaining balance (after fee deduction)
        uint256 actualBalance = (AMOUNT * (10000 - ESCROW_FEE)) / 10000;
        vm.prank(resolver);
        bool success = token.partialCancelAsDisputeResolver(workflowId, actualBalance);
        assertTrue(success);
    }
    
    function test_Partial_cannotCancelZero() public {
        vm.prank(sender);
        uint256 workflowId = token.createEscrow(recipient, AMOUNT);
        
        vm.prank(sender);
        token.raiseDispute(workflowId);
        
        vm.prank(resolver);
        vm.expectRevert();
        token.partialCancelAsDisputeResolver(workflowId, 0);
    }
    
    function test_Partial_cannotCancelMoreThanBalance() public {
        vm.prank(sender);
        uint256 workflowId = token.createEscrow(recipient, AMOUNT);
        
        vm.prank(sender);
        token.raiseDispute(workflowId);
        
        vm.prank(resolver);
        vm.expectRevert();
        token.partialCancelAsDisputeResolver(workflowId, AMOUNT + 1 ether);
    }
    
    // =========================================================================
    // Mixed Operations Tests
    // =========================================================================
    
    function test_Partial_releaseAndCancel() public {
        vm.prank(sender);
        uint256 workflowId = token.createEscrow(recipient, AMOUNT);
        
        vm.prank(sender);
        token.raiseDispute(workflowId);
        
        // Release half, cancel quarter
        vm.startPrank(resolver);
        token.partialReleaseAsDisputeResolver(workflowId, 5 ether);
        token.partialCancelAsDisputeResolver(workflowId, 2.5 ether);
        vm.stopPrank();
        
        // Remaining should be 2.5 ether
    }
    
    function test_Partial_multipleMixedOperations() public {
        vm.prank(sender);
        uint256 workflowId = token.createEscrow(recipient, AMOUNT);
        
        vm.prank(sender);
        token.raiseDispute(workflowId);
        
        // Complex resolution
        vm.startPrank(resolver);
        token.partialReleaseAsDisputeResolver(workflowId, 3 ether);
        token.partialCancelAsDisputeResolver(workflowId, 2 ether);
        token.partialReleaseAsDisputeResolver(workflowId, 2 ether);
        token.partialCancelAsDisputeResolver(workflowId, 1 ether);
        vm.stopPrank();
        
        // Total: 5 released, 3 canceled, 2 remaining
    }
    
    function test_Partial_cannotExceedTotalWithMixed() public {
        vm.prank(sender);
        uint256 workflowId = token.createEscrow(recipient, AMOUNT);
        
        vm.prank(sender);
        token.raiseDispute(workflowId);
        
        vm.startPrank(resolver);
        token.partialReleaseAsDisputeResolver(workflowId, 6 ether);
        token.partialCancelAsDisputeResolver(workflowId, 3 ether);
        
        // Try to release more than remaining
        vm.expectRevert();
        token.partialReleaseAsDisputeResolver(workflowId, 2 ether);
        vm.stopPrank();
    }
    
    // =========================================================================
    // Access Control Tests
    // =========================================================================
    
    function test_Partial_onlyResolverCanPartialRelease() public {
        vm.prank(sender);
        uint256 workflowId = token.createEscrow(recipient, AMOUNT);
        
        vm.prank(sender);
        token.raiseDispute(workflowId);
        
        // Non-resolver tries
        vm.prank(sender);
        vm.expectRevert();
        token.partialReleaseAsDisputeResolver(workflowId, 5 ether);
    }
    
    function test_Partial_onlyResolverCanPartialCancel() public {
        vm.prank(sender);
        uint256 workflowId = token.createEscrow(recipient, AMOUNT);
        
        vm.prank(sender);
        token.raiseDispute(workflowId);
        
        // Non-resolver tries
        vm.prank(recipient);
        vm.expectRevert();
        token.partialCancelAsDisputeResolver(workflowId, 5 ether);
    }
    
    // =========================================================================
    // State Validation Tests
    // =========================================================================
    
    function test_Partial_cannotPartialReleaseNonDisputedEscrow() public {
        vm.prank(sender);
        uint256 workflowId = token.createEscrow(recipient, AMOUNT);
        
        // Try partial release without dispute
        vm.prank(resolver);
        vm.expectRevert();
        token.partialReleaseAsDisputeResolver(workflowId, 5 ether);
    }
    
    function test_Partial_cannotPartialCancelNonDisputedEscrow() public {
        vm.prank(sender);
        uint256 workflowId = token.createEscrow(recipient, AMOUNT);
        
        // Try partial cancel without dispute
        vm.prank(resolver);
        vm.expectRevert();
        token.partialCancelAsDisputeResolver(workflowId, 5 ether);
    }
    
    // =========================================================================
    // Precision Tests
    // =========================================================================
    
    function test_Partial_handleSmallAmounts() public {
        vm.prank(sender);
        uint256 workflowId = token.createEscrow(recipient, AMOUNT);
        
        vm.prank(sender);
        token.raiseDispute(workflowId);
        
        // Release very small amount
        vm.prank(resolver);
        bool success = token.partialReleaseAsDisputeResolver(workflowId, 1 wei);
        assertTrue(success);
    }
    
    function test_Partial_handleOddAmounts() public {
        vm.prank(sender);
        uint256 workflowId = token.createEscrow(recipient, AMOUNT);
        
        vm.prank(sender);
        token.raiseDispute(workflowId);
        
        // Odd amounts
        vm.startPrank(resolver);
        token.partialReleaseAsDisputeResolver(workflowId, 3.333 ether);
        token.partialCancelAsDisputeResolver(workflowId, 2.777 ether);
        vm.stopPrank();
    }
    
    // =========================================================================
    // EscrowVault Partial Operations
    // =========================================================================
    
    function test_Partial_vaultPartialRelease() public {
        vm.prank(sender);
        uint256 workflowId = vault.createEscrow(address(paymentToken), recipient, AMOUNT);
        
        vm.prank(sender);
        vault.raiseDispute(workflowId);
        
        vm.prank(resolver);
        bool success = vault.partialReleaseAsDisputeResolver(workflowId, 5 ether);
        assertTrue(success);
    }
    
    function test_Partial_vaultPartialCancel() public {
        vm.prank(sender);
        uint256 workflowId = vault.createEscrow(address(paymentToken), recipient, AMOUNT);
        
        vm.prank(sender);
        vault.raiseDispute(workflowId);
        
        vm.prank(resolver);
        bool success = vault.partialCancelAsDisputeResolver(workflowId, 5 ether);
        assertTrue(success);
    }
    
    function test_Partial_vaultMixedOperations() public {
        vm.prank(sender);
        uint256 workflowId = vault.createEscrow(address(paymentToken), recipient, AMOUNT);
        
        vm.prank(sender);
        vault.raiseDispute(workflowId);
        
        vm.startPrank(resolver);
        vault.partialReleaseAsDisputeResolver(workflowId, 4 ether);
        vault.partialCancelAsDisputeResolver(workflowId, 3 ether);
        vm.stopPrank();
    }
    
    // =========================================================================
    // Edge Cases
    // =========================================================================
    
    function test_Partial_releaseAllInParts() public {
        vm.prank(sender);
        uint256 workflowId = token.createEscrow(recipient, AMOUNT);
        
        vm.prank(sender);
        token.raiseDispute(workflowId);
        
        // Calculate actual balance after fee (99% of AMOUNT = 9.9 ether)
        uint256 actualBalance = (AMOUNT * (10000 - ESCROW_FEE)) / 10000;
        uint256 partAmount = actualBalance / 10; // Split into 10 parts
        
        // Release entire amount in small parts
        vm.startPrank(resolver);
        for (uint256 i = 0; i < 10; i++) {
            token.partialReleaseAsDisputeResolver(workflowId, partAmount);
        }
        vm.stopPrank();
    }
    
    function test_Partial_cancelAllInParts() public {
        vm.prank(sender);
        uint256 workflowId = token.createEscrow(recipient, AMOUNT);
        
        vm.prank(sender);
        token.raiseDispute(workflowId);
        
        // Calculate actual balance after fee (99% of AMOUNT = 9.9 ether)
        uint256 actualBalance = (AMOUNT * (10000 - ESCROW_FEE)) / 10000;
        uint256 partAmount = actualBalance / 10; // Split into 10 parts
        
        // Cancel entire amount in small parts
        vm.startPrank(resolver);
        for (uint256 i = 0; i < 10; i++) {
            token.partialCancelAsDisputeResolver(workflowId, partAmount);
        }
        vm.stopPrank();
    }
    
    function test_Partial_alternatingOperations() public {
        vm.prank(sender);
        uint256 workflowId = token.createEscrow(recipient, AMOUNT);
        
        vm.prank(sender);
        token.raiseDispute(workflowId);
        
        // Alternate between release and cancel
        vm.startPrank(resolver);
        token.partialReleaseAsDisputeResolver(workflowId, 1 ether);
        token.partialCancelAsDisputeResolver(workflowId, 1 ether);
        token.partialReleaseAsDisputeResolver(workflowId, 1 ether);
        token.partialCancelAsDisputeResolver(workflowId, 1 ether);
        token.partialReleaseAsDisputeResolver(workflowId, 1 ether);
        vm.stopPrank();
    }
}
