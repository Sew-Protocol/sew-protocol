// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.37;

import 'forge-std/Test.sol';
import 'contracts/modules/AaveYieldModule.sol';
import 'contracts/mocks/MockAavePool.sol';
import 'contracts/mocks/ERC20Mock.sol';
import 'contracts/types/YieldPresets.sol';

/**
 * @title AaveYieldModuleRecoveryTest
 * @notice Tests for the emergency recovery surface of AaveYieldModule:
 *         setRecoveryOperator, emergencyUnwind, and emergencyUnwindForEscrow.
 *
 * The module is PULL-model: an approved escrow funds a position by approving the
 * module and calling initializeYield (the module pulls from msg.sender). Recovery
 * operations always send proceeds back to the escrow that owns the position.
 *
 * Run: forge test --match-contract AaveYieldModuleRecoveryTest -vvv
 */
contract AaveYieldModuleRecoveryTest is Test {
    AaveYieldModule public module;
    MockAavePool public pool;
    ERC20Mock public token;
    MockAToken public aToken;

    address public escrow;
    address public otherEscrow;
    address public operator;

    uint256 constant DEPOSIT_AMOUNT = 1000e18;

    event RecoveryOperatorSet(address indexed operator, bool allowed);

    function setUp() public {
        pool = new MockAavePool();
        token = new ERC20Mock("Test", "TST", address(this), 1_000_000e18);
        aToken = new MockAToken(address(token), "aTest", "aTEST");

        pool.setAToken(address(token), address(aToken));
        aToken.setPool(address(pool));

        module = new AaveYieldModule(address(pool));
        token.approve(address(pool), type(uint256).max);

        escrow = address(0x1001);
        otherEscrow = address(0x1002);
        operator = address(0x3001);

        module.approveEscrow(escrow);
        module.approveEscrow(otherEscrow);
        module.configureToken(address(token), address(aToken));

        token.transfer(escrow, DEPOSIT_AMOUNT * 4);
        token.transfer(otherEscrow, DEPOSIT_AMOUNT * 4);
    }

    /// @dev Pull-model deposit helper: escrow funds the module by approval only.
    function _deposit(address who, uint256 escrowId, uint256 amount) internal {
        vm.prank(who);
        token.approve(address(module), type(uint256).max);
        vm.prank(who);
        module.initializeYield(escrowId, address(token), amount, YieldPreset.TO_SENDER);
    }

    // ================= Recovery operator administration =================

    function test_setRecoveryOperator_onlyOwner() public {
        module.setRecoveryOperator(operator, true);
        assertTrue(module.recoveryOperators(operator));

        module.setRecoveryOperator(operator, false);
        assertFalse(module.recoveryOperators(operator));
    }

    function test_setRecoveryOperator_emits() public {
        vm.expectEmit(true, true, true, true);
        emit RecoveryOperatorSet(operator, true);
        module.setRecoveryOperator(operator, true);
    }

    function test_setRecoveryOperator_onlyOwner_revertsForNonOwner() public {
        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", operator)
        );
        module.setRecoveryOperator(operator, true);
    }

    function test_setRecoveryOperator_zeroReverts() public {
        vm.expectRevert("InvalidAddress");
        module.setRecoveryOperator(address(0), true);
    }

    // ================= emergencyUnwind (escrow self-service) =================

    function test_emergencyUnwind_returnsPrincipal_toEscrow() public {
        _deposit(escrow, 1, DEPOSIT_AMOUNT);

        uint256 escrowBalBefore = token.balanceOf(escrow);

        vm.prank(escrow);
        uint256 recovered = module.emergencyUnwind(1, address(token), DEPOSIT_AMOUNT);

        assertEq(recovered, DEPOSIT_AMOUNT);
        // INVARIANT 2: proceeds go to the escrow, not the caller of the module.
        assertEq(token.balanceOf(escrow), escrowBalBefore + DEPOSIT_AMOUNT);
        // All underlying returned to the escrow; the module holds no tokens.
        assertEq(token.balanceOf(address(module)), 0);

        // Position cleared.
        (, uint256 principal, , ) = module.positions(escrow, 1);
        assertEq(principal, 0);
    }

    function test_emergencyUnwind_unauthorizedReverts() public {
        _deposit(escrow, 1, DEPOSIT_AMOUNT);

        // A non-approved caller is rejected by onlyEscrow.
        address stranger = address(0x9001);
        vm.prank(stranger);
        vm.expectRevert("UnauthorizedEscrow");
        module.emergencyUnwind(1, address(token), DEPOSIT_AMOUNT);
    }

    function test_emergencyUnwind_tokenMismatchReverts() public {
        _deposit(escrow, 1, DEPOSIT_AMOUNT);

        vm.prank(escrow);
        vm.expectRevert("TokenMismatch");
        module.emergencyUnwind(1, address(0x1234), DEPOSIT_AMOUNT);
    }

    function test_emergencyUnwind_capturesYield() public {
        _deposit(escrow, 1, DEPOSIT_AMOUNT);

        pool.simulateYield(address(token), 100);

        vm.prank(escrow);
        uint256 recovered = module.emergencyUnwind(1, address(token), DEPOSIT_AMOUNT);

        assertGt(recovered, DEPOSIT_AMOUNT);
    }

    function test_emergencyUnwind_clearsPositionAndRevertsOnReuse() public {
        _deposit(escrow, 1, DEPOSIT_AMOUNT);
        vm.prank(escrow);
        module.emergencyUnwind(1, address(token), DEPOSIT_AMOUNT);

        // Second emergency unwind must fail: no position left.
        vm.prank(escrow);
        vm.expectRevert("TokenMismatch");
        module.emergencyUnwind(1, address(token), DEPOSIT_AMOUNT);
    }

    // ================= emergencyUnwindForEscrow (operator / escrow) =================

    function test_emergencyUnwindForEscrow_escrowItself() public {
        _deposit(escrow, 1, DEPOSIT_AMOUNT);

        vm.prank(escrow);
        uint256 recovered = module.emergencyUnwindForEscrow(escrow, 1, address(token), DEPOSIT_AMOUNT);
        assertEq(recovered, DEPOSIT_AMOUNT);
    }

    function test_emergencyUnwindForEscrow_recoveryOperator() public {
        module.setRecoveryOperator(operator, true);
        _deposit(escrow, 1, DEPOSIT_AMOUNT);

        uint256 escrowBalBefore = token.balanceOf(escrow);

        vm.prank(operator);
        uint256 recovered = module.emergencyUnwindForEscrow(escrow, 1, address(token), DEPOSIT_AMOUNT);

        assertEq(recovered, DEPOSIT_AMOUNT);
        // INVARIANT 2: even though the operator initiated, funds go to the escrow.
        assertEq(token.balanceOf(escrow), escrowBalBefore + DEPOSIT_AMOUNT);
        assertEq(token.balanceOf(operator), 0);
    }

    function test_emergencyUnwindForEscrow_nonOperatorReverts() public {
        module.setRecoveryOperator(operator, true);
        _deposit(escrow, 1, DEPOSIT_AMOUNT);

        address random = address(0x9001);
        vm.prank(random);
        vm.expectRevert("UnauthorizedEscrow");
        module.emergencyUnwindForEscrow(escrow, 1, address(token), DEPOSIT_AMOUNT);
    }

    function test_emergencyUnwindForEscrow_revokedOperatorReverts() public {
        module.setRecoveryOperator(operator, true);
        module.setRecoveryOperator(operator, false);
        _deposit(escrow, 1, DEPOSIT_AMOUNT);

        vm.prank(operator);
        vm.expectRevert("UnauthorizedEscrow");
        module.emergencyUnwindForEscrow(escrow, 1, address(token), DEPOSIT_AMOUNT);
    }

    function test_emergencyUnwindForEscrow_unauthorizedEscrowReverts() public {
        _deposit(escrow, 1, DEPOSIT_AMOUNT);

        // otherEscrow is approved but does not own the position.
        vm.prank(otherEscrow);
        vm.expectRevert("UnauthorizedEscrow");
        module.emergencyUnwindForEscrow(escrow, 1, address(token), DEPOSIT_AMOUNT);
    }

    function test_emergencyUnwindForEscrow_operatorUnwindsOtherEscrowPosition() public {
        module.setRecoveryOperator(operator, true);
        _deposit(otherEscrow, 7, DEPOSIT_AMOUNT);

        uint256 otherBalBefore = token.balanceOf(otherEscrow);

        vm.prank(operator);
        uint256 recovered = module.emergencyUnwindForEscrow(otherEscrow, 7, address(token), DEPOSIT_AMOUNT);

        assertEq(recovered, DEPOSIT_AMOUNT);
        assertEq(token.balanceOf(otherEscrow), otherBalBefore + DEPOSIT_AMOUNT);
    }

    function test_emergencyUnwindForEscrow_doesNotTouchOtherPositions() public {
        module.setRecoveryOperator(operator, true);
        _deposit(escrow, 1, DEPOSIT_AMOUNT);
        _deposit(escrow, 2, DEPOSIT_AMOUNT);

        vm.prank(operator);
        module.emergencyUnwindForEscrow(escrow, 1, address(token), DEPOSIT_AMOUNT);

        (, uint256 remaining, , ) = module.positions(escrow, 2);
        assertEq(remaining, DEPOSIT_AMOUNT);
    }
    // ============ #3 Revocation gates new deposits, not exits ============

    function test_revokedEscrow_canStillUnwindExistingPosition() public {
        _deposit(escrow, 1, DEPOSIT_AMOUNT);
        module.revokeEscrow(escrow);

        uint256 balBefore = token.balanceOf(escrow);
        vm.prank(escrow);
        (uint256 principal, ) = module.unwindToEscrow(1, address(token), DEPOSIT_AMOUNT);
        assertEq(principal, DEPOSIT_AMOUNT);
        assertEq(token.balanceOf(escrow), balBefore + DEPOSIT_AMOUNT);
    }

    function test_revokedEscrow_canStillEmergencyUnwindItself() public {
        _deposit(escrow, 1, DEPOSIT_AMOUNT);
        module.revokeEscrow(escrow);

        vm.prank(escrow);
        uint256 recovered = module.emergencyUnwind(1, address(token), DEPOSIT_AMOUNT);
        assertEq(recovered, DEPOSIT_AMOUNT);
    }

    function test_revokedEscrow_operatorCanStillEmergencyUnwind() public {
        module.setRecoveryOperator(operator, true);
        _deposit(escrow, 1, DEPOSIT_AMOUNT);
        module.revokeEscrow(escrow);

        uint256 escrowBalBefore = token.balanceOf(escrow);
        vm.prank(operator);
        uint256 recovered = module.emergencyUnwindForEscrow(escrow, 1, address(token), DEPOSIT_AMOUNT);
        assertEq(recovered, DEPOSIT_AMOUNT);
        assertEq(token.balanceOf(escrow), escrowBalBefore + DEPOSIT_AMOUNT);
    }

    function test_revokedEscrow_cannotInitializeNewPosition() public {
        _deposit(escrow, 1, DEPOSIT_AMOUNT);
        module.revokeEscrow(escrow);

        vm.prank(escrow);
        vm.expectRevert("UnauthorizedEscrow");
        module.initializeYield(2, address(token), DEPOSIT_AMOUNT, YieldPreset.TO_SENDER);
    }

    function test_strangerCannotUnwindRevokedEscrow() public {
        _deposit(escrow, 1, DEPOSIT_AMOUNT);
        module.revokeEscrow(escrow);

        address stranger = address(0x9002);
        vm.prank(stranger);
        vm.expectRevert("UnauthorizedEscrow");
        module.unwindToEscrow(1, address(token), DEPOSIT_AMOUNT);
    }
}
