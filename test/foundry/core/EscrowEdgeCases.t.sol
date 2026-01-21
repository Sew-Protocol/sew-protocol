// SPDX-License-Identifier: Apache-2.0
import "../../../contracts/types/YieldPresets.sol";
pragma solidity ^0.8.33;

import 'forge-std/Test.sol';
import '../../../contracts/core/EscrowVault.sol';
import '../../../contracts/mocks/ERC20Mock.sol';
import '../../../contracts/mocks/MockFeeOnTransfer.sol';
import '../../../contracts/core/modules/DefaultResolutionModule.sol';
import '../../../contracts/types/EscrowTypes.sol';
import '../../../contracts/YieldOps.sol';
import '../../../contracts/DisputeOps.sol';
import '../../../contracts/SettlementOps.sol';
import '../../../contracts/CreateOps.sol';
import '../../../contracts/core/BondCollector.sol';
import '../../../contracts/core/ModuleManagementContract.sol';
import '../../../contracts/admin/EscrowAdminContract.sol';
import '../../../contracts/libraries/SettingsValidationLibrary.sol';

/**
 * @title EscrowEdgeCasesTest
 * @notice Tests for edge cases including Fee-on-Transfer tokens and large amounts
 */
contract EscrowEdgeCasesTest is Test {
    EscrowVault public vault;
    ERC20Mock public token;
    MockFeeOnTransfer public feeToken;
    DefaultResolutionModule public resolutionModule;
    YieldOps public yieldOps;
    DisputeOps public disputeOps;
    SettlementOps public settlementOps;
    CreateOps public createOps;
    BondCollector public bondCollector;
    ModuleManagementContract public moduleManagement;
    EscrowAdminContract public adminContract;

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
        token = new ERC20Mock('Token', 'TKN', owner, 10000000e18);
        // Fee token with 1% fee (100 bps)
        feeToken = new MockFeeOnTransfer('FeeToken', 'FEE', owner, 10000000e18, 100, address(0xdead));
        
        yieldOps = new YieldOps(address(this));
        disputeOps = new DisputeOps(address(this));
        settlementOps = new SettlementOps(address(this));
        createOps = new CreateOps(address(this));
        bondCollector = new BondCollector(address(this));
        moduleManagement = new ModuleManagementContract(address(this));
        adminContract = new EscrowAdminContract(address(this));
        vault = new EscrowVault(ESCROW_FEE, feeAddress, address(yieldOps), address(disputeOps), address(moduleManagement));
        moduleManagement.registerEscrowContract(address(vault));

        // Register escrow contract callers on ops contracts
        yieldOps.registerEscrowContract(address(vault));
        disputeOps.registerEscrowContract(address(vault));
        settlementOps.registerEscrowContract(address(vault));
        createOps.registerEscrowContract(address(vault));
        bondCollector.registerEscrowContract(address(vault));

        // Setup vault
        vault.grantRole(vault.ROLE_TIMELOCK(), owner);
        vault.grantRole(vault.ROLE_TIMELOCK(), timelock);

        // Allow this test contract to wire ops on the vault
        vault.grantRole(vault.ROLE_ADMIN_CONTRACT(), owner);
        vault.grantRole(vault.ROLE_ADMIN_CONTRACT(), address(adminContract));
        vault.setCreateOps(address(createOps));
        vault.setSettlementOps(address(settlementOps));
        vault.setBondCollector(address(bondCollector));
        adminContract.grantRole(adminContract.ROLE_TIMELOCK(), owner);
        adminContract.grantRole(adminContract.ROLE_TIMELOCK(), timelock);

        // Queue and activate resolution module
        adminContract.queueResolutionModule(address(vault), address(resolutionModule));
        vm.warp(block.timestamp + 7 days + 1);
        adminContract.activateResolutionModule(address(vault));
    }

    // ============ Fee-on-Transfer Tests ============

    function test_createEscrow_FeeOnTransfer_Insolvency() public {
        uint256 amount = 1000e18;
        // Mint to buyer
        feeToken.transfer(buyer, amount * 2); // Give extra

        vm.startPrank(buyer);
        feeToken.approve(address(vault), amount);
        
        // Policy: Fee-on-transfer / deflationary tokens are rejected at creation time,
        // because they create an accounting deficit (recorded > actual).
        vm.expectRevert(abi.encodeWithSelector(AccountingDeficit.selector, address(feeToken), 10e18));
        vault.createEscrow(address(feeToken), seller, amount, SettingsValidationLibrary.getDefaultSettings());
        vm.stopPrank();
    }

    // ============ Large Amount Tests ============

    function test_createEscrow_MaxAmount_Overflow() public {
        // ESCROW_FEE is 100 (1%), ESCROW_FEE_DENOMINATOR is 10000
        // Fee calculation: fee = (amount * 100) / 10000
        // For overflow: amount * 100 > type(uint256).max
        // So: amount > type(uint256).max / 100
        // Use an amount that will definitely cause overflow
        uint256 unsafeAmount = (type(uint256).max / 100) + 1;
        
        token.mint(buyer, unsafeAmount);
        vm.startPrank(buyer);
        token.approve(address(vault), unsafeAmount);
        
        // Should revert due to arithmetic overflow when calculating fee
        vm.expectRevert(); // Arithmetic overflow/panic
        vault.createEscrow(address(token), seller, unsafeAmount, SettingsValidationLibrary.getDefaultSettings());
        vm.stopPrank();
    }

    function test_createEscrow_MaxSafeAmount() public {
        uint256 maxSafeAmount = type(uint256).max / 100;
        
        token.mint(buyer, maxSafeAmount);
        vm.startPrank(buyer);
        token.approve(address(vault), maxSafeAmount);
        
        uint256 escrowId = vault.createEscrow(address(token), seller, maxSafeAmount, SettingsValidationLibrary.getDefaultSettings());
        
        uint256 fee = (maxSafeAmount * 100) / 10000;
        uint256 expectedAmountAfterFee = maxSafeAmount - fee;
        
        (, , , , uint256 amountAfterFee, , , , , ) = vault.escrowTransfers(escrowId);
        assertEq(amountAfterFee, expectedAmountAfterFee);
        vm.stopPrank();
    }
}
