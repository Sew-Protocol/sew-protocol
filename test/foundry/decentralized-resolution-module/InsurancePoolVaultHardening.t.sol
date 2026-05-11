// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import 'forge-std/Test.sol';
import '../../../contracts/modules/decentralized-resolution-module/InsurancePoolVault.sol';
import '../../../contracts/modules/decentralized-resolution-module/ISlashingModule.sol';
import '../../../contracts/mocks/ERC20Mock.sol';

/**
 * @title InsurancePoolVaultHardeningTest
 * @notice Focused governance/break-glass movement hardening tests.
 */
contract InsurancePoolVaultHardeningTest is Test {
    InsurancePoolVault public vault;
    ERC20Mock public stable;

    address public admin = address(this);
    address public timelock = address(0xBEEF);
    address public slashing = address(0xCAFE);
    address public payoutRecipient = address(0xD00D);

    function setUp() public {
        stable = new ERC20Mock('Mock USDC', 'mUSDC', admin, 1_000_000e6);
        vault = new InsurancePoolVault(admin, address(stable));

        vault.grantRole(vault.ROLE_TIMELOCK(), timelock);
        vault.grantRole(vault.ROLE_SLASHING_MODULE(), slashing);

        // Seed vault and record tagged funding.
        stable.transfer(address(vault), 10_000e6);
        vm.prank(slashing);
        vault.recordDeposit(10_000e6, ISlashingModule.SlashReason.TIMEOUT_RESOLVE, 1, address(0));
    }

    function test_withdraw_breakGlass_disabledByDefault() public {
        vm.prank(timelock);
        vm.expectRevert('Withdrawals disabled');
        vault.withdraw(payoutRecipient, 100e6, 1);
    }

    function test_executePayout_requiresSlowDelay_thenSucceeds() public {
        vm.prank(timelock);
        uint256 payoutId = vault.proposePayout(payoutRecipient, 500e6, 42, address(0), 'coverage payout');

        // Cannot execute before delay.
        vm.prank(timelock);
        vm.expectRevert();
        vault.executePayout(payoutId);

        // Execute after delay.
        vm.warp(block.timestamp + vault.SLOW_DELAY() + 1);
        uint256 beforeBal = stable.balanceOf(payoutRecipient);

        vm.prank(timelock);
        vault.executePayout(payoutId);

        assertEq(stable.balanceOf(payoutRecipient) - beforeBal, 500e6, 'payout amount mismatch');
    }

    function test_setWithdrawalsEnabled_onlyTimelock() public {
        vm.prank(address(0xABCD));
        vm.expectRevert();
        vault.setWithdrawalsEnabled(true);

        vm.prank(timelock);
        vault.setWithdrawalsEnabled(true);
        assertTrue(vault.withdrawalsEnabled(), 'timelock should be able to enable withdrawals');
    }
}
