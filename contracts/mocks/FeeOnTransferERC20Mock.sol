// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title FeeOnTransferERC20Mock
 * @notice ERC20 test token that burns a fee on every transfer.
 * @dev This is useful to reproduce "contract balance deficit" scenarios when the escrow
 *      assumes exact amounts are received, but the token deflates on transferFrom/transfer.
 */
contract FeeOnTransferERC20Mock is ERC20 {
    uint256 public immutable feeBps; // 0-10000

    constructor(string memory name_, string memory symbol_, uint256 feeBps_) ERC20(name_, symbol_) {
        require(feeBps_ <= 10_000, "feeBps too high");
        feeBps = feeBps_;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    // OZ v5 ERC20 uses _update for transfers/mint/burn.
    function _update(address from, address to, uint256 value) internal virtual override {
        if (from != address(0) && to != address(0) && feeBps != 0) {
            uint256 fee = (value * feeBps) / 10_000;
            if (fee > 0) {
                // Burn the fee from the sender, send the remainder to the recipient.
                super._update(from, address(0), fee);
                super._update(from, to, value - fee);
                return;
            }
        }
        super._update(from, to, value);
    }
}

