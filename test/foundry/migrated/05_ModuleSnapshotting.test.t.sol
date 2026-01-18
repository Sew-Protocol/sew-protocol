// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import 'forge-std/Test.sol';
import 'contracts/YieldOps.sol';
import 'contracts/DisputeOps.sol';
import 'contracts/core/ModuleManagementContract.sol';
import 'contracts/core/EscrowVault.sol';
import 'contracts/mocks/ERC20Mock.sol';
import 'contracts/core/modules/DefaultResolutionModule.sol';
import 'contracts/types/YieldPresets.sol';
import 'contracts/admin/EscrowAdminContract.sol';
import 'contracts/types/EscrowTypes.sol';

contract Test_05_ModuleSnapshotting_test is Test {
    EscrowVault vault;
    EscrowAdminContract adminContract;
    YieldOps public yieldOps;
    DisputeOps public disputeOps;
    ModuleManagementContract public moduleManagement;
    address deployer = address(this);
    address timelock = address(0x1);

    function setUp() public {
        yieldOps = new YieldOps(address(this));
        disputeOps = new DisputeOps(address(this));
        moduleManagement = new ModuleManagementContract(address(this));
        vault = new EscrowVault(100, address(this), address(yieldOps), address(disputeOps), address(moduleManagement));
        adminContract = new EscrowAdminContract(address(this));
        vault.grantRole(vault.ROLE_TIMELOCK(), timelock);
        adminContract.grantRole(adminContract.ROLE_TIMELOCK(), timelock);

        // deploy and activate a default resolution module so createEscrow can succeed
        DefaultResolutionModule rm = new DefaultResolutionModule(address(this), address(0x2));
        vm.prank(timelock);
        adminContract.queueResolutionModule(address(vault), address(rm));
        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(timelock);
        adminContract.activateResolutionModule(address(vault));
    }

    function test_snapshot_emitted_on_createEscrow() public {
        ERC20Mock token = new ERC20Mock('TKN', 'TKN', deployer, 1e24);
        address sender = address(0x5);
        address recipient = address(0x6); // Different from sender
        token.transfer(sender, 1e20);
        vm.prank(sender);
        token.approve(address(vault), 1e20);

        // create escrow
        EscrowSettings memory settings = EscrowSettings({
            customResolver: address(0),
            yieldPreset: YieldPreset.OFF,
            autoReleaseTime: 0,
            autoCancelTime: 0
        });
        vm.prank(sender);
        uint256 workflowId = vault.createEscrow(address(token), recipient, 1e20, settings);
        assertEq(workflowId, 0);
    }

}
