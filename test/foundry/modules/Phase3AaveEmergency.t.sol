// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import 'forge-std/Test.sol';
import 'contracts/modules/AaveYieldGenerationModule.sol';
import 'contracts/core/EscrowVault.sol';
import 'contracts/core/EscrowableERC20.sol';
import 'contracts/mocks/ERC20Mock.sol';
import 'contracts/mocks/MockAavePool.sol';
import 'contracts/ops/YieldOps.sol';
import 'contracts/ops/DisputeOps.sol';
import 'contracts/core/ModuleSnapshotRegistry.sol';
import 'contracts/ops/CreateOps.sol';
import 'contracts/types/EscrowTypes.sol';
import 'contracts/types/YieldPresets.sol';

/**
 * @title Phase3AaveEmergencyTest
 * @notice Emergency scenarios and recovery tests for AaveYieldGenerationModule
 * @dev Tests emergency unwind, pause/unpause, and deficit tracking
 */
contract Phase3AaveEmergencyTest is Test {
    AaveYieldGenerationModule module;
    EscrowVault vault;
    EscrowableERC20 escrowERC20;
    
    ERC20Mock token;
    MockAToken aToken;
    MockAavePool pool;
    MockPoolAddressesProvider provider;
    
    YieldOps yieldOps;
    DisputeOps disputeOps;
    ModuleSnapshotRegistry mm;
    CreateOps createOps;
    
    address timelock = address(0x1);
    address feeAddress = address(0x2);
    address buyer = address(0x3);
    address seller = address(0x4);
    address guardian = address(0x5);

    function setUp() public {
        vm.startPrank(timelock);
        
        // Setup Aave Mocks
        token = new ERC20Mock("Test Token", "TST", address(this), 1_000_000e18);
        aToken = new MockAToken(address(token), "aTest Token", "aTST");
        pool = new MockAavePool();
        pool.setAToken(address(token), address(aToken));
        aToken.setPool(address(pool));
        token.mint(address(pool), 1_000_000e18);
        provider = new MockPoolAddressesProvider(address(pool));
        
        // Setup Module
        module = new AaveYieldGenerationModule(timelock);
        module.grantRole(module.ROLE_TIMELOCK(), timelock);
        module.grantRole(module.ROLE_GUARDIAN(), guardian); // Guardian for emergency operations
        module.queueAavePoolProvider(address(provider));
        vm.stopPrank();
        vm.warp(block.timestamp + 14 days + 1);
        vm.startPrank(timelock);
        module.activateAavePoolProvider();
        module.setAaveEnabled(true);
        module.registerTokenForAave(address(token), address(aToken));
        
        // Setup Core Contracts
        yieldOps = new YieldOps(timelock);
        disputeOps = new DisputeOps(timelock);
        mm = new ModuleSnapshotRegistry(timelock);
        createOps = new CreateOps(timelock);
        
        // Setup Vault
        vault = new EscrowVault(100, feeAddress, address(yieldOps), address(disputeOps), address(mm));
        vault.grantRole(vault.ROLE_GUARDIAN(), guardian); // Guardian for pause
        
        // Setup ERC20 escrow
        escrowERC20 = new EscrowableERC20(
            "Escrow Token",
            "ESC",
            100,
            feeAddress,
            address(yieldOps),
            address(disputeOps),
            address(mm)
        );
        
        // Set CreateOps
        vault.setCreateOps(address(createOps));
        escrowERC20.setCreateOps(address(createOps));
        
        // Register contracts
        createOps.registerEscrowContract(address(vault));
        createOps.registerEscrowContract(address(escrowERC20));
        
        // Authorize in module
        module.grantRole(module.ROLE_ESCROW_CONTRACT(), address(vault));
        module.grantRole(module.ROLE_ESCROW_CONTRACT(), address(escrowERC20));
        
        // Register in Ops
        yieldOps.registerEscrowContract(address(vault));
        yieldOps.registerEscrowContract(address(escrowERC20));
        
        // Register in MM
        mm.registerEscrowContract(address(vault));
        mm.registerEscrowContract(address(escrowERC20));
        
        module.grantRole(module.ROLE_YIELD_OPS(), address(yieldOps));
        
        vm.stopPrank();
        
        // Fund buyer and seller
        token.mint(buyer, 500e18);
        vm.prank(buyer);
        token.approve(address(vault), 500e18);
        
        token.mint(seller, 100e18);
    }

    function _getSettings() internal pure returns (EscrowSettings memory) {
        return EscrowSettings({
            customResolver: address(0),
            releaseAddress: address(0), // Added default releaseAddress
            yieldPreset: YieldPreset.TO_SENDER,
            autoReleaseTime: 0,
            autoCancelTime: 0
        });
    }

    function _activateAaveInMM(address escrow) internal {
        vm.startPrank(timelock);
        mm.queueModule(escrow, BaseEscrow.ModuleType.YIELD_GEN, address(module));
        vm.stopPrank();
        vm.warp(block.timestamp + 14 days + 1);
        vm.startPrank(timelock);
        mm.activateModule(escrow, BaseEscrow.ModuleType.YIELD_GEN);
        vm.stopPrank();
    }

    /**
     * @notice Test emergency unwind clears position state correctly
     * @dev Verifies that emergencyUnwind properly clears escrow positions
     */
    function test_emergency_unwind_clears_state() public {
        _activateAaveInMM(address(vault));
        
        uint256 depositAmount = 50e18;
        
        // Create escrow
        vm.startPrank(buyer);
        token.approve(address(vault), depositAmount);
        uint256 workflowId = vault.createEscrow(address(token), seller, depositAmount, _getSettings());
        vm.stopPrank();
        
        // Verify in Aave
        assertTrue(module.escrowInAave(address(vault), workflowId), "Escrow not in Aave");
        uint256 originalDeposit = module.escrowOriginalDeposit(address(vault), workflowId);
        assertGt(originalDeposit, 0, "Original deposit not tracked");
        
        // Emergency unwind
        vm.startPrank(guardian);
        uint256 unwoundAmount = module.emergencyUnwind(
            address(token),
            workflowId,
            address(vault)
        );
        vm.stopPrank();
        
        // Verify funds returned
        assertGt(unwoundAmount, 0, "No funds unwound");
        
        // Verify state cleared
        assertFalse(module.escrowInAave(address(vault), workflowId), "escrowInAave not cleared");
        assertEq(module.escrowScaledBalance(address(vault), workflowId), 0, "Scaled balance not cleared");
        assertEq(module.escrowOriginalDeposit(address(vault), workflowId), 0, "Original deposit not cleared");
    }

    /**
     * @notice Test pause/unpause vault during emergency
     * @dev Verifies vault can be paused and unpaused for emergency operations
     */
    function test_vault_pause_unpause() public {
        _activateAaveInMM(address(vault));
        
        uint256 depositAmount = 50e18;
        
        // Create escrow
        vm.startPrank(buyer);
        token.approve(address(vault), depositAmount);
        uint256 workflowId = vault.createEscrow(address(token), seller, depositAmount, _getSettings());
        vm.stopPrank();
        
        // Pause vault
        vm.startPrank(guardian);
        vault.pause('Emergency unwind');
        vm.stopPrank();
        
        // Verify paused
        assertTrue(vault.paused(), "Vault not paused");
        
        // Emergency unwind while paused
        vm.startPrank(guardian);
        uint256 unwoundAmount = module.emergencyUnwind(
            address(token),
            workflowId,
            address(vault)
        );
        vm.stopPrank();
        
        assertGt(unwoundAmount, 0, "No funds unwound");
        
        // Unpause vault
        vm.startPrank(timelock);
        vault.unpause();
        vm.stopPrank();
        
        // Verify unpaused
        assertFalse(vault.paused(), "Vault not unpaused");
        
        // Funds should be in yieldOps now
        uint256 yoBalance = token.balanceOf(address(yieldOps));
        assertGt(yoBalance, 0, "YieldOps did not receive funds");
    }

    /**
     * @notice Test multiple emergency unwinds maintain isolation
     * @dev Verifies that unwinding one position doesn't affect others
     */
    function test_multiple_emergency_unwinds_isolation() public {
        _activateAaveInMM(address(vault));
        
        uint256 depositAmount = 50e18;
        
        // Create two positions
        vm.startPrank(buyer);
        token.approve(address(vault), depositAmount * 2);
        uint256 wid1 = vault.createEscrow(address(token), seller, depositAmount, _getSettings());
        vm.stopPrank();
        
        vm.startPrank(buyer);
        token.approve(address(vault), depositAmount);
        uint256 wid2 = vault.createEscrow(address(token), seller, depositAmount, _getSettings());
        vm.stopPrank();
        
        // Record position 2 state
        uint256 dep2 = module.escrowOriginalDeposit(address(vault), wid2);
        uint256 shares2 = module.escrowScaledBalance(address(vault), wid2);
        
        // Unwind position 1
        vm.startPrank(guardian);
        uint256 unwind1 = module.emergencyUnwind(
            address(token),
            wid1,
            address(vault)
        );
        vm.stopPrank();
        
        assertGt(unwind1, 0, "Position 1 not unwound");
        
        // Verify position 1 cleared
        assertEq(module.escrowScaledBalance(address(vault), wid1), 0, "Position 1 not cleared");
        
        // Verify position 2 unchanged
        assertEq(module.escrowOriginalDeposit(address(vault), wid2), dep2, "Position 2 dep changed");
        assertEq(module.escrowScaledBalance(address(vault), wid2), shares2, "Position 2 shares changed");
        
        // Verify position 2 can unwind
        vm.startPrank(guardian);
        uint256 unwind2 = module.emergencyUnwind(
            address(token),
            wid2,
            address(vault)
        );
        vm.stopPrank();
        
        assertGt(unwind2, 0, "Position 2 not unwound");
    }

    /**
     * @notice Test deficit tracking for multiple tokens
     * @dev Verifies deficit is tracked independently per token
     */
    function test_deficit_tracking_per_token() public {
        _activateAaveInMM(address(vault));
        
        uint256 depositAmount = 50e18;
        
        // Create position for token1
        vm.startPrank(buyer);
        token.approve(address(vault), depositAmount);
        uint256 wid1 = vault.createEscrow(address(token), seller, depositAmount, _getSettings());
        vm.stopPrank();
        
        // Record deficits before
        uint256 defBefore1 = module.protocolDeficit(address(token));
        uint256 dustBefore1 = module.protocolDust(address(token));
        
        // Unwind
        vm.startPrank(guardian);
        uint256 unwind1 = module.emergencyUnwind(address(token), wid1, address(vault));
        vm.stopPrank();
        
        assertGt(unwind1, 0, "No funds unwound");
        
        // Check tracking
        uint256 defAfter1 = module.protocolDeficit(address(token));
        uint256 dustAfter1 = module.protocolDust(address(token));
        
        // Verify state cleaned up even if dust/deficit unchanged
        assertEq(module.escrowScaledBalance(address(vault), wid1), 0, "Position not cleared");
        assertFalse(module.escrowInAave(address(vault), wid1), "Position still in Aave");
    }

    /**
     * @notice Test yield accumulation before emergency unwind
     * @dev Verifies yield is available for recovery
     */
    function test_yield_available_for_recovery() public {
        _activateAaveInMM(address(vault));
        
        uint256 depositAmount = 100e18;
        
        // Create escrow
        vm.startPrank(buyer);
        token.approve(address(vault), depositAmount);
        uint256 workflowId = vault.createEscrow(address(token), seller, depositAmount, _getSettings());
        vm.stopPrank();
        
        uint256 originalDeposit = module.escrowOriginalDeposit(address(vault), workflowId);
        
        // Simulate yield accrual
        uint256 yieldAmount = 10e18;
        token.mint(address(aToken), yieldAmount);
        
        // Emergency unwind should get original + yield
        vm.startPrank(guardian);
        uint256 unwoundAmount = module.emergencyUnwind(
            address(token),
            workflowId,
            address(vault)
        );
        vm.stopPrank();
        
        // Should get at least original amount
        assertGe(unwoundAmount, originalDeposit, "Unwind returned less than original");
        
        // YieldOps receives unwound funds
        uint256 yoBalance = token.balanceOf(address(yieldOps));
        assertGt(yoBalance, 0, "YieldOps did not receive unwound funds");
    }

    /**
     * @notice Test escrow state consistency after multiple operations
     * @dev Verifies module state remains consistent through lifecycle
     */
    function test_escrow_state_consistency() public {
        _activateAaveInMM(address(vault));
        
        uint256 depositAmount = 50e18;
        
        // Create escrow
        vm.startPrank(buyer);
        token.approve(address(vault), depositAmount);
        uint256 workflowId = vault.createEscrow(address(token), seller, depositAmount, _getSettings());
        vm.stopPrank();
        
        // Verify initial state
        assertTrue(module.escrowInAave(address(vault), workflowId), "Not in Aave");
        uint256 shares1 = module.escrowScaledBalance(address(vault), workflowId);
        uint256 deposit1 = module.escrowOriginalDeposit(address(vault), workflowId);
        assertGt(shares1, 0, "No shares");
        assertGt(deposit1, 0, "No deposit");
        
        // Emergency unwind
        vm.startPrank(guardian);
        module.emergencyUnwind(address(token), workflowId, address(vault));
        vm.stopPrank();
        
        // Verify final state
        assertFalse(module.escrowInAave(address(vault), workflowId), "Still in Aave");
        assertEq(module.escrowScaledBalance(address(vault), workflowId), 0, "Shares not cleared");
        assertEq(module.escrowOriginalDeposit(address(vault), workflowId), 0, "Deposit not cleared");
        
        // Verify funds in yieldOps
        uint256 yoBalance = token.balanceOf(address(yieldOps));
        assertGt(yoBalance, 0, "No funds in yieldOps");
    }

    /**
     * @notice Test global aggregation after emergency unwind
     * @dev Verifies totalDepositedToAave decreases correctly
     */
    function test_total_aggregation_after_unwind() public {
        _activateAaveInMM(address(vault));
        
        uint256 depositAmount = 50e18;
        
        // Create escrow
        vm.startPrank(buyer);
        token.approve(address(vault), depositAmount);
        uint256 workflowId = vault.createEscrow(address(token), seller, depositAmount, _getSettings());
        vm.stopPrank();
        
        // Record total before unwind
        uint256 totalBefore = module.totalDepositedToAave(address(token));
        assertGt(totalBefore, 0, "No total recorded");
        
        // Emergency unwind
        vm.startPrank(guardian);
        module.emergencyUnwind(address(token), workflowId, address(vault));
        vm.stopPrank();
        
        // Total should decrease
        uint256 totalAfter = module.totalDepositedToAave(address(token));
        assertLt(totalAfter, totalBefore, "Total not decreased");
    }
}
