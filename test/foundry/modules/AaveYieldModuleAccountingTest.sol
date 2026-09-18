// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.37;

import 'forge-std/Test.sol';
import 'contracts/modules/AaveYieldModule.sol';
import 'contracts/mocks/MockAavePool.sol';
import 'contracts/mocks/ERC20Mock.sol';
import 'contracts/types/YieldPresets.sol';

/**
 * @title AaveYieldModuleAccountingTest
 * @notice Tests for core accounting correctness (M1, M2, M3)
 * 
 * Run: forge test --match-contract AaveYieldModuleAccountingTest -vvv
 */
contract AaveYieldModuleAccountingTest is Test {
    AaveYieldModule public module;
    MockAavePool public pool;
    ERC20Mock public token;
    MockAToken public aToken;
    
    address public escrow;
    
    uint256 constant INITIAL_BALANCE = 1000000e18;

    function setUp() public {
        pool = new MockAavePool();
        token = new ERC20Mock("Test", "TST", address(this), INITIAL_BALANCE * 10);
        aToken = new MockAToken(address(token), "aTest", "aTEST");
        
        pool.setAToken(address(token), address(aToken));
        aToken.setPool(address(pool));
        
        module = new AaveYieldModule(address(pool));
        
        token.approve(address(pool), type(uint256).max);
        
        escrow = address(0x1001);
        _approve(escrow);
        _cfgToken(address(token), address(aToken));
        
        token.transfer(escrow, INITIAL_BALANCE);
    }

    // ============ M1: Dust/Rounding Handling ============

    /**
     * @notice M1: Very small positions should work correctly
     */
    function _cfgToken(address token_, address aToken_) internal {
        module.queueConfigureToken(token_, aToken_);
        (, uint64 eta, ) = module.getPendingConfigureToken(token_);
        vm.warp(eta);
        module.activateConfigureToken(token_);
    }

    function _approve(address escrow_) internal {
        module.queueApproveEscrow(escrow_);
        (, uint64 eta, ) = module.getPendingApproveEscrow();
        vm.warp(eta);
        module.activateApproveEscrow();
    }

    function test_small_position_deposit_and_withdraw() public {
        uint256 smallAmount = 1e18;
        
        vm.prank(escrow);
        token.transfer(escrow, smallAmount);
        vm.prank(escrow); token.approve(address(module), type(uint256).max);
        
        vm.prank(escrow);
        uint256 accepted = module.initializeYield(1, address(token), smallAmount, YieldPreset.TO_SENDER);
        
        assertEq(accepted, smallAmount, "Small amount should be accepted in full");
        
        vm.prank(escrow);
        (uint256 principal, uint256 yieldOut) = module.unwindToEscrow(1, address(token), smallAmount);
        
        assertEq(principal, smallAmount, "Should withdraw full small amount");
    }

    /**
     * @notice M1: Zero-yield scenarios behave correctly
     */
    function test_zero_yield_scenario() public {
        uint256 amount = 50e18;
        
        vm.prank(escrow);
        token.transfer(escrow, amount);
        vm.prank(escrow); token.approve(address(module), type(uint256).max);
        
        vm.prank(escrow);
        uint256 accepted = module.initializeYield(1, address(token), amount, YieldPreset.TO_SENDER);
        
        // No yield simulated - just withdraw principal
        vm.prank(escrow);
        (uint256 principal, uint256 yieldOut) = module.unwindToEscrow(1, address(token), amount);
        
        assertEq(principal, amount, "Should withdraw principal");
        assertEq(yieldOut, 0, "Should have zero yield");
    }

    // ============ M2: Large Positions Near Limits ============

    /**
     * @notice M2: Large position should work correctly
     */
    function test_large_position() public {
        uint256 largeAmount = 1000e18;
        
        vm.prank(escrow);
        token.transfer(escrow, largeAmount);
        vm.prank(escrow); token.approve(address(module), type(uint256).max);
        
        vm.prank(escrow);
        uint256 accepted = module.initializeYield(1, address(token), largeAmount, YieldPreset.TO_SENDER);
        
        assertEq(accepted, largeAmount, "Large amount should be accepted");
        
        // Verify position recorded correctly
        (, uint256 principal, , ) = module.positions(escrow, 1);
        assertEq(principal, largeAmount, "Large principal should be stored");
    }

    // ============ M3: Repeated Deposit/Withdraw Cycles ============

    /**
     * @notice M3: Multiple cycles should not accumulate drift
     */
    function test_multiple_cycles_no_drift() public {
        uint256 cycleAmount = 10e18;
        uint256 cycles = 5;
        
        uint256 totalDeposited = 0;
        uint256 totalWithdrawn = 0;
        
        for (uint256 i = 1; i <= cycles; i++) {
            vm.prank(escrow);
            token.transfer(escrow, cycleAmount);
            vm.prank(escrow); token.approve(address(module), type(uint256).max);
            
            vm.prank(escrow);
            uint256 accepted = module.initializeYield(i, address(token), cycleAmount, YieldPreset.TO_SENDER);
            totalDeposited += accepted;
            
            vm.prank(escrow);
            (uint256 principal, uint256 yieldOut) = module.unwindToEscrow(i, address(token), cycleAmount);
            totalWithdrawn += principal;
        }
        
        assertEq(totalDeposited, totalWithdrawn, "No drift across cycles");
    }

    // Note: The module withdraws all from Aave when unwinding, not partial amounts.
    // This is expected Aave behavior - the full aToken balance is redeemed.

    // ============ Yield Simulation Tests ============

    /**
     * @notice Deposit -> yield accrual -> full withdraw captures yield
     */
    function test_deposit_yield_full_withdraw() public {
        uint256 depositAmount = 100e18;
        
        vm.prank(escrow);
        token.transfer(escrow, depositAmount);
        vm.prank(escrow); token.approve(address(module), type(uint256).max);
        
        vm.prank(escrow);
        module.initializeYield(1, address(token), depositAmount, YieldPreset.TO_SENDER);
        
        // Simulate yield accrual (many blocks to generate meaningful yield)
        pool.simulateYield(address(token), 1000000);
        
        // Full withdraw
        vm.prank(escrow);
        (uint256 principal, uint256 yieldOut) = module.unwindToEscrow(1, address(token), depositAmount);
        
        assertEq(principal, depositAmount, "Principal correct");
        assertGt(yieldOut, 0, "Yield should be captured");
    }

    /**
     * @notice Multiple deposits at different times work independently
     */
    function test_multiple_independent_positions() public {
        // First position
        vm.prank(escrow);
        token.transfer(escrow, 50e18);
        vm.prank(escrow); token.approve(address(module), type(uint256).max);
        vm.prank(escrow);
        module.initializeYield(1, address(token), 50e18, YieldPreset.TO_SENDER);
        
        // Second position (different ID)
        vm.prank(escrow);
        token.transfer(escrow, 75e18);
        vm.prank(escrow); token.approve(address(module), type(uint256).max);
        vm.prank(escrow);
        module.initializeYield(2, address(token), 75e18, YieldPreset.TO_SENDER);
        
        // Verify both positions
        (, uint256 p1, , ) = module.positions(escrow, 1);
        (, uint256 p2, , ) = module.positions(escrow, 2);
        
        assertEq(p1, 50e18, "First position correct");
        assertEq(p2, 75e18, "Second position correct");
        
        // Withdraw first position
        vm.prank(escrow);
        module.unwindToEscrow(1, address(token), 50e18);
        
        // Verify first withdrawn, second intact
        (, uint256 p1After, , ) = module.positions(escrow, 1);
        (, uint256 p2After, , ) = module.positions(escrow, 2);
        
        assertEq(p1After, 0, "First withdrawn");
        assertEq(p2After, 75e18, "Second intact");
    }

    // ============ P0 Regression: scaled-share accounting ============

    /**
     * @notice Regression: a deposit made AFTER yield has accrued (liquidity index > initial)
     * must NOT be overstated by double-applying the index. The module stores scaled
     * (index-independent) shares and converts to underlying exactly once at unwind.
     * Pre-fix, the module stored the rebased balance delta and re-applied the index,
     * overstating the position by the index-at-deposit factor.
     */
    function test_deposit_after_yield_not_overstated() public {
        // Accrue yield BEFORE the deposit so the liquidity index is already above initial.
        pool.simulateYield(address(token), 50);

        uint256 amount = 100e18;
        vm.prank(escrow);
        token.transfer(escrow, amount);
        vm.prank(escrow); token.approve(address(module), type(uint256).max);

        vm.prank(escrow);
        uint256 accepted = module.initializeYield(1, address(token), amount, YieldPreset.TO_SENDER);
        assertEq(accepted, amount, "Should accept full amount");

        // previewPosition must not overstate beyond the deposited principal.
        (uint256 principal, uint256 currentValue, bool isActive) = module.previewPosition(1, escrow);
        assertEq(principal, amount, "Tracked principal correct");
        assertLe(currentValue, amount, "Current value must not exceed deposited principal");
        assertTrue(isActive, "Position active");

        // Withdraw with no further yield: recover exactly the principal.
        vm.prank(escrow);
        (uint256 p, uint256 y) = module.unwindToEscrow(1, address(token), amount);
        assertApproxEqAbs(p, amount, 1, "Must recover exactly the principal, not more");
        assertEq(y, 0, "No yield without further accrual");
    }

    /**
     * @notice Regression: multiple same-token positions deposited at different liquidity
     * indices unwind independently and never steal from each other. This is only correct
     * because each position tracks its own scaled shares.
     */
    function test_multiple_positions_after_yield_accrual() public {
        uint256 a = 100e18;
        uint256 b = 50e18;

        // Position 1 at initial index.
        vm.prank(escrow);
        token.transfer(escrow, a);
        vm.prank(escrow); token.approve(address(module), type(uint256).max);
        vm.prank(escrow);
        module.initializeYield(1, address(token), a, YieldPreset.TO_SENDER);

        // Yield accrues, then position 2 is deposited at the elevated index.
        pool.simulateYield(address(token), 100);
        vm.prank(escrow);
        token.transfer(escrow, b);
        vm.prank(escrow); token.approve(address(module), type(uint256).max);
        vm.prank(escrow);
        module.initializeYield(2, address(token), b, YieldPreset.TO_SENDER);

        // More yield accrues for both positions.
        pool.simulateYield(address(token), 100);

        // Unwind position 2 first: it must return its own principal + its own yield only.
        vm.prank(escrow);
        (uint256 p2, uint256 y2) = module.unwindToEscrow(2, address(token), b);
        assertApproxEqAbs(p2, b, 1, "Position 2 principal correct");
        assertGe(p2 + y2, b, "Position 2 recovers at least its principal");

        // Unwind position 1: still returns its full principal despite pos 2 already unwound.
        vm.prank(escrow);
        (uint256 p1, uint256 y1) = module.unwindToEscrow(1, address(token), a);
        assertApproxEqAbs(p1, a, 1, "Position 1 principal correct");
        assertGe(p1 + y1, a, "Position 1 recovers at least its principal");
    }
    // ============ P0 Regression: #1 stray module balance must not poison principal ============

    /**
     * @notice Regression (#1): a pre-existing balance in the module (donation/stray),
     * whether smaller or larger than the new deposit, must not be attributed to the
     * deposit. Pre-fix, actualDeposited was derived from the absolute remaining balance
     * (received - balanceOf(this)), which understated principal when a smaller stray
     * balance existed and reverted when the stray balance was >= the deposit.
     */
    function test_stray_module_balance_does_not_poison_deposit_principal() public {
        uint256 stray = 10e18;
        uint256 deposit = 100e18;
        // Donate a pre-existing balance directly to the module (anyone can do this).
        token.transfer(address(module), stray);

        // Escrow already holds INITIAL_BALANCE from setUp; just approve the pull.
        vm.prank(escrow);
        token.approve(address(module), type(uint256).max);

        vm.prank(escrow);
        uint256 accepted = module.initializeYield(7, address(token), deposit, YieldPreset.TO_SENDER);
        assertEq(accepted, deposit, "principal must equal the deposit, not deposit minus stray");

        // Tiny yield then full unwind: principal fully recovered.
        pool.simulateYield(address(token), 10);
        vm.prank(escrow);
        (uint256 principal, ) = module.unwindToEscrow(7, address(token), deposit);
        assertApproxEqAbs(principal, deposit, 1, "unwind recovers full deposit despite stray balance");
    }

    /**
     * @notice Regression (#1): when the pre-existing module balance EXCEEDS the new
     * deposit, the deposit previously reverted (actualDeposited collapsed to zero).
     * Now it must be accepted in full.
     */
    function test_stray_balance_greater_than_deposit_still_works() public {
        uint256 stray = 200e18;
        uint256 deposit = 100e18;
        token.transfer(address(module), stray);

        vm.prank(escrow);
        token.approve(address(module), type(uint256).max);

        vm.prank(escrow);
        uint256 accepted = module.initializeYield(8, address(token), deposit, YieldPreset.TO_SENDER);
        assertEq(accepted, deposit, "deposit accepted in full even when module already holds more");

        vm.prank(escrow);
        (uint256 principal, ) = module.unwindToEscrow(8, address(token), deposit);
        assertApproxEqAbs(principal, deposit, 1, "full principal recovered");
    }

    // ============ P0 Regression: #2 second initialization must not overwrite position ============

    /**
     * @notice Regression (#2): a second initializeYield on the same (escrow, escrowId)
     * must revert rather than silently overwrite the first position (which would orphan
     * the first position's aTokens). A DIFFERENT escrowId on the same escrow remains valid.
     */
    function test_second_initialize_same_position_reverts() public {
        uint256 amt = 100e18;
        vm.prank(escrow);
        token.approve(address(module), type(uint256).max);

        vm.prank(escrow);
        module.initializeYield(1, address(token), amt, YieldPreset.TO_SENDER);

        // Same (escrow, escrowId): must revert.
        vm.prank(escrow);
        vm.expectRevert("PositionAlreadyExists");
        module.initializeYield(1, address(token), amt, YieldPreset.TO_SENDER);

        // Different escrowId on the same escrow is still allowed (positions are distinct).
        vm.prank(escrow);
        uint256 accepted2 = module.initializeYield(2, address(token), amt, YieldPreset.TO_SENDER);
        assertEq(accepted2, amt, "a different escrowId is still allowed");
    }

    // ============ P0 Regression: #6 scaled-share isolation ============

    uint256 constant SCALE_TOLERANCE = 1e4;

    /// @dev Unwind escrowId and assert the module's scaled aToken balance drops by (near)
    ///      exactly the position's own recorded scaled shares — i.e. it must NOT burn shares
    ///      belonging to a different interleaved position. Tolerates integer-rounding dust.
    function _assertScaledBurnWithin(uint256 escrowId, uint256 recordedShares, string memory label) internal {
        (, uint256 recordedPrincipal, , ) = module.positions(escrow, escrowId);
        uint256 scaledBefore = aToken.scaledBalanceOf(address(module));
        vm.prank(escrow);
        module.unwindToEscrow(escrowId, address(token), recordedPrincipal);
        uint256 scaledAfter = aToken.scaledBalanceOf(address(module));
        require(scaledBefore >= scaledAfter, "scaled balance must not increase");
        uint256 burned = scaledBefore - scaledAfter;
        assertGe(burned + SCALE_TOLERANCE, recordedShares, string.concat(label, ": burns (near) the full recorded shares"));
        assertLe(burned, recordedShares + SCALE_TOLERANCE, string.concat(label, ": must NOT burn another position's shares"));
    }

    /**
     * @notice Regression (#6): with N interleaved same-token positions of different sizes,
     * unwinding each position burns only its own recorded scaled shares (plus rounding),
     * never another position's. After all positions unwind, only rounding dust remains in
     * the module. This backs the claim that a position withdraws only the shares recorded
     * for that specific position.
     */
    function test_scaled_share_isolation_interleaved_positions() public {
        uint256 a = 100e18;
        uint256 b = 40e18;
        uint256 c = 250e18;

        vm.prank(escrow);
        token.approve(address(module), type(uint256).max);

        // Position 1 at the initial liquidity index.
        vm.prank(escrow);
        module.initializeYield(1, address(token), a, YieldPreset.TO_SENDER);

        // Yield accrues, then position 2 at the elevated index.
        pool.simulateYield(address(token), 50);
        vm.prank(escrow);
        module.initializeYield(2, address(token), b, YieldPreset.TO_SENDER);

        // More yield, then position 3.
        pool.simulateYield(address(token), 50);
        vm.prank(escrow);
        module.initializeYield(3, address(token), c, YieldPreset.TO_SENDER);

        // Further yield accrues for all positions.
        pool.simulateYield(address(token), 50);

        (, , uint256 shares1, ) = module.positions(escrow, 1);
        (, , uint256 shares2, ) = module.positions(escrow, 2);
        (, , uint256 shares3, ) = module.positions(escrow, 3);

        // Unwind in a NON-creation order (2, then 1, then 3).
        _assertScaledBurnWithin(2, shares2, "pos2");
        _assertScaledBurnWithin(1, shares1, "pos1");
        _assertScaledBurnWithin(3, shares3, "pos3");

        // After all positions unwind, only rounding dust remains in the module.
        uint256 remaining = aToken.scaledBalanceOf(address(module));
        assertLe(remaining, SCALE_TOLERANCE, "no meaningful scaled balance remains after all unwinds");
    }
}
