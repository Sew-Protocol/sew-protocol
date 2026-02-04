// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract MockEscrow {
    mapping(address => uint256) public balanceOf;
    bool public isActive = true;

    event Deposit(address indexed user, uint256 amount);
    event Withdraw(address indexed user, uint256 amount);

    function deposit(uint256 amount) external {
        balanceOf[msg.sender] += amount;
        emit Deposit(msg.sender, amount);
    }

    function withdraw(uint256 amount) external {
        require(balanceOf[msg.sender] >= amount, "Insufficient balance");
        balanceOf[msg.sender] -= amount;
        emit Withdraw(msg.sender, amount);
    }

    function setBalance(address user, uint256 amount) external {
        balanceOf[user] = amount;
    }

    function setActive(bool _active) external {
        isActive = _active;
    }
}
