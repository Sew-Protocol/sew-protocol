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
        disputeOps = new DisputeOps(address(this));
        moduleManagement = new ModuleManagementContract(address(this));
        vault = new EscrowVault(100, address(this), address(yieldOps), address(disputeOps), address(moduleManagement));
        vault.grantRole(vault.ROLE_TIMELOCK(), timelock);
    }

    function test_auto_cancel_time_bounds_accept_and_reject() public {
        // accept 0
        vm.prank(timelock);
        (uint256 dar, uint256 dac, uint256 mdd, uint256 awd) = vault.timeoutConfig();
        TimeoutConfig memory config = TimeoutConfig({
            defaultAutoReleaseTime: dar,
            defaultAutoCancelTime: dac,
            maxDisputeDuration: mdd,
            appealWindowDuration: awd
        });
        config.defaultAutoCancelTime = 0;
        vault.setTimeoutConfig(config);
        (, uint256 newDefaultAutoCancelTime, , ) = vault.timeoutConfig();
        assertEq(newDefaultAutoCancelTime, 0);

        // accept max (30 days)
        uint256 maxTime = block.timestamp + 30 days;
        vm.prank(timelock);
        (dar, dac, mdd, awd) = vault.timeoutConfig();
        config = TimeoutConfig({
            defaultAutoReleaseTime: dar,
            defaultAutoCancelTime: dac,
            maxDisputeDuration: mdd,
            appealWindowDuration: awd
        });
        config.defaultAutoCancelTime = maxTime;
        vault.setTimeoutConfig(config);
        (, newDefaultAutoCancelTime, , ) = vault.timeoutConfig();
        assertEq(newDefaultAutoCancelTime, maxTime);

        // exceed max -> revert
        vm.prank(timelock);
        vm.expectRevert();
        (dar, dac, mdd, awd) = vault.timeoutConfig();
        config = TimeoutConfig({
            defaultAutoReleaseTime: dar,
            defaultAutoCancelTime: dac,
            maxDisputeDuration: mdd,
            appealWindowDuration: awd
        });
        config.defaultAutoCancelTime = block.timestamp + 30 days + 1;
        vault.setTimeoutConfig(config);
    }

    function test_auto_release_time_bounds() public {
        vm.prank(timelock);
        (uint256 dar, uint256 dac, uint256 mdd, uint256 awd) = vault.timeoutConfig();
        TimeoutConfig memory config = TimeoutConfig({
            defaultAutoReleaseTime: dar,
            defaultAutoCancelTime: dac,
            maxDisputeDuration: mdd,
            appealWindowDuration: awd
        });
        config.defaultAutoReleaseTime = 0;
        vault.setTimeoutConfig(config);
        (uint256 newDefaultAutoReleaseTime, , , ) = vault.timeoutConfig();
        assertEq(newDefaultAutoReleaseTime, 0);

        uint256 maxTime = block.timestamp + 30 days;
        vm.prank(timelock);
        (dar, dac, mdd, awd) = vault.timeoutConfig();
        config = TimeoutConfig({
            defaultAutoReleaseTime: dar,
            defaultAutoCancelTime: dac,
            maxDisputeDuration: mdd,
            appealWindowDuration: awd
        });
        config.defaultAutoReleaseTime = maxTime;
        vault.setTimeoutConfig(config);
        (newDefaultAutoReleaseTime, , , ) = vault.timeoutConfig();
        assertEq(newDefaultAutoReleaseTime, maxTime);

        vm.prank(timelock);
        vm.expectRevert();
        (dar, dac, mdd, awd) = vault.timeoutConfig();
        config = TimeoutConfig({
            defaultAutoReleaseTime: dar,
            defaultAutoCancelTime: dac,
            maxDisputeDuration: mdd,
            appealWindowDuration: awd
        });
        config.defaultAutoReleaseTime = block.timestamp + 30 days + 1;
        vault.setTimeoutConfig(config);
    }
}
