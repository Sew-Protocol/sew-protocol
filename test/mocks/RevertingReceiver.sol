// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

/**
 * @title RevertingReceiver
 * @notice Contract that reverts on token receive (for testing autotransfer fallback)
 */
contract RevertingReceiver {
    bool public shouldRevert = true;

    function setShouldRevert(bool _shouldRevert) external {
        shouldRevert = _shouldRevert;
    }

    // Note: ERC20 transfers don't call onERC20Received (that's ERC721/ERC1155)
    // Instead, we'll use a contract that reverts in its receive/fallback
    // For ERC20, we need a different approach - use a contract that can't receive tokens
    // Actually, ERC20 transfers to contracts work fine unless the contract reverts
    // We'll use a contract that reverts on any external call
    receive() external payable {
        if (shouldRevert) {
            revert('RevertingReceiver: Revert on receive');
        }
    }

    fallback() external payable {
        if (shouldRevert) {
            revert('RevertingReceiver: Revert on fallback');
        }
    }
}
