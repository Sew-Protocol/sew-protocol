// SPDX-License-Identifier: MIT
import "../../../contracts/types/YieldPresets.sol";
pragma solidity ^0.8.33;

import 'forge-std/Test.sol';
import 'contracts/YieldOps.sol';
import 'contracts/DisputeOps.sol';
import 'contracts/core/ModuleManagementContract.sol';
import 'contracts/core/EscrowVault.sol';
import 'contracts/types/EscrowTypes.sol';

contract Test_03_BoundsEnforcement_test is Test {
    EscrowVault vault;
    YieldOps public yieldOps;
    DisputeOps public disputeOps;
    ModuleManagementContract public moduleManagement;
    address timelock = address(0x1);

    function setUp() public {
        yieldOps = new YieldOps(address(this));
        disputeOps = new DisputeOps();
        moduleManagement = new ModuleManagementContract(address(this));
        vault = new EscrowVault(100, address(this), address(yieldOps), address(disputeOps), address(moduleManagement));
        vault.grantRole(vault.ROLE_TIMELOCK(), timelock);
    }

    function test_auto_cancel_time_bounds_accept_and_reject() public {
        // accept 0
        vm.prank(timelock);
        TimeoutConfig memory config = vault.getTimeoutConfig();
        config.defaultAutoCancelTime = 0;
        vault.setTimeoutConfig(config);
        assertEq(vault.getTimeoutConfig().defaultAutoCancelTime, 0);

        // accept max (30 days)
        uint256 maxTime = block.timestamp + 30 days;
        vm.prank(timelock);
        config = vault.getTimeoutConfig();
        config.defaultAutoCancelTime = maxTime;
        vault.setTimeoutConfig(config);
        assertEq(vault.getTimeoutConfig().defaultAutoCancelTime, maxTime);

        // exceed max -> revert
        vm.prank(timelock);
        vm.expectRevert();
        config = vault.getTimeoutConfig();
        config.defaultAutoCancelTime = block.timestamp + 30 days + 1;
        vault.setTimeoutConfig(config);
    }

    function test_auto_release_time_bounds() public {
        vm.prank(timelock);
        TimeoutConfig memory config = vault.getTimeoutConfig();
        config.defaultAutoReleaseTime = 0;
        vault.setTimeoutConfig(config);
        assertEq(vault.getTimeoutConfig().defaultAutoReleaseTime, 0);

        uint256 maxTime = block.timestamp + 30 days;
        vm.prank(timelock);
        config = vault.getTimeoutConfig();
        config.defaultAutoReleaseTime = maxTime;
        vault.setTimeoutConfig(config);
        assertEq(vault.getTimeoutConfig().defaultAutoReleaseTime, maxTime);

        vm.prank(timelock);
        vm.expectRevert();
        config = vault.getTimeoutConfig();
        config.defaultAutoReleaseTime = block.timestamp + 30 days + 1;
        vault.setTimeoutConfig(config);
    }
}
