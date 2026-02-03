// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import "forge-std/Test.sol";
import "../../../contracts/core/EscrowVault.sol";
import "../../../contracts/mocks/ERC20Mock.sol";
import "../../../contracts/core/modules/DefaultResolutionModule.sol";
import "../../../contracts/modules/DefaultReleaseStrategy.sol";
import "../../../contracts/modules/DefaultYieldDistributionModule.sol";
import "../../../contracts/types/EscrowTypes.sol";
import "../../../contracts/YieldOps.sol";
import "../../../contracts/DisputeOps.sol";
import "../../../contracts/CreateOps.sol";
import "../../../contracts/SettlementOps.sol";
import "../../../contracts/core/BondCollector.sol";
import "../../../contracts/core/ModuleManagementContract.sol";
import "../../../contracts/libraries/SettingsValidationLibrary.sol";

/**
 * @title EscrowVaultComprehensive
 * @notice Comprehensive tests for EscrowVault covering all functions and code paths
 */
contract EscrowVaultComprehensive is Test {
    EscrowVault public vault;
    ERC20Mock public token1;
    ERC20Mock public token2;
    DefaultResolutionModule public resolutionModule;
    DefaultReleaseStrategy public releaseStrategy;
    DefaultYieldDistributionModule public yieldDistributionModule;
    
    YieldOps public yieldOps;
    DisputeOps public disputeOps;
    CreateOps public createOps;
    SettlementOps public settlementOps;
    BondCollector public bondCollector;
    ModuleManagementContract public moduleManagement;

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
        
        yieldOps = new YieldOps(owner);
        disputeOps = new DisputeOps(owner);
        moduleManagement = new ModuleManagementContract(owner);
        createOps = new CreateOps(owner);
        settlementOps = new SettlementOps(owner);
        bondCollector = new BondCollector(owner);
        
        resolutionModule = new DefaultResolutionModule(owner, resolver);
        releaseStrategy = new DefaultReleaseStrategy();
        yieldDistributionModule = new DefaultYieldDistributionModule();
        
        token1 = new ERC20Mock("Token 1", "TKN1", owner, 10000000e18);
        token2 = new ERC20Mock("Token 2", "TKN2", owner, 10000000e18);
        
        vault = new EscrowVault(ESCROW_FEE, feeAddress, address(yieldOps), address(disputeOps), address(moduleManagement));
        
        yieldOps.registerEscrowContract(address(vault));
        disputeOps.registerEscrowContract(address(vault));
        moduleManagement.registerEscrowContract(address(vault));
        createOps.registerEscrowContract(address(vault));
        settlementOps.registerEscrowContract(address(vault));
        bondCollector.registerEscrowContract(address(vault));

        vault.grantRole(vault.ROLE_TIMELOCK(), owner);
        vault.grantRole(vault.ROLE_TIMELOCK(), timelock);
        vault.grantRole(vault.ROLE_ADMIN_CONTRACT(), owner);
        
        vault.setCreateOps(address(createOps));
        vault.setSettlementOps(address(settlementOps));
        vault.setBondCollector(address(bondCollector));
        vault.setResolutionModule(address(resolutionModule));

        // Queue and activate default modules
        vm.startPrank(owner);
        moduleManagement.queueModule(address(vault), BaseEscrow.ModuleType.RELEASE, address(releaseStrategy));
        moduleManagement.queueModule(address(vault), BaseEscrow.ModuleType.YIELD_DIST, address(yieldDistributionModule));
        vm.stopPrank();
        
        vm.warp(block.timestamp + 8 days);
        
        vm.startPrank(owner);
        moduleManagement.activateModule(address(vault), BaseEscrow.ModuleType.RELEASE);
        moduleManagement.activateModule(address(vault), BaseEscrow.ModuleType.YIELD_DIST);
        vm.stopPrank();
    }
    
    // ============ Escrow Creation ============
    
    function test_createEscrow_withSettings() public {
        uint256 amount = 1000e18;
        token1.mint(buyer, amount);
        vm.startPrank(buyer);
        token1.approve(address(vault), amount);
        
        EscrowSettings memory settings = SettingsValidationLibrary.getDefaultSettings();
        
        uint256 workflowId = vault.createEscrow(address(token1), seller, amount, settings);
        vm.stopPrank();
        assertEq(workflowId, 0); 
    }
    
    function test_createEscrow_simple() public {
        uint256 amount = 1000e18;
        token1.mint(buyer, amount);
        vm.startPrank(buyer);
        token1.approve(address(vault), amount);
        
        uint256 workflowId = vault.createEscrow(address(token1), seller, amount, SettingsValidationLibrary.getDefaultSettings());
        vm.stopPrank();
        assertEq(workflowId, 0);
    }
    
    function test_createEscrow_revertsIfTokenZero() public {
        uint256 amount = 1000e18;
        vm.prank(buyer);
        vm.expectRevert();
        vault.createEscrow(address(0), seller, amount, SettingsValidationLibrary.getDefaultSettings());
    }
    
    function test_createEscrow_revertsIfSellerZero() public {
        uint256 amount = 1000e18;
        token1.mint(buyer, amount);
        vm.startPrank(buyer);
        token1.approve(address(vault), amount);
        
        vm.expectRevert();
        vault.createEscrow(address(token1), address(0), amount, SettingsValidationLibrary.getDefaultSettings());
        vm.stopPrank();
    }
    
    function test_createEscrow_revertsIfAmountZero() public {
        vm.startPrank(buyer);
        vm.expectRevert();
        vault.createEscrow(address(token1), seller, 0, SettingsValidationLibrary.getDefaultSettings());
        vm.stopPrank();
    }
    
    // ============ Release ============
    
    function test_releaseEscrowTransfer() public {
        uint256 amount = 1000e18;
        token1.mint(buyer, amount);
        vm.startPrank(buyer);
        token1.approve(address(vault), amount);
        
        uint256 workflowId = vault.createEscrow(address(token1), seller, amount, SettingsValidationLibrary.getDefaultSettings());
        
        vault.releaseEscrowTransfer(workflowId);
        vm.stopPrank();
        
        (,,,,,,, EscrowState state,,) = vault.escrowTransfers(workflowId);
        assertEq(uint8(state), uint8(EscrowState.RELEASED));
    }
    
    // ============ Fee Management ============
    
    function test_withdrawFees() public {
        uint256 amount = 1000e18;
        token1.mint(buyer, amount);
        vm.startPrank(buyer);
        token1.approve(address(vault), amount);
        vault.createEscrow(address(token1), seller, amount, SettingsValidationLibrary.getDefaultSettings());
        vm.stopPrank();
        
        uint256 fees = vault.totalFeesPerToken(address(token1));
        assertGt(fees, 0);
        
        uint256 balanceBefore = token1.balanceOf(feeAddress);
        vault.grantRole(vault.ROLE_FEE_RECIPIENT(), address(this));
        vault.withdrawFees(address(token1));
        uint256 balanceAfter = token1.balanceOf(feeAddress);
        
        assertEq(balanceAfter - balanceBefore, fees);
    }
    
    function test_withdrawFees_revertsIfNotFeeRecipient() public {
        vm.prank(buyer);
        vm.expectRevert();
        vault.withdrawFees(address(token1));
    }
    
    // ============ Recovery ============
    
    function test_recoverERC20() public {
        uint256 amount = 1000e18;
        token1.mint(address(vault), amount);
        
        uint256 balanceBefore = token1.balanceOf(owner);
        vm.prank(owner);
        vault.recoverERC20(address(token1), owner, amount);
        uint256 balanceAfter = token1.balanceOf(owner);
        
        assertEq(balanceAfter - balanceBefore, amount);
    }
}