// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import "forge-std/Test.sol";
import "contracts/core/EscrowVault.sol";
import "contracts/mocks/ERC20Mock.sol";
import "contracts/core/modules/DefaultResolutionModule.sol";
import "contracts/types/EscrowTypes.sol";
import "contracts/YieldOps.sol";
import "contracts/DisputeOps.sol";

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
        token = new ERC20Mock("Test", "TST", address(this), 1e24);
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

        // Release
        vm.prank(sender);
        vault.releaseEscrowTransfer(wid);

        // After release, claimable should be (amount - fee)
        uint256 claimableAfter = vault.claimable(wid, recipient, address(token));
        assertEq(claimableAfter, expected);

        // Before withdrawal, recipient should have 0 balance in hand
        assertEq(token.balanceOf(recipient), 0);

        // Recipient calls withdrawEscrow
        vm.prank(recipient);
        uint256 withdrawn = vault.withdrawEscrow(wid);

        assertEq(withdrawn, expected);
        assertEq(token.balanceOf(recipient), expected);
        
        // After withdrawal, claimable should be 0
        uint256 claimableFinal = vault.claimable(wid, recipient, address(token));
        assertEq(claimableFinal, 0);
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

        // First withdrawal succeeds
        vm.prank(recipient);
        uint256 w1 = vault.withdrawEscrow(wid);
        assertEq(w1, expected);

        // Second withdrawal should fail (no claimable balance)
        vm.prank(recipient);
        vm.expectRevert("No claimable balance");
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
        vm.expectRevert("Not finalized");
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

        // Release both
        vm.prank(sender);
        vault.releaseEscrowTransfer(wid1);

        vm.prank(sender2);
        vault.releaseEscrowTransfer(wid2);

        // Withdraw first
        uint256 fee1 = (amount1 * ESCROW_FEE) / 10000;
        vm.prank(recipient);
        uint256 w1 = vault.withdrawEscrow(wid1);
        assertEq(w1, amount1 - fee1);

        // Withdraw second
        uint256 fee2 = (amount2 * ESCROW_FEE) / 10000;
        vm.prank(recipient);
        uint256 w2 = vault.withdrawEscrow(wid2);
        assertEq(w2, amount2 - fee2);

        assertEq(token.balanceOf(recipient), amount1 - fee1 + amount2 - fee2);
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

        // Release
        vm.prank(sender);
        vault.releaseEscrowTransfer(wid);

        // After release, claimable should be (amount - fee)
        uint256 fee = (AMOUNT * ESCROW_FEE) / 10000;
        uint256 claimableAfter = vault.claimable(wid, recipient, address(token));
        assertEq(claimableAfter, AMOUNT - fee);

        // After withdrawal, claimable should be 0 again
        vm.prank(recipient);
        vault.withdrawEscrow(wid);

        uint256 claimableFinal = vault.claimable(wid, recipient, address(token));
        assertEq(claimableFinal, 0);
    }
}
