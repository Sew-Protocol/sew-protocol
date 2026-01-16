// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import 'forge-std/Test.sol';
import 'contracts/core/EscrowVault.sol';
import 'contracts/mocks/ERC20Mock.sol';
import 'contracts/core/modules/DefaultResolutionModule.sol';
import 'contracts/types/EscrowTypes.sol';
import 'contracts/YieldOps.sol';
import 'contracts/DisputeOps.sol';

contract WithdrawEscrowTest is Test {
    EscrowVault vault;
    ERC20Mock token;
    DefaultResolutionModule rm;
    YieldOps yieldOps;
    DisputeOps disputeOps;

    address sender = address(0x10);
    address recipient = address(0x20);
    address resolver = address(0x30);
    address feeAddress = address(0x40);

    uint256 constant ESCROW_FEE = 100; // 1%
    uint256 constant AMOUNT = 10 ether;

    function setUp() public {
        yieldOps = new YieldOps();
        disputeOps = new DisputeOps();
        vault = new EscrowVault(ESCROW_FEE, feeAddress, address(yieldOps), address(disputeOps));
        token = new ERC20Mock('Test', 'TST', address(this), 1e24);
        rm = new DefaultResolutionModule(address(this), resolver);

        // Setup roles and modules
        vault.grantRole(vault.ROLE_TIMELOCK(), address(this));
        vault.queueResolutionModule(address(rm));
        vm.warp(block.timestamp + 7 days + 1);
        vault.activateResolutionModule();

        // Fund sender
        token.transfer(sender, 1000 ether);
    }

    function test_withdrawEscrow_after_release() public {
        // Create escrow
        vm.prank(sender);
        token.approve(address(vault), AMOUNT);

        vm.prank(sender);
        uint256 wid = vault.createEscrow(address(token), recipient, AMOUNT);

        uint256 fee = (AMOUNT * ESCROW_FEE) / 10000;
        uint256 expected = AMOUNT - fee;

        // Before release, claimable should be 0
        uint256 claimableBefore = vault.claimable(wid, recipient, address(token));
        assertEq(claimableBefore, 0);

        // Release - autotransfer should automatically transfer funds
        uint256 recipientBalanceBefore = token.balanceOf(recipient);
        vm.prank(sender);
        vault.releaseEscrowTransfer(wid);

        // After release, autotransfer should have transferred funds automatically
        uint256 recipientBalanceAfter = token.balanceOf(recipient);
        assertEq(recipientBalanceAfter - recipientBalanceBefore, expected, 'Autotransfer should have transferred funds');

        // Claimable should be 0 (autotransfer succeeded)
        uint256 claimableAfter = vault.claimable(wid, recipient, address(token));
        assertEq(claimableAfter, 0, 'Claimable should be 0 when autotransfer succeeds');

        // Withdrawal should fail (no claimable balance, already transferred)
        vm.prank(recipient);
        vm.expectRevert('No claimable balance');
        vault.withdrawEscrow(wid);
    }

    function test_withdrawEscrow_idempotent() public {
        // Create and release
        vm.prank(sender);
        token.approve(address(vault), AMOUNT);

        vm.prank(sender);
        uint256 wid = vault.createEscrow(address(token), recipient, AMOUNT);

        vm.prank(sender);
        vault.releaseEscrowTransfer(wid);

        uint256 fee = (AMOUNT * ESCROW_FEE) / 10000;
        uint256 expected = AMOUNT - fee;

        // Autotransfer should have automatically transferred funds
        assertEq(token.balanceOf(recipient), expected, 'Autotransfer should have transferred funds');

        // Withdrawal should fail (no claimable balance, already transferred)
        vm.prank(recipient);
        vm.expectRevert('No claimable balance');
        vault.withdrawEscrow(wid);
    }

    function test_withdrawEscrow_non_finalized_fails() public {
        // Create escrow (PENDING state)
        vm.prank(sender);
        token.approve(address(vault), AMOUNT);

        vm.prank(sender);
        uint256 wid = vault.createEscrow(address(token), recipient, AMOUNT);

        // Recipient tries to withdraw while escrow is PENDING
        vm.prank(recipient);
        vm.expectRevert('Not finalized');
        vault.withdrawEscrow(wid);
    }

    function test_withdrawEscrow_multiple_escrows_same_recipient() public {
        uint256 amount1 = 5 ether;
        uint256 amount2 = 3 ether;

        // Create first escrow
        vm.prank(sender);
        token.approve(address(vault), amount1);
        vm.prank(sender);
        uint256 wid1 = vault.createEscrow(address(token), recipient, amount1);

        // Create second escrow
        address sender2 = address(0x50);
        token.transfer(sender2, 100 ether);
        vm.prank(sender2);
        token.approve(address(vault), amount2);
        vm.prank(sender2);
        uint256 wid2 = vault.createEscrow(address(token), recipient, amount2);

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
        vm.expectRevert('No claimable balance');
        vault.withdrawEscrow(wid1);
        
        vm.prank(recipient);
        vm.expectRevert('No claimable balance');
        vault.withdrawEscrow(wid2);
    }

    function test_claimable_balance_tracking() public {
        // Create escrow
        vm.prank(sender);
        token.approve(address(vault), AMOUNT);

        vm.prank(sender);
        uint256 wid = vault.createEscrow(address(token), recipient, AMOUNT);

        // Before release, claimable should be 0
        uint256 claimableBefore = vault.claimable(wid, recipient, address(token));
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
        uint256 claimableAfter = vault.claimable(wid, recipient, address(token));
        assertEq(claimableAfter, 0, 'Claimable should be 0 when autotransfer succeeds');

        // Withdrawal should fail (no claimable balance, already transferred)
        vm.prank(recipient);
        vm.expectRevert('No claimable balance');
        vault.withdrawEscrow(wid);

        uint256 claimableFinal = vault.claimable(wid, recipient, address(token));
        assertEq(claimableFinal, 0, 'Claimable should remain 0');
    }
}
