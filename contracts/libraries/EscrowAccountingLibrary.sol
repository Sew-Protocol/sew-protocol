// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import '@openzeppelin/contracts/token/ERC20/IERC20.sol';

library EscrowAccountingLibrary {
    function getDelta(
        address token,
        mapping(address => uint256) storage totalHeld,
        mapping(address => uint256) storage totalFees
    ) internal view returns (int256 delta) {
        uint256 actual = IERC20(token).balanceOf(address(this));
        uint256 expected = totalHeld[token] + totalFees[token];
        // In this system, token balances are expected to remain far below int256.max.
        return int256(actual) - int256(expected); // forge-lint: disable-line(unsafe-typecast)
    }

    function reconcile(
        address token,
        mapping(address => uint256) storage totalHeld,
        mapping(address => uint256) storage totalFees
    ) internal view returns (uint256 delta, bool hasDeficit) {
        uint256 actual = IERC20(token).balanceOf(address(this));
        uint256 expected = totalHeld[token] + totalFees[token];
        
        if (actual > expected) {
            return (actual - expected, false);
        } else if (actual < expected) {
            return (expected - actual, true);
        }
        return (0, false);
    }
}
