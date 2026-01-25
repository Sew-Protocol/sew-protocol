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

contract EscrowLifecycleTest is Test {
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

    function test_PauseUnpause_AccessControl() public {
        vm.prank(guardian);
        vault.pause();
        assertTrue(vault.paused());

        vm.prank(guardian);
        vm.expectRevert(); // Only ROLE_TIMELOCK can unpause
        vault.unpause();

        vm.prank(timelock);
        vault.unpause();
        assertFalse(vault.paused());
    }

    function test_AdminSetters_AccessControl() public {
        // Only ROLE_ADMIN_CONTRACT
        vm.prank(unauthorized);
        vm.expectRevert();
        vault.setFeeRecipient(address(0x123));

        vm.prank(owner); // Has ROLE_ADMIN_CONTRACT
        vault.setFeeRecipient(address(0x123));
        assertEq(vault.escrowFeeAddress(), address(0x123));
    }

    function test_createEscrow_FeeOnTransfer_Deficit() public {
        // Create a token that takes a fee on transfer
        FeeOnTransferToken fotToken = new FeeOnTransferToken("FOT", "FOT", owner, 1000e18);
        fotToken.transfer(buyer, 1000e18);
        
        vm.startPrank(buyer);
        fotToken.approve(address(vault), 1000e18);
        
        // Should revert with AccountingDeficit
        vm.expectRevert();
        vault.createEscrow(address(fotToken), seller, 1000e18, SettingsValidationLibrary.getDefaultSettings());
        vm.stopPrank();
    }

    function test_Cancel_DoubleAgreement() public {
        uint256 amount = 1000e18;
        token.mint(buyer, amount);
        vm.startPrank(buyer);
        token.approve(address(vault), amount);
        uint256 wid = vault.createEscrow(address(token), seller, amount, SettingsValidationLibrary.getDefaultSettings());
        
        vault.senderCancel(wid);
        vm.stopPrank();

        vm.prank(seller);
        vault.recipientCancel(wid);

        // Use EscrowViewContract to check status
        EscrowViewContract viewContract = new EscrowViewContract(address(vault));
        (EscrowState state, , ) = viewContract.getEscrowStatusInfo(wid);
        assertEq(uint8(state), uint8(EscrowState.REFUNDED));
    }
}

contract FeeOnTransferToken is ERC20Mock {
    constructor(string memory n, string memory s, address o, uint256 i) ERC20Mock(n, s, o, i) {}
    function transfer(address to, uint256 amount) public override returns (bool) {
        return super.transfer(to, amount - 1); // Take 1 wei fee
    }
    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        return super.transferFrom(from, to, amount - 1); // Take 1 wei fee
    }
}
