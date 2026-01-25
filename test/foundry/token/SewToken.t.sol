// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import 'forge-std/Test.sol';
import '../../../contracts/token/SewToken.sol';

contract SewTokenTest is Test {
    SewToken public token;
    address public owner;
    address public user1;

    function setUp() public {
        owner = address(this);
        user1 = address(0x1);
        token = new SewToken("Sew", "SEW", owner, 1000e18);
    }

    function test_Metadata() public {
        assertEq(token.name(), "Sew");
        assertEq(token.symbol(), "SEW");
        assertEq(token.totalSupply(), 1000e18);
    }

    function test_Voting() public {
        token.transfer(user1, 100e18);
        vm.prank(user1);
        token.delegate(user1);
        
        assertEq(token.getVotes(user1), 100e18);
        
        vm.roll(block.number + 1);
        assertEq(token.getPastVotes(user1, block.number - 1), 100e18);
    }

    function test_Burning() public {
        token.burn(100e18);
        assertEq(token.totalSupply(), 900e18);
    }

    function test_Ownership() public {
        address newOwner = address(0x2);
        token.transferOwnership(newOwner);
        // Ownable2Step: pending
        assertEq(token.owner(), owner);
        
        vm.prank(newOwner);
        token.acceptOwnership();
        assertEq(token.owner(), newOwner);
    }
}
