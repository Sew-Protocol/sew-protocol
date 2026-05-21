// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import "forge-std/Test.sol";
import "../../../contracts/modules/DefaultCancellationStrategy.sol";
import "../../../contracts/modules/BuyerOnlyCancellationStrategy.sol";
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
 * @title CancellationStrategySwapTest
 * @notice Tests swapping between cancellation strategies
 */
contract CancellationStrategySwapTest is Test {
    EscrowVault public vault;
    CreateOps public createOps;
    YieldOps public yieldOps;
    DisputeOps public disputeOps;
    SettlementOps public settlementOps;
    BondCollector public bondCollector;
    ModuleSnapshotRegistry public moduleManagement;
    DefaultCancellationStrategy public defaultStrategy;
    BuyerOnlyCancellationStrategy public buyerOnlyStrategy;
    
    ERC20Mock public token;
    
    address public sender = address(0x1001);
    address public recipient = address(0x1002);
    address public feeAddress = address(0xFEE);
    
    uint256 constant ESCROW_FEE = 200;
    
    function setUp() public {
        token = new ERC20Mock("Test", "TST", address(this), 10000e18);
        
        yieldOps = new YieldOps(address(this));
        disputeOps = new DisputeOps(address(this));
        settlementOps = new SettlementOps(address(this));
        createOps = new CreateOps(address(this));
        
        bondCollector = new BondCollector(address(this));
        moduleManagement = new ModuleSnapshotRegistry(address(this));
        
        defaultStrategy = new DefaultCancellationStrategy();
        buyerOnlyStrategy = new BuyerOnlyCancellationStrategy();
        
        vault = new EscrowVault(ESCROW_FEE, feeAddress, address(yieldOps), address(disputeOps), address(moduleManagement));
        
        moduleManagement.registerEscrowContract(address(vault));
        yieldOps.registerEscrowContract(address(vault));
        disputeOps.registerEscrowContract(address(vault));
        settlementOps.registerEscrowContract(address(vault));
        createOps.registerEscrowContract(address(vault));
        bondCollector.registerEscrowContract(address(vault));
        
        vault.grantRole(vault.ROLE_ADMIN_CONTRACT(), address(this));
        vault.grantRole(vault.ROLE_FEE_RECIPIENT(), address(this));
        vault.setCreateOps(address(createOps));
        vault.setSettlementOps(address(settlementOps));
        vault.setBondCollector(address(bondCollector));
        
        token.transfer(sender, 1000e18);
    }

    function _setStrategy(address strategy) internal {
        moduleManagement.queueModule(address(vault), BaseEscrow.ModuleType.CANCELLATION, strategy);
        vm.warp(block.timestamp + 7 days + 1);
        moduleManagement.activateModule(address(vault), BaseEscrow.ModuleType.CANCELLATION);
    }

    // ============ Test: Default Strategy (Mutual Consent) ============

    /**
     * @notice With default strategy, BOTH parties must agree to cancel
     */
    function test_default_strategy_requires_mutual_consent() public {
        _setStrategy(address(defaultStrategy));
        
        vm.prank(sender);
        token.approve(address(vault), 100e18);
        
        EscrowSettings memory settings = SettingsValidationLibrary.getDefaultSettings();
        settings.yieldPreset = YieldPreset.OFF;
        
        vm.prank(sender);
        uint256 wid = vault.createEscrow(address(token), recipient, 100e18, settings);
        
        // Sender initiates cancel
        vm.prank(sender);
        vault.senderCancel(wid);
        
        // Check: still pending (needs recipient too)
        (,,,,,,, EscrowState state,,) = vault.escrowTransfers(wid);
        assertEq(uint8(state), uint8(EscrowState.PENDING), "Needs mutual consent");
        
        // Recipient completes
        vm.prank(recipient);
        vault.recipientCancel(wid);
        
        // Check: refunded
        (,,,,,,, state,,) = vault.escrowTransfers(wid);
        assertEq(uint8(state), uint8(EscrowState.REFUNDED), "Should be refunded");
    }

    /**
     * @notice With default strategy, sender cannot cancel alone
     */
    function test_default_strategy_sender_cannot_cancel_alone() public {
        _setStrategy(address(defaultStrategy));
        
        vm.prank(sender);
        token.approve(address(vault), 100e18);
        
        EscrowSettings memory settings = SettingsValidationLibrary.getDefaultSettings();
        settings.yieldPreset = YieldPreset.OFF;
        
        vm.prank(sender);
        uint256 wid = vault.createEscrow(address(token), recipient, 100e18, settings);
        
        // Sender initiates cancel - status becomes AGREE_TO_CANCEL
        vm.prank(sender);
        vault.senderCancel(wid);
        
        // But escrow should still be PENDING
        (,,,,,,, EscrowState state,,) = vault.escrowTransfers(wid);
        assertEq(uint8(state), uint8(EscrowState.PENDING), "Should still be pending");
    }

    // ============ Test: Buyer-Only Strategy ============

    /**
     * @notice With buyer-only strategy, buyer can cancel anytime
     */
    function test_buyer_only_strategy_buyer_can_cancel_alone() public {
        _setStrategy(address(buyerOnlyStrategy));
        
        vm.prank(sender);
        token.approve(address(vault), 100e18);
        
        EscrowSettings memory settings = SettingsValidationLibrary.getDefaultSettings();
        settings.yieldPreset = YieldPreset.OFF;
        
        vm.prank(sender);
        uint256 wid = vault.createEscrow(address(token), recipient, 100e18, settings);
        
        // Buyer (recipient) cancels directly
        vm.prank(recipient);
        vault.recipientCancel(wid);
        
        // Check: refunded immediately
        (,,,,,,, EscrowState state,,) = vault.escrowTransfers(wid);
        assertEq(uint8(state), uint8(EscrowState.REFUNDED), "Buyer can cancel alone");
    }

    /**
     * @notice With buyer-only strategy, seller CANNOT cancel
     */
    function test_buyer_only_strategy_sender_cannot_cancel() public {
        _setStrategy(address(buyerOnlyStrategy));
        
        vm.prank(sender);
        token.approve(address(vault), 100e18);
        
        EscrowSettings memory settings = SettingsValidationLibrary.getDefaultSettings();
        settings.yieldPreset = YieldPreset.OFF;
        
        vm.prank(sender);
        uint256 wid = vault.createEscrow(address(token), recipient, 100e18, settings);
        
        // Sender tries to cancel - should revert
        vm.prank(sender);
        vm.expectRevert();
        vault.senderCancel(wid);
    }

    // ============ Test: Strategy Swap Between Escrows ============

    /**
     * @notice Different escrows can use different strategies
     */
    function test_different_escrows_different_strategies() public {
        // First escrow uses default (mutual)
        _setStrategy(address(defaultStrategy));
        
        vm.prank(sender);
        token.approve(address(vault), 100e18);
        
        EscrowSettings memory settings = SettingsValidationLibrary.getDefaultSettings();
        settings.yieldPreset = YieldPreset.OFF;
        
        vm.prank(sender);
        uint256 wid1 = vault.createEscrow(address(token), recipient, 100e18, settings);
        
        // Second escrow - swap to buyer-only
        _setStrategy(address(buyerOnlyStrategy));
        
        vm.prank(sender);
        token.approve(address(vault), 200e18);
        
        vm.prank(sender);
        uint256 wid2 = vault.createEscrow(address(token), recipient, 200e18, settings);
        
        // Escrow 1: sender initiates, needs recipient
        vm.prank(sender);
        vault.senderCancel(wid1);
        
        // Escrow 2: recipient cancels immediately
        vm.prank(recipient);
        vault.recipientCancel(wid2);
        
        // Check states
        (,,,,,,, EscrowState state1,,) = vault.escrowTransfers(wid1);
        (,,,,,,, EscrowState state2,,) = vault.escrowTransfers(wid2);
        
        assertEq(uint8(state1), uint8(EscrowState.PENDING), "Escrow1 needs mutual consent");
        assertEq(uint8(state2), uint8(EscrowState.REFUNDED), "Escrow2 cancelled by buyer alone");
    }

    // ============ Test: Strategy Snapshotted at Creation ============

    /**
     * @notice Strategy is snapshotted at escrow creation
     */
    function test_strategy_snapshotted_at_creation() public {
        // Set default to buyer-only
        _setStrategy(address(buyerOnlyStrategy));
        
        vm.prank(sender);
        token.approve(address(vault), 100e18);
        
        EscrowSettings memory settings = SettingsValidationLibrary.getDefaultSettings();
        settings.yieldPreset = YieldPreset.OFF;
        
        vm.prank(sender);
        uint256 wid = vault.createEscrow(address(token), recipient, 100e18, settings);
        
        // Now swap to default - escrow should still use buyer-only
        _setStrategy(address(defaultStrategy));
        
        // Try to cancel as sender - should fail (still buyer-only)
        vm.prank(sender);
        vm.expectRevert();
        vault.senderCancel(wid);
        
        // But buyer can cancel
        vm.prank(recipient);
        vault.recipientCancel(wid);
        
        (,,,,,,, EscrowState state,,) = vault.escrowTransfers(wid);
        assertEq(uint8(state), uint8(EscrowState.REFUNDED), "Used snapshotted strategy");
    }

    // ============ Test: Multiple Cancel Attempts with Different Strategies ============

    /**
     * @notice Test cancellation flow with buyer-only after partial steps
     */
    function test_buyer_only_after_partial_default_flow() public {
        // Start with default strategy
        _setStrategy(address(defaultStrategy));
        
        vm.prank(sender);
        token.approve(address(vault), 100e18);
        
        EscrowSettings memory settings = SettingsValidationLibrary.getDefaultSettings();
        settings.yieldPreset = YieldPreset.OFF;
        
        vm.prank(sender);
        uint256 wid = vault.createEscrow(address(token), recipient, 100e18, settings);
        
        // Swap to buyer-only BEFORE another escrow
        _setStrategy(address(buyerOnlyStrategy));
        
        // Create another escrow with new strategy
        vm.prank(sender);
        token.approve(address(vault), 200e18);
        
        vm.prank(sender);
        uint256 wid2 = vault.createEscrow(address(token), recipient, 200e18, settings);
        
        // First escrow: sender initiated, needs recipient
        vm.prank(sender);
        vault.senderCancel(wid);
        
        // Second escrow: recipient can cancel alone
        vm.prank(recipient);
        vault.recipientCancel(wid2);
        
        (,,,,,,, EscrowState state1,,) = vault.escrowTransfers(wid);
        (,,,,,,, EscrowState state2,,) = vault.escrowTransfers(wid2);
        
        assertEq(uint8(state1), uint8(EscrowState.PENDING), "First still pending");
        assertEq(uint8(state2), uint8(EscrowState.REFUNDED), "Second cancelled");
    }

    // ============ Test: Non-Participant Blocked in Both Strategies ============

    /**
     * @notice Third party cannot cancel in either strategy
     */
    function test_third_party_blocked_in_both_strategies() public {
        address attacker = address(0xDEAD);
        
        // Test with default
        _setStrategy(address(defaultStrategy));
        
        vm.prank(sender);
        token.approve(address(vault), 100e18);
        
        EscrowSettings memory settings = SettingsValidationLibrary.getDefaultSettings();
        settings.yieldPreset = YieldPreset.OFF;
        
        vm.prank(sender);
        uint256 wid = vault.createEscrow(address(token), recipient, 100e18, settings);
        
        vm.prank(attacker);
        vm.expectRevert();
        vault.senderCancel(wid);
        
        // Swap to buyer-only
        _setStrategy(address(buyerOnlyStrategy));
        
        // Need to approve again for second escrow
        vm.prank(sender);
        token.approve(address(vault), 100e18);
        
        vm.prank(sender);
        uint256 wid2 = vault.createEscrow(address(token), recipient, 100e18, settings);
        
        vm.prank(attacker);
        vm.expectRevert();
        vault.recipientCancel(wid2);
    }
}
