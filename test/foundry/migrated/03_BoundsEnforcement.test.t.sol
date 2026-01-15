// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import "../../../../contracts/YieldOps.sol";
import "../../../../contracts/DisputeOps.sol";
import "contracts/core/EscrowVault.sol";

contract Test_03_BoundsEnforcement_test is Test {
    EscrowVault vault;
    YieldOps public yieldOps;
    DisputeOps public disputeOps;
    address timelock = address(0x1);

    function setUp() public {
        yieldOps = new YieldOps();
        disputeOps = new DisputeOps();
        vault = new EscrowVault(100, address(this), address(yieldOps), address(disputeOps));
        vault.grantRole(vault.ROLE_TIMELOCK(), timelock);
    }

    function test_auto_cancel_time_bounds_accept_and_reject() public {
        // accept 0
        vm.prank(timelock);
        vault.setDefaultAutoCancelTime(0);
        assertEq(vault.defaultAutoCancelTime(), 0);

        // accept max (30 days)
        uint256 maxTime = block.timestamp + 30 days;
        vm.prank(timelock);
        vault.setDefaultAutoCancelTime(maxTime);
        assertEq(vault.defaultAutoCancelTime(), maxTime);

        // exceed max -> revert
        vm.prank(timelock);
        vm.expectRevert();
        vault.setDefaultAutoCancelTime(block.timestamp + 30 days + 1);
    }

    function test_auto_release_time_bounds() public {
        vm.prank(timelock);
        vault.setDefaultAutoReleaseTime(0);
        assertEq(vault.defaultAutoReleaseTime(), 0);

        uint256 maxTime = block.timestamp + 30 days;
        vm.prank(timelock);
        vault.setDefaultAutoReleaseTime(maxTime);
        assertEq(vault.defaultAutoReleaseTime(), maxTime);

        vm.prank(timelock);
        vm.expectRevert();
        vault.setDefaultAutoReleaseTime(block.timestamp + 30 days + 1);
    }
}
