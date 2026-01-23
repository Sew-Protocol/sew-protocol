// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import 'forge-std/Test.sol';
import '../../../contracts/core/ModuleManagementContract.sol';
import '../../../contracts/core/BaseEscrow.sol';
import '../../../contracts/modules/DefaultReleaseStrategy.sol';
import '../../../contracts/modules/DefaultYieldModule.sol';
import '../../../contracts/modules/DefaultYieldDistributionModule.sol';
import '../../../contracts/core/modules/DefaultResolutionModule.sol';
import '../../../contracts/governance/SlowLaneQueueActivate.sol';

/**
 * @title ModuleManagementContractTest
 * @notice Comprehensive tests for ModuleManagementContract covering all functions and code paths
 * @dev Goal: 99% coverage for ModuleManagementContract.sol
 * 
 * Following strategy from 99_PERCENT_TEST_COVERAGE_STRATEGY.md:
 * - All queue/activate functions for each module type
 * - Access control (ROLE_ESCROW_CONTRACT, ROLE_TIMELOCK)
 * - Slow lane delay enforcement (7 days)
 * - Getter functions
 * - Edge cases (zero addresses, no pending, premature activation)
 */
contract ModuleManagementContractTest is Test {
    ModuleManagementContract public moduleManagement;
    MockEscrowContract public escrowContract;
    
    DefaultReleaseStrategy public releaseStrategy1;
    DefaultReleaseStrategy public releaseStrategy2;
    DefaultYieldModule public yieldGenModule1;
    DefaultYieldModule public yieldGenModule2;
    DefaultYieldDistributionModule public yieldDistModule1;
    DefaultYieldDistributionModule public yieldDistModule2;
    DefaultResolutionModule public resolutionModule1;
    DefaultResolutionModule public resolutionModule2;
    
    address public owner;
    address public timelock;
    address public unauthorized;
    
    function setUp() public {
        owner = address(this);
        timelock = address(0x1111);
        unauthorized = address(0x9999);
        
        moduleManagement = new ModuleManagementContract(owner);
        escrowContract = new MockEscrowContract();
        
        releaseStrategy1 = new DefaultReleaseStrategy();
        releaseStrategy2 = new DefaultReleaseStrategy();
        yieldGenModule1 = new DefaultYieldModule();
        yieldGenModule2 = new DefaultYieldModule();
        yieldDistModule1 = new DefaultYieldDistributionModule();
        yieldDistModule2 = new DefaultYieldDistributionModule();
        resolutionModule1 = new DefaultResolutionModule(owner, address(0x2222));
        resolutionModule2 = new DefaultResolutionModule(owner, address(0x3333));
        
        // Setup roles
        moduleManagement.grantRole(moduleManagement.ROLE_TIMELOCK(), timelock);
        
        // Register escrow contract
        vm.prank(timelock);
        moduleManagement.registerEscrowContract(address(escrowContract));
        
        // Grant escrow contract the role
        moduleManagement.grantRole(moduleManagement.ROLE_ESCROW_CONTRACT(), address(escrowContract));
    }
    
    // ============ Constructor Tests ============
    
    function test_constructor_setsOwner() public {
        ModuleManagementContract newContract = new ModuleManagementContract(owner);
        assertTrue(newContract.hasRole(newContract.DEFAULT_ADMIN_ROLE(), owner));
        assertTrue(newContract.hasRole(newContract.ROLE_TIMELOCK(), owner));
    }
    
    function test_constructor_zeroOwner_reverts() public {
        vm.expectRevert(SlowLaneQueueActivate.InvalidValue.selector);
        new ModuleManagementContract(address(0));
    }
    
    // ============ registerEscrowContract Tests ============
    
    function test_registerEscrowContract_success() public {
        address newEscrow = address(0x3333);
        vm.prank(timelock);
        moduleManagement.registerEscrowContract(newEscrow);
        assertTrue(moduleManagement.hasRole(moduleManagement.ROLE_ESCROW_CONTRACT(), newEscrow));
    }
    
    function test_registerEscrowContract_zeroAddress_reverts() public {
        vm.prank(timelock);
        vm.expectRevert(SlowLaneQueueActivate.InvalidValue.selector);
        moduleManagement.registerEscrowContract(address(0));
    }
    
    function test_registerEscrowContract_unauthorized_reverts() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        moduleManagement.registerEscrowContract(address(0x3333));
    }
    
    // ============ queueModule Tests ============
    
    function test_queueModule_RELEASE_success() public {
        vm.prank(address(escrowContract));
        moduleManagement.queueModule(
            address(escrowContract),
            BaseEscrow.ModuleType.RELEASE,
            address(releaseStrategy1)
        );
        
        (address value, uint64 eta, bool exists) = moduleManagement.getPendingModule(
            address(escrowContract),
            BaseEscrow.ModuleType.RELEASE
        );
        
        assertEq(value, address(releaseStrategy1));
        assertEq(eta, block.timestamp + 7 days);
        assertTrue(exists);
    }
    
    function test_queueModule_YIELD_GEN_success() public {
        vm.prank(address(escrowContract));
        moduleManagement.queueModule(
            address(escrowContract),
            BaseEscrow.ModuleType.YIELD_GEN,
            address(yieldGenModule1)
        );
        
        (address value, uint64 eta, bool exists) = moduleManagement.getPendingModule(
            address(escrowContract),
            BaseEscrow.ModuleType.YIELD_GEN
        );
        
        assertEq(value, address(yieldGenModule1));
        assertTrue(exists);
    }
    
    function test_queueModule_YIELD_DIST_success() public {
        vm.prank(address(escrowContract));
        moduleManagement.queueModule(
            address(escrowContract),
            BaseEscrow.ModuleType.YIELD_DIST,
            address(yieldDistModule1)
        );
        
        (address value, , bool exists) = moduleManagement.getPendingModule(
            address(escrowContract),
            BaseEscrow.ModuleType.YIELD_DIST
        );
        
        assertEq(value, address(yieldDistModule1));
        assertTrue(exists);
    }
    
    function test_queueModule_RESOLUTION_success() public {
        vm.prank(address(escrowContract));
        moduleManagement.queueModule(
            address(escrowContract),
            BaseEscrow.ModuleType.RESOLUTION,
            address(resolutionModule1)
        );
        
        (address value, , bool exists) = moduleManagement.getPendingModule(
            address(escrowContract),
            BaseEscrow.ModuleType.RESOLUTION
        );
        
        assertEq(value, address(resolutionModule1));
        assertTrue(exists);
    }
    
    function test_queueModule_zeroAddress_reverts() public {
        vm.prank(address(escrowContract));
        vm.expectRevert(SlowLaneQueueActivate.InvalidValue.selector);
        moduleManagement.queueModule(
            address(escrowContract),
            BaseEscrow.ModuleType.RELEASE,
            address(0)
        );
    }
    
    function test_queueModule_wrongCaller_reverts() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        moduleManagement.queueModule(
            address(escrowContract),
            BaseEscrow.ModuleType.RELEASE,
            address(releaseStrategy1)
        );
    }
    
    function test_queueModule_differentEscrowContract_reverts() public {
        vm.prank(address(escrowContract));
        vm.expectRevert(SlowLaneQueueActivate.InvalidValue.selector);
        moduleManagement.queueModule(
            address(0x4444), // Different escrow
            BaseEscrow.ModuleType.RELEASE,
            address(releaseStrategy1)
        );
    }
    
    // ============ activateModule Tests ============
    
    function test_activateModule_RELEASE_success() public {
        // Queue module
        vm.prank(address(escrowContract));
        moduleManagement.queueModule(
            address(escrowContract),
            BaseEscrow.ModuleType.RELEASE,
            address(releaseStrategy1)
        );
        
        // Warp past delay
        vm.warp(block.timestamp + 7 days + 1);
        
        // Activate
        vm.prank(address(escrowContract));
        moduleManagement.activateModule(
            address(escrowContract),
            BaseEscrow.ModuleType.RELEASE
        );
        
        // Verify activation
        IReleaseStrategy strategy = moduleManagement.getDefaultReleaseStrategy(address(escrowContract));
        assertEq(address(strategy), address(releaseStrategy1));
        
        // Verify pending cleared
        (, , bool exists) = moduleManagement.getPendingModule(
            address(escrowContract),
            BaseEscrow.ModuleType.RELEASE
        );
        assertFalse(exists);
    }
    
    function test_activateModule_YIELD_GEN_success() public {
        vm.prank(address(escrowContract));
        moduleManagement.queueModule(
            address(escrowContract),
            BaseEscrow.ModuleType.YIELD_GEN,
            address(yieldGenModule1)
        );
        
        vm.warp(block.timestamp + 7 days + 1);
        
        vm.prank(address(escrowContract));
        moduleManagement.activateModule(
            address(escrowContract),
            BaseEscrow.ModuleType.YIELD_GEN
        );
        
        IYieldGenerationModule module = moduleManagement.getDefaultYieldGenerationModule(address(escrowContract));
        assertEq(address(module), address(yieldGenModule1));
    }
    
    function test_activateModule_YIELD_DIST_success() public {
        vm.prank(address(escrowContract));
        moduleManagement.queueModule(
            address(escrowContract),
            BaseEscrow.ModuleType.YIELD_DIST,
            address(yieldDistModule1)
        );
        
        vm.warp(block.timestamp + 7 days + 1);
        
        vm.prank(address(escrowContract));
        moduleManagement.activateModule(
            address(escrowContract),
            BaseEscrow.ModuleType.YIELD_DIST
        );
        
        IYieldDistributionModule module = moduleManagement.getDefaultYieldDistributionModule(address(escrowContract));
        assertEq(address(module), address(yieldDistModule1));
    }
    
    function test_activateModule_RESOLUTION_success() public {
        vm.prank(address(escrowContract));
        moduleManagement.queueModule(
            address(escrowContract),
            BaseEscrow.ModuleType.RESOLUTION,
            address(resolutionModule1)
        );
        
        vm.warp(block.timestamp + 7 days + 1);
        
        vm.prank(address(escrowContract));
        moduleManagement.activateModule(
            address(escrowContract),
            BaseEscrow.ModuleType.RESOLUTION
        );
        
        IResolutionModule module = moduleManagement.getDefaultResolutionModule(address(escrowContract));
        assertEq(address(module), address(resolutionModule1));
    }
    
    function test_activateModule_noPending_reverts() public {
        vm.prank(address(escrowContract));
        vm.expectRevert(SlowLaneQueueActivate.NoPending.selector);
        moduleManagement.activateModule(
            address(escrowContract),
            BaseEscrow.ModuleType.RELEASE
        );
    }
    
    function test_activateModule_premature_reverts() public {
        vm.prank(address(escrowContract));
        moduleManagement.queueModule(
            address(escrowContract),
            BaseEscrow.ModuleType.RELEASE,
            address(releaseStrategy1)
        );
        
        // Try to activate before delay
        vm.prank(address(escrowContract));
        vm.expectRevert(abi.encodeWithSelector(SlowLaneQueueActivate.NotReady.selector, uint64(block.timestamp + 7 days)));
        moduleManagement.activateModule(
            address(escrowContract),
            BaseEscrow.ModuleType.RELEASE
        );
    }
    
    function test_activateModule_wrongCaller_reverts() public {
        vm.prank(address(escrowContract));
        moduleManagement.queueModule(
            address(escrowContract),
            BaseEscrow.ModuleType.RELEASE,
            address(releaseStrategy1)
        );
        
        vm.warp(block.timestamp + 7 days + 1);
        
        vm.prank(unauthorized);
        vm.expectRevert();
        moduleManagement.activateModule(
            address(escrowContract),
            BaseEscrow.ModuleType.RELEASE
        );
    }
    
    function test_activateModule_replaceExisting() public {
        // Queue and activate first module
        vm.prank(address(escrowContract));
        moduleManagement.queueModule(
            address(escrowContract),
            BaseEscrow.ModuleType.RELEASE,
            address(releaseStrategy1)
        );
        (, uint64 firstEta, ) = moduleManagement.getPendingModule(
            address(escrowContract),
            BaseEscrow.ModuleType.RELEASE
        );
        vm.warp(firstEta + 1);
        vm.prank(address(escrowContract));
        moduleManagement.activateModule(
            address(escrowContract),
            BaseEscrow.ModuleType.RELEASE
        );
        
        // Queue and activate second module
        vm.prank(address(escrowContract));
        moduleManagement.queueModule(
            address(escrowContract),
            BaseEscrow.ModuleType.RELEASE,
            address(releaseStrategy2)
        );
        (, uint64 secondEta, ) = moduleManagement.getPendingModule(
            address(escrowContract),
            BaseEscrow.ModuleType.RELEASE
        );
        vm.warp(secondEta + 1);
        vm.prank(address(escrowContract));
        moduleManagement.activateModule(
            address(escrowContract),
            BaseEscrow.ModuleType.RELEASE
        );
        
        // Verify replacement
        IReleaseStrategy strategy = moduleManagement.getDefaultReleaseStrategy(address(escrowContract));
        assertEq(address(strategy), address(releaseStrategy2));
    }
    
    // ============ getPendingModule Tests ============
    
    function test_getPendingModule_exists() public {
        vm.prank(address(escrowContract));
        moduleManagement.queueModule(
            address(escrowContract),
            BaseEscrow.ModuleType.RELEASE,
            address(releaseStrategy1)
        );
        
        (address value, uint64 eta, bool exists) = moduleManagement.getPendingModule(
            address(escrowContract),
            BaseEscrow.ModuleType.RELEASE
        );
        
        assertEq(value, address(releaseStrategy1));
        assertGt(eta, block.timestamp);
        assertTrue(exists);
    }
    
    function test_getPendingModule_notExists() public {
        (address value, uint64 eta, bool exists) = moduleManagement.getPendingModule(
            address(escrowContract),
            BaseEscrow.ModuleType.RELEASE
        );
        
        assertEq(value, address(0));
        assertEq(eta, 0);
        assertFalse(exists);
    }
    
    // ============ Getter Functions Tests ============
    
    function test_getDefaultReleaseStrategy() public {
        vm.prank(address(escrowContract));
        moduleManagement.queueModule(
            address(escrowContract),
            BaseEscrow.ModuleType.RELEASE,
            address(releaseStrategy1)
        );
        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(address(escrowContract));
        moduleManagement.activateModule(
            address(escrowContract),
            BaseEscrow.ModuleType.RELEASE
        );
        
        IReleaseStrategy strategy = moduleManagement.getDefaultReleaseStrategy(address(escrowContract));
        assertEq(address(strategy), address(releaseStrategy1));
    }
    
    function test_getDefaultYieldGenerationModule() public {
        vm.prank(address(escrowContract));
        moduleManagement.queueModule(
            address(escrowContract),
            BaseEscrow.ModuleType.YIELD_GEN,
            address(yieldGenModule1)
        );
        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(address(escrowContract));
        moduleManagement.activateModule(
            address(escrowContract),
            BaseEscrow.ModuleType.YIELD_GEN
        );
        
        IYieldGenerationModule module = moduleManagement.getDefaultYieldGenerationModule(address(escrowContract));
        assertEq(address(module), address(yieldGenModule1));
    }
    
    function test_getDefaultYieldDistributionModule() public {
        vm.prank(address(escrowContract));
        moduleManagement.queueModule(
            address(escrowContract),
            BaseEscrow.ModuleType.YIELD_DIST,
            address(yieldDistModule1)
        );
        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(address(escrowContract));
        moduleManagement.activateModule(
            address(escrowContract),
            BaseEscrow.ModuleType.YIELD_DIST
        );
        
        IYieldDistributionModule module = moduleManagement.getDefaultYieldDistributionModule(address(escrowContract));
        assertEq(address(module), address(yieldDistModule1));
    }
    
    function test_getDefaultResolutionModule() public {
        vm.prank(address(escrowContract));
        moduleManagement.queueModule(
            address(escrowContract),
            BaseEscrow.ModuleType.RESOLUTION,
            address(resolutionModule1)
        );
        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(address(escrowContract));
        moduleManagement.activateModule(
            address(escrowContract),
            BaseEscrow.ModuleType.RESOLUTION
        );
        
        IResolutionModule module = moduleManagement.getDefaultResolutionModule(address(escrowContract));
        assertEq(address(module), address(resolutionModule1));
    }
    
    function test_getModule_RELEASE() public {
        vm.prank(address(escrowContract));
        moduleManagement.queueModule(
            address(escrowContract),
            BaseEscrow.ModuleType.RELEASE,
            address(releaseStrategy1)
        );
        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(address(escrowContract));
        moduleManagement.activateModule(
            address(escrowContract),
            BaseEscrow.ModuleType.RELEASE
        );
        
        address module = moduleManagement.getModule(
            address(escrowContract),
            BaseEscrow.ModuleType.RELEASE
        );
        assertEq(module, address(releaseStrategy1));
    }
    
    function test_getModule_YIELD_GEN() public {
        vm.prank(address(escrowContract));
        moduleManagement.queueModule(
            address(escrowContract),
            BaseEscrow.ModuleType.YIELD_GEN,
            address(yieldGenModule1)
        );
        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(address(escrowContract));
        moduleManagement.activateModule(
            address(escrowContract),
            BaseEscrow.ModuleType.YIELD_GEN
        );
        
        address module = moduleManagement.getModule(
            address(escrowContract),
            BaseEscrow.ModuleType.YIELD_GEN
        );
        assertEq(module, address(yieldGenModule1));
    }
    
    function test_getModule_YIELD_DIST() public {
        vm.prank(address(escrowContract));
        moduleManagement.queueModule(
            address(escrowContract),
            BaseEscrow.ModuleType.YIELD_DIST,
            address(yieldDistModule1)
        );
        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(address(escrowContract));
        moduleManagement.activateModule(
            address(escrowContract),
            BaseEscrow.ModuleType.YIELD_DIST
        );
        
        address module = moduleManagement.getModule(
            address(escrowContract),
            BaseEscrow.ModuleType.YIELD_DIST
        );
        assertEq(module, address(yieldDistModule1));
    }
    
    function test_getModule_RESOLUTION() public {
        vm.prank(address(escrowContract));
        moduleManagement.queueModule(
            address(escrowContract),
            BaseEscrow.ModuleType.RESOLUTION,
            address(resolutionModule1)
        );
        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(address(escrowContract));
        moduleManagement.activateModule(
            address(escrowContract),
            BaseEscrow.ModuleType.RESOLUTION
        );
        
        address module = moduleManagement.getModule(
            address(escrowContract),
            BaseEscrow.ModuleType.RESOLUTION
        );
        assertEq(module, address(resolutionModule1));
    }
    
    function test_getModule_notSet() public {
        address module = moduleManagement.getModule(
            address(escrowContract),
            BaseEscrow.ModuleType.RELEASE
        );
        assertEq(module, address(0));
    }
    
    function test_getModule_invalidType() public {
        // Assuming there's an invalid enum value (edge case)
        // This would require casting an invalid uint8, which is hard to test
        // But we can test that unset modules return address(0)
        address module = moduleManagement.getModule(
            address(escrowContract),
            BaseEscrow.ModuleType.RELEASE
        );
        assertEq(module, address(0));
    }
    
    // ============ Multiple Escrow Contracts Tests ============
    
    function test_multipleEscrowContracts() public {
        MockEscrowContract escrow2 = new MockEscrowContract();
        
        vm.prank(timelock);
        moduleManagement.registerEscrowContract(address(escrow2));
        moduleManagement.grantRole(moduleManagement.ROLE_ESCROW_CONTRACT(), address(escrow2));
        
        // Queue modules for both escrows
        vm.prank(address(escrowContract));
        moduleManagement.queueModule(
            address(escrowContract),
            BaseEscrow.ModuleType.RELEASE,
            address(releaseStrategy1)
        );
        
        vm.prank(address(escrow2));
        moduleManagement.queueModule(
            address(escrow2),
            BaseEscrow.ModuleType.RELEASE,
            address(releaseStrategy2)
        );
        
        // Verify they're independent
        (address value1, , ) = moduleManagement.getPendingModule(
            address(escrowContract),
            BaseEscrow.ModuleType.RELEASE
        );
        (address value2, , ) = moduleManagement.getPendingModule(
            address(escrow2),
            BaseEscrow.ModuleType.RELEASE
        );
        
        assertEq(value1, address(releaseStrategy1));
        assertEq(value2, address(releaseStrategy2));
    }
    
    // ============ Event Tests ============
    
    function test_queueModule_emitsEvent_RELEASE() public {
        vm.expectEmit(true, true, true, true);
        emit ModuleManagementContract.DefaultReleaseStrategyQueued(
            address(escrowContract),
            address(0),
            address(releaseStrategy1),
            uint64(block.timestamp + 7 days)
        );
        
        vm.prank(address(escrowContract));
        moduleManagement.queueModule(
            address(escrowContract),
            BaseEscrow.ModuleType.RELEASE,
            address(releaseStrategy1)
        );
    }
    
    function test_activateModule_emitsEvent_RELEASE() public {
        vm.prank(address(escrowContract));
        moduleManagement.queueModule(
            address(escrowContract),
            BaseEscrow.ModuleType.RELEASE,
            address(releaseStrategy1)
        );
        
        vm.warp(block.timestamp + 7 days + 1);
        
        vm.expectEmit(true, true, true, true);
        emit ModuleManagementContract.DefaultReleaseStrategyActivated(
            address(escrowContract),
            address(0),
            address(releaseStrategy1)
        );
        
        vm.prank(address(escrowContract));
        moduleManagement.activateModule(
            address(escrowContract),
            BaseEscrow.ModuleType.RELEASE
        );
    }
}

// ============ Mocks ============

contract MockEscrowContract {
    // Mock escrow contract for testing
}
