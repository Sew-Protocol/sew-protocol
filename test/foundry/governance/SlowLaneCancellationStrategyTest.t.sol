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
 * @title SlowLaneCancellationStrategyTest
 * @notice Verifies that CancellationStrategy upgrades follow the 7-day slow lane governance.
 */
contract SlowLaneCancellationStrategyTest is Test {
    EscrowVault public vault;
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
        
        YieldOps yieldOps = new YieldOps(address(this));
        DisputeOps disputeOps = new DisputeOps(address(this));
        SettlementOps settlementOps = new SettlementOps(address(this));
        CreateOps createOps = new CreateOps(address(this));
        BondCollector bondCollector = new BondCollector(address(this));
        
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
        vault.setCreateOps(address(createOps));
        vault.setSettlementOps(address(settlementOps));
        vault.setBondCollector(address(bondCollector));
        
        token.transfer(sender, 1000e18);
    }

    function _setStrategy(address strategy) internal {
        moduleManagement.queueModule(address(vault), BaseEscrow.ModuleType.CANCELLATION, strategy);
        (, uint64 eta, ) = moduleManagement.getPendingModule(address(vault), BaseEscrow.ModuleType.CANCELLATION);
        vm.warp(eta + 1);
        moduleManagement.activateModule(address(vault), BaseEscrow.ModuleType.CANCELLATION);
    }

    /**
     * @notice Verify that queuing a new cancellation strategy requires 7 days
     */
    function test_slow_lane_cancellation_strategy() public {
        // 1. Queue strategy
        moduleManagement.queueModule(address(vault), BaseEscrow.ModuleType.CANCELLATION, address(defaultStrategy));
        
        // Check pending
        (address pending, uint64 eta, bool exists) = moduleManagement.getPendingModule(address(vault), BaseEscrow.ModuleType.CANCELLATION);
        assertEq(pending, address(defaultStrategy), "Pending strategy should be set");
        assertTrue(exists, "Pending change should exist");
        assertEq(eta, uint64(block.timestamp + 7 days), "ETA should be 7 days from now");
        
        // 2. Try to activate immediately - should fail
        vm.expectRevert(abi.encodeWithSignature("NotReady(uint64)", eta));
        moduleManagement.activateModule(address(vault), BaseEscrow.ModuleType.CANCELLATION);
        
        // 3. Warp to 6 days - should still fail
        vm.warp(block.timestamp + 6 days);
        vm.expectRevert(abi.encodeWithSignature("NotReady(uint64)", eta));
        moduleManagement.activateModule(address(vault), BaseEscrow.ModuleType.CANCELLATION);
        
        // 4. Warp past 7 days - should succeed
        vm.warp(eta + 1);
        moduleManagement.activateModule(address(vault), BaseEscrow.ModuleType.CANCELLATION);
        
        assertEq(moduleManagement.getModule(address(vault), BaseEscrow.ModuleType.CANCELLATION), address(defaultStrategy), "Strategy should be active");
    }

    /**
     * @notice Verify that new escrows use the new strategy after activation,
     * but old escrows created before activation still use the snapshotted old strategy.
     */
    function test_cancellation_strategy_snapshot_consistency() public {
        // Initial strategy: Default (mutual consent)
        _setStrategy(address(defaultStrategy));
        
        // Create Escrow 1
        vm.startPrank(sender);
        token.approve(address(vault), 100e18);
        EscrowSettings memory settings = SettingsValidationLibrary.getDefaultSettings();
        settings.yieldPreset = YieldPreset.OFF;
        uint256 wid1 = vault.createEscrow(address(token), recipient, 100e18, settings);
        vm.stopPrank();
        
        // Check snapshot for Escrow 1
        (,, address strategy1,,,,,,,,,,) = vault.moduleSnapshots(wid1);
        assertEq(strategy1, address(defaultStrategy), "Escrow 1 should use default strategy");
        
        // Queue new strategy: BuyerOnly
        moduleManagement.queueModule(address(vault), BaseEscrow.ModuleType.CANCELLATION, address(buyerOnlyStrategy));
        
        // Create Escrow 2 while BuyerOnly is PENDING
        vm.startPrank(sender);
        token.approve(address(vault), 100e18);
        uint256 wid2 = vault.createEscrow(address(token), recipient, 100e18, settings);
        vm.stopPrank();
        
        // Escrow 2 should still use Default because BuyerOnly is not active
        (,, address strategy2,,,,,,,,,,) = vault.moduleSnapshots(wid2);
        assertEq(strategy2, address(defaultStrategy), "Escrow 2 should still use active default strategy");
        
        // Activate BuyerOnly
        (, uint64 eta, ) = moduleManagement.getPendingModule(address(vault), BaseEscrow.ModuleType.CANCELLATION);
        vm.warp(eta + 1);
        moduleManagement.activateModule(address(vault), BaseEscrow.ModuleType.CANCELLATION);
        
        // Create Escrow 3 after activation
        vm.startPrank(sender);
        token.approve(address(vault), 100e18);
        uint256 wid3 = vault.createEscrow(address(token), recipient, 100e18, settings);
        vm.stopPrank();
        
        // Escrow 3 should use BuyerOnly
        (,, address strategy3,,,,,,,,,,) = vault.moduleSnapshots(wid3);
        assertEq(strategy3, address(buyerOnlyStrategy), "Escrow 3 should use new buyer-only strategy");
        
        // Verify behavioral consistency:
        // Escrow 1 (Default): Sender initiates, still pending
        vm.prank(sender);
        vault.senderCancel(wid1);
        (,,,,,,, EscrowState state1,,) = vault.escrowTransfers(wid1);
        assertEq(uint8(state1), uint8(EscrowState.PENDING), "Escrow 1 needs mutual consent");
        
        // Escrow 3 (BuyerOnly): Recipient cancels alone
        vm.prank(recipient);
        vault.recipientCancel(wid3);
        (,,,,,,, EscrowState state3,,) = vault.escrowTransfers(wid3);
        assertEq(uint8(state3), uint8(EscrowState.REFUNDED), "Escrow 3 cancelled by buyer alone");
    }
}
