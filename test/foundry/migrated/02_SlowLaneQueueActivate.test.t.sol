// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import "../../../../contracts/YieldOps.sol";
import "../../../../contracts/DisputeOps.sol";
import "contracts/core/EscrowVault.sol";

contract Test_02_SlowLaneQueueActivate_test is Test {
    EscrowVault vault;
    YieldOps public yieldOps;
    DisputeOps public disputeOps;
    address timelock = address(0x1);
    address newFeeAddr = address(0x9);

    function setUp() public {
        yieldOps = new YieldOps();
        disputeOps = new DisputeOps();
        vault = new EscrowVault(100, address(this), address(yieldOps), address(disputeOps));
        // grant timelock role to timelock address
        vault.grantRole(vault.ROLE_TIMELOCK(), timelock);
    }

    function test_queue_and_activate_fee_address() public {
        vm.prank(timelock);
        vault.queueEscrowFeeAddress(newFeeAddr);

        (address value, uint64 eta, bool exists) = vault.getPendingFeeRecipient();
        assertTrue(exists);
        assertEq(value, newFeeAddr);
        assertTrue(uint256(eta) > block.timestamp);

        // activate too early should revert
        vm.prank(timelock);
        vm.expectRevert();
        vault.activateEscrowFeeAddress();

        // warp to after eta and activate
        vm.warp(uint256(eta) + 1);
        vm.prank(timelock);
        vault.activateEscrowFeeAddress();
        assertEq(vault.escrowFeeAddress(), newFeeAddr);
    }

    function test_queue_and_activate_fee_bps() public {
        uint256 newFee = 150; // 1.5%
        vm.prank(timelock);
        vault.queueEscrowFee(newFee);

        (uint256 v, uint64 eta, bool exists) = vault.getPendingEscrowFee();
        assertTrue(exists);
        assertEq(v, newFee);

        vm.warp(uint256(eta) + 1);
        vm.prank(timelock);
        vault.activateEscrowFee();
        assertEq(vault.escrowFee(), newFee);
    }
}
