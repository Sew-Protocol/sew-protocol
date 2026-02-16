// SPDX-License-Identifier: MIT
import "../../../contracts/types/YieldPresets.sol";
pragma solidity ^0.8.33;

import 'forge-std/Test.sol';
import 'contracts/ops/YieldOps.sol';
import 'contracts/ops/DisputeOps.sol';
import 'contracts/core/ModuleSnapshotRegistry.sol';
import 'contracts/core/EscrowVault.sol';
import '../TestConfig.sol';

contract Test_04_GuardianControls_test is Test {
    EscrowVault vault;
    YieldOps public yieldOps;
    DisputeOps public disputeOps;
    ModuleSnapshotRegistry public moduleManagement;
    address timelock = address(0x1);
    address guardian = address(0x2);
    address unauthorized = address(0x3);

    function setUp() public {
        vm.skip(!TestConfig.RUN_PAUSE_TESTS);
        yieldOps = new YieldOps(address(this));
        disputeOps = new DisputeOps(address(this));
        moduleManagement = new ModuleSnapshotRegistry(address(this));
        vault = new EscrowVault(100, address(this), address(yieldOps), address(disputeOps), address(moduleManagement));
        vault.grantRole(vault.ROLE_TIMELOCK(), timelock);
        vault.grantRole(vault.ROLE_GUARDIAN(), guardian);
    }

    function test_guardian_pause_unpause_rules() public {
        // Guardian can pause
        vm.prank(guardian);
        vault.pause("test pause");
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
        vault.pause("test pause");
    }
}
