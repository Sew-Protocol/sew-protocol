// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import '@openzeppelin/contracts/token/ERC20/ERC20.sol';

/**
 * @title MockRevertingERC20
 * @notice ERC20 mock that reverts on transfer (for testing autotransfer fallback)
 */
contract MockRevertingERC20 is ERC20 {
    bool public shouldRevert;

    constructor(
        string memory name,
        string memory symbol,
        address initialAccount,
        uint256 initialBalance
    ) ERC20(name, symbol) {
        _mint(initialAccount, initialBalance);
        shouldRevert = false; // Default: normal behavior
    }

    function setShouldRevert(bool _shouldRevert) external {
        shouldRevert = _shouldRevert;
    }

    function mint(address to, uint256 amount) public {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) public {
        _burn(from, amount);
    }

    function transfer(address to, uint256 amount) public virtual override returns (bool) {
        if (shouldRevert) {
            revert('MockRevertingERC20: Transfer reverted');
        }
        return super.transfer(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public virtual override returns (bool) {
        if (shouldRevert) {
            revert('MockRevertingERC20: TransferFrom reverted');
        }
        return super.transferFrom(from, to, amount);
    }
}
