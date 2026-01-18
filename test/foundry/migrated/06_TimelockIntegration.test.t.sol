// SPDX-License-Identifier: MIT
import "../../../contracts/types/YieldPresets.sol";
pragma solidity ^0.8.33;

import 'forge-std/Test.sol';
import 'contracts/YieldOps.sol';
import 'contracts/DisputeOps.sol';
import 'contracts/core/ModuleManagementContract.sol';
import 'contracts/core/EscrowVault.sol';
import 'contracts/core/EscrowableERC20.sol';
import 'contracts/types/EscrowTypes.sol';
import 'contracts/admin/EscrowAdminContract.sol';

contract Test_06_TimelockIntegration_test is Test {
    EscrowableERC20 token;
    YieldOps public yieldOps;
    DisputeOps public disputeOps;
    ModuleManagementContract public moduleManagement;
    EscrowAdminContract public adminContract;
    EscrowVault vault;
    address deployer = address(this);
    address timelock = address(0x10);
    address newFee = address(0x11);

    function setUp() public {
        yieldOps = new YieldOps(address(this));
        disputeOps = new DisputeOps(address(this));
        token = new EscrowableERC20(
            'Test',
            'TST',
            100,
            address(this),
            address(yieldOps),
            address(disputeOps)
        );
        moduleManagement = new ModuleManagementContract(address(this));
        adminContract = new EscrowAdminContract(address(this));
        vault = new EscrowVault(100, address(this), address(yieldOps), address(disputeOps), address(moduleManagement));
        token.grantRole(token.ROLE_TIMELOCK(), timelock);
        vault.grantRole(vault.ROLE_TIMELOCK(), timelock);
        adminContract.grantRole(adminContract.ROLE_TIMELOCK(), timelock);
    }

    function test_timelock_has_role_and_can_execute_standard_lane() public {
        // timelock should have ROLE_TIMELOCK
        assertTrue(token.hasRole(token.ROLE_TIMELOCK(), timelock));

        // impersonate timelock to set default auto cancel time
        uint256 newTime = block.timestamp + 7 days;
        vm.prank(timelock);
        (uint256 dar, uint256 dac, uint256 mdd, uint256 awd) = token.timeoutConfig();
        TimeoutConfig memory config = TimeoutConfig({
            defaultAutoReleaseTime: dar,
            defaultAutoCancelTime: dac,
            maxDisputeDuration: mdd,
            appealWindowDuration: awd
        });
        config.defaultAutoCancelTime = newTime;
        token.setTimeoutConfig(config);
        (, uint256 newDefaultAutoCancelTime, , ) = token.timeoutConfig();
        assertEq(newDefaultAutoCancelTime, newTime);
    }

    function test_timelock_can_queue_and_activate_slow_lane() public {
        // queue via timelock
        vm.prank(timelock);
        adminContract.queueFeeRecipient(address(token), newFee);

        (address value, uint64 eta, bool exists) = adminContract.getPendingFeeRecipient(address(token));
        assertTrue(exists);
        assertEq(value, newFee);

        // warp and activate
        vm.warp(uint256(eta) + 1);
        vm.prank(timelock);
        adminContract.activateFeeRecipient(address(token));
        assertEq(token.escrowFeeAddress(), newFee);
    }
}
