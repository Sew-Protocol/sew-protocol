// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.33;

import "./core/BaseEscrow.sol";
import "./libraries/RecoveryLibrary.sol";

/**
 * @title EscrowOps
 * @notice Peripheral contract for escrow operations to reduce main contract size
 */
contract EscrowOps {
    event FeesWithdrawn(address indexed token, uint256 amount);
    event ERC20Recovered(address indexed token, address indexed recipient, uint256 amount);

    function withdrawFees(BaseEscrow escrow, address token, address feeAddress) external returns (uint256) {
        // This is a helper, but actual transfer must happen from the escrow contract
        // So this contract must be called BY the escrow contract via delegatecall OR
        // the escrow contract must provide an interface for this.
        return 0; 
    }
}