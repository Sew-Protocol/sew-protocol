// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import 'forge-std/Test.sol';
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import '../../../contracts/admin/EscrowGovernanceTimelock.sol';
import '../../../contracts/core/EscrowVault.sol';
import '../../../contracts/core/modules/DefaultResolutionModule.sol';
import '../../../contracts/types/EscrowTypes.sol';
import '../../../contracts/governance/SlowLaneQueueActivate.sol';
import '../../../contracts/ops/YieldOps.sol';
import '../../../contracts/ops/DisputeOps.sol';
import '../../../contracts/core/ModuleSnapshotRegistry.sol';

/**
 * @title EscrowGovernanceTimelockTest
 * @notice Comprehensive tests for EscrowGovernanceTimelock covering all functions and code paths
 * @dev Goal: 99% coverage for EscrowGovernanceTimelock.sol
 * 
 * Following strategy from 99_PERCENT_TEST_COVERAGE_STRATEGY.md:
 * - All queue/activate functions for each admin setting
 * - Access control (ROLE_TIMELOCK)
 * - Slow lane delay enforcement (7 days)
 * - Bounds validation (fee limits)
 * - Getter functions
 * - Edge cases (zero addresses, no pending, premature activation)
 */
contract EscrowGovernanceTimelockTest is Test {
    EscrowGovernanceTimelock public adminContract;
    EscrowVault public vault;
    DefaultResolutionModule public resolutionModule1;
    DefaultResolutionModule public resolutionModule2;
    
    YieldOps public yieldOps;
    DisputeOps public disputeOps;
    ModuleSnapshotRegistry public moduleManagement;
    
    address public owner;
    address public timelock;
    address public feeAddress1;
    address public feeAddress2;
    address public unauthorized;
    
    uint256 public constant ESCROW_FEE = 100; // 1%
    
    function setUp() public {
        owner = address(this);
        timelock = address(0x1111);
        feeAddress1 = address(0xFEE1);
        feeAddress2 = address(0xFEE2);
        unauthorized = address(0x9999);
        
        yieldOps = new YieldOps(owner);
        disputeOps = new DisputeOps(owner);
        moduleManagement = new ModuleSnapshotRegistry(owner);
        
        vault = new EscrowVault(ESCROW_FEE, feeAddress1, address(yieldOps), address(disputeOps), address(moduleManagement));
        
        resolutionModule1 = new DefaultResolutionModule(owner, address(0x2222));
        resolutionModule2 = new DefaultResolutionModule(owner, address(0x3333));
        
        adminContract = new EscrowGovernanceTimelock(owner);
        
        // Setup roles
        adminContract.grantRole(adminContract.ROLE_TIMELOCK(), timelock);
        vault.grantRole(vault.ROLE_ADMIN_CONTRACT(), address(adminContract));
        
        // Register escrow contract
        vm.prank(timelock);
        adminContract.registerEscrowContract(address(vault));
    }
    
    // ============ Constructor Tests ============
    
    function test_constructor_setsOwner() public {
        EscrowGovernanceTimelock newContract = new EscrowGovernanceTimelock(owner);
        assertTrue(newContract.hasRole(newContract.DEFAULT_ADMIN_ROLE(), owner));
        assertTrue(newContract.hasRole(newContract.ROLE_TIMELOCK(), owner));
    }
    
    // ============ registerEscrowContract Tests ============
    
    function test_registerEscrowContract_success() public {
        address newEscrow = address(0x3333);
        vm.prank(timelock);
        adminContract.registerEscrowContract(newEscrow);
        assertTrue(adminContract.hasRole(adminContract.ROLE_ESCROW_CONTRACT(), newEscrow));
    }
    
    function test_registerEscrowContract_zeroAddress_reverts() public {
        vm.prank(timelock);
        vm.expectRevert(InvalidValue.selector);
        adminContract.registerEscrowContract(address(0));
    }
    
    function test_registerEscrowContract_unauthorized_reverts() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        adminContract.registerEscrowContract(address(0x3333));
    }
    
    // ============ Fee Recipient Management Tests ============
    
    function test_queueFeeRecipient_success() public {
        vm.prank(timelock);
        adminContract.queueFeeRecipient(address(vault), feeAddress2);
        
        (address value, uint64 eta, bool exists) = adminContract.getPendingFeeRecipient(address(vault));
        
        assertEq(value, feeAddress2);
        assertEq(eta, block.timestamp + 7 days);
        assertTrue(exists);
    }
    
    function test_activateFeeRecipient_success() public {
        vm.prank(timelock);
        adminContract.queueFeeRecipient(address(vault), feeAddress2);
        
        vm.warp(block.timestamp + 7 days + 1);
        
        vm.prank(timelock);
        adminContract.activateFeeRecipient(address(vault));
        
        assertEq(vault.escrowFeeAddress(), feeAddress2);
        
        // Verify pending cleared
        (, , bool exists) = adminContract.getPendingFeeRecipient(address(vault));
        assertFalse(exists);
    }
    
    function test_activateFeeRecipient_noPending_reverts() public {
        vm.prank(timelock);
        vm.expectRevert(SlowLaneQueueActivate.NoPending.selector);
        adminContract.activateFeeRecipient(address(vault));
    }
    
    function test_activateFeeRecipient_premature_reverts() public {
        vm.prank(timelock);
        adminContract.queueFeeRecipient(address(vault), feeAddress2);
        
        vm.prank(timelock);
        vm.expectRevert(abi.encodeWithSelector(SlowLaneQueueActivate.NotReady.selector, uint64(block.timestamp + 7 days)));
        adminContract.activateFeeRecipient(address(vault));
    }
    
    // ============ Escrow Fee Management Tests ============
    
    function test_queueEscrowFee_success() public {
        uint256 newFee = 150; // 1.5%
        vm.prank(timelock);
        adminContract.queueEscrowFee(address(vault), newFee);
        
        (uint256 value, uint64 eta, bool exists) = adminContract.getPendingEscrowFee(address(vault));
        
        assertEq(value, newFee);
        assertEq(eta, block.timestamp + 7 days);
        assertTrue(exists);
    }
    
    function test_queueEscrowFee_maxFee() public {
        uint256 maxFee = 200; // 2%
        vm.prank(timelock);
        adminContract.queueEscrowFee(address(vault), maxFee);
        
        (uint256 value, , ) = adminContract.getPendingEscrowFee(address(vault));
        assertEq(value, maxFee);
    }
    
    function test_queueEscrowFee_exceedsMax_reverts() public {
        uint256 invalidFee = 201; // > 2%
        vm.prank(timelock);
        vm.expectRevert(abi.encodeWithSelector(InvalidEscrowFee.selector, invalidFee, 200));
        adminContract.queueEscrowFee(address(vault), invalidFee);
    }
    
    function test_activateEscrowFee_success() public {
        uint256 newFee = 150;
        vm.prank(timelock);
        adminContract.queueEscrowFee(address(vault), newFee);
        
        vm.warp(block.timestamp + 7 days + 1);
        
        vm.prank(timelock);
        adminContract.activateEscrowFee(address(vault));
        
        assertEq(vault.escrowFee(), newFee);
    }
    
    function test_activateEscrowFee_noPending_reverts() public {
        vm.prank(timelock);
        vm.expectRevert(SlowLaneQueueActivate.NoPending.selector);
        adminContract.activateEscrowFee(address(vault));
    }
    
    // ============ Yield Protocol Fee Management Tests ============
    
    function test_queueYieldProtocolFeeBps_success() public {
        uint256 newFee = 1000; // 10%
        vm.prank(timelock);
        adminContract.queueYieldProtocolFeeBps(address(vault), newFee);
        
        (uint256 value, , bool exists) = adminContract.getPendingYieldProtocolFeeBps(address(vault));
        assertEq(value, newFee);
        assertTrue(exists);
    }
    
    function test_queueYieldProtocolFeeBps_maxFee() public {
        uint256 maxFee = 3000; // 30%
        vm.prank(timelock);
        adminContract.queueYieldProtocolFeeBps(address(vault), maxFee);
        
        (uint256 value, , ) = adminContract.getPendingYieldProtocolFeeBps(address(vault));
        assertEq(value, maxFee);
    }
    
    function test_queueYieldProtocolFeeBps_exceedsMax_reverts() public {
        uint256 invalidFee = 3001; // > 30%
        vm.prank(timelock);
        vm.expectRevert(abi.encodeWithSelector(FeeExceedsMaximum.selector, invalidFee, 3000));
        adminContract.queueYieldProtocolFeeBps(address(vault), invalidFee);
    }
    
    function test_activateYieldProtocolFeeBps_success() public {
        uint256 newFee = 1000;
        vm.prank(timelock);
        adminContract.queueYieldProtocolFeeBps(address(vault), newFee);
        
        vm.warp(block.timestamp + 7 days + 1);
        
        vm.prank(timelock);
        adminContract.activateYieldProtocolFeeBps(address(vault));
        
        assertEq(vault.yieldProtocolFeeBps(), newFee);
    }
    
    function test_activateYieldProtocolFeeBps_noPending_reverts() public {
        vm.prank(timelock);
        vm.expectRevert(SlowLaneQueueActivate.NoPending.selector);
        adminContract.activateYieldProtocolFeeBps(address(vault));
    }
    
    // ============ Appeal Bond Protocol Fee Management Tests ============
    
    function test_queueAppealBondProtocolFeeBps_success() public {
        uint256 newFee = 500; // 5%
        vm.prank(timelock);
        adminContract.queueAppealBondProtocolFeeBps(address(vault), newFee);
        
        (uint256 value, , bool exists) = adminContract.getPendingAppealBondProtocolFeeBps(address(vault));
        assertEq(value, newFee);
        assertTrue(exists);
    }
    
    function test_queueAppealBondProtocolFeeBps_maxFee() public {
        uint256 maxFee = 3000; // 30%
        vm.prank(timelock);
        adminContract.queueAppealBondProtocolFeeBps(address(vault), maxFee);
        
        (uint256 value, , ) = adminContract.getPendingAppealBondProtocolFeeBps(address(vault));
        assertEq(value, maxFee);
    }
    
    function test_queueAppealBondProtocolFeeBps_exceedsMax_reverts() public {
        uint256 invalidFee = 3001;
        vm.prank(timelock);
        vm.expectRevert(abi.encodeWithSelector(FeeExceedsMaximum.selector, invalidFee, 3000));
        adminContract.queueAppealBondProtocolFeeBps(address(vault), invalidFee);
    }
    
    function test_activateAppealBondProtocolFeeBps_success() public {
        uint256 newFee = 500;
        vm.prank(timelock);
        adminContract.queueAppealBondProtocolFeeBps(address(vault), newFee);
        
        vm.warp(block.timestamp + 7 days + 1);
        
        vm.prank(timelock);
        adminContract.activateAppealBondProtocolFeeBps(address(vault));
        
        assertEq(vault.appealBondProtocolFeeBps(), newFee);
    }
    
    function test_activateAppealBondProtocolFeeBps_noPending_reverts() public {
        vm.prank(timelock);
        vm.expectRevert(SlowLaneQueueActivate.NoPending.selector);
        adminContract.activateAppealBondProtocolFeeBps(address(vault));
    }
    
    // ============ Resolution Module Management Tests ============
    
    function test_queueResolutionModule_success() public {
        vm.prank(timelock);
        adminContract.queueResolutionModule(address(vault), address(resolutionModule1));
        
        (address value, uint64 eta, bool exists) = adminContract.getPendingResolutionModule(address(vault));
        
        assertEq(value, address(resolutionModule1));
        assertEq(eta, block.timestamp + 7 days);
        assertTrue(exists);
    }
    
    function test_activateResolutionModule_success() public {
        vm.prank(timelock);
        adminContract.queueResolutionModule(address(vault), address(resolutionModule1));
        
        vm.warp(block.timestamp + 7 days + 1);
        
        vm.prank(timelock);
        adminContract.activateResolutionModule(address(vault));
        
        assertEq(vault.disputeResolutionModule(), address(resolutionModule1));
    }
    
    function test_activateResolutionModule_noPending_reverts() public {
        vm.prank(timelock);
        vm.expectRevert(SlowLaneQueueActivate.NoPending.selector);
        adminContract.activateResolutionModule(address(vault));
    }
    
    function test_activateResolutionModule_replaceExisting() public {
        // Queue and activate first module
        vm.prank(timelock);
        adminContract.queueResolutionModule(address(vault), address(resolutionModule1));
        (, uint64 firstEta, ) = adminContract.getPendingResolutionModule(address(vault));
        vm.warp(firstEta + 1);
        vm.prank(timelock);
        adminContract.activateResolutionModule(address(vault));
        
        // Queue and activate second module
        vm.prank(timelock);
        adminContract.queueResolutionModule(address(vault), address(resolutionModule2));
        (, uint64 secondEta, ) = adminContract.getPendingResolutionModule(address(vault));
        vm.warp(secondEta + 1);
        vm.prank(timelock);
        adminContract.activateResolutionModule(address(vault));
        
        assertEq(vault.disputeResolutionModule(), address(resolutionModule2));
    }
    
    // ============ Timeout Configuration Tests ============
    
    function test_setTimeoutConfig_success() public {
        TimeoutConfig memory config = TimeoutConfig({
            defaultAutoReleaseDelay: 10 days,
            defaultAutoCancelDelay: 5 days,
            maxDisputeDuration: 60 days,
            appealWindowDuration: 3 days
        });
        
        vm.prank(timelock);
        adminContract.setTimeoutConfig(address(vault), config);
        
        (
            uint256 defaultAutoReleaseDelay,
            uint256 defaultAutoCancelDelay,
            uint256 maxDisputeDuration,
            uint256 appealWindowDuration
        ) = vault.timeoutConfig();
        assertEq(defaultAutoReleaseDelay, config.defaultAutoReleaseDelay);
        assertEq(defaultAutoCancelDelay, config.defaultAutoCancelDelay);
        assertEq(maxDisputeDuration, config.maxDisputeDuration);
        assertEq(appealWindowDuration, config.appealWindowDuration);
    }
    
    function test_setTimeoutConfig_validBounds() public {
        TimeoutConfig memory config = TimeoutConfig({
            defaultAutoReleaseDelay: 0, // Disabled
            defaultAutoCancelDelay: 0,  // Disabled
            maxDisputeDuration: 7 days,  // Minimum
            appealWindowDuration: 1 days  // Minimum
        });
        
        vm.prank(timelock);
        adminContract.setTimeoutConfig(address(vault), config);
        
        (
            ,
            ,
            uint256 maxDisputeDuration,
            uint256 appealWindowDuration
        ) = vault.timeoutConfig();
        assertEq(maxDisputeDuration, 7 days);
        assertEq(appealWindowDuration, 1 days);
    }
    
    function test_setTimeoutConfig_maxBounds() public {
        TimeoutConfig memory config = TimeoutConfig({
            defaultAutoReleaseDelay: 0,
            defaultAutoCancelDelay: 0,
            maxDisputeDuration: 365 days,  // Maximum
            appealWindowDuration: 7 days   // Maximum
        });
        
        vm.prank(timelock);
        adminContract.setTimeoutConfig(address(vault), config);
        
        (
            ,
            ,
            uint256 maxDisputeDuration,
            uint256 appealWindowDuration
        ) = vault.timeoutConfig();
        assertEq(maxDisputeDuration, 365 days);
        assertEq(appealWindowDuration, 7 days);
    }
    
    function test_setTimeoutConfig_maxDisputeDuration_tooShort_reverts() public {
        TimeoutConfig memory config = TimeoutConfig({
            defaultAutoReleaseDelay: 0,
            defaultAutoCancelDelay: 0,
            maxDisputeDuration: 6 days,  // Too short
            appealWindowDuration: 1 days
        });
        
        vm.prank(timelock);
        vm.expectRevert(abi.encodeWithSelector(InvalidConfig.selector, 1, 6 days));
        adminContract.setTimeoutConfig(address(vault), config);
    }
    
    function test_setTimeoutConfig_maxDisputeDuration_tooLong_reverts() public {
        TimeoutConfig memory config = TimeoutConfig({
            defaultAutoReleaseDelay: 0,
            defaultAutoCancelDelay: 0,
            maxDisputeDuration: 366 days,  // Too long
            appealWindowDuration: 1 days
        });
        
        vm.prank(timelock);
        vm.expectRevert(abi.encodeWithSelector(InvalidConfig.selector, 1, 366 days));
        adminContract.setTimeoutConfig(address(vault), config);
    }
    
    function test_setTimeoutConfig_appealWindow_tooShort_reverts() public {
        TimeoutConfig memory config = TimeoutConfig({
            defaultAutoReleaseDelay: 0,
            defaultAutoCancelDelay: 0,
            maxDisputeDuration: 30 days,
            appealWindowDuration: 23 hours  // Too short
        });
        
        vm.prank(timelock);
        vm.expectRevert(abi.encodeWithSelector(InvalidConfig.selector, 2, 23 hours));
        adminContract.setTimeoutConfig(address(vault), config);
    }
    
    function test_setTimeoutConfig_appealWindow_tooLong_reverts() public {
        TimeoutConfig memory config = TimeoutConfig({
            defaultAutoReleaseDelay: 0,
            defaultAutoCancelDelay: 0,
            maxDisputeDuration: 30 days,
            appealWindowDuration: 8 days  // Too long
        });
        
        vm.prank(timelock);
        vm.expectRevert(abi.encodeWithSelector(InvalidConfig.selector, 2, 8 days));
        adminContract.setTimeoutConfig(address(vault), config);
    }
    
    function test_setTimeoutConfig_unauthorized_reverts() public {
        TimeoutConfig memory config = TimeoutConfig({
            defaultAutoReleaseDelay: 0,
            defaultAutoCancelDelay: 0,
            maxDisputeDuration: 30 days,
            appealWindowDuration: 1 days
        });
        
        vm.prank(unauthorized);
        vm.expectRevert();
        adminContract.setTimeoutConfig(address(vault), config);
    }
    
    // ============ Getter Functions Tests ============
    
    function test_getPendingFeeRecipient() public {
        vm.prank(timelock);
        adminContract.queueFeeRecipient(address(vault), feeAddress2);
        
        (address value, uint64 eta, bool exists) = adminContract.getPendingFeeRecipient(address(vault));
        assertEq(value, feeAddress2);
        assertGt(eta, block.timestamp);
        assertTrue(exists);
    }
    
    function test_getPendingEscrowFee() public {
        vm.prank(timelock);
        adminContract.queueEscrowFee(address(vault), 150);
        
        (uint256 value, , bool exists) = adminContract.getPendingEscrowFee(address(vault));
        assertEq(value, 150);
        assertTrue(exists);
    }
    
    function test_getPendingYieldProtocolFeeBps() public {
        vm.prank(timelock);
        adminContract.queueYieldProtocolFeeBps(address(vault), 1000);
        
        (uint256 value, , bool exists) = adminContract.getPendingYieldProtocolFeeBps(address(vault));
        assertEq(value, 1000);
        assertTrue(exists);
    }
    
    function test_getPendingAppealBondProtocolFeeBps() public {
        vm.prank(timelock);
        adminContract.queueAppealBondProtocolFeeBps(address(vault), 500);
        
        (uint256 value, , bool exists) = adminContract.getPendingAppealBondProtocolFeeBps(address(vault));
        assertEq(value, 500);
        assertTrue(exists);
    }
    
    function test_getPendingResolutionModule() public {
        vm.prank(timelock);
        adminContract.queueResolutionModule(address(vault), address(resolutionModule1));
        
        (address value, , bool exists) = adminContract.getPendingResolutionModule(address(vault));
        assertEq(value, address(resolutionModule1));
        assertTrue(exists);
    }
    
    // ============ Multiple Escrow Contracts Tests ============
    
    function test_multipleEscrowContracts() public {
        EscrowVault vault2 = new EscrowVault(ESCROW_FEE, feeAddress1, address(yieldOps), address(disputeOps), address(moduleManagement));
        vault2.grantRole(vault2.ROLE_ADMIN_CONTRACT(), address(adminContract));
        
        vm.prank(timelock);
        adminContract.registerEscrowContract(address(vault2));
        
        // Queue different values for each vault
        vm.prank(timelock);
        adminContract.queueFeeRecipient(address(vault), feeAddress2);
        
        address feeAddress3 = address(0xFEE3);
        vm.prank(timelock);
        adminContract.queueFeeRecipient(address(vault2), feeAddress3);
        
        // Verify they're independent
        (address value1, , ) = adminContract.getPendingFeeRecipient(address(vault));
        (address value2, , ) = adminContract.getPendingFeeRecipient(address(vault2));
        
        assertEq(value1, feeAddress2);
        assertEq(value2, feeAddress3);
    }
    
    // ============ Event Tests ============
    
    function test_queueFeeRecipient_emitsEvent() public {
        vm.expectEmit(true, true, true, true);
        emit EscrowGovernanceTimelock.FeeRecipientQueued(
            address(vault),
            feeAddress1,
            feeAddress2,
            uint64(block.timestamp + 7 days)
        );
        
        vm.prank(timelock);
        adminContract.queueFeeRecipient(address(vault), feeAddress2);
    }
    
    function test_activateFeeRecipient_emitsEvent() public {
        vm.prank(timelock);
        adminContract.queueFeeRecipient(address(vault), feeAddress2);
        
        vm.warp(block.timestamp + 7 days + 1);
        
        vm.expectEmit(true, true, true, true);
        emit EscrowGovernanceTimelock.FeeRecipientActivated(
            address(vault),
            feeAddress1,
            feeAddress2
        );
        
        vm.prank(timelock);
        adminContract.activateFeeRecipient(address(vault));
    }
}
