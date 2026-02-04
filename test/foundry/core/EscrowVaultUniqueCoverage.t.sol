// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import 'forge-std/Test.sol';
import '../../../contracts/core/EscrowVault.sol';
import '../../../contracts/mocks/ERC20Mock.sol';
import '../../../contracts/core/modules/DefaultResolutionModule.sol';
import '../../../contracts/types/EscrowTypes.sol';
import '../../../contracts/types/YieldPresets.sol';
import '../../../contracts/YieldOps.sol';
import '../../../contracts/DisputeOps.sol';
import '../../../contracts/SettlementOps.sol';
import '../../../contracts/CreateOps.sol';
import '../../../contracts/core/BondCollector.sol';
import '../../../contracts/core/ModuleSnapshotRegistry.sol';
import '../../../contracts/admin/EscrowGovernanceTimelock.sol';
import '../../../contracts/libraries/SettingsValidationLibrary.sol';

/**
 * @title EscrowVaultUniqueCoverage
 * @notice Tests for EscrowVault features not covered elsewhere
 * @dev Focuses on unique test cases extracted from EscrowVaultComprehensive
 */
contract EscrowVaultUniqueCoverageTest is Test {
    EscrowVault public vault;
    ERC20Mock public token1;
    ERC20Mock public token2;
    DefaultResolutionModule public resolutionModule;
    YieldOps public yieldOps;
    DisputeOps public disputeOps;
    SettlementOps public settlementOps;
    CreateOps public createOps;
    BondCollector public bondCollector;
    ModuleSnapshotRegistry public moduleManagement;
    EscrowGovernanceTimelock public adminContract;

    address public owner;
    address public timelock;
    address public feeAddress;
    address public resolver;
    address public buyer;
    address public seller;

    uint256 public constant ESCROW_FEE = 100; // 1%

    function setUp() public {
        owner = address(this);
        timelock = address(0x1111);
        feeAddress = address(0xFEE);
        resolver = address(0x1234);
        buyer = address(0x1001);
        seller = address(0x1002);

        resolutionModule = new DefaultResolutionModule(owner, resolver);
        token1 = new ERC20Mock('Token 1', 'TKN1', owner, 10000000e18);
        token2 = new ERC20Mock('Token 2', 'TKN2', owner, 10000000e18);
        yieldOps = new YieldOps(address(this));
        disputeOps = new DisputeOps(address(this));
        settlementOps = new SettlementOps(address(this));
        createOps = new CreateOps(address(this));
        bondCollector = new BondCollector(address(this));
        moduleManagement = new ModuleSnapshotRegistry(address(this));
        adminContract = new EscrowGovernanceTimelock(address(this));
        vault = new EscrowVault(ESCROW_FEE, feeAddress, address(yieldOps), address(disputeOps), address(moduleManagement));
        moduleManagement.registerEscrowContract(address(vault));

        // Register escrow contract with all ops contracts
        yieldOps.registerEscrowContract(address(vault));
        disputeOps.registerEscrowContract(address(vault));
        settlementOps.registerEscrowContract(address(vault));
        createOps.registerEscrowContract(address(vault));
        bondCollector.registerEscrowContract(address(vault));

        // Setup vault
        vault.grantRole(vault.ROLE_TIMELOCK(), owner);
        vault.grantRole(vault.ROLE_TIMELOCK(), timelock);
        adminContract.grantRole(adminContract.ROLE_TIMELOCK(), owner);
        adminContract.grantRole(adminContract.ROLE_TIMELOCK(), timelock);

        // Wire ops contracts on the vault
        vault.grantRole(vault.ROLE_ADMIN_CONTRACT(), owner);
        vault.grantRole(vault.ROLE_ADMIN_CONTRACT(), address(adminContract));
        vault.setCreateOps(address(createOps));
        vault.setSettlementOps(address(settlementOps));
        vault.setBondCollector(address(bondCollector));

        // Queue and activate resolution module
        adminContract.queueResolutionModule(address(vault), address(resolutionModule));
        vm.warp(block.timestamp + 7 days + 1);
        adminContract.activateResolutionModule(address(vault));
    }

    // ============ Escrow Creation Tests ============

    function test_createEscrow_simple() public {
        uint256 amount = 1000e18;
        token1.mint(buyer, amount);
        vm.prank(buyer);
        token1.approve(address(vault), amount);
        EscrowSettings memory settings = SettingsValidationLibrary.getDefaultSettings();
        vm.prank(buyer);
        uint256 workflowId = vault.createEscrow(address(token1), seller, amount, settings);
        assertEq(workflowId, 0);
    }

    function test_createEscrow_withSettings() public {
        uint256 amount = 1000e18;
        token1.mint(buyer, amount);
        vm.prank(buyer);
        token1.approve(address(vault), amount);

        EscrowSettings memory settings = EscrowSettings({
            customResolver: address(0),
            yieldPreset: YieldPreset.OFF,
            autoReleaseTime: 0,
            autoCancelTime: 0
        });
        vm.prank(buyer);
        uint256 workflowId = vault.createEscrow(address(token1), seller, amount, settings);
        assertEq(workflowId, 0);
    }

}
