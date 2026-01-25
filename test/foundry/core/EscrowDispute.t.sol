// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import "forge-std/Test.sol";
import "../../../contracts/core/EscrowVault.sol";
import "../../../contracts/core/EscrowViewContract.sol";
import "../../../contracts/mocks/ERC20Mock.sol";
import "../../../contracts/core/modules/DefaultResolutionModule.sol";
import "../../../contracts/types/EscrowTypes.sol";
import "../../../contracts/types/YieldPresets.sol";
import "../../../contracts/YieldOps.sol";
import "../../../contracts/DisputeOps.sol";
import "../../../contracts/SettlementOps.sol";
import "../../../contracts/CreateOps.sol";
import "../../../contracts/core/BondCollector.sol";
import "../../../contracts/core/ModuleManagementContract.sol";
import "../../../contracts/libraries/SettingsValidationLibrary.sol";

contract EscrowDisputeTest is Test {
    EscrowVault public vault;
    ERC20Mock public token;
    DefaultResolutionModule public resolutionModule;
    YieldOps public yieldOps;
    DisputeOps public disputeOps;
    SettlementOps public settlementOps;
    CreateOps public createOps;
    BondCollector public bondCollector;
    ModuleManagementContract public moduleManagement;

    address public owner;
    address public timelock;
    address public guardian;
    address public feeAddress = address(0xFEE);
    address public resolver = address(0x1234);
    address public buyer = address(0x1001);
    address public seller = address(0x1002);
    address public unauthorized = address(0x9999);

    function setUp() public {
        owner = address(this);
        timelock = address(0x1);
        guardian = address(0x2);
        
        token = new ERC20Mock("Test", "TEST", owner, 10000e18);
        yieldOps = new YieldOps(owner);
        disputeOps = new DisputeOps(owner);
        moduleManagement = new ModuleManagementContract(owner);
        createOps = new CreateOps(owner);
        settlementOps = new SettlementOps(owner);
        bondCollector = new BondCollector(owner);
        resolutionModule = new DefaultResolutionModule(owner, resolver);

        vault = new EscrowVault(100, feeAddress, address(yieldOps), address(disputeOps), address(moduleManagement));
        
        yieldOps.registerEscrowContract(address(vault));
        disputeOps.registerEscrowContract(address(vault));
        moduleManagement.registerEscrowContract(address(vault));
        createOps.registerEscrowContract(address(vault));
        settlementOps.registerEscrowContract(address(vault));
        bondCollector.registerEscrowContract(address(vault));

        vault.grantRole(vault.ROLE_TIMELOCK(), timelock);
        vault.grantRole(vault.ROLE_GUARDIAN(), guardian);
        vault.grantRole(vault.ROLE_ADMIN_CONTRACT(), owner);
        
        vault.setCreateOps(address(createOps));
        vault.setSettlementOps(address(settlementOps));
        vault.setBondCollector(address(bondCollector));
        vault.setResolutionModule(address(resolutionModule));
    }

    function test_raiseDispute_NonParticipant() public {
        uint256 amount = 1000e18;
        token.mint(buyer, amount);
        vm.startPrank(buyer);
        token.approve(address(vault), amount);
        uint256 wid = vault.createEscrow(address(token), seller, amount, SettingsValidationLibrary.getDefaultSettings());
        vm.stopPrank();

        vm.prank(unauthorized);
        vm.expectRevert(); // NotParticipant
        vault.raiseDispute(wid);
    }

    function test_escalateDispute_NotAllowed() public {
        uint256 amount = 1000e18;
        token.mint(buyer, amount);
        vm.startPrank(buyer);
        token.approve(address(vault), amount);
        uint256 wid = vault.createEscrow(address(token), seller, amount, SettingsValidationLibrary.getDefaultSettings());
        
        vault.raiseDispute(wid);
        vm.stopPrank();

        // DefaultResolutionModule does not allow escalation
        vm.prank(buyer);
        vm.expectRevert(); // EscalationNotAllowed
        vault.escalateDispute(wid);
    }
}
