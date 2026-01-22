// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import "forge-std/Test.sol";

import "../../../contracts/core/EscrowVault.sol";
import "../../../contracts/core/EscrowableERC20.sol";

/**
 * @title SwapWrapperSurfaceTest
 * @notice Compile-time + selector-level guard to ensure escrow-originated module swap wrappers exist.
 *
 * If these wrappers are removed from `EscrowVault` / `EscrowableERC20`, this test will fail to compile
 * (or the selector assertions will fail), preventing accidental regressions in swap executability.
 */
contract SwapWrapperSurfaceTest is Test {
    function test_escrowVault_hasModuleSwapWrappers() public {
        bytes4 expectedQueue = bytes4(keccak256("queueModule(uint8,address)"));
        bytes4 expectedActivate = bytes4(keccak256("activateModule(uint8)"));

        assertEq(EscrowVault.queueModule.selector, expectedQueue);
        assertEq(EscrowVault.activateModule.selector, expectedActivate);
    }

    function test_escrowableERC20_hasModuleSwapWrappers() public {
        bytes4 expectedQueue = bytes4(keccak256("queueModule(uint8,address)"));
        bytes4 expectedActivate = bytes4(keccak256("activateModule(uint8)"));

        assertEq(EscrowableERC20.queueModule.selector, expectedQueue);
        assertEq(EscrowableERC20.activateModule.selector, expectedActivate);
    }
}

