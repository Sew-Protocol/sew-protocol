// SPDX-License-Identifier: MIT
import "../../../contracts/types/YieldPresets.sol";
pragma solidity ^0.8.33;

import 'forge-std/Test.sol';
import 'contracts/ops/YieldOps.sol';
import 'contracts/ops/DisputeOps.sol';
import 'contracts/core/ModuleSnapshotRegistry.sol';
import 'contracts/admin/EscrowGovernanceTimelock.sol';
import 'contracts/core/EscrowVault.sol';

contract Test_02_SlowLaneQueueActivate_test is Test {
    EscrowVault vault;
    YieldOps public yieldOps;
    DisputeOps public disputeOps;
    ModuleSnapshotRegistry public moduleManagement;
    EscrowGovernanceTimelock public adminContract;
    address timelock = address(0x1);
    address newFeeAddr = address(0x9);

    function setUp() public {
        yieldOps = new YieldOps(address(this));
        disputeOps = new DisputeOps(address(this));
        moduleManagement = new ModuleSnapshotRegistry(address(this));
        adminContract = new EscrowGovernanceTimelock(address(this));
        vault = new EscrowVault(100, address(this), address(yieldOps), address(disputeOps), address(moduleManagement));
        // grant timelock role to timelock address
        vault.grantRole(vault.ROLE_TIMELOCK(), timelock);
        vault.grantRole(vault.ROLE_ADMIN_CONTRACT(), address(adminContract));
        adminContract.grantRole(adminContract.ROLE_TIMELOCK(), timelock);
    }

    function test_queue_and_activate_fee_address() public {
        vm.prank(timelock);
        adminContract.queueFeeRecipient(address(vault), newFeeAddr);

        (address value, uint64 eta, bool exists) = adminContract.getPendingFeeRecipient(address(vault));
        assertTrue(exists);
        assertEq(value, newFeeAddr);
        assertTrue(uint256(eta) > block.timestamp);

        // activate too early should revert
        vm.prank(timelock);
        vm.expectRevert();
        adminContract.activateFeeRecipient(address(vault));

        // warp to after eta and activate
        vm.warp(uint256(eta) + 1);
        vm.prank(timelock);
        adminContract.activateFeeRecipient(address(vault));
        assertEq(vault.escrowFeeAddress(), newFeeAddr);
    }

    function test_queue_and_activate_fee_bps() public {
        uint256 newFee = 150; // 1.5%
        vm.prank(timelock);
        adminContract.queueEscrowFee(address(vault), newFee);

        (uint256 v, uint64 eta, bool exists) = adminContract.getPendingEscrowFee(address(vault));
        assertTrue(exists);
        assertEq(v, newFee);

        vm.warp(uint256(eta) + 1);
        vm.prank(timelock);
        adminContract.activateEscrowFee(address(vault));
        assertEq(vault.escrowFee(), newFee);
    }
}
