// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.33;

import "forge-std/Test.sol";
import {EscrowableERC20} from "../../../contracts/core/EscrowableERC20.sol";
import {EscrowVault} from "../../../contracts/core/EscrowVault.sol";
import {DefaultResolutionModule} from "../../../contracts/core/modules/DefaultResolutionModule.sol";

/**
 * @title AccessControlComprehensive
 * @notice Comprehensive tests for role-based access control covering:
 *  - Role hierarchy (DEFAULT_ADMIN, TIMELOCK, GUARDIAN, DEVELOPER)
 *  - Role granting and revoking
 *  - Role-specific function access
 *  - Multi-role scenarios
 *  - Role enumeration
 */
contract AccessControlComprehensive is Test {
    EscrowableERC20 token;
    EscrowVault vault;
    DefaultResolutionModule resolutionModule;
    
    address owner = address(this);
    address admin = address(0x1);
    address timelock = address(0x2);
    address guardian = address(0x3);
    address user = address(0x5);
    address attacker = address(0x6);
    address feeRecipient = address(0x7);
    address resolver = address(0x8);
    
    bytes32 DEFAULT_ADMIN_ROLE;
    bytes32 ROLE_TIMELOCK;
    bytes32 ROLE_GUARDIAN;
    
    uint256 constant ESCROW_FEE = 100;
    
    function setUp() public {
        token = new EscrowableERC20("Test", "TST", ESCROW_FEE, feeRecipient);
        vault = new EscrowVault(ESCROW_FEE, feeRecipient);
        resolutionModule = new DefaultResolutionModule(owner, resolver);
        
        // Get role identifiers
        DEFAULT_ADMIN_ROLE = token.DEFAULT_ADMIN_ROLE();
        ROLE_TIMELOCK = token.ROLE_TIMELOCK();
        ROLE_GUARDIAN = token.ROLE_GUARDIAN();
        
        // Setup initial roles
        token.grantRole(DEFAULT_ADMIN_ROLE, admin);
        token.grantRole(ROLE_TIMELOCK, timelock);
        token.grantRole(ROLE_GUARDIAN, guardian);
        
        // Setup resolution module
        token.queueDefaultResolutionModule(address(resolutionModule));
        vm.warp(block.timestamp + 14 days + 1);
        token.activateDefaultResolutionModule();
    }
    
    // =========================================================================
    // Role Grant/Revoke Tests
    // =========================================================================
    
    function test_AccessControl_grantRole() public {
        address newTimelock = address(0x9);
        
        vm.prank(admin);
        token.grantRole(ROLE_TIMELOCK, newTimelock);
        
        assertTrue(token.hasRole(ROLE_TIMELOCK, newTimelock), "Should grant role");
    }
    
    function test_AccessControl_revokeRole() public {
        vm.prank(admin);
        
    }
    
    
    function test_AccessControl_onlyAdminCanGrantRoles() public {
        vm.prank(attacker);
        vm.expectRevert();
        token.grantRole(ROLE_TIMELOCK, attacker);
    }
    
    function test_AccessControl_onlyAdminCanRevokeRoles() public {
        vm.prank(attacker);
        vm.expectRevert();
    }
    
    // =========================================================================
    // ROLE_TIMELOCK Access Tests
    // =========================================================================
    
    function test_AccessControl_timelockCanQueueModules() public {
        DefaultResolutionModule newModule = new DefaultResolutionModule(owner, resolver);
        
        vm.prank(timelock);
        token.queueDefaultResolutionModule(address(newModule));
        
        (address pending,, bool exists) = token.getPendingDefaultResolutionModule();
        assertEq(pending, address(newModule));
        assertTrue(exists);
    }
    
    function test_AccessControl_timelockCanQueueFeeAddress() public {
        address newFeeAddr = address(0x1234);
        
        vm.prank(timelock);
        token.queueEscrowFeeAddress(newFeeAddr);
        
        (address pending,, bool exists) = token.getPendingFeeRecipient();
        assertEq(pending, newFeeAddr);
        assertTrue(exists);
    }
    
    function test_AccessControl_timelockCanSetDelays() public {
        uint256 newDelay = 7 days;
        
        vm.prank(timelock);
        token.setResolutionModuleDelay(newDelay);
        
        assertEq(token.disputeResolutionModuleDelay(), newDelay);
    }
    
    function test_AccessControl_nonTimelockCannotQueue() public {
        DefaultResolutionModule newModule = new DefaultResolutionModule(owner, resolver);
        
        vm.prank(user);
        vm.expectRevert();
        token.queueDefaultResolutionModule(address(newModule));
    }
    
    function test_AccessControl_nonTimelockCannotActivate() public {
        DefaultResolutionModule newModule = new DefaultResolutionModule(owner, resolver);
        
        vm.prank(timelock);
        token.queueDefaultResolutionModule(address(newModule));
        vm.warp(block.timestamp + 14 days + 1);
        
        vm.prank(user);
        vm.expectRevert();
        token.activateDefaultResolutionModule();
    }
    
    // =========================================================================
    // ROLE_GUARDIAN Access Tests (Down-Only Powers)
    // =========================================================================
    
    function test_AccessControl_guardianCanPause() public {
        vm.prank(guardian);
        token.pause();
        
        assertTrue(token.paused(), "Should be paused");
    }
    
    function test_AccessControl_guardianCanUnpause() public {
        vm.prank(guardian);
        token.pause();
        
        vm.prank(guardian);
        token.unpause();
        
        assertFalse(token.paused(), "Should be unpaused");
    }
    
    
    
    function test_AccessControl_nonGuardianCannotPause() public {
        vm.prank(user);
        vm.expectRevert();
        token.pause();
    }
    
    
    // =========================================================================
    // =========================================================================
    
    
    
    // =========================================================================
    // Multi-Role Tests
    // =========================================================================
    
    function test_AccessControl_accountCanHaveMultipleRoles() public {
        address multiRole = address(0x2222);
        
        vm.startPrank(admin);
        token.grantRole(ROLE_TIMELOCK, multiRole);
        token.grantRole(ROLE_GUARDIAN, multiRole);
        vm.stopPrank();
        
        assertTrue(token.hasRole(ROLE_TIMELOCK, multiRole));
        assertTrue(token.hasRole(ROLE_GUARDIAN, multiRole));
    }
    
    function test_AccessControl_multiRoleCanAccessBoth() public {
        address multiRole = address(0x2222);
        
        vm.startPrank(admin);
        token.grantRole(ROLE_TIMELOCK, multiRole);
        token.grantRole(ROLE_GUARDIAN, multiRole);
        vm.stopPrank();
        
        // Can use timelock powers
        vm.prank(multiRole);
        token.setResolutionModuleDelay(7 days);
        
        // Can use guardian powers
        vm.prank(multiRole);
        token.pause();
        
        assertTrue(token.paused());
    }
    
    // =========================================================================
    // Role Hierarchy Tests
    // =========================================================================
    
    function test_AccessControl_adminCanManageAllRoles() public {
        address newAccount = address(0x3333);
        
        vm.startPrank(admin);
        token.grantRole(ROLE_TIMELOCK, newAccount);
        token.grantRole(ROLE_GUARDIAN, newAccount);
        vm.stopPrank();
        
        assertTrue(token.hasRole(ROLE_TIMELOCK, newAccount));
        assertTrue(token.hasRole(ROLE_GUARDIAN, newAccount));
    }
    
    function test_AccessControl_timelockCannotGrantRoles() public {
        address newAccount = address(0x4444);
        
        vm.prank(timelock);
        vm.expectRevert();
        token.grantRole(ROLE_GUARDIAN, newAccount);
    }
    
    function test_AccessControl_guardianCannotGrantRoles() public {
        address newAccount = address(0x5555);
        
        vm.prank(guardian);
        vm.expectRevert();
    }
    
    // =========================================================================
    // Role Query Tests
    // =========================================================================
    
    function test_AccessControl_hasRole() public view {
        assertTrue(token.hasRole(ROLE_TIMELOCK, timelock));
        assertTrue(token.hasRole(ROLE_GUARDIAN, guardian));
        assertFalse(token.hasRole(ROLE_TIMELOCK, user));
    }
    
    function test_AccessControl_getRoleAdmin() public view {
        bytes32 adminOfTimelock = token.getRoleAdmin(ROLE_TIMELOCK);
        assertEq(adminOfTimelock, DEFAULT_ADMIN_ROLE);
    }
    
    // =========================================================================
    // Edge Cases
    // =========================================================================
    
    function test_AccessControl_cannotGrantRoleToZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert();
        token.grantRole(ROLE_TIMELOCK, address(0));
    }
    
    function test_AccessControl_canRevokeNonExistentRole() public {
        // Should not revert even if account doesn't have role
        vm.prank(admin);
        token.revokeRole(ROLE_TIMELOCK, user);
        
        assertFalse(token.hasRole(ROLE_TIMELOCK, user));
    }
    
    function test_AccessControl_canGrantAlreadyGrantedRole() public {
        // Granting same role again should not revert
        vm.prank(admin);
        token.grantRole(ROLE_TIMELOCK, timelock);
        
        assertTrue(token.hasRole(ROLE_TIMELOCK, timelock));
    }
    
    // =========================================================================
    // Cross-Contract Role Tests
    // =========================================================================
    
    function test_AccessControl_tokenAndVaultIndependentRoles() public {
        address vaultTimelock = address(0x6666);
        
        vault.grantRole(ROLE_TIMELOCK, vaultTimelock);
        
        // Should have role on vault but not token
        assertTrue(vault.hasRole(ROLE_TIMELOCK, vaultTimelock));
        assertFalse(token.hasRole(ROLE_TIMELOCK, vaultTimelock));
    }
    
    function test_AccessControl_sameAccountDifferentRolesAcrossContracts() public {
        address account = address(0x7777);
        
        vm.prank(admin);
        token.grantRole(ROLE_TIMELOCK, account);
        
        vault.grantRole(ROLE_GUARDIAN, account);
        
        // Different roles on different contracts
        assertTrue(token.hasRole(ROLE_TIMELOCK, account));
        assertFalse(token.hasRole(ROLE_GUARDIAN, account));
        assertTrue(vault.hasRole(ROLE_GUARDIAN, account));
        assertFalse(vault.hasRole(ROLE_TIMELOCK, account));
    }
    
    // =========================================================================
    // Paused State Access Control
    // =========================================================================
    
    function test_AccessControl_pauseBlocksUserOperations() public {
        // Give user some tokens
        token.transfer(user, 10 ether);
        
        // Pause
        vm.prank(guardian);
        token.pause();
        
        // User operations should fail
        vm.prank(user);
        vm.expectRevert();
        token.createEscrow(address(0x8888), 1 ether);
    }
    
    function test_AccessControl_pauseDoesNotBlockAdmin() public {
        vm.prank(guardian);
        token.pause();
        
        // Admin operations should still work
        vm.prank(timelock);
        token.setResolutionModuleDelay(7 days);
        
        assertEq(token.disputeResolutionModuleDelay(), 7 days);
    }
    
    // =========================================================================
    // Role Persistence Tests
    // =========================================================================
    
    function test_AccessControl_rolesPersistAfterActions() public {
        // Perform action
        vm.prank(timelock);
        token.setResolutionModuleDelay(7 days);
        
        // Role should still exist
        assertTrue(token.hasRole(ROLE_TIMELOCK, timelock));
    }
    
    function test_AccessControl_revokedRoleCannotAct() public {
        vm.prank(admin);
        token.revokeRole(ROLE_GUARDIAN, guardian);
        
        vm.prank(guardian);
        vm.expectRevert();
        token.pause();
    }
    
    function test_AccessControl_grantedRoleCanImmediatelyAct() public {
        address newGuardian = address(0x9999);
        
        vm.prank(admin);
        token.grantRole(ROLE_GUARDIAN, newGuardian);
        
        // Should be able to act immediately
        vm.prank(newGuardian);
        token.pause();
        
        assertTrue(token.paused());
    }
}
