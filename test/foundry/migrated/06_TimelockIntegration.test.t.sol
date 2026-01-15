// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import 'forge-std/Test.sol';
import 'contracts/YieldOps.sol';
import 'contracts/DisputeOps.sol';
import 'contracts/core/EscrowVault.sol';
import 'contracts/core/EscrowableERC20.sol';

contract Test_06_TimelockIntegration_test is Test {
    EscrowableERC20 token;
    YieldOps public yieldOps;
    DisputeOps public disputeOps;
    EscrowVault vault;
    address deployer = address(this);
    address timelock = address(0x10);
    address newFee = address(0x11);

    function setUp() public {
        yieldOps = new YieldOps();
        disputeOps = new DisputeOps();
        token = new EscrowableERC20(
            'Test',
            'TST',
            100,
            address(this),
            address(yieldOps),
            address(disputeOps)
        );
        vault = new EscrowVault(100, address(this), address(yieldOps), address(disputeOps));
        token.grantRole(token.ROLE_TIMELOCK(), timelock);
        vault.grantRole(vault.ROLE_TIMELOCK(), timelock);
    }

    function test_timelock_has_role_and_can_execute_standard_lane() public {
        // timelock should have ROLE_TIMELOCK
        assertTrue(token.hasRole(token.ROLE_TIMELOCK(), timelock));

        // impersonate timelock to set default auto cancel time
        uint256 newTime = block.timestamp + 7 days;
        vm.prank(timelock);
        token.setDefaultAutoCancelTime(newTime);
        assertEq(token.defaultAutoCancelTime(), newTime);
    }

    function test_timelock_can_queue_and_activate_slow_lane() public {
        // queue via timelock
        vm.prank(timelock);
        token.queueEscrowFeeAddress(newFee);

        (address value, uint64 eta, bool exists) = token.getPendingFeeRecipient();
        assertTrue(exists);
        assertEq(value, newFee);

        // warp and activate
        vm.warp(uint256(eta) + 1);
        vm.prank(timelock);
        token.activateEscrowFeeAddress();
        assertEq(token.escrowFeeAddress(), newFee);
    }
}
