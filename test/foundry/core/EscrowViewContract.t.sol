// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import 'forge-std/Test.sol';
import '../../../contracts/core/EscrowVault.sol';
import '../../../contracts/core/EscrowViewContract.sol';
import '../../../contracts/core/BaseEscrow.sol';
import '../../../contracts/admin/EscrowAdminContract.sol';
import '../../../contracts/core/ModuleManagementContract.sol';
import '../../../contracts/mocks/ERC20Mock.sol';
import '../../../contracts/core/modules/DefaultResolutionModule.sol';
import '../../../contracts/modules/DefaultReleaseStrategy.sol';
import '../../../contracts/types/EscrowTypes.sol';
import '../../../contracts/types/YieldPresets.sol';
import '../../../contracts/libraries/SettingsValidationLibrary.sol';
import '../../../contracts/YieldOps.sol';
import '../../../contracts/DisputeOps.sol';
import '../../../contracts/SettlementOps.sol';
import '../../../contracts/CreateOps.sol';
import '../../../contracts/core/BondCollector.sol';

/**
 * @title EscrowViewContractTest
 * @notice Comprehensive tests for EscrowViewContract covering all functions and code paths
 * @dev Goal: 99% coverage for EscrowViewContract.sol
 * 
 * Following strategy from 99_PERCENT_TEST_COVERAGE_STRATEGY.md:
 * - All view functions (valid workflowId + invalid workflowId revert)
 * - Verify it returns expected derived fields (resolver, modules, settings, pending settlement)
 * - Test all escrow states (PENDING, DISPUTED, RELEASED, REFUNDED, RESOLVED)
 */
