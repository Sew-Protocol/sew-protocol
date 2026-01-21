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
    function test_escrowVault_hasDefaultReleaseStrategySwapWrappers() public {
        bytes4 expectedQueue = bytes4(keccak256("queueDefaultReleaseStrategy(address)"));
        bytes4 expectedActivate = bytes4(keccak256("activateDefaultReleaseStrategy()"));

        assertEq(EscrowVault.queueDefaultReleaseStrategy.selector, expectedQueue);
        assertEq(EscrowVault.activateDefaultReleaseStrategy.selector, expectedActivate);
    }

    function test_escrowableERC20_hasDefaultReleaseStrategySwapWrappers() public {
        bytes4 expectedQueue = bytes4(keccak256("queueDefaultReleaseStrategy(address)"));
        bytes4 expectedActivate = bytes4(keccak256("activateDefaultReleaseStrategy()"));

        assertEq(EscrowableERC20.queueDefaultReleaseStrategy.selector, expectedQueue);
        assertEq(EscrowableERC20.activateDefaultReleaseStrategy.selector, expectedActivate);
    }
}

