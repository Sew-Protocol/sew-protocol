// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import 'forge-std/Test.sol';
import 'contracts/modules/AaveYieldModule.sol';
import 'contracts/mocks/MockAavePool.sol';
import 'contracts/mocks/ERC20Mock.sol';
import 'contracts/types/YieldPresets.sol';

/**
 * @title AaveYieldModuleIntegrationTest
 * @notice Tests for Aave integration correctness
 * 
 * Run: forge test --match-contract AaveYieldModuleIntegrationTest -vvv
 */
contract AaveYieldModuleIntegrationTest is Test {
    AaveYieldModule public module;
    MockAavePool public pool;
    ERC20Mock public token;
    MockAToken public aToken;
    
    address public escrow;
    address public otherEscrow;
    
    uint256 constant INITIAL_BALANCE = 1000000e18;

    function setUp() public {
        pool = new MockAavePool();
        token = new ERC20Mock("Test", "TST", address(this), INITIAL_BALANCE * 2);
        aToken = new MockAToken(address(token), "aTest", "aTEST");
        
        pool.setAToken(address(token), address(aToken));
        aToken.setPool(address(pool));
        
        module = new AaveYieldModule(address(pool));
        
        token.approve(address(pool), type(uint256).max);
        
        escrow = address(0x1001);
        otherEscrow = address(0x1002);
        
        module.approveEscrow(escrow);
        module.approveEscrow(otherEscrow);
        module.configureToken(address(token), address(aToken));
        
        token.transfer(escrow, INITIAL_BALANCE);
        token.transfer(otherEscrow, INITIAL_BALANCE);
    }

    // ============ Failure Mode Tests ============

    /**
     * @notice Withdraw when reserve is unavailable should fail
     */
    function test_withdraw_reserve_unavailable() public {
        vm.prank(escrow);
        token.transfer(address(module), 100e18);
        
        vm.prank(escrow);
        module.initializeYield(1, address(token), 100e18, YieldPreset.TO_SENDER);
        
        pool.setWithdrawFail(true);
        
        vm.prank(escrow);
        vm.expectRevert();
        module.unwindToEscrow(1, address(token), 50e18);
        
        pool.setWithdrawFail(false);
    }

    /**
     * @notice Emergency unwind when reserve unavailable
     */
    function test_emergency_unwind_reserve_unavailable() public {
        vm.prank(escrow);
        token.transfer(address(module), 100e18);
        
        vm.prank(escrow);
        module.initializeYield(1, address(token), 100e18, YieldPreset.TO_SENDER);
        
        pool.setWithdrawFail(true);
        
        vm.prank(escrow);
        vm.expectRevert();
        module.emergencyUnwind(1, address(token), 100e18);
        
        pool.setWithdrawFail(false);
    }

    // ============ Multiple Escrows ============

    /**
     * @notice Multiple escrows should not interfere
     */
    function test_multiple_escrows_isolated() public {
        uint256 amount1 = 50e18;
        uint256 amount2 = 75e18;
        
        vm.prank(escrow);
        token.transfer(address(module), amount1);
        vm.prank(escrow);
        module.initializeYield(1, address(token), amount1, YieldPreset.TO_SENDER);
        
        vm.prank(otherEscrow);
        token.transfer(address(module), amount2);
        vm.prank(otherEscrow);
        module.initializeYield(1, address(token), amount2, YieldPreset.TO_SENDER);
        
        (, uint256 p1, ) = module.positions(escrow, 1);
        (, uint256 p2, ) = module.positions(otherEscrow, 1);
        
        assertEq(p1, amount1, "Escrow1 correct");
        assertEq(p2, amount2, "Escrow2 correct");
        
        vm.prank(escrow);
        module.unwindToEscrow(1, address(token), amount1);
        
        (, uint256 p1After, ) = module.positions(escrow, 1);
        (, uint256 p2After, ) = module.positions(otherEscrow, 1);
        
        assertEq(p1After, 0, "Escrow1 withdrawn");
        assertEq(p2After, amount2, "Escrow2 unchanged");
    }

    // ============ Yield Accrual ============

    /**
     * @notice Full withdraw captures yield
     */
    function test_deposit_yield_full_withdraw() public {
        uint256 depositAmount = 100e18;
        
        vm.prank(escrow);
        token.transfer(address(module), depositAmount);
        
        vm.prank(escrow);
        module.initializeYield(1, address(token), depositAmount, YieldPreset.TO_SENDER);
        
        pool.simulateYield(address(token), 1000000);
        
        vm.prank(escrow);
        (uint256 principal, uint256 yieldOut) = module.unwindToEscrow(1, address(token), depositAmount);
        
        assertEq(principal, depositAmount, "Principal correct");
        assertGt(yieldOut, 0, "Yield should be captured");
    }

    // ============ Access Control ============

    /**
     * @notice Unapproved escrow cannot withdraw
     */
    function test_unapproved_escrow_cannot_withdraw() public {
        address attacker = address(0xDEAD);
        
        vm.prank(escrow);
        token.transfer(address(module), 100e18);
        
        vm.prank(escrow);
        module.initializeYield(1, address(token), 100e18, YieldPreset.TO_SENDER);
        
        vm.prank(attacker);
        vm.expectRevert();
        module.unwindToEscrow(1, address(token), 50e18);
    }

    // ============ Full Flow ============

    /**
     * @notice Complete deposit -> yield -> withdraw flow
     */
    function test_full_flow_with_yield() public {
        uint256 depositAmount = 100e18;
        
        // Deposit
        vm.prank(escrow);
        token.transfer(address(module), depositAmount);
        
        vm.prank(escrow);
        uint256 accepted = module.initializeYield(1, address(token), depositAmount, YieldPreset.TO_SENDER);
        assertEq(accepted, depositAmount, "Deposit accepted");
        
        // Simulate time passing (yield)
        pool.simulateYield(address(token), 100000);
        
        // Withdraw
        vm.prank(escrow);
        (uint256 principal, uint256 yieldOut) = module.unwindToEscrow(1, address(token), depositAmount);
        
        assertEq(principal, depositAmount, "Principal returned");
        assertGt(yieldOut, 0, "Yield earned");
        
        // Position should be cleared
        (, uint256 remaining, ) = module.positions(escrow, 1);
        assertEq(remaining, 0, "Position cleared");
    }
}
