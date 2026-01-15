// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import 'forge-std/Test.sol';
import 'contracts/YieldOps.sol';
import 'contracts/DisputeOps.sol';
import 'contracts/core/EscrowVault.sol';

contract Test_04_GuardianControls_test is Test {
    EscrowVault vault;
    YieldOps public yieldOps;
    DisputeOps public disputeOps;
    address timelock = address(0x1);
    address guardian = address(0x2);
    address unauthorized = address(0x3);

    function setUp() public {
        yieldOps = new YieldOps();
        disputeOps = new DisputeOps();
        vault = new EscrowVault(100, address(this), address(yieldOps), address(disputeOps));
        vault.grantRole(vault.ROLE_TIMELOCK(), timelock);
        vault.grantRole(vault.ROLE_GUARDIAN(), guardian);
    }

    function test_guardian_pause_unpause_rules() public {
        // Guardian can pause
        vm.prank(guardian);
        vault.pause();
        assertTrue(vault.paused());

        // Guardian cannot unpause
        vm.prank(guardian);
        vm.expectRevert();
        vault.unpause();

        // Timelock can unpause
        vm.prank(timelock);
        vault.unpause();
        assertFalse(vault.paused());

        // Unauthorized cannot pause
        vm.prank(unauthorized);
        vm.expectRevert();
        vault.pause();
    }
}
