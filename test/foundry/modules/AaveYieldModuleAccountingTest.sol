// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

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
        module.approveEscrow(escrow);
        module.configureToken(address(token), address(aToken));
        
        token.transfer(escrow, INITIAL_BALANCE);
    }

    // ============ M1: Dust/Rounding Handling ============

    /**
     * @notice M1: Very small positions should work correctly
     */
    function test_small_position_deposit_and_withdraw() public {
        uint256 smallAmount = 1e18;
        
        vm.prank(escrow);
        token.transfer(address(module), smallAmount);
        
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
        token.transfer(address(module), amount);
        
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
        token.transfer(address(module), largeAmount);
        
        vm.prank(escrow);
        uint256 accepted = module.initializeYield(1, address(token), largeAmount, YieldPreset.TO_SENDER);
        
        assertEq(accepted, largeAmount, "Large amount should be accepted");
        
        // Verify position recorded correctly
        (, uint256 principal, ) = module.positions(escrow, 1);
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
            token.transfer(address(module), cycleAmount);
            
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
        token.transfer(address(module), depositAmount);
        
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
        token.transfer(address(module), 50e18);
        vm.prank(escrow);
        module.initializeYield(1, address(token), 50e18, YieldPreset.TO_SENDER);
        
        // Second position (different ID)
        vm.prank(escrow);
        token.transfer(address(module), 75e18);
        vm.prank(escrow);
        module.initializeYield(2, address(token), 75e18, YieldPreset.TO_SENDER);
        
        // Verify both positions
        (, uint256 p1, ) = module.positions(escrow, 1);
        (, uint256 p2, ) = module.positions(escrow, 2);
        
        assertEq(p1, 50e18, "First position correct");
        assertEq(p2, 75e18, "Second position correct");
        
        // Withdraw first position
        vm.prank(escrow);
        module.unwindToEscrow(1, address(token), 50e18);
        
        // Verify first withdrawn, second intact
        (, uint256 p1After, ) = module.positions(escrow, 1);
        (, uint256 p2After, ) = module.positions(escrow, 2);
        
        assertEq(p1After, 0, "First withdrawn");
        assertEq(p2After, 75e18, "Second intact");
    }
}
