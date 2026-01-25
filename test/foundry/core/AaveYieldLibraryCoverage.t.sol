// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import "forge-std/Test.sol";
import "../../../contracts/libraries/AaveYieldLibrary.sol";
import "../../../contracts/mocks/ERC20Mock.sol";
import "../../../contracts/mocks/MockAavePool.sol";

contract AaveYieldLibraryCoverageTest is Test {
    ERC20Mock token;
    MockAavePool pool;
    MockAToken aToken;
    
    function setUp() public {
        token = new ERC20Mock("Test", "TEST", address(this), 1000 ether);
        pool = new MockAavePool();
        aToken = new MockAToken(address(token), "aTest", "aTEST");
        pool.setAToken(address(token), address(aToken));
        aToken.setPool(address(pool));
    }

    function test_supply_WithExistingAllowance() public {
        uint256 amount = 100 ether;
        
        // Set an existing but different allowance
        token.approve(address(pool), 50 ether);
        
        // Call library supply
        AaveYieldLibrary.supply(address(pool), address(token), amount, address(this));
        
        // Verify allowance is reset to 0 after supply
        assertEq(token.allowance(address(this), address(pool)), 0);
        // Verify aTokens minted
        assertEq(aToken.balanceOf(address(this)), amount);
    }

    function test_supply_WithSameAllowance() public {
        uint256 amount = 100 ether;
        
        // Set same allowance
        token.approve(address(pool), amount);
        
        // Call library supply
        AaveYieldLibrary.supply(address(pool), address(token), amount, address(this));
        
        assertEq(token.allowance(address(this), address(pool)), 0);
        assertEq(aToken.balanceOf(address(this)), amount);
    }

    function test_withdraw() public {
        uint256 amount = 100 ether;
        
        // First supply
        token.approve(address(pool), amount);
        AaveYieldLibrary.supply(address(pool), address(token), amount, address(this));
        
        // Then withdraw
        uint256 actual = AaveYieldLibrary.withdraw(address(pool), address(token), amount, address(this));
        
        assertEq(actual, amount);
        assertEq(aToken.balanceOf(address(this)), 0);
    }
}
