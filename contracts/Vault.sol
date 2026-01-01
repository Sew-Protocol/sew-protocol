// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice Minimal DeFi-style vault for demo testing patterns.
///         - deposit/withdraw 1:1 shares
///         - NOT production-ready; for test scaffolding only.
contract Vault {
    mapping(address => uint256) public balanceOf;
    uint256 public totalAssets;

    event Deposit(address indexed user, uint256 amount);
    event Withdraw(address indexed user, uint256 amount);

    function deposit(uint256 amount) external {
        require(amount > 0, "amount=0");
        // For demo simplicity, assume token transfer already happened.
        balanceOf[msg.sender] += amount;
        totalAssets += amount;
        emit Deposit(msg.sender, amount);
    }

    function withdraw(uint256 amount) external {
        require(amount > 0, "amount=0");
        uint256 bal = balanceOf[msg.sender];
        require(bal >= amount, "insufficient");
        balanceOf[msg.sender] = bal - amount;
        totalAssets -= amount;
        emit Withdraw(msg.sender, amount);
    }
}