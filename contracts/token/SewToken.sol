// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import '@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol';
import '@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol';
import '@openzeppelin/contracts/access/Ownable.sol';
import '@openzeppelin/contracts/utils/cryptography/EIP712.sol';

/**
 * @title SewToken
 * @notice Governance token for Sew Protocol with voting capabilities
 * @dev Fixed supply ERC20Votes token for DAO governance
 *
 * Features:
 * - ERC20Votes for onchain governance voting (includes ERC20Permit)
 * - ERC20Burnable for token burning (used when SEW is slashed)
 * - Fixed supply (1B tokens, no minting after initial)
 * - Ownable (will be transferred to Safe, then Timelock)
 *
 * Note: ERC20Votes already includes ERC20Permit, so no need to inherit separately
 */
contract SewToken is ERC20Votes, ERC20Burnable, Ownable {
    /**
     * @notice Deploy SewToken with initial supply
     * @param name Token name ("Sew Token")
     * @param symbol Token symbol ("SEW")
     * @param initialOwner Initial owner address (will transfer to Safe/Timelock)
     * @param initialSupply Initial supply in smallest units (1B = 1000000000000000000000000000)
     */
    constructor(
        string memory name,
        string memory symbol,
        address initialOwner,
        uint256 initialSupply
    ) ERC20(name, symbol) EIP712(name, '1') Ownable(initialOwner) {
        _mint(initialOwner, initialSupply);
    }

    /**
     * @notice No minting function - fixed supply token
     * @dev Minting removed for fixed supply. All tokens minted in constructor.
     *      burn() and burnFrom() are available via ERC20Burnable for slashing.
     */
    // Minting intentionally removed - this is a fixed supply token

    /**
     * @notice Override _update to ensure voting snapshots are updated correctly
     * @dev Required when inheriting from both ERC20Votes and ERC20Burnable
     *      Calls ERC20Votes._update which handles voting snapshots
     */
    function _update(address from, address to, uint256 value) internal override(ERC20, ERC20Votes) {
        super._update(from, to, value);
    }
}
