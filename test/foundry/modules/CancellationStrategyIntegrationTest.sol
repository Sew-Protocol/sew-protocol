// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import "forge-std/Test.sol";
import "../../../contracts/modules/DefaultCancellationStrategy.sol";
import "../../../contracts/core/EscrowVault.sol";
import "../../../contracts/ops/CreateOps.sol";
import "../../../contracts/ops/YieldOps.sol";
import "../../../contracts/ops/DisputeOps.sol";
import "../../../contracts/ops/SettlementOps.sol";
import "../../../contracts/core/BondCollector.sol";
import "../../../contracts/core/ModuleSnapshotRegistry.sol";
import "../../../contracts/types/EscrowTypes.sol";
import "../../../contracts/types/YieldPresets.sol";
import "../../../contracts/libraries/SettingsValidationLibrary.sol";
import "../../../contracts/mocks/ERC20Mock.sol";

/**
 * @title CancellationStrategyIntegrationTest
 * @notice Integration tests for cancellation strategy with EscrowVault
 */
contract CancellationStrategyIntegrationTest is Test {
    EscrowVault public vault;
    CreateOps public createOps;
    YieldOps public yieldOps;
    DisputeOps public disputeOps;
    SettlementOps public settlementOps;
    BondCollector public bondCollector;
    ModuleSnapshotRegistry public moduleManagement;
    DefaultCancellationStrategy public cancellationStrategy;
    
    ERC20Mock public token;
    
    address public sender = address(0x1001);
    address public recipient = address(0x1002);
    address public admin = address(0xA11);
    address public feeAddress = address(0xFEE);
    
    uint256 constant ESCROW_FEE = 200; // 2.0%
    
    function setUp() public {
        // Deploy mocks
        token = new ERC20Mock("Test", "TST", address(this), 10000e18);
        
        // Deploy ops contracts
        yieldOps = new YieldOps(address(this));
        disputeOps = new DisputeOps(address(this));
        settlementOps = new SettlementOps(address(this));
        createOps = new CreateOps(address(this));
        
        // Deploy bond collector
        bondCollector = new BondCollector(address(this));
        
        // Deploy module management
        moduleManagement = new ModuleSnapshotRegistry(address(this));
        
        // Deploy cancellation strategy
        cancellationStrategy = new DefaultCancellationStrategy();
        
        // Deploy EscrowVault
        vault = new EscrowVault(ESCROW_FEE, feeAddress, address(yieldOps), address(disputeOps), address(moduleManagement));
        
        // Register escrow contract with all ops contracts
        moduleManagement.registerEscrowContract(address(vault));
        yieldOps.registerEscrowContract(address(vault));
        disputeOps.registerEscrowContract(address(vault));
        settlementOps.registerEscrowContract(address(vault));
        createOps.registerEscrowContract(address(vault));
        bondCollector.registerEscrowContract(address(vault));
        
        // Wire required ops contracts on the vault
        vault.grantRole(vault.ROLE_ADMIN_CONTRACT(), address(this));
        vault.setCreateOps(address(createOps));
        vault.setSettlementOps(address(settlementOps));
        vault.setBondCollector(address(bondCollector));
        
        // Setup roles
        vault.grantRole(vault.ROLE_FEE_RECIPIENT(), address(this));
        
        // Fund sender
        token.transfer(sender, 1000e18);
    }

    // ============ Integration Tests ============

    /**
     * @notice Test that escrow uses the default cancellation strategy
     */
    function test_escrow_uses_default_cancellation_strategy() public {
        // Set default cancellation strategy on vault
        vault.setDefaultCancellationStrategy(address(cancellationStrategy));
        
        vm.prank(sender);
        token.approve(address(vault), 100e18);
        
        EscrowSettings memory settings = SettingsValidationLibrary.getDefaultSettings();
        settings.yieldPreset = YieldPreset.OFF;
        
        vm.prank(sender);
        uint256 wid = vault.createEscrow(address(token), recipient, 100e18, settings);
        
        // Check that the cancellation strategy was snapshotted
        // ModuleSnapshot: resolution, release, cancellation, yieldGen, yieldDist, incentive, yieldFee, appealFee, escrowFee, autoRelease, autoCancel, maxDispute, appealWindow
        (,, address cancelStrategy,,,,,,,,,,) = vault.moduleSnapshots(wid);
        assertEq(cancelStrategy, address(cancellationStrategy), "Should use default cancellation strategy");
    }

    /**
     * @notice Test mutual cancellation flow with strategy
     */
    function test_mutual_cancellation_with_strategy() public {
        // Set default cancellation strategy on vault
        vault.setDefaultCancellationStrategy(address(cancellationStrategy));
        
        vm.prank(sender);
        token.approve(address(vault), 100e18);
        
        EscrowSettings memory settings = SettingsValidationLibrary.getDefaultSettings();
        settings.yieldPreset = YieldPreset.OFF;
        
        vm.prank(sender);
        uint256 wid = vault.createEscrow(address(token), recipient, 100e18, settings);
        
        // Sender initiates cancellation
        vm.prank(sender);
        bool senderResult = vault.senderCancel(wid);
        assertTrue(senderResult, "Sender should be able to initiate cancel");
        
        // Check sender status - use proper tuple unpacking
        (,,,,,,, EscrowState state,,) = vault.escrowTransfers(wid);
        assertEq(uint8(state), uint8(EscrowState.PENDING), "Should still be pending");
        
        // Recipient completes cancellation
        vm.prank(recipient);
        bool recipientResult = vault.recipientCancel(wid);
        assertTrue(recipientResult, "Recipient should be able to complete cancel");
        
        // Check final state
        (,,,,,,, state,,) = vault.escrowTransfers(wid);
        assertEq(uint8(state), uint8(EscrowState.REFUNDED), "Should be refunded");
    }

    /**
     * @notice Test that non-participant cannot cancel
     */
    function test_non_participant_cannot_cancel() public {
        // Set default cancellation strategy on vault
        vault.setDefaultCancellationStrategy(address(cancellationStrategy));
        
        vm.prank(sender);
        token.approve(address(vault), 100e18);
        
        EscrowSettings memory settings = SettingsValidationLibrary.getDefaultSettings();
        settings.yieldPreset = YieldPreset.OFF;
        
        vm.prank(sender);
        uint256 wid = vault.createEscrow(address(token), recipient, 100e18, settings);
        
        // Third party tries to cancel
        address attacker = address(0xDEAD);
        
        vm.prank(attacker);
        vm.expectRevert();
        vault.senderCancel(wid);
    }

    /**
     * @notice Test cancellation only works when escrow is PENDING
     */
    function test_cannot_cancel_non_pending_escrow() public {
        // Set default cancellation strategy on vault
        vault.setDefaultCancellationStrategy(address(cancellationStrategy));
        
        vm.prank(sender);
        token.approve(address(vault), 100e18);
        
        EscrowSettings memory settings = SettingsValidationLibrary.getDefaultSettings();
        settings.yieldPreset = YieldPreset.OFF;
        
        vm.prank(sender);
        uint256 wid = vault.createEscrow(address(token), recipient, 100e18, settings);
        
        // Release the escrow first
        vm.prank(sender);
        vault.releaseEscrowTransfer(wid);
        
        // Try to cancel - should fail
        vm.prank(sender);
        vm.expectRevert();
        vault.senderCancel(wid);
    }

    /**
     * @notice Test without cancellation strategy (backward compatible)
     */
    function test_cancellation_without_strategy() public {
        // Don't set any cancellation strategy - should still work with basic flow
        
        vm.prank(sender);
        token.approve(address(vault), 100e18);
        
        EscrowSettings memory settings = SettingsValidationLibrary.getDefaultSettings();
        settings.yieldPreset = YieldPreset.OFF;
        
        vm.prank(sender);
        uint256 wid = vault.createEscrow(address(token), recipient, 100e18, settings);
        
        // Sender initiates cancellation
        vm.prank(sender);
        vault.senderCancel(wid);
        
        // Recipient completes
        vm.prank(recipient);
        vault.recipientCancel(wid);
        
        // Check final state
        (,,,,,,, EscrowState state,,) = vault.escrowTransfers(wid);
        assertEq(uint8(state), uint8(EscrowState.REFUNDED), "Should be refunded");
    }
}
