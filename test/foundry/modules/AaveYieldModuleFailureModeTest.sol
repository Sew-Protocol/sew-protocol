// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import 'forge-std/Test.sol';
import 'contracts/modules/AaveYieldModule.sol';
import 'contracts/mocks/MockAavePool.sol';
import 'contracts/mocks/ERC20Mock.sol';
import 'contracts/types/YieldPresets.sol';

/**
 * @title AaveYieldModuleFailureModeTest
 * @notice Tests for failure modes in AaveYieldModule (G5, G6, G7)
 * 
 * Run: forge test --match-contract AaveYieldModuleFailureModeTest -vvv
 */
contract AaveYieldModuleFailureModeTest is Test {
    AaveYieldModule public module;
    MockAavePool public pool;
    ERC20Mock public token;
    MockAToken public aToken;
    
    address public escrow;
    address public attacker;
    
    uint256 constant DEPOSIT_AMOUNT = 100e18;

    function setUp() public {
        pool = new MockAavePool();
        token = new ERC20Mock("Test", "TST", address(this), 1e24);
        aToken = new MockAToken(address(token), "aTest", "aTEST");
        
        pool.setAToken(address(token), address(aToken));
        aToken.setPool(address(pool));
        
        module = new AaveYieldModule(address(pool));
        
        token.approve(address(pool), type(uint256).max);
        
        escrow = address(0x1001);
        attacker = makeAddr('Attacker');
        
        module.approveEscrow(escrow);
        module.configureToken(address(token), address(aToken));
        
        token.transfer(escrow, DEPOSIT_AMOUNT * 10);
    }

    // ============ G5: Aave Withdraw Revert Handling ============

    /**
     * @notice G5: Module fails closed when Aave withdraw reverts
     */
    function test_aave_withdraw_reverts_fail_closed() public {
        vm.prank(escrow);
        token.transfer(address(module), DEPOSIT_AMOUNT);
        
        vm.prank(escrow);
        module.initializeYield(1, address(token), DEPOSIT_AMOUNT, YieldPreset.TO_SENDER);
        
        pool.setWithdrawFail(true);
        
        vm.prank(escrow);
        vm.expectRevert();
        module.unwindToEscrow(1, address(token), DEPOSIT_AMOUNT);
        
        (address posToken, uint256 principal) = module.positions(escrow, 1);
        assertEq(posToken, address(token));
        assertEq(principal, DEPOSIT_AMOUNT);
        
        pool.setWithdrawFail(false);
    }

    /**
     * @notice G5: Emergency unwind also fails closed
     */
    function test_emergency_unwind_fail_closed() public {
        vm.prank(escrow);
        token.transfer(address(module), DEPOSIT_AMOUNT);
        
        vm.prank(escrow);
        module.initializeYield(1, address(token), DEPOSIT_AMOUNT, YieldPreset.TO_SENDER);
        
        pool.setWithdrawFail(true);
        
        vm.prank(escrow);
        vm.expectRevert();
        module.emergencyUnwind(1, address(token), DEPOSIT_AMOUNT);
        
        pool.setWithdrawFail(false);
    }

    // ============ G6: Aave Deposit Revert Handling ============

    /**
     * @notice G6: Module handles deposit failures correctly
     */
    function test_aave_deposit_reverts_fail_closed() public {
        pool.setSupplyFail(true);
        
        vm.prank(escrow);
        token.transfer(address(module), DEPOSIT_AMOUNT);
        
        vm.prank(escrow);
        vm.expectRevert();
        module.initializeYield(1, address(token), DEPOSIT_AMOUNT, YieldPreset.TO_SENDER);
        
        (address posToken, uint256 principal) = module.positions(escrow, 1);
        assertEq(posToken, address(0));
        assertEq(principal, 0);
        
        pool.setSupplyFail(false);
    }

    /**
     * @notice G6: Partial deposit failure is handled correctly
     */
    function test_partial_deposit_failure() public {
        pool.setSupplyFailAmount(DEPOSIT_AMOUNT / 2);
        
        vm.prank(escrow);
        token.transfer(address(module), DEPOSIT_AMOUNT);
        
        vm.prank(escrow);
        uint256 accepted = module.initializeYield(1, address(token), DEPOSIT_AMOUNT, YieldPreset.TO_SENDER);
        
        assertEq(accepted, DEPOSIT_AMOUNT / 2);
        
        pool.setSupplyFailAmount(0);
    }

    // ============ G7: Max Withdraw Edge Case ============

    /**
     * @notice G7: Withdrawing more than available - module withdraws what's available
     */
    function test_withdraw_exceeds_available() public {
        vm.prank(escrow);
        token.transfer(address(module), DEPOSIT_AMOUNT / 2);
        
        vm.prank(escrow);
        module.initializeYield(1, address(token), DEPOSIT_AMOUNT / 2, YieldPreset.TO_SENDER);
        
        // Module will withdraw what's available, not revert
        vm.prank(escrow);
        (uint256 principal, uint256 yieldOut) = module.unwindToEscrow(1, address(token), DEPOSIT_AMOUNT);
        
        // Only available amount is withdrawn
        assertEq(principal, DEPOSIT_AMOUNT / 2);
    }

    /**
     * @notice G7: Withdrawing exactly available should succeed
     */
    function test_withdraw_exactly_available() public {
        vm.prank(escrow);
        token.transfer(address(module), DEPOSIT_AMOUNT);
        
        vm.prank(escrow);
        module.initializeYield(1, address(token), DEPOSIT_AMOUNT, YieldPreset.TO_SENDER);
        
        vm.prank(escrow);
        (uint256 principal, uint256 yieldOut) = module.unwindToEscrow(1, address(token), DEPOSIT_AMOUNT);
        
        assertEq(principal, DEPOSIT_AMOUNT);
    }

    // ============ Additional Failure Modes ============

    /**
     * @notice Test: Unapproved escrow cannot trigger any module functions
     */
    function test_unauthorized_escrow_blocked() public {
        vm.prank(attacker);
        vm.expectRevert("UnauthorizedEscrow");
        module.initializeYield(1, address(token), DEPOSIT_AMOUNT, YieldPreset.TO_SENDER);
    }

    /**
     * @notice Test: Wrong token is rejected
     */
    function test_wrong_token_rejected() public {
        address fakeToken = makeAddr('FakeToken');
        
        vm.prank(escrow);
        vm.expectRevert();
        module.initializeYield(1, fakeToken, DEPOSIT_AMOUNT, YieldPreset.TO_SENDER);
    }

    /**
     * @notice Test: Zero amount is rejected
     */
    function test_zero_amount_rejected() public {
        vm.prank(escrow);
        vm.expectRevert("ZeroAmount");
        module.initializeYield(1, address(token), 0, YieldPreset.TO_SENDER);
    }

    /**
     * @notice Test: Position must exist to unwind
     */
    function test_no_position_cannot_unwind() public {
        vm.prank(escrow);
        vm.expectRevert("TokenMismatch");
        module.unwindToEscrow(1, address(token), DEPOSIT_AMOUNT);
    }

    /**
     * @notice Test: Module cannot be tricked into giving out wrong amount
     */
    function test_accounting_integrity() public {
        vm.prank(escrow);
        token.transfer(address(module), DEPOSIT_AMOUNT);
        
        vm.prank(escrow);
        module.initializeYield(1, address(token), DEPOSIT_AMOUNT, YieldPreset.TO_SENDER);
        
        (address posToken, uint256 principal) = module.positions(escrow, 1);
        assertEq(posToken, address(token));
        assertEq(principal, DEPOSIT_AMOUNT);
    }
}
