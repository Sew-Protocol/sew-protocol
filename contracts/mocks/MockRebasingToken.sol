// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import './ERC20Mock.sol';

/**
 * @notice Simple rebasing-like token for tests. For test purposes this exposes a `rebase`
 * method that increases total supply by minting to a designated receiver (simulates supply changes).
 * It's intentionally simple — full rebase semantics are out of scope for these tests.
 */
contract MockRebasingToken is ERC20Mock {
    event Rebase(address indexed who, uint256 amount);

    constructor(
        string memory name,
        string memory symbol,
        address initialAccount,
        uint256 initialBalance
    ) ERC20Mock(name, symbol, initialAccount, initialBalance) {}

    /// @notice Simulate a rebase by minting `amount` to `who` and emitting `Rebase`.
    function rebase(address who, uint256 amount) external {
        _mint(who, amount);
        emit Rebase(who, amount);
    }
}
