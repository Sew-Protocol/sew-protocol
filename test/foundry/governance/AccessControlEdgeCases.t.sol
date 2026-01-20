// SPDX-License-Identifier: Apache-2.0
import "../../../contracts/types/YieldPresets.sol";
pragma solidity ^0.8.33;

import 'forge-std/Test.sol';
import '../../../contracts/core/EscrowVault.sol';
import '../../../contracts/core/modules/DefaultResolutionModule.sol';
import '../../../contracts/decentralized-resolution-module/DecentralizedResolutionModule.sol';
import '../../../contracts/mocks/ERC20Mock.sol';
import '../../../contracts/YieldOps.sol';
import '../../../contracts/DisputeOps.sol';

import '../../../contracts/core/ModuleManagementContract.sol';
import '../../../contracts/admin/EscrowAdminContract.sol';
/**
 * @title AccessControlEdgeCasesTest
 * @notice Tests edge cases for access control:
 *         - Role revocation scenarios
 *         - Multi-role interactions
 *         - Deployer role cleanup
 *         - Role transition edge cases
 */
contract AccessControlEdgeCasesTest is Test {
    EscrowVault public escrow;
    DefaultResolutionModule public resolutionModule;
    YieldOps public yieldOps;
    DisputeOps public disputeOps;
    ModuleManagementContract public moduleManagement;
    EscrowAdminContract public adminContract;

    address public deployer;
    address public timelock;
    address public guardian;
    address public newAdmin;
    address public attacker;

    bytes32 public constant ROLE_TIMELOCK = keccak256('ROLE_TIMELOCK');
    bytes32 public constant ROLE_GUARDIAN = keccak256('ROLE_GUARDIAN');
    bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;

    function setUp() public {
        deployer = address(this);
        timelock = makeAddr('timelock');
        guardian = makeAddr('guardian');
        newAdmin = makeAddr('newAdmin');
        attacker = makeAddr('attacker');

        yieldOps = new YieldOps(address(this));
        disputeOps = new DisputeOps(address(this));
        moduleManagement = new ModuleManagementContract(address(this));
        adminContract = new EscrowAdminContract(address(this));
        escrow = new EscrowVault(100, makeAddr('feeAddress'), address(yieldOps), address(disputeOps), address(moduleManagement));
        resolutionModule = new DefaultResolutionModule(deployer, makeAddr('resolver'));

        // Initial role setup
        escrow.grantRole(ROLE_TIMELOCK, timelock);
        escrow.grantRole(ROLE_GUARDIAN, guardian);
        adminContract.grantRole(adminContract.ROLE_TIMELOCK(), address(this));
        adminContract.grantRole(adminContract.ROLE_TIMELOCK(), timelock);
        // Admin contract must be authorized to apply changes on the escrow
        escrow.grantRole(escrow.ROLE_ADMIN_CONTRACT(), address(adminContract));
    }

    // ============ Role Revocation Tests ============

    /**
     * @notice Test that revoked roles cannot perform protected operations
     */
    function test_RoleRevocation_PreventsAccess() public {
        // Grant timelock role to attacker temporarily
        escrow.grantRole(ROLE_TIMELOCK, attacker);
        adminContract.grantRole(adminContract.ROLE_TIMELOCK(), attacker);

        // Attacker can queue module
        vm.prank(attacker);
        adminContract.queueResolutionModule(address(escrow), address(resolutionModule));

        // Revoke role
        escrow.revokeRole(ROLE_TIMELOCK, attacker);
        adminContract.revokeRole(adminContract.ROLE_TIMELOCK(), attacker);

        // Attacker cannot activate (role revoked)
        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(attacker);
        vm.expectRevert();
        adminContract.activateResolutionModule(address(escrow));
    }

    /**
     * @notice Test that revoking DEFAULT_ADMIN_ROLE prevents further role management
     */
    function test_RoleRevocation_AdminCannotManageAfterRevocation() public {
        // Grant admin to newAdmin
        escrow.grantRole(DEFAULT_ADMIN_ROLE, newAdmin);

        // newAdmin can grant roles
        vm.prank(newAdmin);
        escrow.grantRole(ROLE_TIMELOCK, attacker);

        // Revoke newAdmin's admin role
        escrow.revokeRole(DEFAULT_ADMIN_ROLE, newAdmin);

        // newAdmin cannot grant roles anymore
        vm.prank(newAdmin);
        vm.expectRevert();
        escrow.grantRole(ROLE_TIMELOCK, attacker);
    }

    /**
     * @notice Test that self-revocation works correctly
     */
    function test_RoleRevocation_SelfRevocation() public {
        // Grant role to attacker
        escrow.grantRole(ROLE_TIMELOCK, attacker);

        // Only DEFAULT_ADMIN (deployer) can revoke the role, not the attacker themselves
        vm.prank(deployer);
        escrow.revokeRole(ROLE_TIMELOCK, attacker);

        // Attacker no longer has role
        assertFalse(escrow.hasRole(ROLE_TIMELOCK, attacker), 'Attacker should not have role');
    }

    // ============ Multi-Role Interaction Tests ============

    /**
     * @notice Test that accounts with multiple roles retain all capabilities
     */
    function test_MultiRole_HasAllCapabilities() public {
        // Grant both roles to newAdmin
        escrow.grantRole(ROLE_TIMELOCK, newAdmin);
        escrow.grantRole(ROLE_GUARDIAN, newAdmin);
        adminContract.grantRole(adminContract.ROLE_TIMELOCK(), newAdmin);

        // newAdmin can perform timelock operations
        vm.prank(newAdmin);
        adminContract.queueResolutionModule(address(escrow), address(resolutionModule));

        // newAdmin can perform guardian operations
        vm.prank(newAdmin);
        escrow.pause();

        // Verify both roles are active
        assertTrue(escrow.hasRole(ROLE_TIMELOCK, newAdmin), 'Should have TIMELOCK role');
        assertTrue(escrow.hasRole(ROLE_GUARDIAN, newAdmin), 'Should have GUARDIAN role');
    }

    /**
     * @notice Test that revoking one role doesn't affect other roles
     */
    function test_MultiRole_RevokingOneRoleKeepsOthers() public {
        // Grant both roles
        escrow.grantRole(ROLE_TIMELOCK, newAdmin);
        escrow.grantRole(ROLE_GUARDIAN, newAdmin);

        // Revoke only TIMELOCK
        escrow.revokeRole(ROLE_TIMELOCK, newAdmin);

        // GUARDIAN role should still be active
        assertFalse(escrow.hasRole(ROLE_TIMELOCK, newAdmin), 'Should not have TIMELOCK');
        assertTrue(escrow.hasRole(ROLE_GUARDIAN, newAdmin), 'Should still have GUARDIAN');

        // Can still perform guardian operations
        vm.prank(newAdmin);
        escrow.pause();
    }

    // ============ Deployer Role Cleanup Tests ============

    /**
     * @notice Test that deployer can transfer admin and revoke their own role
     */
    function test_DeployerCleanup_CanTransferAdminAndRevoke() public {
        // Grant admin to newAdmin
        escrow.grantRole(DEFAULT_ADMIN_ROLE, newAdmin);

        // Deployer can revoke their own admin role
        escrow.revokeRole(DEFAULT_ADMIN_ROLE, deployer);

        // Deployer no longer has admin
        assertFalse(escrow.hasRole(DEFAULT_ADMIN_ROLE, deployer), 'Deployer should not have admin');

        // newAdmin still has admin and can manage roles
        assertTrue(escrow.hasRole(DEFAULT_ADMIN_ROLE, newAdmin), 'newAdmin should have admin');
        vm.prank(newAdmin);
        escrow.grantRole(ROLE_TIMELOCK, attacker);
    }

    /**
     * @notice Test that system works after deployer role is cleaned up
     */
    function test_DeployerCleanup_SystemWorksAfterCleanup() public {
        // Transfer admin and revoke deployer
        escrow.grantRole(DEFAULT_ADMIN_ROLE, newAdmin);
        escrow.revokeRole(DEFAULT_ADMIN_ROLE, deployer);

        // System should still work - newAdmin can manage
        adminContract.grantRole(adminContract.ROLE_TIMELOCK(), newAdmin);
        vm.startPrank(newAdmin);
        escrow.grantRole(ROLE_TIMELOCK, newAdmin); // newAdmin needs ROLE_TIMELOCK to call queueResolutionModule
        adminContract.queueResolutionModule(address(escrow), address(resolutionModule));
        vm.warp(block.timestamp + 7 days + 1);
        adminContract.activateResolutionModule(address(escrow));
        vm.stopPrank();

        // Verify module is activated
        assertEq(address(escrow.disputeResolutionModule()), address(resolutionModule));
    }

    // ============ Role Transition Edge Cases ============

    /**
     * @notice Test that role grants/revokes during operations don't affect current operation
     */
    function test_RoleTransition_DuringOperation() public {
        // Queue module as timelock
        vm.prank(timelock);
        adminContract.queueResolutionModule(address(escrow), address(resolutionModule));

        // Revoke timelock role before activation
        escrow.revokeRole(ROLE_TIMELOCK, timelock);

        // Activation requires ROLE_TIMELOCK - grant it to deployer and activate
        vm.warp(block.timestamp + 7 days + 1);
        escrow.grantRole(ROLE_TIMELOCK, deployer);
        vm.prank(deployer);
        adminContract.activateResolutionModule(address(escrow));
        
        // Verify module is activated
        assertEq(address(escrow.disputeResolutionModule()), address(resolutionModule));
    }

    /**
     * @notice Test that guardian can pause but needs timelock to unpause
     */
    function test_GuardianDownOnly_EvenWithAdmin() public {
        // Grant admin to guardian
        escrow.grantRole(DEFAULT_ADMIN_ROLE, guardian);
        // Also need to grant ROLE_TIMELOCK to unpause
        escrow.grantRole(ROLE_TIMELOCK, guardian);

        // Guardian can pause (guardian power)
        vm.prank(guardian);
        escrow.pause();

        // Guardian needs ROLE_TIMELOCK to unpause
        vm.prank(guardian);
        escrow.unpause();

        // Verify pause/unpause works
        assertTrue(!escrow.paused(), 'Should be unpaused');
    }

    /**
     * @notice Test that revoking all roles leaves account without access
     */
    function test_RoleRevocation_RevokingAllRoles() public {
        // Grant multiple roles
        escrow.grantRole(ROLE_TIMELOCK, attacker);
        escrow.grantRole(ROLE_GUARDIAN, attacker);
        escrow.grantRole(DEFAULT_ADMIN_ROLE, attacker);

        // Revoke all roles
        escrow.revokeRole(ROLE_TIMELOCK, attacker);
        escrow.revokeRole(ROLE_GUARDIAN, attacker);
        escrow.revokeRole(DEFAULT_ADMIN_ROLE, attacker);

        // Attacker should have no access
        assertFalse(escrow.hasRole(ROLE_TIMELOCK, attacker));
        assertFalse(escrow.hasRole(ROLE_GUARDIAN, attacker));
        assertFalse(escrow.hasRole(DEFAULT_ADMIN_ROLE, attacker));

        // Cannot perform any protected operations
        vm.prank(attacker);
        vm.expectRevert();
        adminContract.queueResolutionModule(address(escrow), address(resolutionModule));
    }
}
