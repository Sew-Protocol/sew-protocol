// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import 'forge-std/Test.sol';
import '../../../contracts/core/EscrowVault.sol';
import '../../../contracts/mocks/ERC20Mock.sol';
import '../../../contracts/ops/YieldOps.sol';
import '../../../contracts/ops/DisputeOps.sol';
import '../../../contracts/core/modules/DefaultResolutionModule.sol';
import '../../../contracts/core/ModuleSnapshotRegistry.sol';
import '../../../contracts/libraries/SettingsValidationLibrary.sol';
import '../../../contracts/ops/CreateOps.sol';
import '../../../contracts/ops/SettlementOps.sol';
import '../../../contracts/core/BondCollector.sol';
import '../../../contracts/mocks/MockRevertingERC20.sol';
import '../../../contracts/types/EscrowTypes.sol';

/**
 * @title EscrowVaultAccountingTest
 * @notice Comprehensive accounting tests for EscrowVault.
 */
contract EscrowVaultAccountingTest is Test {
    EscrowVault public vault;
    YieldOps public yieldOps;
    DisputeOps public disputeOps;
    ModuleSnapshotRegistry public mm;
    CreateOps public createOps;
    SettlementOps public settlementOps;
    BondCollector public bondCollector;
    DefaultResolutionModule public resolutionModule;
    
    ERC20Mock public tokenA;
    ERC20Mock public tokenB;
    MockRevertingERC20 public revertingToken;

    address public feeAddress = address(0xFEE);
    address public buyer = address(0x1001);
    address public seller = address(0x1002);
    address public resolver = address(0x1234);

    uint256 constant FEE_BPS = 100; // 1%

    function setUp() public {
        tokenA = new ERC20Mock("Token A", "TKNA", address(this), 1000000e18);
        tokenB = new ERC20Mock("Token B", "TKNB", address(this), 1000000e18);
        revertingToken = new MockRevertingERC20("Reverting", "REVERT", address(this), 1000000e18);

        yieldOps = new YieldOps(address(this));
        disputeOps = new DisputeOps(address(this));
        mm = new ModuleSnapshotRegistry(address(this));
        createOps = new CreateOps(address(this));
        settlementOps = new SettlementOps(address(this));
        bondCollector = new BondCollector(address(this));
        resolutionModule = new DefaultResolutionModule(address(this), resolver);

        vault = new EscrowVault(FEE_BPS, feeAddress, address(yieldOps), address(disputeOps), address(mm));

        yieldOps.registerEscrowContract(address(vault));
        disputeOps.registerEscrowContract(address(vault));
        mm.registerEscrowContract(address(vault));
        createOps.registerEscrowContract(address(vault));
        settlementOps.registerEscrowContract(address(vault));
        bondCollector.registerEscrowContract(address(vault));

        vault.grantRole(vault.ROLE_ADMIN_CONTRACT(), address(this));
        vault.setCreateOps(address(createOps));
        vault.setSettlementOps(address(settlementOps));
        vault.setBondCollector(address(bondCollector));
        vault.setResolutionModule(address(resolutionModule));

        tokenA.transfer(buyer, 100000e18);
        tokenB.transfer(buyer, 100000e18);
        revertingToken.transfer(buyer, 100000e18);
    }

    // ============ Multi-Token Isolation ============

    function test_accounting_isolation_different_tokens() public {
        uint256 amountA = 1000e18;
        uint256 amountB = 2000e18;

        vm.startPrank(buyer);
        tokenA.approve(address(vault), amountA);
        tokenB.approve(address(vault), amountB);

        vault.createEscrow(address(tokenA), seller, amountA, SettingsValidationLibrary.getDefaultSettings());
        vault.createEscrow(address(tokenB), seller, amountB, SettingsValidationLibrary.getDefaultSettings());
        vm.stopPrank();

        (uint256 principalA, uint256 feesA, , ) = vault.getAccountingBreakdown(address(tokenA));
        (uint256 principalB, uint256 feesB, , ) = vault.getAccountingBreakdown(address(tokenB));

        assertEq(principalA, amountA - (amountA * FEE_BPS / 10000));
        assertEq(feesA, amountA * FEE_BPS / 10000);
        assertEq(principalB, amountB - (amountB * FEE_BPS / 10000));
        assertEq(feesB, amountB * FEE_BPS / 10000);
    }

    // ============ Release/Refund Accounting ============

    function test_accounting_after_release() public {
        uint256 amount = 1000e18;
        uint256 expectedFee = amount * FEE_BPS / 10000;
        uint256 expectedPrincipal = amount - expectedFee;

        vm.startPrank(buyer);
        tokenA.approve(address(vault), amount);
        uint256 wid = vault.createEscrow(address(tokenA), seller, amount, SettingsValidationLibrary.getDefaultSettings());
        vault.release(wid);
        vm.stopPrank();

        (uint256 principal, uint256 fees, uint256 bal, ) = vault.getAccountingBreakdown(address(tokenA));
        assertEq(principal, 0, "Principal should be 0 after release");
        assertEq(fees, expectedFee, "Fees should still be tracked");
        assertEq(bal, amount, "Vault balance should retain principal+fees until withdrawEscrow");
        assertEq(tokenA.balanceOf(seller), 0, "Seller should not be paid during settlement");
        assertEq(vault.claimableBalances(wid, seller), expectedPrincipal, "Seller should have claimable principal");
    }

    function test_accounting_after_refund() public {
        uint256 amount = 1000e18;
        uint256 expectedFee = amount * FEE_BPS / 10000;
        uint256 expectedPrincipal = amount - expectedFee;

        vm.startPrank(buyer);
        tokenA.approve(address(vault), amount);
        uint256 wid = vault.createEscrow(address(tokenA), seller, amount, SettingsValidationLibrary.getDefaultSettings());
        vm.stopPrank();

        vm.prank(seller);
        vault.recipientCancel(wid);
        vm.prank(buyer);
        vault.senderCancel(wid);

        (uint256 principal, uint256 fees, uint256 bal, ) = vault.getAccountingBreakdown(address(tokenA));
        assertEq(principal, 0, "Principal should be 0 after refund");
        assertEq(fees, expectedFee, "Fees should still be tracked");
        assertEq(bal, amount, "Vault balance should retain principal+fees until withdrawEscrow");
        assertEq(tokenA.balanceOf(buyer), 100000e18 - amount);
        assertEq(vault.claimableBalances(wid, buyer), expectedPrincipal, "Buyer should have claimable refund");
    }

    // ============ Claimable Balances ============

    function test_accounting_with_claimable_balances() public {
        uint256 amount = 1000e18;
        uint256 expectedFee = amount * FEE_BPS / 10000;
        uint256 expectedPrincipal = amount - expectedFee;

        vm.startPrank(buyer);
        revertingToken.approve(address(vault), amount);
        uint256 wid = vault.createEscrow(address(revertingToken), seller, amount, SettingsValidationLibrary.getDefaultSettings());
        
        revertingToken.setShouldRevert(true);
        
        vault.release(wid);
        vm.stopPrank();

        (uint256 principal, uint256 fees, uint256 bal, ) = vault.getAccountingBreakdown(address(revertingToken));
        assertEq(principal, 0, "Principal should be 0 after release attempt");
        assertEq(fees, expectedFee);
        assertEq(bal, amount, "Vault balance should still have all tokens because transfer failed");
        
        assertEq(vault.claimableBalances(wid, seller), expectedPrincipal, "Principal should be in claimableBalances");

        revertingToken.setShouldRevert(false);
        vm.prank(seller);
        vault.withdrawEscrow(wid);

        assertEq(revertingToken.balanceOf(seller), expectedPrincipal);
        (,,, uint256 yield) = vault.getAccountingBreakdown(address(revertingToken));
        assertEq(yield, 0);
    }

    // ============ Fee Withdrawal ============

    function test_partial_fee_withdrawal() public {
        uint256 amount = 1000e18;
        uint256 expectedFee = amount * FEE_BPS / 10000;

        vm.startPrank(buyer);
        tokenA.approve(address(vault), amount);
        vault.createEscrow(address(tokenA), seller, amount, SettingsValidationLibrary.getDefaultSettings());
        vm.stopPrank();

        vault.grantRole(vault.ROLE_FEE_RECIPIENT(), address(this));
        
        vault.withdrawFees(address(tokenA));
        
        assertEq(tokenA.balanceOf(feeAddress), expectedFee);
        assertEq(vault.totalFeesPerToken(address(tokenA)), 0);
    }

    // ============ Recovery Accounting ============

    function test_recovery_accounting() public {
        // SKIPPED: recoverERC20 method does not exist in EscrowVault contract
        vm.skip(true);
    }

    function test_zero_amount_escrow() public {
        vm.startPrank(buyer);
        tokenA.approve(address(vault), 0);
        
        vm.expectRevert(AmountZero.selector); 
        vault.createEscrow(address(tokenA), seller, 0, SettingsValidationLibrary.getDefaultSettings());
        vm.stopPrank();
    }

    function test_massive_amount_accounting() public {
        uint256 amount = 1e30; 
        tokenA.mint(buyer, amount);

        vm.startPrank(buyer);
        tokenA.approve(address(vault), amount);
        vault.createEscrow(address(tokenA), seller, amount, SettingsValidationLibrary.getDefaultSettings());
        vm.stopPrank();

        uint256 expectedFee = amount * FEE_BPS / 10000;
        uint256 expectedPrincipal = amount - expectedFee;

        (uint256 principal, uint256 fees, uint256 bal, ) = vault.getAccountingBreakdown(address(tokenA));
        assertEq(principal, expectedPrincipal);
        assertEq(fees, expectedFee);
        assertEq(bal, amount);
    }
}
