// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import '@openzeppelin/contracts/token/ERC20/ERC20.sol';

/**
 * @title ERC20LowDecimalMock
 * @notice Simple ERC20 token with configurable decimals for testing
 */
contract ERC20LowDecimalMock is ERC20 {
    uint8 private immutable _decimals;

    constructor(
        string memory name,
        string memory symbol,
        uint8 decimalUnits,
        address initialAccount,
        uint256 initialBalance
    ) ERC20(name, symbol) {
        _decimals = decimalUnits;
        _mint(initialAccount, initialBalance);
    }

    function decimals() public view virtual override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) public {
        _mint(to, amount);
    }
}
