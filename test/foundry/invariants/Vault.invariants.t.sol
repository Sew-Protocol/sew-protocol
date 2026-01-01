// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "forge-std/StdInvariant.sol";
import "../../../contracts/Vault.sol";

contract VaultHandler is Test {
    Vault public vault;

    constructor(Vault _vault) {
        vault = _vault;
    }

    function deposit(uint256 amount) external {
        if (amount == 0) return;
        // Bound to keep runtime reasonable
        amount = bound(amount, 1, 1e24);
        vault.deposit(amount);
    }

    function withdraw(uint256 amount) external {
        if (amount == 0) return;
        amount = bound(amount, 1, 1e24);
        // If it reverts, that's ok—StdInvariant will ignore the reverted action.
        try vault.withdraw(amount) {} catch {}
    }
}

contract VaultInvariants is StdInvariant, Test {
    Vault vault;
    VaultHandler handler;

    function setUp() public {
        vault = new Vault();
        handler = new VaultHandler(vault);
        targetContract(address(handler));
    }

    /// @notice Invariant: totalAssets equals sum of balances for this simplified vault
    ///         (only one actor in handler since it calls as itself).
    function invariant_totalAssetsMatchesBalance() public view {
        assertEq(vault.totalAssets(), vault.balanceOf(address(handler)));
    }

    /// @notice Invariant: balances never exceed totalAssets
    function invariant_balanceLeTotalAssets() public view {
        assertLe(vault.balanceOf(address(handler)), vault.totalAssets());
    }
}
