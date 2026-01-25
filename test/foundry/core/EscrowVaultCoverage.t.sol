// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import "forge-std/Test.sol";
import "../../../contracts/core/EscrowVault.sol";
import "../../../contracts/mocks/ERC20Mock.sol";
import "../../../contracts/core/modules/DefaultResolutionModule.sol";
import "../../../contracts/types/EscrowTypes.sol";
import "../../../contracts/types/YieldPresets.sol";
import "../../../contracts/YieldOps.sol";
import "../../../contracts/DisputeOps.sol";
import "../../../contracts/CreateOps.sol";
import "../../../contracts/SettlementOps.sol";
import "../../../contracts/core/BondCollector.sol";
import "../../../contracts/core/ModuleManagementContract.sol";
import "../../../contracts/libraries/SettingsValidationLibrary.sol";

contract EscrowVaultCoverageTest is Test {
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
    address public feeAddress = address(0xFEE);
    address public resolver = address(0x1234);
    address public buyer = address(0x1001);
    address public seller = address(0x1002);

    function setUp() public {
        owner = address(this);
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

        vault.grantRole(vault.ROLE_ADMIN_CONTRACT(), owner);
        vault.setCreateOps(address(createOps));
        vault.setSettlementOps(address(settlementOps));
        vault.setBondCollector(address(bondCollector));
        vault.setResolutionModule(address(resolutionModule));
    }

    function test_Constructor_InvalidParams() public {
        vm.expectRevert(); // InvalidEscrowFee
        new EscrowVault(201, feeAddress, address(yieldOps), address(disputeOps), address(moduleManagement));
        
        vm.expectRevert(); // ZeroAddress(1)
        new EscrowVault(100, address(0), address(yieldOps), address(disputeOps), address(moduleManagement));
        
        vm.expectRevert(); // ZeroAddress(2)
        new EscrowVault(100, feeAddress, address(0), address(disputeOps), address(moduleManagement));
    }

    function test_getAccountingBreakdown() public {
        uint256 amount = 1000e18;
        token.mint(buyer, amount);
        vm.startPrank(buyer);
        token.approve(address(vault), amount);
        uint256 wid = vault.createEscrow(address(token), seller, amount, SettingsValidationLibrary.getDefaultSettings());
        vm.stopPrank();

        (uint256 principal, uint256 fees, uint256 bal, uint256 yield) = vault.getAccountingBreakdown(address(token));
        
        uint256 expectedFee = (amount * 100) / 10000;
        assertEq(principal, amount - expectedFee);
        assertEq(fees, expectedFee);
        assertEq(bal, amount);
        assertEq(yield, 0);

        // Send some tokens directly to vault to simulate yield
        token.mint(address(vault), 100e18);
        (,,, yield) = vault.getAccountingBreakdown(address(token));
        assertEq(yield, 100e18);
    }

    function test_withdrawFees_Success() public {
        uint256 amount = 1000e18;
        token.mint(buyer, amount);
        vm.startPrank(buyer);
        token.approve(address(vault), amount);
        vault.createEscrow(address(token), seller, amount, SettingsValidationLibrary.getDefaultSettings());
        vm.stopPrank();

        uint256 feeAmount = (amount * 100) / 10000;
        
        vault.grantRole(vault.ROLE_FEE_RECIPIENT(), address(0xBEEF));
        vm.prank(address(0xBEEF));
        vault.withdrawFees(address(token));
        
        assertEq(token.balanceOf(feeAddress), feeAmount);
        assertEq(vault.totalFeesPerToken(address(token)), 0);
    }

    function test_recoverERC20_Success() public {
        token.mint(address(vault), 100e18);
        
        uint256 balBefore = token.balanceOf(owner);
        vault.recoverERC20(address(token), owner, 100e18);
        assertEq(token.balanceOf(owner) - balBefore, 100e18);
    }

    function test_recoverERC20_FailExceeds() public {
        token.mint(address(vault), 50e18);
        vm.expectRevert(); // AmountExceedsAvailable
        vault.recoverERC20(address(token), owner, 100e18);
    }

    function test_releaseEscrowTransfer_NotSender() public {
        uint256 amount = 1000e18;
        token.mint(buyer, amount);
        vm.startPrank(buyer);
        token.approve(address(vault), amount);
        uint256 wid = vault.createEscrow(address(token), seller, amount, SettingsValidationLibrary.getDefaultSettings());
        vm.stopPrank();

        vm.prank(address(0xDEAD));
        vm.expectRevert(); // NotSender
        vault.releaseEscrowTransfer(wid);
    }
}
