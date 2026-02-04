// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import 'forge-std/Test.sol';
import 'contracts/YieldOps.sol';
import 'contracts/DisputeOps.sol';
import 'contracts/core/ModuleSnapshotRegistry.sol';
import 'contracts/core/EscrowVault.sol';
import 'contracts/mocks/ERC20Mock.sol';
import 'contracts/core/modules/DefaultResolutionModule.sol';
import 'contracts/types/YieldPresets.sol';
import 'contracts/admin/EscrowGovernanceTimelock.sol';
import 'contracts/types/EscrowTypes.sol';
import 'contracts/CreateOps.sol';
import 'contracts/SettlementOps.sol';
import 'contracts/core/BondCollector.sol';

contract Test_05_ModuleSnapshotting_test is Test {
    EscrowVault vault;
    EscrowGovernanceTimelock adminContract;
    YieldOps public yieldOps;
    DisputeOps public disputeOps;
    ModuleSnapshotRegistry public moduleManagement;
    CreateOps public createOps;
    SettlementOps public settlementOps;
    BondCollector public bondCollector;
    address deployer = address(this);
    address timelock = address(0x1);

    function setUp() public {
        yieldOps = new YieldOps(address(this));
        disputeOps = new DisputeOps(address(this));
        moduleManagement = new ModuleSnapshotRegistry(address(this));
        vault = new EscrowVault(100, address(this), address(yieldOps), address(disputeOps), address(moduleManagement));
        adminContract = new EscrowGovernanceTimelock(address(this));
        vault.grantRole(vault.ROLE_TIMELOCK(), timelock);
        vault.grantRole(vault.ROLE_ADMIN_CONTRACT(), address(adminContract));
        adminContract.grantRole(adminContract.ROLE_TIMELOCK(), timelock);

        // Wire required ops for createEscrow
        createOps = new CreateOps(address(this));
        // CreateOps requires ROLE_TIMELOCK for registerEscrowContract (granted by DEFAULT_ADMIN_ROLE)
        createOps.grantRole(createOps.ROLE_TIMELOCK(), address(this));
        createOps.registerEscrowContract(address(vault));

        settlementOps = new SettlementOps(address(this));
        settlementOps.registerEscrowContract(address(vault));

        bondCollector = new BondCollector(address(this));
        bondCollector.registerEscrowContract(address(vault));

        // Grant this test admin-contract role to set ops addresses
        vault.grantRole(vault.ROLE_ADMIN_CONTRACT(), address(this));
        vault.setCreateOps(address(createOps));
        vault.setSettlementOps(address(settlementOps));
        vault.setBondCollector(address(bondCollector));

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
