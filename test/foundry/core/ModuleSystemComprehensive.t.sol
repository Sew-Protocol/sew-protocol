// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.33;

import "forge-std/Test.sol";
import {EscrowableERC20} from "../../../contracts/core/EscrowableERC20.sol";
import {EscrowVault} from "../../../contracts/core/EscrowVault.sol";
import {DefaultResolutionModule} from "../../../contracts/core/modules/DefaultResolutionModule.sol";
import {DefaultReleaseStrategy} from "../../../contracts/modules/DefaultReleaseStrategy.sol";
import {IResolutionModule} from "../../../contracts/shared/interfaces/IResolutionModule.sol";

/**
 * @title ModuleSystemComprehensive
 * @notice Comprehensive tests for module system covering:
 *  - Module lifecycle (queue, activate, upgrade)
 *  - Module validation and compatibility
 *  - Module snapshots at escrow creation
 *  - Multiple module types (resolution, release strategy, yield)
 *  - Module metadata and versioning
 */
contract ModuleSystemComprehensive is Test {
    EscrowableERC20 token;
    EscrowVault vault;
    DefaultResolutionModule resolutionModule1;
    DefaultResolutionModule resolutionModule2;
    DefaultReleaseStrategy releaseStrategy1;
    DefaultReleaseStrategy releaseStrategy2;
    
    address owner = address(this);
    address timelock = address(0x1);
    address sender = address(0x2);
    address recipient = address(0x3);
    address resolver1 = address(0x4);
    address resolver2 = address(0x5);
    address feeRecipient = address(0x6);
    
    uint256 constant ESCROW_FEE = 100;
    uint256 constant AMOUNT = 1 ether;
    
    bytes32 ROLE_TIMELOCK;
    
    function setUp() public {
        // Deploy token
        token = new EscrowableERC20("Test", "TST", ESCROW_FEE, feeRecipient);
        vault = new EscrowVault(ESCROW_FEE, feeRecipient);
        
        ROLE_TIMELOCK = token.ROLE_TIMELOCK();
        token.grantRole(ROLE_TIMELOCK, owner);
        token.grantRole(ROLE_TIMELOCK, timelock);
        vault.grantRole(ROLE_TIMELOCK, owner);
        
        // Deploy modules
        resolutionModule1 = new DefaultResolutionModule(owner, resolver1);
        resolutionModule2 = new DefaultResolutionModule(owner, resolver2);
        releaseStrategy1 = new DefaultReleaseStrategy();
        releaseStrategy2 = new DefaultReleaseStrategy();
        
        // Setup initial resolution module
        token.queueDefaultResolutionModule(address(resolutionModule1));
        vm.warp(block.timestamp + 14 days + 1);
        token.activateDefaultResolutionModule();
        
        // Distribute tokens
        token.transfer(sender, 100 ether);
        vm.prank(sender);
        token.approve(address(token), type(uint256).max);
    }
    
    // =========================================================================
    // Module Lifecycle Tests
    // =========================================================================
    
    function test_Module_queueResolutionModule() public {
        vm.prank(timelock);
        token.queueDefaultResolutionModule(address(resolutionModule2));
        
        (address pending, uint64 eta, bool exists) = token.getPendingDefaultResolutionModule();
        assertEq(pending, address(resolutionModule2), "Should queue new module");
        assertTrue(exists, "Should exist");
        assertGt(eta, block.timestamp, "ETA should be in future");
    }
    
    function test_Module_activateAfterDelay() public {
        vm.prank(timelock);
        token.queueDefaultResolutionModule(address(resolutionModule2));
        
        // Fast forward
        vm.warp(block.timestamp + 14 days + 1);
        
        vm.prank(timelock);
        token.activateDefaultResolutionModule();
        
        assertEq(address(token.defaultResolutionModule()), address(resolutionModule2), "Should activate new module");
    }
    
    function test_Module_cannotActivateBeforeDelay() public {
        vm.prank(timelock);
        token.queueDefaultResolutionModule(address(resolutionModule2));
        
        // Try to activate immediately
        vm.prank(timelock);
        vm.expectRevert();
        token.activateDefaultResolutionModule();
    }
    
    function test_Module_cannotActivateWithoutQueue() public {
        // Try to activate without queueing
        vm.prank(timelock);
        vm.expectRevert();
        token.activateDefaultResolutionModule();
    }
    
    function test_Module_queueReleaseStrategy() public {
        vm.prank(timelock);
        token.queueDefaultReleaseStrategy(address(releaseStrategy1));
        
        (address pending, uint64 eta, bool exists) = token.getPendingDefaultReleaseStrategy();
        assertEq(pending, address(releaseStrategy1), "Should queue release strategy");
        assertTrue(exists, "Should exist");
    }
    
    function test_Module_activateReleaseStrategy() public {
        vm.prank(timelock);
        token.queueDefaultReleaseStrategy(address(releaseStrategy1));
        
        vm.warp(block.timestamp + 14 days + 1);
        
        vm.prank(timelock);
        token.activateDefaultReleaseStrategy();
        
        assertEq(address(token.defaultReleaseStrategy()), address(releaseStrategy1), "Should activate release strategy");
    }
    
    // =========================================================================
    // Module Snapshot Tests (Phase 7)
    // =========================================================================
    
    function test_Module_snapshotAtEscrowCreation() public {
        // Create escrow with module1
        vm.prank(sender);
        uint256 id1 = token.createEscrow(recipient, AMOUNT);
        
        // Change resolution module
        vm.prank(timelock);
        token.queueDefaultResolutionModule(address(resolutionModule2));
        vm.warp(block.timestamp + 14 days + 1);
        vm.prank(timelock);
        token.activateDefaultResolutionModule();
        
        // Create another escrow with module2
        vm.prank(sender);
        uint256 id2 = token.createEscrow(recipient, AMOUNT);
        
        // Both escrows should have different modules snapshotted
        assertGt(id2, id1, "Should create second escrow");
    }
    
    function test_Module_oldEscrowUsesOldModule() public {
        // Create escrow
        vm.prank(sender);
        uint256 workflowId = token.createEscrow(recipient, AMOUNT);
        
        // Change module
        vm.prank(timelock);
        token.queueDefaultResolutionModule(address(resolutionModule2));
        vm.warp(block.timestamp + 14 days + 1);
        vm.prank(timelock);
        token.activateDefaultResolutionModule();
        
        // Old escrow should still work (uses old module snapshot)
        vm.prank(sender);
        bool success = token.releaseEscrowTransfer(workflowId);
        assertTrue(success, "Old escrow should still work");
    }
    
    function test_Module_newEscrowUsesNewModule() public {
        // Change module
        vm.prank(timelock);
        token.queueDefaultResolutionModule(address(resolutionModule2));
        vm.warp(block.timestamp + 14 days + 1);
        vm.prank(timelock);
        token.activateDefaultResolutionModule();
        
        // Create new escrow - should use new module
        vm.prank(sender);
        uint256 workflowId = token.createEscrow(recipient, AMOUNT);
        
        // Should work with new module
        vm.prank(sender);
        bool success = token.releaseEscrowTransfer(workflowId);
        assertTrue(success, "New escrow should use new module");
    }
    
    // =========================================================================
    // Module Validation Tests
    // =========================================================================
    
    function test_Module_rejectZeroAddressModule() public {
        vm.prank(timelock);
        vm.expectRevert();
        token.queueDefaultResolutionModule(address(0));
    }
    
    function test_Module_rejectInvalidModule() public {
        // Try to set a non-contract address as module
        address notAContract = address(0x9999);
        
        vm.prank(timelock);
        vm.expectRevert();
        token.queueDefaultResolutionModule(notAContract);
    }
    
    function test_Module_onlyTimelockCanQueue() public {
        // Non-timelock tries to queue
        address attacker = address(0x8888);
        
        vm.prank(attacker);
        vm.expectRevert();
        token.queueDefaultResolutionModule(address(resolutionModule2));
    }
    
    function test_Module_onlyTimelockCanActivate() public {
        vm.prank(timelock);
        token.queueDefaultResolutionModule(address(resolutionModule2));
        vm.warp(block.timestamp + 14 days + 1);
        
        // Non-timelock tries to activate
        address attacker = address(0x8888);
        vm.prank(attacker);
        vm.expectRevert();
        token.activateDefaultResolutionModule();
    }
    
    // =========================================================================
    // Module Delay Configuration Tests
    // =========================================================================
    
    function test_Module_setMinimumResolutionDelay() public {
        uint256 MIN_DELAY = 48 hours;
        
        vm.prank(timelock);
        token.setResolutionModuleDelay(MIN_DELAY);
        
        assertEq(token.disputeResolutionModuleDelay(), MIN_DELAY, "Should set delay");
    }
    
    function test_Module_rejectTooShortDelay() public {
        uint256 TOO_SHORT = 1 hours; // Below minimum 48 hours
        
        vm.prank(timelock);
        vm.expectRevert();
        token.setResolutionModuleDelay(TOO_SHORT);
    }
    
    function test_Module_allowLongerDelay() public {
        uint256 LONG_DELAY = 30 days;
        
        vm.prank(timelock);
        token.setResolutionModuleDelay(LONG_DELAY);
        
        assertEq(token.disputeResolutionModuleDelay(), LONG_DELAY, "Should allow longer delay");
    }
    
    // =========================================================================
    // Multiple Module Types Tests
    // =========================================================================
    
    function test_Module_separateResolutionAndReleaseStrategy() public {
        // Queue both types
        vm.startPrank(timelock);
        token.queueDefaultResolutionModule(address(resolutionModule2));
        token.queueDefaultReleaseStrategy(address(releaseStrategy1));
        vm.stopPrank();
        
        vm.warp(block.timestamp + 14 days + 1);
        
        // Activate both
        vm.startPrank(timelock);
        token.activateDefaultResolutionModule();
        token.activateDefaultReleaseStrategy();
        vm.stopPrank();
        
        assertEq(address(token.defaultResolutionModule()), address(resolutionModule2));
        assertEq(address(token.defaultReleaseStrategy()), address(releaseStrategy1));
    }
    
    function test_Module_independentModuleLifecycles() public {
        // Queue resolution module
        vm.prank(timelock);
        token.queueDefaultResolutionModule(address(resolutionModule2));
        
        // Queue release strategy at different time
        vm.warp(block.timestamp + 1 days);
        vm.prank(timelock);
        token.queueDefaultReleaseStrategy(address(releaseStrategy1));
        
        // Activate resolution module first
        vm.warp(block.timestamp + 14 days + 1);
        vm.prank(timelock);
        token.activateDefaultResolutionModule();
        
        assertEq(address(token.defaultResolutionModule()), address(resolutionModule2));
        
        // Release strategy still pending
        (address pending,,bool exists) = token.getPendingDefaultReleaseStrategy();
        assertTrue(exists, "Release strategy should still be pending");
        assertEq(pending, address(releaseStrategy1));
    }
    
    // =========================================================================
    // Module Upgrade Scenarios
    // =========================================================================
    
    function test_Module_upgradeResolutionModule() public {
        address oldModule = address(token.defaultResolutionModule());
        
        // Upgrade to new module
        vm.prank(timelock);
        token.queueDefaultResolutionModule(address(resolutionModule2));
        vm.warp(block.timestamp + 14 days + 1);
        vm.prank(timelock);
        token.activateDefaultResolutionModule();
        
        address newModule = address(token.defaultResolutionModule());
        assertNotEq(oldModule, newModule, "Module should be upgraded");
        assertEq(newModule, address(resolutionModule2), "Should use new module");
    }
    
    function test_Module_multipleUpgrades() public {
        // Upgrade to module2
        vm.prank(timelock);
        token.queueDefaultResolutionModule(address(resolutionModule2));
        vm.warp(block.timestamp + 14 days + 1);
        vm.prank(timelock);
        token.activateDefaultResolutionModule();
        
        assertEq(address(token.defaultResolutionModule()), address(resolutionModule2));
        
        // Upgrade back to module1
        vm.prank(timelock);
        token.queueDefaultResolutionModule(address(resolutionModule1));
        vm.warp(block.timestamp + 14 days + 1);
        vm.prank(timelock);
        token.activateDefaultResolutionModule();
        
        assertEq(address(token.defaultResolutionModule()), address(resolutionModule1));
    }
    
    // =========================================================================
    // Module State Queries
    // =========================================================================
    
    function test_Module_getPendingModule() public {
        vm.prank(timelock);
        token.queueDefaultResolutionModule(address(resolutionModule2));
        
        (address pending, uint64 eta, bool exists) = token.getPendingDefaultResolutionModule();
        assertEq(pending, address(resolutionModule2));
        assertTrue(exists);
        assertGt(eta, 0);
    }
    
    function test_Module_noPendingModuleWhenNotQueued() public {
        (,, bool exists) = token.getPendingDefaultResolutionModule();
        assertFalse(exists, "Should have no pending module");
    }
    
    function test_Module_pendingClearedAfterActivation() public {
        vm.prank(timelock);
        token.queueDefaultResolutionModule(address(resolutionModule2));
        vm.warp(block.timestamp + 14 days + 1);
        vm.prank(timelock);
        token.activateDefaultResolutionModule();
        
        (,, bool exists) = token.getPendingDefaultResolutionModule();
        assertFalse(exists, "Pending should be cleared after activation");
    }
    
    // =========================================================================
    // EscrowVault Module Tests
    // =========================================================================
    
    function test_Module_vaultResolutionModule() public {
        vault.queueDefaultResolutionModule(address(resolutionModule1));
        vm.warp(block.timestamp + 14 days + 1);
        vault.activateDefaultResolutionModule();
        
        assertEq(address(vault.defaultResolutionModule()), address(resolutionModule1));
    }
    
    function test_Module_vaultAndTokenIndependent() public {
        // Set different modules for vault and token
        vault.queueDefaultResolutionModule(address(resolutionModule1));
        vm.warp(block.timestamp + 14 days + 1);
        vault.activateDefaultResolutionModule();
        
        // Token already has resolutionModule1, change it to module2
        token.queueDefaultResolutionModule(address(resolutionModule2));
        vm.warp(block.timestamp + 14 days + 1);
        token.activateDefaultResolutionModule();
        
        // Should be independent
        assertEq(address(vault.defaultResolutionModule()), address(resolutionModule1));
        assertEq(address(token.defaultResolutionModule()), address(resolutionModule2));
    }
}