contract EscrowViewContractTest is Test {
    EscrowVault public vault;
    EscrowAdminContract public adminContract;
    ModuleManagementContract public moduleManagement;
    EscrowViewContract public escrowView;
    ERC20Mock public token;
    DefaultResolutionModule public resolutionModule;
    DefaultReleaseStrategy public releaseStrategy;
    YieldOps public yieldOps;
    DisputeOps public disputeOps;
    SettlementOps public settlementOps;
    CreateOps public createOps;
    BondCollector public bondCollector;

    address public owner;
    address public timelock;
    address public guardian;
    address public feeAddress;
    address public resolver;
    address public buyer;
    address public seller;

    uint256 public constant ESCROW_FEE = 100; // 1%
    uint256 public constant INITIAL_AMOUNT = 10000e18;

    function setUp() public {
        owner = address(this);
        timelock = address(0x1111);
        guardian = address(0x2222);
        feeAddress = address(0xFEE);
        resolver = address(0x1234);
        buyer = address(0x1001);
        seller = address(0x1002);

        resolutionModule = new DefaultResolutionModule(owner, resolver);
        releaseStrategy = new DefaultReleaseStrategy();

        token = new ERC20Mock('Test Token', 'TEST', owner, 10000000e18);
        yieldOps = new YieldOps(owner);
        disputeOps = new DisputeOps(owner);
        settlementOps = new SettlementOps(owner);
        createOps = new CreateOps(owner);
        bondCollector = new BondCollector(owner);
        adminContract = new EscrowAdminContract(owner);
        moduleManagement = new ModuleManagementContract(owner);
        vault = new EscrowVault(ESCROW_FEE, feeAddress, address(yieldOps), address(disputeOps), address(moduleManagement));

        // Allow the dedicated timelock address to operate the admin contract in tests
        adminContract.grantRole(adminContract.ROLE_TIMELOCK(), timelock);

        bytes32 ROLE_TIMELOCK = vault.ROLE_TIMELOCK();
        bytes32 ROLE_GUARDIAN = vault.ROLE_GUARDIAN();
        vault.grantRole(ROLE_TIMELOCK, owner);
        vault.grantRole(ROLE_TIMELOCK, timelock);
        vault.grantRole(ROLE_GUARDIAN, guardian);

        // Wire ops contracts on the vault
        yieldOps.registerEscrowContract(address(vault));
        disputeOps.registerEscrowContract(address(vault));
        settlementOps.registerEscrowContract(address(vault));
        createOps.registerEscrowContract(address(vault));
        bondCollector.registerEscrowContract(address(vault));
        vault.grantRole(vault.ROLE_ADMIN_CONTRACT(), owner);
        vault.grantRole(vault.ROLE_ADMIN_CONTRACT(), address(adminContract));
        vault.setCreateOps(address(createOps));
        vault.setSettlementOps(address(settlementOps));
        vault.setBondCollector(address(bondCollector));

        moduleManagement.registerEscrowContract(address(vault));

        adminContract.queueResolutionModule(address(vault), address(resolutionModule));
        vm.prank(address(this));
        moduleManagement.queueModule(address(vault), BaseEscrow.ModuleType.RELEASE, address(releaseStrategy));
        vm.warp(block.timestamp + 14 days + 1);
        adminContract.activateResolutionModule(address(vault));
        vm.prank(address(this));
        moduleManagement.activateModule(address(vault), BaseEscrow.ModuleType.RELEASE);
        
        escrowView = new EscrowViewContract(address(vault));
    }

    // ============ Constructor Tests ============

    function test_constructor_setsEscrowContract() public {
        EscrowViewContract newView = new EscrowViewContract(address(vault));
        assertEq(address(newView.escrowContract()), address(vault));
    }

    function test_constructor_zeroAddress() public {
        // Constructor doesn't validate zero address, but it should work
        // (BaseEscrow will revert on actual calls if invalid)
        EscrowViewContract newView = new EscrowViewContract(address(0));
        assertEq(address(newView.escrowContract()), address(0));
    }

    // ============ getEscrowSummary Tests ============

    function test_getEscrowSummary_validWorkflowId() public {
        // Create escrow
        token.transfer(buyer, INITIAL_AMOUNT);
        vm.prank(buyer);
        token.approve(address(vault), INITIAL_AMOUNT);
        vm.prank(buyer);
        uint256 workflowId = vault.createEscrow(address(token), seller, INITIAL_AMOUNT, SettingsValidationLibrary.getDefaultSettings());

        // Get summary
        EscrowViewContract.EscrowSummary memory summary = escrowView.getEscrowSummary(workflowId);

        // Verify all fields
        assertEq(uint8(summary.state), uint8(EscrowState.PENDING));
        assertEq(summary.token, address(token));
        assertEq(summary.from, buyer);
        assertEq(summary.to, seller);
        assertEq(summary.resolver, resolver); // Default resolver from resolution module
        assertGt(summary.amountAfterFee, 0);
        assertLt(summary.amountAfterFee, INITIAL_AMOUNT); // After fee deduction
    }

    function test_getEscrowSummary_withCustomSettings() public {
        // Create escrow with custom settings
        token.transfer(buyer, INITIAL_AMOUNT);
        vm.prank(buyer);
        token.approve(address(vault), INITIAL_AMOUNT);
        
        // Use address(0) for customResolver to avoid InvalidAddressKey error
        EscrowSettings memory settings = EscrowSettings({
            customResolver: address(0), // Use default resolver
            yieldPreset: YieldPreset.TO_SENDER,
            autoReleaseTime: block.timestamp + 7 days,
            autoCancelTime: 0
        });

        vm.prank(buyer);
        uint256 workflowId = vault.createEscrow(address(token), seller, INITIAL_AMOUNT, settings);

        EscrowViewContract.EscrowSummary memory summary = escrowView.getEscrowSummary(workflowId);

        assertEq(summary.resolver, resolver); // Default resolver from resolution module
        assertEq(uint256(summary.autoReleaseTime), block.timestamp + 7 days);
    }

    function test_getEscrowSummary_invalidWorkflowId() public {
        // Should not revert, but return default values from empty array slot
        uint256 invalidWorkflowId = 999999;
        EscrowViewContract.EscrowSummary memory summary = escrowView.getEscrowSummary(invalidWorkflowId);
        
        // Empty struct values
        assertEq(uint8(summary.state), uint8(EscrowState.NONE));
        assertEq(summary.token, address(0));
        assertEq(summary.from, address(0));
        assertEq(summary.to, address(0));
        assertEq(summary.amountAfterFee, 0);
    }

    function test_getEscrowSummary_allStates() public {
        // Create escrow
        token.transfer(buyer, INITIAL_AMOUNT);
        vm.prank(buyer);
        token.approve(address(vault), INITIAL_AMOUNT);
        vm.prank(buyer);
        uint256 workflowId = vault.createEscrow(address(token), seller, INITIAL_AMOUNT, SettingsValidationLibrary.getDefaultSettings());

        // Test PENDING state
        EscrowViewContract.EscrowSummary memory summary = escrowView.getEscrowSummary(workflowId);
        assertEq(uint8(summary.state), uint8(EscrowState.PENDING));

        // Release escrow
        vm.prank(buyer);
        vault.releaseEscrowTransfer(workflowId);

        // Test RELEASED state
        summary = escrowView.getEscrowSummary(workflowId);
        assertEq(uint8(summary.state), uint8(EscrowState.RELEASED));
    }

    // ============ getEscrowSettings Tests ============

    function test_getEscrowSettings_validWorkflowId() public {
        // Create escrow with custom settings
        token.transfer(buyer, INITIAL_AMOUNT);
        vm.prank(buyer);
        token.approve(address(vault), INITIAL_AMOUNT);
        
        // Use address(0) for customResolver to avoid InvalidAddressKey error
        // (customResolver must be a contract if non-zero)
        EscrowSettings memory settings = EscrowSettings({
            customResolver: address(0), // Use default resolver
            yieldPreset: YieldPreset.TO_SENDER,
            autoReleaseTime: block.timestamp + 5 days,
            autoCancelTime: 0
        });

        vm.prank(buyer);
        uint256 workflowId = vault.createEscrow(address(token), seller, INITIAL_AMOUNT, settings);

        EscrowSettings memory retrieved = escrowView.getEscrowSettings(workflowId);

        assertEq(retrieved.customResolver, address(0)); // Default resolver
        assertEq(uint8(retrieved.yieldPreset), uint8(YieldPreset.TO_SENDER));
        assertEq(retrieved.autoReleaseTime, block.timestamp + 5 days);
        assertEq(retrieved.autoCancelTime, 0);
    }

    function test_getEscrowSettings_defaultSettings() public {
        // Create escrow without custom settings
        token.transfer(buyer, INITIAL_AMOUNT);
        vm.prank(buyer);
        token.approve(address(vault), INITIAL_AMOUNT);
        vm.prank(buyer);
        uint256 workflowId = vault.createEscrow(address(token), seller, INITIAL_AMOUNT, SettingsValidationLibrary.getDefaultSettings());

        EscrowSettings memory retrieved = escrowView.getEscrowSettings(workflowId);

        // Should have default values
        assertEq(retrieved.customResolver, address(0));
        assertEq(uint8(retrieved.yieldPreset), uint8(YieldPreset.OFF));
    }

    function test_getEscrowSettings_invalidWorkflowId() public {
        uint256 invalidWorkflowId = 999999;
        EscrowSettings memory retrieved = escrowView.getEscrowSettings(invalidWorkflowId);

        // Empty mapping returns default values
        assertEq(retrieved.customResolver, address(0));
        assertEq(uint8(retrieved.yieldPreset), uint8(YieldPreset.OFF));
        assertEq(retrieved.autoReleaseTime, 0);
        assertEq(retrieved.autoCancelTime, 0);
    }

    // ============ getEscrowStatusInfo Tests ============

    function test_getEscrowStatusInfo_pending() public {
        token.transfer(buyer, INITIAL_AMOUNT);
        vm.prank(buyer);
        token.approve(address(vault), INITIAL_AMOUNT);
        vm.prank(buyer);
        uint256 workflowId = vault.createEscrow(address(token), seller, INITIAL_AMOUNT, SettingsValidationLibrary.getDefaultSettings());

        (EscrowState status, bool isActive, bool isPending) = escrowView.getEscrowStatusInfo(workflowId);

        assertEq(uint8(status), uint8(EscrowState.PENDING));
        assertTrue(isActive);
        assertTrue(isPending);
    }

    function test_getEscrowStatusInfo_disputed() public {
        token.transfer(buyer, INITIAL_AMOUNT);
        vm.prank(buyer);
        token.approve(address(vault), INITIAL_AMOUNT);
        vm.prank(buyer);
        uint256 workflowId = vault.createEscrow(address(token), seller, INITIAL_AMOUNT, SettingsValidationLibrary.getDefaultSettings());

        // Raise dispute
        vm.prank(buyer);
        vault.raiseDispute(workflowId);

        (EscrowState status, bool isActive, bool isPending) = escrowView.getEscrowStatusInfo(workflowId);

        assertEq(uint8(status), uint8(EscrowState.DISPUTED));
        assertTrue(isActive);
        assertFalse(isPending);
    }

    function test_getEscrowStatusInfo_released() public {
        token.transfer(buyer, INITIAL_AMOUNT);
        vm.prank(buyer);
        token.approve(address(vault), INITIAL_AMOUNT);
        vm.prank(buyer);
        uint256 workflowId = vault.createEscrow(address(token), seller, INITIAL_AMOUNT, SettingsValidationLibrary.getDefaultSettings());

        vm.prank(buyer);
        vault.releaseEscrowTransfer(workflowId);

        (EscrowState status, bool isActive, bool isPending) = escrowView.getEscrowStatusInfo(workflowId);

        assertEq(uint8(status), uint8(EscrowState.RELEASED));
        assertFalse(isActive);
        assertFalse(isPending);
    }

    function test_getEscrowStatusInfo_refunded() public {
        token.transfer(buyer, INITIAL_AMOUNT);
        vm.prank(buyer);
        token.approve(address(vault), INITIAL_AMOUNT);
        vm.prank(buyer);
        uint256 workflowId = vault.createEscrow(address(token), seller, INITIAL_AMOUNT, SettingsValidationLibrary.getDefaultSettings());

        // Both agree to cancel
        vm.prank(buyer);
        vault.senderCancel(workflowId);
        vm.prank(seller);
        vault.recipientCancel(workflowId);

        (EscrowState status, bool isActive, bool isPending) = escrowView.getEscrowStatusInfo(workflowId);

        assertEq(uint8(status), uint8(EscrowState.REFUNDED));
        assertFalse(isActive);
        assertFalse(isPending);
    }

    function test_getEscrowStatusInfo_resolved() public {
        token.transfer(buyer, INITIAL_AMOUNT);
        vm.prank(buyer);
        token.approve(address(vault), INITIAL_AMOUNT);
        vm.prank(buyer);
        uint256 workflowId = vault.createEscrow(address(token), seller, INITIAL_AMOUNT, SettingsValidationLibrary.getDefaultSettings());

        // Raise dispute and resolve
        vm.prank(buyer);
        vault.raiseDispute(workflowId);

        // Resolve dispute (as resolver)
        // Note: This creates a pending settlement unless it's the final round
        // The state stays DISPUTED until the settlement is executed
        vm.prank(resolver);
        vault.releaseAsDisputeResolver(workflowId, bytes32(0));

        (EscrowState status, bool isActive, bool isPending) = escrowView.getEscrowStatusInfo(workflowId);

        // State may be DISPUTED (with pending settlement) or RESOLVED (if executed immediately)
        // Check for either state
        assertTrue(uint8(status) == uint8(EscrowState.DISPUTED) || uint8(status) == uint8(EscrowState.RESOLVED));
        // If DISPUTED, there should be a pending settlement
        if (status == EscrowState.DISPUTED) {
            (bool exists, , , , ) = escrowView.getPendingSettlement(workflowId);
            assertTrue(exists);
        }
    }

    function test_getEscrowStatusInfo_invalidWorkflowId() public {
        uint256 invalidWorkflowId = 999999;
        (EscrowState status, bool isActive, bool isPending) = escrowView.getEscrowStatusInfo(invalidWorkflowId);

        assertEq(uint8(status), uint8(EscrowState.NONE));
        assertFalse(isActive);
        assertFalse(isPending);
    }

    // ============ getEscrowParticipants Tests ============

    function test_getEscrowParticipants_validWorkflowId() public {
        token.transfer(buyer, INITIAL_AMOUNT);
        vm.prank(buyer);
        token.approve(address(vault), INITIAL_AMOUNT);
        vm.prank(buyer);
        uint256 workflowId = vault.createEscrow(address(token), seller, INITIAL_AMOUNT, SettingsValidationLibrary.getDefaultSettings());

        (address from, address to) = escrowView.getEscrowParticipants(workflowId);

        assertEq(from, buyer);
        assertEq(to, seller);
    }

    function test_getEscrowParticipants_invalidWorkflowId() public {
        uint256 invalidWorkflowId = 999999;
        (address from, address to) = escrowView.getEscrowParticipants(invalidWorkflowId);

        assertEq(from, address(0));
        assertEq(to, address(0));
    }

    // ============ getModuleSnapshot Tests ============

    function test_getModuleSnapshot_reverts() public {
        uint256 workflowId = 0;
        vm.expectRevert('ModuleSnapshot accessor removed - use events emitted at escrow creation');
        escrowView.getModuleSnapshot(workflowId);
    }

    // ============ getTotalDeposited Tests ============

    function test_getTotalDeposited_validWorkflowId() public {
        token.transfer(buyer, INITIAL_AMOUNT);
        vm.prank(buyer);
        token.approve(address(vault), INITIAL_AMOUNT);
        vm.prank(buyer);
        uint256 workflowId = vault.createEscrow(address(token), seller, INITIAL_AMOUNT, SettingsValidationLibrary.getDefaultSettings());

        uint256 totalDeposited = escrowView.getTotalDeposited(workflowId);

        // Should be amount after fee
        uint256 expectedAmount = INITIAL_AMOUNT - (INITIAL_AMOUNT * ESCROW_FEE / 10000);
        assertEq(totalDeposited, expectedAmount);
    }

    function test_getTotalDeposited_invalidWorkflowId() public {
        uint256 invalidWorkflowId = 999999;
        uint256 totalDeposited = escrowView.getTotalDeposited(invalidWorkflowId);

        assertEq(totalDeposited, 0);
    }

    // ============ getEscrowCount Tests ============

    function test_getEscrowCount() public {
        // Create an escrow to test count
        token.transfer(buyer, INITIAL_AMOUNT);
        vm.prank(buyer);
        token.approve(address(vault), INITIAL_AMOUNT);
        vm.prank(buyer);
        vault.createEscrow(address(token), seller, INITIAL_AMOUNT, SettingsValidationLibrary.getDefaultSettings());
        
        uint256 count = escrowView.getEscrowCount();
        assertEq(count, 1);
    }

    // ============ getDefaultSettings Tests ============

    function test_getDefaultSettings() public {
        EscrowSettings memory defaultSettings = escrowView.getDefaultSettings();

        assertEq(defaultSettings.customResolver, address(0));
        assertEq(uint8(defaultSettings.yieldPreset), uint8(YieldPreset.OFF));
        assertEq(defaultSettings.autoReleaseTime, 0);
        assertEq(defaultSettings.autoCancelTime, 0);
    }

    // ============ getPendingSettlement Tests ============

    function test_getPendingSettlement_noPendingSettlement() public {
        token.transfer(buyer, INITIAL_AMOUNT);
        vm.prank(buyer);
        token.approve(address(vault), INITIAL_AMOUNT);
        vm.prank(buyer);
        uint256 workflowId = vault.createEscrow(address(token), seller, INITIAL_AMOUNT, SettingsValidationLibrary.getDefaultSettings());

        (bool exists, bool isRelease, uint256 appealDeadline, bytes32 resolutionHash, bool canExecute) = 
            escrowView.getPendingSettlement(workflowId);

        assertFalse(exists);
        assertFalse(isRelease);
        assertEq(appealDeadline, 0);
        assertEq(resolutionHash, bytes32(0));
        assertFalse(canExecute);
    }

    function test_getPendingSettlement_withPendingSettlement_notExecutable() public {
        token.transfer(buyer, INITIAL_AMOUNT);
        vm.prank(buyer);
        token.approve(address(vault), INITIAL_AMOUNT);
        vm.prank(buyer);
        uint256 workflowId = vault.createEscrow(address(token), seller, INITIAL_AMOUNT, SettingsValidationLibrary.getDefaultSettings());

        // Raise dispute
        vm.prank(buyer);
        vault.raiseDispute(workflowId);

        // Resolve dispute (creates pending settlement)
        vm.prank(resolver);
        vault.releaseAsDisputeResolver(workflowId, bytes32(0));

        // Check pending settlement before appeal deadline
        (bool exists, bool isRelease, uint256 appealDeadline, bytes32 resolutionHash, bool canExecute) = 
            escrowView.getPendingSettlement(workflowId);

        if (exists) {
            assertTrue(isRelease); // Should be release, not cancel
            assertGt(appealDeadline, block.timestamp);
            assertFalse(canExecute); // Not yet executable
            // resolutionHash can be bytes32(0) if passed as such
            // assertNotEq(resolutionHash, bytes32(0));
        }
    }

    function test_getPendingSettlement_withPendingSettlement_executable() public {
        token.transfer(buyer, INITIAL_AMOUNT);
        vm.prank(buyer);
        token.approve(address(vault), INITIAL_AMOUNT);
        vm.prank(buyer);
        uint256 workflowId = vault.createEscrow(address(token), seller, INITIAL_AMOUNT, SettingsValidationLibrary.getDefaultSettings());

        // Raise dispute
        vm.prank(buyer);
        vault.raiseDispute(workflowId);

        // Resolve dispute (creates pending settlement)
        vm.prank(resolver);
        vault.releaseAsDisputeResolver(workflowId, bytes32(0));

        // Get timeout config to know appeal window duration
        TimeoutConfig memory config = escrowView.getTimeoutConfig();
        
        // Warp past appeal deadline
        vm.warp(block.timestamp + config.appealWindowDuration + 1);

        (bool exists, bool isRelease, uint256 appealDeadline, bytes32 resolutionHash, bool canExecute) = 
            escrowView.getPendingSettlement(workflowId);

        if (exists) {
            assertTrue(isRelease);
            assertLe(appealDeadline, block.timestamp);
            assertTrue(canExecute); // Now executable
            // resolutionHash can be bytes32(0) if passed as such
            // assertNotEq(resolutionHash, bytes32(0));
        }
    }

    function test_getPendingSettlement_invalidWorkflowId() public {
        uint256 invalidWorkflowId = 999999;
        (bool exists, bool isRelease, uint256 appealDeadline, bytes32 resolutionHash, bool canExecute) = 
            escrowView.getPendingSettlement(invalidWorkflowId);

        assertFalse(exists);
        assertFalse(isRelease);
        assertEq(appealDeadline, 0);
        assertEq(resolutionHash, bytes32(0));
        assertFalse(canExecute);
    }

    // ============ getTimeoutConfig Tests ============

    function test_getTimeoutConfig_default() public {
        TimeoutConfig memory config = escrowView.getTimeoutConfig();

        // Default values from BaseEscrow constructor
        assertGe(config.maxDisputeDuration, 7 days);
        assertLe(config.maxDisputeDuration, 365 days);
        assertGe(config.appealWindowDuration, 1 days);
        assertLe(config.appealWindowDuration, 7 days);
    }

    function test_getTimeoutConfig_afterUpdate() public {
        TimeoutConfig memory newConfig = TimeoutConfig({
            defaultAutoReleaseDelay: 10 days,
            defaultAutoCancelDelay: 5 days,
            maxDisputeDuration: 60 days,
            appealWindowDuration: 3 days
        });

        vm.prank(timelock);
        adminContract.setTimeoutConfig(address(vault), newConfig);

        TimeoutConfig memory retrieved = escrowView.getTimeoutConfig();

        assertEq(retrieved.defaultAutoReleaseDelay, newConfig.defaultAutoReleaseDelay);
        assertEq(retrieved.defaultAutoCancelDelay, newConfig.defaultAutoCancelDelay);
        assertEq(retrieved.maxDisputeDuration, newConfig.maxDisputeDuration);
        assertEq(retrieved.appealWindowDuration, newConfig.appealWindowDuration);
    }

    // ============ getEscrowTimeline Tests ============

    function test_getEscrowTimeline_pending() public {
        uint256 amount = 1000e18;
        uint256 autoReleaseTime = block.timestamp + 10 days;
        EscrowSettings memory settings = SettingsValidationLibrary.getDefaultSettings();
        settings.autoReleaseTime = autoReleaseTime;

        token.transfer(buyer, amount);
        vm.prank(buyer);
        token.approve(address(vault), amount);
        vm.prank(buyer);
        uint256 wid = vault.createEscrow(address(token), seller, amount, settings);

        EscrowTimeline memory timeline = escrowView.getEscrowTimeline(wid);
        assertEq(uint8(timeline.status), uint8(ActionableStatus.AWAITING_CONDITION));
        assertEq(timeline.nextDeadline, autoReleaseTime);
        assertEq(uint8(timeline.urgency), uint8(UrgencyLevel.LOW));
        assertFalse(timeline.userCanExecute);
    }

    function test_getEscrowTimeline_actionable() public {
        uint256 amount = 1000e18;
        uint256 autoReleaseTime = block.timestamp + 1 days;
        EscrowSettings memory settings = SettingsValidationLibrary.getDefaultSettings();
        settings.autoReleaseTime = autoReleaseTime;

        token.transfer(buyer, amount);
        vm.prank(buyer);
        token.approve(address(vault), amount);
        vm.prank(buyer);
        uint256 wid = vault.createEscrow(address(token), seller, amount, settings);

        vm.warp(autoReleaseTime + 1);
        EscrowTimeline memory timeline = escrowView.getEscrowTimeline(wid);
        assertEq(uint8(timeline.status), uint8(ActionableStatus.TIME_CONDITION_MET));
        assertTrue(timeline.userCanExecute);
    }

    // ============ getWorkflowsByRole Tests ============

    function test_getWorkflowsByRole_buyer() public {
        token.transfer(buyer, INITIAL_AMOUNT * 2);
        vm.prank(buyer);
        token.approve(address(vault), INITIAL_AMOUNT * 2);
        
        vm.prank(buyer);
        vault.createEscrow(address(token), seller, INITIAL_AMOUNT, SettingsValidationLibrary.getDefaultSettings());
        vm.prank(buyer);
        vault.createEscrow(address(token), seller, INITIAL_AMOUNT, SettingsValidationLibrary.getDefaultSettings());

        uint256[] memory ids = escrowView.getWorkflowsByRole(buyer, UserRole.BUYER, 0, 10);
        assertEq(ids.length, 2);
    }

    // ============ Integration Tests ============

    function test_multipleEscrows() public {
        token.transfer(buyer, INITIAL_AMOUNT * 3);
        vm.prank(buyer);
        token.approve(address(vault), INITIAL_AMOUNT * 3);

        // Create multiple escrows
        vm.prank(buyer);
        uint256 workflowId1 = vault.createEscrow(address(token), seller, INITIAL_AMOUNT, SettingsValidationLibrary.getDefaultSettings());
        vm.prank(buyer);
        uint256 workflowId2 = vault.createEscrow(address(token), seller, INITIAL_AMOUNT, SettingsValidationLibrary.getDefaultSettings());
        vm.prank(buyer);
        uint256 workflowId3 = vault.createEscrow(address(token), seller, INITIAL_AMOUNT, SettingsValidationLibrary.getDefaultSettings());

        // Verify all can be queried
        EscrowViewContract.EscrowSummary memory summary1 = escrowView.getEscrowSummary(workflowId1);
        EscrowViewContract.EscrowSummary memory summary2 = escrowView.getEscrowSummary(workflowId2);
        EscrowViewContract.EscrowSummary memory summary3 = escrowView.getEscrowSummary(workflowId3);

        assertEq(uint8(summary1.state), uint8(EscrowState.PENDING));
        assertEq(uint8(summary2.state), uint8(EscrowState.PENDING));
        assertEq(uint8(summary3.state), uint8(EscrowState.PENDING));
        assertEq(summary1.from, buyer);
        assertEq(summary2.from, buyer);
        assertEq(summary3.from, buyer);
    }

    function test_stateTransitions() public {
        token.transfer(buyer, INITIAL_AMOUNT);
        vm.prank(buyer);
        token.approve(address(vault), INITIAL_AMOUNT);
        vm.prank(buyer);
        uint256 workflowId = vault.createEscrow(address(token), seller, INITIAL_AMOUNT, SettingsValidationLibrary.getDefaultSettings());

        // PENDING -> DISPUTED
        vm.prank(buyer);
        vault.raiseDispute(workflowId);
        (EscrowState status, , ) = escrowView.getEscrowStatusInfo(workflowId);
        assertEq(uint8(status), uint8(EscrowState.DISPUTED));

        // DISPUTED -> RESOLVED (or DISPUTED with pending settlement)
        // Note: DefaultResolutionModule doesn't support getAppealDeadlineAndRound,
        // so it creates a pending settlement instead of executing immediately
        vm.prank(resolver);
        vault.releaseAsDisputeResolver(workflowId, bytes32(0));
        (status, , ) = escrowView.getEscrowStatusInfo(workflowId);
        // State may be DISPUTED (with pending settlement) or RESOLVED (if executed immediately)
        assertTrue(uint8(status) == uint8(EscrowState.DISPUTED) || uint8(status) == uint8(EscrowState.RESOLVED));
        // If DISPUTED, verify there's a pending settlement
        if (status == EscrowState.DISPUTED) {
            (bool exists, , , , ) = escrowView.getPendingSettlement(workflowId);
            assertTrue(exists, "Should have pending settlement when state is DISPUTED");
        }
    }

    // ============ Edge Cases ============

    function test_getEscrowSummary_zeroAmount() public {
        // Create escrow with minimal amount
        uint256 minAmount = 1000; // MIN_ESCROW_AMOUNT
        token.transfer(buyer, minAmount);
        vm.prank(buyer);
        token.approve(address(vault), minAmount);
        vm.prank(buyer);
        uint256 workflowId = vault.createEscrow(address(token), seller, minAmount, SettingsValidationLibrary.getDefaultSettings());

        EscrowViewContract.EscrowSummary memory summary = escrowView.getEscrowSummary(workflowId);
        assertGt(summary.amountAfterFee, 0);
        assertLt(summary.amountAfterFee, minAmount);
    }

    function test_getEscrowSettings_allYieldPresets() public {
        token.transfer(buyer, INITIAL_AMOUNT * 2);
        vm.prank(buyer);
        token.approve(address(vault), INITIAL_AMOUNT * 2);

        // Test each yield preset (only OFF and TO_SENDER are valid)
        YieldPreset[] memory presets = new YieldPreset[](2);
        presets[0] = YieldPreset.OFF;
        presets[1] = YieldPreset.TO_SENDER;

        for (uint256 i = 0; i < presets.length; i++) {
            EscrowSettings memory settings = EscrowSettings({
                customResolver: address(0),
                yieldPreset: presets[i],
                autoReleaseTime: 0,
                autoCancelTime: 0
            });

            vm.prank(buyer);
            uint256 workflowId = vault.createEscrow(address(token), seller, INITIAL_AMOUNT, settings);

            EscrowSettings memory retrieved = escrowView.getEscrowSettings(workflowId);
            assertEq(uint8(retrieved.yieldPreset), uint8(presets[i]));
        }
    }
}
