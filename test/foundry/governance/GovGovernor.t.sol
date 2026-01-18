// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import 'forge-std/Test.sol';
import '../../../contracts/governance/GovGovernor.sol';
import '../../../contracts/token/SewToken.sol';
import '@openzeppelin/contracts/governance/TimelockController.sol';

contract GovGovernorTest is Test {
    GovGovernor public governor;
    SewToken public token;
    TimelockController public timelock;

    address public owner;
    address public user1;
    address public user2;
    address[] public proposers;
    address[] public executors;

    function setUp() public {
        owner = address(this);
        user1 = address(0x1);
        user2 = address(0x2);

        token = new SewToken("Sew", "SEW", owner, 1000000000e18); // 1B supply

        proposers = new address[](1);
        proposers[0] = address(this);
        executors = new address[](1);
        executors[0] = address(0); // Anyone can execute

        timelock = new TimelockController(
            1 days,
            proposers,
            executors,
            owner
        );

        address[] memory initialNonCirculating = new address[](1);
        initialNonCirculating[0] = user1;

        governor = new GovGovernor(
            address(token),
            timelock,
            1, // Voting delay
            50400, // Voting period
            1000e18, // Proposal threshold
            4000000e18, // Absolute quorum
            initialNonCirculating
        );

        // Grant proposer role to governor
        timelock.grantRole(timelock.PROPOSER_ROLE(), address(governor));
        timelock.grantRole(timelock.EXECUTOR_ROLE(), address(governor));
        timelock.grantRole(timelock.CANCELLER_ROLE(), address(governor));
    }

    function test_constructor_Success() public {
        assertEq(governor.absoluteQuorum(), 4000000e18);
        assertEq(governor.getNonCirculatingAddressesCount(), 1);
        assertTrue(governor.nonCirculatingAddresses(user1));
    }

    function test_constructor_ZeroQuorum() public {
        address[] memory initialNonCirculating = new address[](0);
        vm.expectRevert(GovGovernor.QuorumMustBePositive.selector);
        new GovGovernor(
            address(token),
            timelock,
            1,
            50400,
            1000e18,
            0,
            initialNonCirculating
        );
    }

    function test_constructor_TooManyAddresses() public {
        uint256 max = governor.MAX_NON_CIRCULATING_ADDRESSES();
        address[] memory initialNonCirculating = new address[](max + 1);
        for(uint256 i=0; i<max+1; i++) {
            initialNonCirculating[i] = address(uint160(i + 1));
        }
        
        vm.expectRevert(abi.encodeWithSelector(GovGovernor.TooManyInitialAddresses.selector, max + 1, max));
        new GovGovernor(
            address(token),
            timelock,
            1,
            50400,
            1000e18,
            4000000e18,
            initialNonCirculating
        );
    }

    function test_constructor_DuplicateAddress() public {
        address[] memory initialNonCirculating = new address[](2);
        initialNonCirculating[0] = user1;
        initialNonCirculating[1] = user1;
        
        vm.expectRevert(abi.encodeWithSelector(GovGovernor.DuplicateAddress.selector, user1));
        new GovGovernor(
            address(token),
            timelock,
            1,
            50400,
            1000e18,
            4000000e18,
            initialNonCirculating
        );
    }

    function test_quorum() public {
        assertEq(governor.quorum(block.number), 4000000e18);
    }

    function test_getCirculatingSupply() public {
        // user1 is non-circulating
        // owner has all supply initially
        token.transfer(user1, 100000e18); // 100k to non-circulating
        
        uint256 totalSupply = token.totalSupply();
        uint256 nonCirculating = 100000e18;
        
        assertEq(governor.getCirculatingSupply(block.number), totalSupply - nonCirculating);
        assertEq(governor.getCurrentCirculatingSupply(), totalSupply - nonCirculating);
    }

    function test_addNonCirculatingAddress() public {
        vm.prank(address(timelock));
        governor.addNonCirculatingAddress(user2);
        
        assertTrue(governor.nonCirculatingAddresses(user2));
        assertEq(governor.getNonCirculatingAddressesCount(), 2);
    }

    function test_addNonCirculatingAddress_Unauthorized() public {
        vm.expectRevert(abi.encodeWithSelector(GovGovernor.OnlyTimelock.selector, address(this), address(timelock)));
        governor.addNonCirculatingAddress(user2);
    }

    function test_addNonCirculatingAddress_Duplicate() public {
        vm.prank(address(timelock));
        vm.expectRevert(abi.encodeWithSelector(GovGovernor.DuplicateAddress.selector, user1));
        governor.addNonCirculatingAddress(user1);
    }

    function test_removeNonCirculatingAddress() public {
        vm.prank(address(timelock));
        governor.removeNonCirculatingAddress(user1);
        
        assertFalse(governor.nonCirculatingAddresses(user1));
        assertEq(governor.getNonCirculatingAddressesCount(), 0);
    }

    function test_removeNonCirculatingAddress_Unauthorized() public {
        vm.expectRevert(abi.encodeWithSelector(GovGovernor.OnlyTimelock.selector, address(this), address(timelock)));
        governor.removeNonCirculatingAddress(user1);
    }

    function test_removeNonCirculatingAddress_NotFound() public {
        vm.prank(address(timelock));
        vm.expectRevert(abi.encodeWithSelector(GovGovernor.AddressNotInList.selector, user2));
        governor.removeNonCirculatingAddress(user2);
    }

    function test_setAbsoluteQuorum() public {
        vm.prank(address(timelock));
        governor.setAbsoluteQuorum(5000000e18);
        assertEq(governor.absoluteQuorum(), 5000000e18);
    }

    function test_setAbsoluteQuorum_Unauthorized() public {
        vm.expectRevert(abi.encodeWithSelector(GovGovernor.OnlyTimelock.selector, address(this), address(timelock)));
        governor.setAbsoluteQuorum(5000000e18);
    }

    function test_setAbsoluteQuorum_Zero() public {
        vm.prank(address(timelock));
        vm.expectRevert(GovGovernor.QuorumMustBePositive.selector);
        governor.setAbsoluteQuorum(0);
    }
}
