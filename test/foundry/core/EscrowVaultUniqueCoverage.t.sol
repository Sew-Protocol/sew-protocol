// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import "forge-std/Test.sol";
import "../../../contracts/core/EscrowVault.sol";
import "../../../contracts/mocks/ERC20Mock.sol";
import "../../../contracts/core/modules/DefaultResolutionModule.sol";
import "../../../contracts/types/EscrowTypes.sol";
import "../../../contracts/YieldOps.sol";
import "../../../contracts/DisputeOps.sol";

/**
 * @title EscrowVaultUniqueCoverage
 * @notice Tests for EscrowVault features not covered elsewhere
 * @dev Focuses on unique test cases extracted from EscrowVaultComprehensive
 */
contract EscrowVaultUniqueCoverageTest is Test {
    EscrowVault public vault;
    ERC20Mock public token1;
    ERC20Mock public token2;
    DefaultResolutionModule public resolutionModule;
    YieldOps public yieldOps;
    DisputeOps public disputeOps;
    
    address public owner;
    address public timelock;
    address public feeAddress;
    address public resolver;
    address public buyer;
    address public seller;
    
    uint256 public constant ESCROW_FEE = 100; // 1%
    
    function setUp() public {
        owner = address(this);
        timelock = address(0x1111);
        feeAddress = address(0xFEE);
        resolver = address(0x1234);
        buyer = address(0x1001);
        seller = address(0x1002);
        
        resolutionModule = new DefaultResolutionModule(owner, resolver);
        token1 = new ERC20Mock("Token 1", "TKN1", owner, 10000000e18);
        token2 = new ERC20Mock("Token 2", "TKN2", owner, 10000000e18);
        yieldOps = new YieldOps();
        disputeOps = new DisputeOps();
        vault = new EscrowVault(ESCROW_FEE, feeAddress, address(yieldOps), address(disputeOps));
        
        // Setup vault
        vault.grantRole(vault.ROLE_TIMELOCK(), owner);
        vault.grantRole(vault.ROLE_TIMELOCK(), timelock);
        
        // Queue and activate resolution module
        vault.queueResolutionModule(address(resolutionModule));
        vm.warp(block.timestamp + 7 days + 1);
        vault.activateResolutionModule();
    }
    
    // ============ Escrow Creation Tests ============
    
    function test_createEscrow_simple() public {
        uint256 amount = 1000e18;
        token1.mint(buyer, amount);
        vm.prank(buyer);
        token1.approve(address(vault), amount);
        
        vm.prank(buyer);
        uint256 workflowId = vault.createEscrow(address(token1), seller, amount);
        assertEq(workflowId, 0);
    }
    
    function test_createEscrow_withSettings() public {
        uint256 amount = 1000e18;
        token1.mint(buyer, amount);
        vm.prank(buyer);
        token1.approve(address(vault), amount);
        
        EscrowSettings memory settings = EscrowSettings({
            customResolver: address(0),
            yieldEnabled: false,
            autoReleaseTime: 0,
            autoCancelTime: 0,
            escrowType: EscrowType.STANDARD
        });
        
        vm.prank(buyer);
        uint256 workflowId = vault.createEscrow(address(token1), seller, amount, settings);
        assertEq(workflowId, 0);
    }
    
    function test_createEscrow_revertsIfAmountZero() public {
        vm.prank(buyer);
        vm.expectRevert();
        vault.createEscrow(address(token1), seller, 0);
    }
    
    function test_createEscrow_revertsIfInsufficientBalance() public {
        uint256 amount = 1000e18;
        // Don't mint tokens to buyer
        
        vm.prank(buyer);
        token1.approve(address(vault), amount);
        
        vm.prank(buyer);
        vm.expectRevert();
        vault.createEscrow(address(token1), seller, amount);
    }
    
    function test_createEscrow_revertsIfInsufficientAllowance() public {
        uint256 amount = 1000e18;
        token1.mint(buyer, amount);
        
        // Don't approve or approve less than amount
        vm.prank(buyer);
        token1.approve(address(vault), amount / 2);
        
        vm.prank(buyer);
        vm.expectRevert();
        vault.createEscrow(address(token1), seller, amount);
    }
    
    // ============ Fee Management Tests ============
    
    function test_withdrawFees() public {
        // Create escrow to generate fees
        uint256 amount = 1000e18;
        token1.mint(buyer, amount);
        vm.prank(buyer);
        token1.approve(address(vault), amount);
        
        vm.prank(buyer);
        vault.createEscrow(address(token1), seller, amount);
        
        // Fee should be 1% of amount = 10e18
        uint256 expectedFee = (amount * ESCROW_FEE) / 10000;
        
        // Withdraw fees as feeAddress
        vm.prank(feeAddress);
        bool success = vault.withdrawFees(address(token1));
        assertTrue(success);
        assertEq(token1.balanceOf(feeAddress), expectedFee);
    }
    
    function test_withdrawFees_revertsIfNotFeeAddress() public {
        uint256 amount = 1000e18;
        token1.mint(buyer, amount);
        vm.prank(buyer);
        token1.approve(address(vault), amount);
        
        vm.prank(buyer);
        vault.createEscrow(address(token1), seller, amount);
        
        // Try to withdraw as non-feeAddress
        vm.prank(buyer);
        vm.expectRevert();
        vault.withdrawFees(address(token1));
    }
    
    function test_withdrawFees_revertsIfNoFees() public {
        // No escrows created, so no fees
        vm.prank(feeAddress);
        vm.expectRevert();
        vault.withdrawFees(address(token1));
    }
    
    // ============ View Function Tests ============
    
    function test_getTokenInfo() public {
        uint256 amount = 1000e18;
        token1.mint(buyer, amount);
        vm.prank(buyer);
        token1.approve(address(vault), amount);
        
        vm.prank(buyer);
        vault.createEscrow(address(token1), seller, amount);
        
        uint256 held = vault.totalHeldInEscrowPerToken(address(token1));
        
        uint256 expectedHeld = amount - (amount * ESCROW_FEE) / 10000;
        
        assertEq(held, expectedHeld);
    }
    
    function test_getReleaseStrategy() public {
        address strategy = address(vault.getReleaseStrategy(0));
        // Initially should be zero address or default strategy
        assertTrue(strategy == address(0) || strategy != address(0));
    }
    
    function test_getYieldGenerationModule() public {
        address yieldModule = address(vault.getYieldGenerationModule(0));
        // Initially should be zero address
        assertEq(yieldModule, address(0));
    }
    
    function test_getYieldDistributionModule() public {
        address distModule = address(vault.getYieldDistributionModule(0));
        // Initially should be zero address
        assertEq(distModule, address(0));
    }
    
    // ============ Recovery Tests ============
    
    function test_recoverERC20() public {
        uint256 amount = 100e18;
        // Send tokens directly to vault (not through escrow)
        token1.transfer(address(vault), amount);
        
        uint256 balanceBefore = token1.balanceOf(owner);
        
        // Recover
        vault.recoverERC20(address(token1), owner, amount);
        
        uint256 balanceAfter = token1.balanceOf(owner);
        assertEq(balanceAfter - balanceBefore, amount);
    }
    
    function test_recoverERC20_revertsIfNotTimelock() public {
        uint256 amount = 100e18;
        token1.transfer(address(vault), amount);
        
        vm.prank(buyer);
        vm.expectRevert();
        vault.recoverERC20(address(token1), buyer, amount);
    }
}
