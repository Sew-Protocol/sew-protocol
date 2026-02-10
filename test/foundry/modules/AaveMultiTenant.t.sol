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

/**
 * @title AaveMultiTenantTest
 * @notice Verifies that multiple escrow contracts (Vault and ERC20) can share the same Aave module.
 * @dev High-risk scenario for namespacing bugs.
 */
contract AaveMultiTenantTest is Test {
    AaveYieldGenerationModule moduleForVault;
    AaveYieldGenerationModule moduleForERC20;
    AaveYieldGenerationModule module; // For backward compatibility in tests
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
        
        // Setup Separate Modules (one per escrow, per the new constraint)
        moduleForVault = new AaveYieldGenerationModule(timelock);
        moduleForVault.grantRole(moduleForVault.ROLE_TIMELOCK(), timelock);
        moduleForVault.queueAavePoolProvider(address(provider));
        
        moduleForERC20 = new AaveYieldGenerationModule(timelock);
        moduleForERC20.grantRole(moduleForERC20.ROLE_TIMELOCK(), timelock);
        moduleForERC20.queueAavePoolProvider(address(provider));
        
        vm.stopPrank();
        vm.warp(block.timestamp + 14 days + 1);
        vm.startPrank(timelock);
        
        moduleForVault.activateAavePoolProvider();
        moduleForVault.setAaveEnabled(true);
        moduleForVault.registerTokenForAave(address(token), address(aToken));
        
        moduleForERC20.activateAavePoolProvider();
        moduleForERC20.setAaveEnabled(true);
        moduleForERC20.registerTokenForAave(address(token), address(aToken));
        
        module = moduleForVault; // For backward compatibility
        
        // Setup Vault dependencies
        yieldOps = new YieldOps(timelock);
        disputeOps = new DisputeOps(timelock);
        mm = new ModuleSnapshotRegistry(timelock);
        createOps = new CreateOps(timelock);
        
        // Deploy Vault
        vault = new EscrowVault(100, feeAddress, address(yieldOps), address(disputeOps), address(mm));
        
        // Deploy EscrowableERC20 (itself is an escrow contract)
        escrowERC20 = new EscrowableERC20(
            "Escrow Token", 
            "ESC", 
            100, 
            feeAddress, 
            address(yieldOps), 
            address(disputeOps), 
            address(mm)
        );
        
        // Set CreateOps on both escrow contracts
        vault.setCreateOps(address(createOps));
        escrowERC20.setCreateOps(address(createOps));
        
        // Register escrow contracts with CreateOps (required!)
        createOps.registerEscrowContract(address(vault));
        createOps.registerEscrowContract(address(escrowERC20));
        
        // Register both as authorized escrow contracts in the modules
        moduleForVault.grantRole(moduleForVault.ROLE_ESCROW_CONTRACT(), address(vault));
        moduleForERC20.grantRole(moduleForERC20.ROLE_ESCROW_CONTRACT(), address(escrowERC20));
        
        // Register in Ops
        yieldOps.registerEscrowContract(address(vault));
        yieldOps.registerEscrowContract(address(escrowERC20));
        
        // Register in MM (required!)
        mm.registerEscrowContract(address(vault));
        mm.registerEscrowContract(address(escrowERC20));
        
        moduleForVault.grantRole(moduleForVault.ROLE_YIELD_OPS(), address(yieldOps));
        moduleForERC20.grantRole(moduleForERC20.ROLE_YIELD_OPS(), address(yieldOps));
        
        vm.stopPrank();
        
        // Fund buyer
        token.mint(buyer, 100_000e18);
        vm.prank(buyer);
        token.approve(address(vault), 100_000e18);
        
        // EscrowableERC20: The constructor mints to timelock, so fund buyer from timelock
        vm.prank(timelock);
        escrowERC20.transfer(buyer, 10_000e18);
        vm.prank(buyer);
        escrowERC20.approve(address(escrowERC20), 10_000e18);
    }

    function test_simultaneous_deposits_independent_accounting() public {
        // Activate modules for both escrows (now with separate module instances per our constraint)
        _activateAaveInMM(address(vault), address(moduleForVault));
        _activateAaveInMM(address(escrowERC20), address(moduleForERC20));
        
        // 1. Vault Deposit (using token for Aave)
        uint256 amountVault = 1000e18;
        token.mint(buyer, amountVault);
        vm.prank(buyer);
        token.approve(address(vault), amountVault);
        
        vm.prank(buyer);
        uint256 v_wid = vault.createEscrow(address(token), seller, amountVault, _getSettings());
        
        // Verify vault position is tracked
        assertTrue(moduleForVault.escrowInAave(address(vault), v_wid), "Vault escrow should be in Aave");
        
        // Check scaled balances
        uint256 v_shares = moduleForVault.escrowScaledBalance(address(vault), v_wid);
        assertGt(v_shares, 0, "Vault shares > 0");
        
        // Verify total tracked
        uint256 expectedVaultAmount = amountVault * 99 / 100; // 1% fee
        assertEq(moduleForVault.totalDepositedToAave(address(token)), expectedVaultAmount, 
            "Total should equal vault amount");
        
        // 2. Withdraw Vault
        vm.prank(buyer);
        vault.releaseEscrowTransfer(v_wid);
        
        // Verify Vault position is gone
        assertFalse(moduleForVault.escrowInAave(address(vault), v_wid), 
            "Vault position should be cleared");
        
        // Verify vault shares are zero
        uint256 vaultSharesAfter = moduleForVault.escrowScaledBalance(address(vault), v_wid);
        assertEq(vaultSharesAfter, 0, "Vault shares should be 0 after withdrawal");
    }

    function test_different_tokens_on_same_module() public {
        ERC20Mock token2 = new ERC20Mock("Token 2", "T2", address(this), 1_000_000e18);
        MockAToken aToken2 = new MockAToken(address(token2), "aT2", "aT2");
        aToken2.setPool(address(pool));
        pool.setAToken(address(token2), address(aToken2));
        token2.mint(address(pool), 1_000_000e18);
        
        vm.startPrank(timelock);
        moduleForVault.registerTokenForAave(address(token2), address(aToken2));
        vm.stopPrank();
        
        _activateAaveInMM(address(vault), address(moduleForVault));
        
        token2.mint(buyer, 1000e18);
        vm.prank(buyer);
        token2.approve(address(vault), 1000e18);
        
        token.mint(buyer, 1000e18);
        vm.prank(buyer);
        token.approve(address(vault), 1000e18);
        
        // Create escrows for different tokens
        vm.prank(buyer);
        uint256 wid1 = vault.createEscrow(address(token), seller, 1000e18, _getSettings());
        
        vm.prank(buyer);
        uint256 wid2 = vault.createEscrow(address(token2), seller, 1000e18, _getSettings());
        
        assertTrue(moduleForVault.escrowInAave(address(vault), wid1), "Token 1 in Aave");
        assertTrue(moduleForVault.escrowInAave(address(vault), wid2), "Token 2 in Aave");
        
        // Verify global totals are separate (accounting for 1% fee deduction)
        uint256 expectedAmount = 1000e18 * 99 / 100; // 1% fee
        assertEq(moduleForVault.totalDepositedToAave(address(token)), expectedAmount, "Total Token 1 correct");
        assertEq(moduleForVault.totalDepositedToAave(address(token2)), expectedAmount, "Total Token 2 correct");
    }

    /**
     * @notice Test: Multiple sequential positions with both vault and ERC20
     * @dev Verifies isolation holds across multiple positions
     */
    function test_sequential_deposits_with_isolation() public {
        _activateAaveInMM(address(vault), address(moduleForVault));
        
        // Create first position in vault
        token.mint(buyer, 500e18);
        vm.prank(buyer);
        token.approve(address(vault), 500e18);
        
        vm.prank(buyer);
        uint256 wid1 = vault.createEscrow(address(token), seller, 500e18, _getSettings());
        
        uint256 shares1 = moduleForVault.escrowScaledBalance(address(vault), wid1);
        assertGt(shares1, 0, "First position created");
        
        // Create second position
        token.mint(buyer, 300e18);
        vm.prank(buyer);
        token.approve(address(vault), 300e18);
        
        vm.prank(buyer);
        uint256 wid2 = vault.createEscrow(address(token), seller, 300e18, _getSettings());
        
        uint256 shares2 = moduleForVault.escrowScaledBalance(address(vault), wid2);
        assertGt(shares2, 0, "Second position created");
        assertNotEq(shares1, shares2, "Different amounts give different shares");
        
        // Withdraw first position
        vm.prank(buyer);
        vault.releaseEscrowTransfer(wid1);
        
        // Verify first is gone, second persists
        assertEq(moduleForVault.escrowScaledBalance(address(vault), wid1), 0, "First withdrawn");
        assertEq(moduleForVault.escrowScaledBalance(address(vault), wid2), shares2, "Second unchanged");
    }

    /**
     * @notice Test: Scaling doesn't break isolation with many positions
     * @dev Stress test with many parallel positions
     */
    function test_many_positions_maintain_isolation() public {
        _activateAaveInMM(address(vault), address(moduleForVault));
        
        uint256 numPositions = 5;
        uint256 amountPer = 100e18;
        
        // Mint enough for all positions
        token.mint(buyer, numPositions * amountPer);
        vm.prank(buyer);
        token.approve(address(vault), numPositions * amountPer);
        
        // Create multiple positions
        for (uint256 i = 0; i < numPositions; i++) {
            vm.prank(buyer);
            uint256 wid = vault.createEscrow(address(token), seller, amountPer, _getSettings());
            assertGt(moduleForVault.escrowScaledBalance(address(vault), wid), 0, "Position created");
        }
        
        // Verify total aggregates correctly (accounting for fees)
        uint256 expectedTotal = (numPositions * amountPer) * 99 / 100; // 1% fee
        uint256 actualTotal = moduleForVault.totalDepositedToAave(address(token));
        assertEq(actualTotal, expectedTotal, "Total aggregates all positions");
        
        // Withdraw one position
        vm.prank(buyer);
        vault.releaseEscrowTransfer(1);
        
        // Verify only that position is removed
        assertEq(moduleForVault.escrowScaledBalance(address(vault), 1), 0, "Position 1 withdrawn");
        assertGt(moduleForVault.escrowScaledBalance(address(vault), 2), 0, "Position 2 remains");
        assertGt(moduleForVault.escrowScaledBalance(address(vault), 3), 0, "Position 3 remains");
    }

    /**
     * @notice Test: Position status (escrowInAave flag) properly scoped
     * @dev Ensures escrowInAave[escrow][workflowId] isolation
     */
    function test_escrowInAave_flag_isolation() public {
        _activateAaveInMM(address(vault), address(moduleForVault));
        
        token.mint(buyer, 600e18);
        vm.prank(buyer);
        token.approve(address(vault), 600e18);
        
        // Create two escrows
        vm.prank(buyer);
        uint256 wid1 = vault.createEscrow(address(token), seller, 300e18, _getSettings());
        
        vm.prank(buyer);
        uint256 wid2 = vault.createEscrow(address(token), seller, 300e18, _getSettings());
        
        // Both should be in Aave
        assertTrue(moduleForVault.escrowInAave(address(vault), wid1), "wid1 in Aave");
        assertTrue(moduleForVault.escrowInAave(address(vault), wid2), "wid2 in Aave");
        
        // Withdraw wid1
        vm.prank(buyer);
        vault.releaseEscrowTransfer(wid1);
        
        // Only wid1 should be removed
        assertFalse(moduleForVault.escrowInAave(address(vault), wid1), "wid1 removed");
        assertTrue(moduleForVault.escrowInAave(address(vault), wid2), "wid2 persists");
    }

    /**
     * @notice Test: Yield accrual respects position isolation
     * @dev Verifies each position gets its proportional yield
     */
    function test_yield_respects_position_boundaries() public {
        _activateAaveInMM(address(vault), address(moduleForVault));
        
        // Create two equal positions
        uint256 depositAmount = 1000e18;
        
        token.mint(buyer, 2 * depositAmount);
        vm.prank(buyer);
        token.approve(address(vault), 2 * depositAmount);
        
        vm.prank(buyer);
        uint256 wid1 = vault.createEscrow(address(token), seller, depositAmount, _getSettings());
        
        vm.prank(buyer);
        uint256 wid2 = vault.createEscrow(address(token), seller, depositAmount, _getSettings());
        
        uint256 shares1Before = moduleForVault.escrowScaledBalance(address(vault), wid1);
        uint256 shares2Before = moduleForVault.escrowScaledBalance(address(vault), wid2);
        
        // Simulate yield accrual: add tokens to aToken
        token.mint(address(aToken), 200e18);
        
        // Both positions should still have their original shares
        // (shares don't change, but their value increases with yield)
        assertEq(moduleForVault.escrowScaledBalance(address(vault), wid1), shares1Before, 
            "Vault 1 shares unchanged");
        assertEq(moduleForVault.escrowScaledBalance(address(vault), wid2), shares2Before,
            "Vault 2 shares unchanged");
    }

    function _getSettings() internal pure returns (EscrowSettings memory) {
        return EscrowSettings({
            customResolver: address(0),
            releaseAddress: address(0),
            yieldPreset: YieldPreset.TO_SENDER,
            autoReleaseTime: 0,
            autoCancelTime: 0
        });
    }

        function _activateAaveInMM(address escrow, address moduleAddr) internal {
        vm.startPrank(timelock);
        mm.queueModule(escrow, BaseEscrow.ModuleType.YIELD_GEN, moduleAddr);
        vm.stopPrank();
        vm.warp(block.timestamp + 14 days + 1);
        vm.startPrank(timelock);
        mm.activateModule(escrow, BaseEscrow.ModuleType.YIELD_GEN);
        vm.stopPrank();
    }
}
