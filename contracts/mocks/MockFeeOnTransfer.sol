// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import "./ERC20Mock.sol";

/**
 * @notice ERC20 mock that charges a small fee on every transfer.
 */
contract MockFeeOnTransfer is ERC20Mock {
    uint256 public feeBps; // basis points (100 = 1%)
    address public feeRecipient;

    constructor(
        string memory name,
        string memory symbol,
        address initialAccount,
        uint256 initialBalance,
        uint256 _feeBps,
        address _feeRecipient
    ) ERC20Mock(name, symbol, initialAccount, initialBalance) {
        feeBps = _feeBps;
        feeRecipient = _feeRecipient;
    }

    /// OpenZeppelin's ERC20 makes `_transfer` non-virtual; override `_update` instead.
    function _update(address from, address to, uint256 value) internal virtual override {
        if (from == address(0) || to == address(0)) {
            // for mint/burn behavior, delegate to parent
            super._update(from, to, value);
            return;
        }

        uint256 fee = (value * feeBps) / 10000;
        uint256 sent = value - fee;

        // perform main transfer (from -> to)
        super._update(from, to, sent);

        // send fee to recipient if any
        if (fee > 0) {
            super._update(from, feeRecipient, fee);
        }
    }
}
