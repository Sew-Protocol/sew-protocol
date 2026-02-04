// SPDX-License-Identifier: MIT
import "../../../contracts/types/YieldPresets.sol";
pragma solidity ^0.8.33;

import 'forge-std/Test.sol';
import 'contracts/YieldOps.sol';
import 'contracts/DisputeOps.sol';
import 'contracts/core/ModuleSnapshotRegistry.sol';
import 'contracts/core/EscrowableERC20.sol';
import 'contracts/core/EscrowVault.sol';
import 'contracts/admin/EscrowGovernanceTimelock.sol';
import 'contracts/types/EscrowTypes.sol';

contract Test_01_AccessControl_test is Test {
    EscrowableERC20 escrowable;
    YieldOps public yieldOps;
    DisputeOps public disputeOps;
    ModuleSnapshotRegistry public moduleManagement;
    EscrowVault escrowVault;
    EscrowGovernanceTimelock public adminContract;
    address timelock = address(0x1);
    address guardian = address(0x2);
    address unauthorized = address(0x3);
    address feeAddr = address(0x4);

    function setUp() public {
        yieldOps = new YieldOps(address(this));
        disputeOps = new DisputeOps(address(this));
        moduleManagement = new ModuleSnapshotRegistry(address(this));
        escrowable = new EscrowableERC20(
            'Test Token',
            'TEST',
            100,
            feeAddr,
            address(yieldOps),
            address(disputeOps),
            address(moduleManagement)
        );
        escrowVault = new EscrowVault(100, feeAddr, address(yieldOps), address(disputeOps), address(moduleManagement));
        adminContract = new EscrowGovernanceTimelock(address(this));
        adminContract.grantRole(adminContract.ROLE_TIMELOCK(), timelock);
        escrowable.grantRole(escrowable.ROLE_ADMIN_CONTRACT(), address(adminContract));
    }

    function test_role_constants_and_granting() public {
        bytes32 ROLE_TIMELOCK = escrowable.ROLE_TIMELOCK();
        bytes32 ROLE_GUARDIAN = escrowable.ROLE_GUARDIAN();
        bytes32 DEFAULT_ADMIN_ROLE = escrowable.DEFAULT_ADMIN_ROLE();

        assertTrue(ROLE_TIMELOCK != bytes32(0));
        assertTrue(ROLE_GUARDIAN != bytes32(0));
        assertEq(DEFAULT_ADMIN_ROLE, bytes32(0)); // OpenZeppelin default

        // Grant ROLE_TIMELOCK to timelock and verify
        escrowable.grantRole(ROLE_TIMELOCK, timelock);
        assertTrue(escrowable.hasRole(ROLE_TIMELOCK, timelock));
    }

    function test_timelock_actions_can_set_defaults() public {
        bytes32 ROLE_TIMELOCK = escrowable.ROLE_TIMELOCK();
        escrowable.grantRole(ROLE_TIMELOCK, timelock);

        uint256 newTime = block.timestamp + 7 days;
        (uint256 dar, uint256 dac, uint256 mdd, uint256 awd) = escrowable.timeoutConfig();
        TimeoutConfig memory config = TimeoutConfig({
            defaultAutoReleaseDelay: dar,
            defaultAutoCancelDelay: dac,
            maxDisputeDuration: mdd,
            appealWindowDuration: awd
        });
        config.defaultAutoCancelDelay = newTime;
        vm.prank(timelock);
        adminContract.setTimeoutConfig(address(escrowable), config);
        (, uint256 newDefaultAutoCancelTime, , ) = escrowable.timeoutConfig();
        assertEq(newDefaultAutoCancelTime, newTime);

        // EscrowVault should share role constants
        bytes32 ROLE_TIMELOCK_V = escrowVault.ROLE_TIMELOCK();
        assertEq(ROLE_TIMELOCK, ROLE_TIMELOCK_V);
    }

    function test_guardian_pause_behavior() public {
        bytes32 ROLE_GUARDIAN = escrowable.ROLE_GUARDIAN();
        escrowable.grantRole(ROLE_GUARDIAN, guardian);

        vm.prank(guardian);
        escrowable.pause("test pause");
        assertTrue(escrowable.paused());

        // Guardian cannot unpause
        vm.prank(guardian);
        vm.expectRevert();
        escrowable.unpause();

        // Unauthorized cannot pause
        vm.prank(unauthorized);
        vm.expectRevert();
        escrowable.pause("test pause");
    }
}
