// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.37;

import 'forge-std/Test.sol';
import 'contracts/modules/AaveYieldModule.sol';
import 'contracts/mocks/MockAavePool.sol';
import 'contracts/mocks/ERC20Mock.sol';
import 'contracts/interfaces/IYieldModule.sol';
import 'contracts/types/YieldPresets.sol';

/**
 * @title AaveYieldModuleExposureCapTest
 * @notice Adversarial coverage for the per-token exposure cap (task #2):
 *   - deposits that would exceed the cap revert (CapExceeded)
 *   - already-at-cap blocks new deposits
 *   - unwind reduces exposure, allowing further deposits
 *   - lowering a cap is FAST (risk-reducing) and never strands existing funds
 *   - raising a cap is SLOW-LANE (risk-increasing)
 *   - canHandle mirrors the cap check (CAP_EXCEEDED)
 */
contract AaveYieldModuleExposureCapTest is Test {
    AaveYieldModule public module;
    MockAavePool public pool;
    ERC20Mock public token;
    MockAToken public aToken;

    address internal constant ESCROW = address(0x1001);
    uint256 internal constant DEPOSIT = 1000e18;

    function setUp() public {
        token = new ERC20Mock('CapToken', 'CAP', address(this), 1_000_000e18);
        aToken = new MockAToken(address(token), 'aCap', 'aCAP');
        pool = new MockAavePool();
        pool.setAToken(address(token), address(aToken));
        aToken.setPool(address(pool));

        module = new AaveYieldModule(address(pool));

        // Queue both slow-lane changes first, then warp once well past the 7d delay
        // and activate both. Avoids fragmentary cumulative warps.
        module.queueConfigureToken(address(token), address(aToken));
        module.queueApproveEscrow(ESCROW);
        vm.warp(block.timestamp + 8 days);
        module.activateConfigureToken(address(token));
        module.activateApproveEscrow();
    }

    function _configureToken() internal {
        module.queueConfigureToken(address(token), address(aToken));
        vm.warp(block.timestamp + 7 days);
        module.activateConfigureToken(address(token));
    }

    function _approveEscrow() internal {
        module.queueApproveEscrow(ESCROW);
        vm.warp(block.timestamp + 7 days);
        module.activateApproveEscrow();
    }

    function _fundEscrow(uint256 amt) internal {
        token.transfer(ESCROW, amt);
        vm.prank(ESCROW);
        token.approve(address(module), type(uint256).max);
    }

    function _deposit(uint256 amountsOutEscrowId, uint256 amt) internal returns (uint256 escrowId) {
        _fundEscrow(amt);
        vm.prank(ESCROW);
        return module.initializeYield(amountsOutEscrowId, address(token), amt, YieldPreset.OFF);
    }

    // Slow-lane cap raise helper.
    function _raiseCap(uint256 cap) internal {
        module.queueConfigureTokenCap(address(token), cap);
        vm.warp(block.timestamp + 7 days);
        module.activateConfigureTokenCap(address(token));
    }

    // ---- Cap enforcement on deposit ----

    function test_deposit_over_cap_reverts() public {
        _raiseCap(DEPOSIT);
        _deposit(1, DEPOSIT); // fills the cap exactly

        _fundEscrow(DEPOSIT);
        vm.prank(ESCROW);
        vm.expectRevert('CapExceeded');
        module.initializeYield(2, address(token), DEPOSIT, YieldPreset.OFF);
    }

    function test_already_at_cap_blocks_further_deposit() public {
        _raiseCap(DEPOSIT + 1);
        _deposit(1, DEPOSIT); // totalDeposited = DEPOSIT < cap

        // Remaining room below cap: amount would exceed -> revert.
        _fundEscrow(2);
        vm.prank(ESCROW);
        vm.expectRevert('CapExceeded');
        module.initializeYield(2, address(token), 2, YieldPreset.OFF);
    }

    function test_unwind_reduces_exposure_then_allows_deposit_again() public {
        _raiseCap(DEPOSIT);
        _deposit(1, DEPOSIT);

        // Unwind frees the full cap.
        vm.prank(ESCROW);
        module.unwindToEscrow(1, address(token), DEPOSIT);

        assertEq(module.totalDepositedByToken(address(token)), 0, 'exposure fully released after unwind');
        _deposit(2, DEPOSIT); // now allowed again
    }

    function test_emergencyUnwind_reduces_exposure() public {
        _raiseCap(DEPOSIT);
        _deposit(1, DEPOSIT);

        vm.prank(ESCROW);
        module.emergencyUnwind(1, address(token), DEPOSIT);
        assertEq(module.totalDepositedByToken(address(token)), 0, 'exposure released by emergency unwind');
        _deposit(2, DEPOSIT);
    }

    // ---- Lowering a cap is fast; raising is slow-lane ----

    function test_lowerCap_is_fast_no_delay() public {
        _raiseCap(DEPOSIT * 2);
        assertEq(module.depositCapByToken(address(token)), DEPOSIT * 2);

        // Fast lower, no warp needed.
        module.lowerTokenCap(address(token), DEPOSIT);
        assertEq(module.depositCapByToken(address(token)), DEPOSIT);
    }

    function test_lowerCap_must_strictly_decrease() public {
        _raiseCap(DEPOSIT);
        vm.expectRevert('CapNotLowered');
        module.lowerTokenCap(address(token), DEPOSIT); // equal -> revert

        vm.expectRevert('CapNotLowered');
        module.lowerTokenCap(address(token), DEPOSIT * 2); // raise via fast path -> revert
    }

    function test_lowering_cap_below_exposure_does_not_strand_funds() public {
        _raiseCap(DEPOSIT);
        _deposit(1, DEPOSIT); // exposure = DEPOSIT = cap

        // Lower cap below current exposure. Existing funds must remain unwindable.
        module.lowerTokenCap(address(token), DEPOSIT / 2);

        // New deposits blocked.
        _fundEscrow(1);
        vm.prank(ESCROW);
        vm.expectRevert('CapExceeded');
        module.initializeYield(2, address(token), 1, YieldPreset.OFF);

        // Existing position still unwinds fully (no stranding).
        vm.prank(ESCROW);
        (uint256 principal,) = module.unwindToEscrow(1, address(token), DEPOSIT);
        assertEq(principal, DEPOSIT, 'existing exposure fully recoverable after cap lowered below it');
        assertEq(module.totalDepositedByToken(address(token)), 0);

        // Now fresh deposits are allowed up to the new lower cap.
        _deposit(3, DEPOSIT / 4);
    }

    function test_raise_cap_is_slow_lane() public {
        _raiseCap(DEPOSIT);
        assertEq(module.depositCapByToken(address(token)), DEPOSIT);

        // Queue a raise — not applied until the slow-lane delay elapses.
        module.queueConfigureTokenCap(address(token), DEPOSIT * 2);
        assertEq(module.depositCapByToken(address(token)), DEPOSIT, 'cap unchanged until activation');

        vm.warp(block.timestamp + 7 days);
        module.activateConfigureTokenCap(address(token));
        assertEq(module.depositCapByToken(address(token)), DEPOSIT * 2);
    }

    // ---- canHandle mirrors the cap ----

    function test_canHandle_cap_exceeded() public {
        _raiseCap(DEPOSIT);
        _deposit(1, DEPOSIT);

        (bool supported, bytes32 reason) = module.canHandle(address(token), YieldPreset.OFF, DEPOSIT);
        assertFalse(supported);
        assertEq(reason, keccak256('CAP_EXCEEDED'));
    }

    function test_canHandle_ok_within_cap() public {
        _raiseCap(DEPOSIT * 2);
        _deposit(1, DEPOSIT);

        (bool supported, bytes32 reason) = module.canHandle(address(token), YieldPreset.OFF, DEPOSIT);
        assertTrue(supported);
        assertEq(reason, 0x0);
    }

    // ---- Zero cap = unlimited ----

    function test_zero_cap_is_unlimited() public {
        // No cap ever set (0 = unlimited), so repeated large deposits are fine.
        _deposit(1, DEPOSIT);
        _deposit(2, DEPOSIT);
        _deposit(3, DEPOSIT);
        assertEq(module.depositCapByToken(address(token)), 0);
        assertEq(module.totalDepositedByToken(address(token)), DEPOSIT * 3);
    }
}
