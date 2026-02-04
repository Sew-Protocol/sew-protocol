// SPDX-License-Identifier: MIT
import "../../../contracts/types/YieldPresets.sol";
pragma solidity ^0.8.33;

import 'forge-std/Test.sol';
import 'contracts/YieldOps.sol';
import 'contracts/DisputeOps.sol';
import 'contracts/core/ModuleSnapshotRegistry.sol';
import 'contracts/core/EscrowVault.sol';
import 'contracts/admin/EscrowGovernanceTimelock.sol';
import 'contracts/types/EscrowTypes.sol';

contract Test_03_BoundsEnforcement_test is Test {
    EscrowVault vault;
    YieldOps public yieldOps;
    DisputeOps public disputeOps;
    ModuleSnapshotRegistry public moduleManagement;
    EscrowGovernanceTimelock public adminContract;
    address timelock = address(0x1);

    function setUp() public {
        yieldOps = new YieldOps(address(this));
        disputeOps = new DisputeOps(address(this));
        moduleManagement = new ModuleSnapshotRegistry(address(this));
        vault = new EscrowVault(100, address(this), address(yieldOps), address(disputeOps), address(moduleManagement));
        vault.grantRole(vault.ROLE_TIMELOCK(), timelock);
        adminContract = new EscrowGovernanceTimelock(address(this));
        adminContract.grantRole(adminContract.ROLE_TIMELOCK(), timelock);
        vault.grantRole(vault.ROLE_ADMIN_CONTRACT(), address(adminContract));
    }

    function test_auto_cancel_time_bounds_accept_and_reject() public {
        // accept 0
        (uint256 dar, uint256 dac, uint256 mdd, uint256 awd) = vault.timeoutConfig();
        TimeoutConfig memory config = TimeoutConfig({
            defaultAutoReleaseDelay: dar,
            defaultAutoCancelDelay: dac,
            maxDisputeDuration: mdd,
            appealWindowDuration: awd
        });
        config.defaultAutoCancelDelay = 0;
        vm.prank(timelock);
        adminContract.setTimeoutConfig(address(vault), config);
        (, uint256 newDefaultAutoCancelTime, , ) = vault.timeoutConfig();
        assertEq(newDefaultAutoCancelTime, 0);

        // accept max (30 days)
        uint256 maxTime = 30 days;
        (dar, dac, mdd, awd) = vault.timeoutConfig();
        config = TimeoutConfig({
            defaultAutoReleaseDelay: dar,
            defaultAutoCancelDelay: dac,
            maxDisputeDuration: mdd,
            appealWindowDuration: awd
        });
        config.defaultAutoCancelDelay = maxTime;
        vm.prank(timelock);
        adminContract.setTimeoutConfig(address(vault), config);
        (, newDefaultAutoCancelTime, , ) = vault.timeoutConfig();
        assertEq(newDefaultAutoCancelTime, maxTime);

        // exceed max -> revert
        (dar, dac, mdd, awd) = vault.timeoutConfig();
        config = TimeoutConfig({
            defaultAutoReleaseDelay: dar,
            defaultAutoCancelDelay: dac,
            maxDisputeDuration: mdd,
            appealWindowDuration: awd
        });
        config.defaultAutoCancelDelay = 30 days + 1;
        vm.expectRevert();
        vm.prank(timelock);
        adminContract.setTimeoutConfig(address(vault), config);
    }

    function test_auto_release_time_bounds() public {
        (uint256 dar, uint256 dac, uint256 mdd, uint256 awd) = vault.timeoutConfig();
        TimeoutConfig memory config = TimeoutConfig({
            defaultAutoReleaseDelay: dar,
            defaultAutoCancelDelay: dac,
            maxDisputeDuration: mdd,
            appealWindowDuration: awd
        });
        config.defaultAutoReleaseDelay = 0;
        vm.prank(timelock);
        adminContract.setTimeoutConfig(address(vault), config);
        (uint256 newDefaultAutoReleaseTime, , , ) = vault.timeoutConfig();
        assertEq(newDefaultAutoReleaseTime, 0);

        uint256 maxTime = 30 days;
        (dar, dac, mdd, awd) = vault.timeoutConfig();
        config = TimeoutConfig({
            defaultAutoReleaseDelay: dar,
            defaultAutoCancelDelay: dac,
            maxDisputeDuration: mdd,
            appealWindowDuration: awd
        });
        config.defaultAutoReleaseDelay = maxTime;
        vm.prank(timelock);
        adminContract.setTimeoutConfig(address(vault), config);
        (newDefaultAutoReleaseTime, , , ) = vault.timeoutConfig();
        assertEq(newDefaultAutoReleaseTime, maxTime);

        (dar, dac, mdd, awd) = vault.timeoutConfig();
        config = TimeoutConfig({
            defaultAutoReleaseDelay: dar,
            defaultAutoCancelDelay: dac,
            maxDisputeDuration: mdd,
            appealWindowDuration: awd
        });
        config.defaultAutoReleaseDelay = 30 days + 1;
        vm.expectRevert();
        vm.prank(timelock);
        adminContract.setTimeoutConfig(address(vault), config);
    }
}
