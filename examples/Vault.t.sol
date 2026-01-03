// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../../contracts/Vault.sol";

contract VaultTest is Test {
    Vault vault;

    function setUp() public {
        vault = new Vault();
    }

    function testDepositIncreasesBalances() public {
        vault.deposit(1 ether);
        assertEq(vault.balanceOf(address(this)), 1 ether);
        assertEq(vault.totalAssets(), 1 ether);
    }

    function testWithdrawDecreasesBalances() public {
        vault.deposit(2 ether);
        vault.withdraw(1 ether);
        assertEq(vault.balanceOf(address(this)), 1 ether);
        assertEq(vault.totalAssets(), 1 ether);
    }

    function testWithdrawRevertsIfInsufficient() public {
        vault.deposit(1 ether);
        vm.expectRevert("insufficient");
        vault.withdraw(2 ether);
    }

    // Example fuzz test: withdrawing never makes totalAssets negative and never exceeds deposited.
    function testFuzz_DepositThenWithdraw(uint128 dep, uint128 wd) public {
        vm.assume(dep > 0);
        vault.deposit(uint256(dep));
        if (wd > dep) {
            vm.expectRevert("insufficient");
            vault.withdraw(uint256(wd));
        } else if (wd == 0) {
            vm.expectRevert("amount=0");
            vault.withdraw(0);
        } else {
            vault.withdraw(uint256(wd));
            assertEq(vault.balanceOf(address(this)), uint256(dep) - uint256(wd));
            assertEq(vault.totalAssets(), uint256(dep) - uint256(wd));
        }
    }
}
