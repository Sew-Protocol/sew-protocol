// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/cryptography/EIP712.sol";

/**
 * @title SewToken
 * @notice Governance token for Sew Protocol with voting capabilities
 * @dev Fixed supply ERC20Votes token for DAO governance
 * 
 * Features:
 * - ERC20Votes for onchain governance voting (includes ERC20Permit)
 * - Fixed supply (1B tokens, no minting)
 * - Ownable (will be transferred to Safe, then Timelock)
 * 
 * Note: ERC20Votes already includes ERC20Permit, so no need to inherit separately
 */
contract SewToken is ERC20Votes, Ownable {
    /**
     * @notice Deploy SewToken with initial supply
     * @param name Token name (e.g., "Sew Token")
     * @param symbol Token symbol (e.g., "$EW" or "SEW")
     * @param initialOwner Initial owner address (will transfer to Safe/Timelock)
     * @param initialSupply Initial supply in smallest units (1B = 1000000000000000000000000000)
     */
    constructor(
        string memory name,
        string memory symbol,
        address initialOwner,
        uint256 initialSupply
    ) ERC20(name, symbol) EIP712(name, "1") Ownable(initialOwner) {
        _mint(initialOwner, initialSupply);
    }

    /**
     * @notice No minting function - fixed supply token
     * @dev Minting removed for fixed supply. All tokens minted in constructor.
     */
    // Minting intentionally removed - this is a fixed supply token
}

