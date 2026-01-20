// SPDX-License-Identifier: MIT
import "../../../contracts/types/YieldPresets.sol";
pragma solidity ^0.8.33;

import 'forge-std/Test.sol';
import 'contracts/core/EscrowVault.sol';
import 'contracts/core/BaseEscrow.sol';
import 'contracts/mocks/ERC20Mock.sol';
import 'contracts/core/modules/DefaultResolutionModule.sol';
import 'contracts/types/EscrowTypes.sol';
import 'contracts/YieldOps.sol';
import 'contracts/DisputeOps.sol';
import 'contracts/SettlementOps.sol';
import 'contracts/CreateOps.sol';
import 'contracts/core/BondCollector.sol';
import 'contracts/core/ModuleManagementContract.sol';
import 'contracts/admin/EscrowAdminContract.sol';
import 'contracts/libraries/SettingsValidationLibrary.sol';

contract WithdrawEscrowTest is Test {
    EscrowVault vault;
    ERC20Mock token;
    DefaultResolutionModule rm;
    YieldOps yieldOps;
    DisputeOps disputeOps;
    SettlementOps settlementOps;
    CreateOps createOps;
    BondCollector bondCollector;
    ModuleManagementContract moduleManagement;
    EscrowAdminContract adminContract;

    address sender = address(0x10);
    address recipient = address(0x20);
    address resolver = address(0x30);
    address feeAddress = address(0x40);

    uint256 constant ESCROW_FEE = 100; // 1%
    uint256 constant AMOUNT = 10 ether;

    function setUp() public {
        yieldOps = new YieldOps(address(this));
        disputeOps = new DisputeOps(address(this));
        settlementOps = new SettlementOps(address(this));
        createOps = new CreateOps(address(this));
        bondCollector = new BondCollector(address(this));
        moduleManagement = new ModuleManagementContract(address(this));
        adminContract = new EscrowAdminContract(address(this));
        vault = new EscrowVault(ESCROW_FEE, feeAddress, address(yieldOps), address(disputeOps), address(moduleManagement));
        moduleManagement.registerEscrowContract(address(vault));

        // Register escrow contract with all ops contracts
        yieldOps.registerEscrowContract(address(vault));
        disputeOps.registerEscrowContract(address(vault));
        settlementOps.registerEscrowContract(address(vault));
        createOps.registerEscrowContract(address(vault));
        bondCollector.registerEscrowContract(address(vault));

        // Wire ops contracts on the vault
        vault.grantRole(vault.ROLE_ADMIN_CONTRACT(), address(this));
        // Allow EscrowAdminContract to apply queued changes on the vault
        vault.grantRole(vault.ROLE_ADMIN_CONTRACT(), address(adminContract));
        vault.setCreateOps(address(createOps));
        vault.setSettlementOps(address(settlementOps));
        vault.setBondCollector(address(bondCollector));

        token = new ERC20Mock('Test', 'TST', address(this), 1e24);
        rm = new DefaultResolutionModule(address(this), resolver);

        // Setup roles and modules
        vault.grantRole(vault.ROLE_TIMELOCK(), address(this));
        adminContract.grantRole(adminContract.ROLE_TIMELOCK(), address(this));
        adminContract.queueResolutionModule(address(vault), address(rm));
        vm.warp(block.timestamp + 7 days + 1);
        adminContract.activateResolutionModule(address(vault));

        // Fund sender
        token.transfer(sender, 1000 ether);
    }

    function test_withdrawEscrow_after_release() public {
        // Create escrow
        vm.prank(sender);
        token.approve(address(vault), AMOUNT);

        EscrowSettings memory settings = SettingsValidationLibrary.getDefaultSettings();
        vm.prank(sender);
        uint256 wid = vault.createEscrow(address(token), recipient, AMOUNT, settings);

        uint256 fee = (AMOUNT * ESCROW_FEE) / 10000;
        uint256 expected = AMOUNT - fee;

        // Before release, claimable should be 0
        uint256 claimableBefore = vault.claimableBalances(wid, recipient);
        assertEq(claimableBefore, 0);

        // Release - autotransfer should automatically transfer funds
        uint256 recipientBalanceBefore = token.balanceOf(recipient);
        vm.prank(sender);
        vault.releaseEscrowTransfer(wid);

        // After release, autotransfer should have transferred funds automatically
        uint256 recipientBalanceAfter = token.balanceOf(recipient);
        assertEq(recipientBalanceAfter - recipientBalanceBefore, expected, 'Autotransfer should have transferred funds');

        // Claimable should be 0 (autotransfer succeeded)
        uint256 claimableAfter = vault.claimableBalances(wid, recipient);
        assertEq(claimableAfter, 0, 'Claimable should be 0 when autotransfer succeeds');

        // Withdrawal should fail (no claimable balance, already transferred)
        vm.prank(recipient);
        vm.expectRevert(abi.encodeWithSignature("NoClaimableBalance(uint256,address,address)", wid, recipient, address(token)));
        vault.withdrawEscrow(wid);
    }

    function test_withdrawEscrow_idempotent() public {
        // Create and release
        vm.prank(sender);
        token.approve(address(vault), AMOUNT);

        EscrowSettings memory settings = SettingsValidationLibrary.getDefaultSettings();
        vm.prank(sender);
        uint256 wid = vault.createEscrow(address(token), recipient, AMOUNT, settings);

        vm.prank(sender);
        vault.releaseEscrowTransfer(wid);

        uint256 fee = (AMOUNT * ESCROW_FEE) / 10000;
        uint256 expected = AMOUNT - fee;

        // Autotransfer should have automatically transferred funds
        assertEq(token.balanceOf(recipient), expected, 'Autotransfer should have transferred funds');

        // Withdrawal should fail (no claimable balance, already transferred)
        vm.prank(recipient);
        vm.expectRevert(abi.encodeWithSignature("NoClaimableBalance(uint256,address,address)", wid, recipient, address(token)));
        vault.withdrawEscrow(wid);
    }

    function test_withdrawEscrow_non_finalized_fails() public {
        // Create escrow (PENDING state)
        vm.prank(sender);
        token.approve(address(vault), AMOUNT);

        EscrowSettings memory settings = SettingsValidationLibrary.getDefaultSettings();
        vm.prank(sender);
        uint256 wid = vault.createEscrow(address(token), recipient, AMOUNT, settings);

        // Recipient tries to withdraw while escrow is PENDING
        // EscrowState.PENDING = 1 (enum starts at 1)
        vm.prank(recipient);
        vm.expectRevert(abi.encodeWithSignature("TransferNotFinalized(uint256,uint8)", wid, uint8(1))); // 1 = PENDING
        vault.withdrawEscrow(wid);
    }

    function test_withdrawEscrow_multiple_escrows_same_recipient() public {
        uint256 amount1 = 5 ether;
        uint256 amount2 = 3 ether;

        // Create first escrow
        vm.prank(sender);
        token.approve(address(vault), amount1);
        EscrowSettings memory settings = SettingsValidationLibrary.getDefaultSettings();
        vm.prank(sender);
        uint256 wid1 = vault.createEscrow(address(token), recipient, amount1, settings);

        // Create second escrow
        address sender2 = address(0x50);
        token.transfer(sender2, 100 ether);
        vm.prank(sender2);
        token.approve(address(vault), amount2);
        EscrowSettings memory settings2 = SettingsValidationLibrary.getDefaultSettings();
        vm.prank(sender2);
        uint256 wid2 = vault.createEscrow(address(token), recipient, amount2, settings2);

        // Release both - autotransfer should automatically transfer funds
        uint256 recipientBalanceBefore = token.balanceOf(recipient);
        vm.prank(sender);
        vault.releaseEscrowTransfer(wid1);

        vm.prank(sender2);
        vault.releaseEscrowTransfer(wid2);

        // Autotransfer should have transferred both amounts
        uint256 fee1 = (amount1 * ESCROW_FEE) / 10000;
        uint256 fee2 = (amount2 * ESCROW_FEE) / 10000;
        uint256 expectedTotal = (amount1 - fee1) + (amount2 - fee2);
        
        uint256 recipientBalanceAfter = token.balanceOf(recipient);
        assertEq(recipientBalanceAfter - recipientBalanceBefore, expectedTotal, 'Autotransfer should have transferred both amounts');

        // Withdrawals should fail (no claimable balance, already transferred)
        vm.prank(recipient);
        vm.expectRevert(abi.encodeWithSignature("NoClaimableBalance(uint256,address,address)", wid1, recipient, address(token)));
        vault.withdrawEscrow(wid1);
        
        vm.prank(recipient);
        vm.expectRevert(abi.encodeWithSignature("NoClaimableBalance(uint256,address,address)", wid2, recipient, address(token)));
        vault.withdrawEscrow(wid2);
    }

    function test_claimable_balance_tracking() public {
        // Create escrow
        vm.prank(sender);
        token.approve(address(vault), AMOUNT);

        EscrowSettings memory settings = SettingsValidationLibrary.getDefaultSettings();
        vm.prank(sender);
        uint256 wid = vault.createEscrow(address(token), recipient, AMOUNT, settings);

        // Before release, claimable should be 0
        uint256 claimableBefore = vault.claimableBalances(wid, recipient);
        assertEq(claimableBefore, 0);

        // Release - autotransfer should automatically transfer funds
        uint256 recipientBalanceBefore = token.balanceOf(recipient);
        vm.prank(sender);
        vault.releaseEscrowTransfer(wid);

        // After release, autotransfer should have transferred funds automatically
        uint256 fee = (AMOUNT * ESCROW_FEE) / 10000;
        uint256 expected = AMOUNT - fee;
        
        uint256 recipientBalanceAfter = token.balanceOf(recipient);
        assertEq(recipientBalanceAfter - recipientBalanceBefore, expected, 'Autotransfer should have transferred funds');

        // Claimable should be 0 (autotransfer succeeded)
        uint256 claimableAfter = vault.claimableBalances(wid, recipient);
        assertEq(claimableAfter, 0, 'Claimable should be 0 when autotransfer succeeds');

        // Withdrawal should fail (no claimable balance, already transferred)
        vm.prank(recipient);
        vm.expectRevert(abi.encodeWithSignature("NoClaimableBalance(uint256,address,address)", wid, recipient, address(token)));
        vault.withdrawEscrow(wid);

        uint256 claimableFinal = vault.claimableBalances(wid, recipient);
        assertEq(claimableFinal, 0, 'Claimable should remain 0');
    }

    function test_withdrawEscrow_succeeds_after_autotransfer_fallback_and_refill() public {
        // Create escrow
        vm.prank(sender);
        token.approve(address(vault), AMOUNT);

        EscrowSettings memory settings = SettingsValidationLibrary.getDefaultSettings();
        vm.prank(sender);
        uint256 wid = vault.createEscrow(address(token), recipient, AMOUNT, settings);

        uint256 fee = (AMOUNT * ESCROW_FEE) / 10000;
        uint256 expected = AMOUNT - fee; // amountAfterFee

        // Simulate an unexpected vault balance deficit right before release:
        // drain the vault's escrowed amount so the push transfer fails and we fall back to pull.
        vm.prank(address(vault));
        token.transfer(address(0xdead), expected);

        // Release: autotransfer should fail and credit claimable balance.
        vm.prank(sender);
        vault.releaseEscrowTransfer(wid);

        uint256 claimable = vault.claimableBalances(wid, recipient);
        assertEq(claimable, expected, 'Claimable should be credited on push failure');

        // Refill vault so withdrawal can succeed.
        token.transfer(address(vault), expected);

        uint256 balBefore = token.balanceOf(recipient);
        vm.prank(recipient);
        vault.withdrawEscrow(wid);
        uint256 balAfter = token.balanceOf(recipient);

        assertEq(balAfter - balBefore, expected, 'Withdraw should transfer claimable amount');
        assertEq(vault.claimableBalances(wid, recipient), 0, 'Claimable should be cleared after withdraw');
    }
}
