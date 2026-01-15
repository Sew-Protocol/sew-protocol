// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

/**
 * @notice Minimal ERC20-like token that does not return booleans from `transfer`/`transferFrom`.
 * This simulates non-standard tokens that SafeERC20 needs to handle.
 */
contract MockNonStandardERC20 {
    string public name;
    string public symbol;
    uint8 public decimals = 18;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor(
        string memory _name,
        string memory _symbol,
        address initialAccount,
        uint256 initialBalance
    ) {
        name = _name;
        symbol = _symbol;
        _mint(initialAccount, initialBalance);
    }

    function _mint(address to, uint256 amount) internal {
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    // Note: No return value
    function transfer(address to, uint256 amount) external {
        require(balanceOf[msg.sender] >= amount, 'NS: insufficient');
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    // Note: No return value
    function transferFrom(address from, address to, uint256 amount) external {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, 'NS: allowance');
        allowance[from][msg.sender] = allowed - amount;
        require(balanceOf[from] >= amount, 'NS: balance');
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
    }
}
