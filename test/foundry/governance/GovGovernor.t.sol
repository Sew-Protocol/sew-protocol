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

    function test_getCirculatingSupply_Historical() public {
        // user1 is non-circulating
        token.transfer(user1, 100000e18); // 100k to non-circulating
        
        // Delegate so that voting power is tracked for getPastVotes
        vm.prank(user1);
        token.delegate(user1);
        
        // Mine a block to checkpoint
        vm.roll(block.number + 1);
        
        // Mine more blocks
        vm.roll(block.number + 10);
        
        uint256 totalSupply = token.getPastTotalSupply(2);
        uint256 nonCirculating = token.getPastVotes(user1, 2);
        
        assertEq(governor.getCirculatingSupply(2), totalSupply - nonCirculating);
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

    function test_removeNonCirculatingAddress_Middle() public {
        vm.startPrank(address(timelock));
        governor.addNonCirculatingAddress(user2);
        address user3 = address(0x3);
        governor.addNonCirculatingAddress(user3);
        // List has [user1, user2, user3]
        
        governor.removeNonCirculatingAddress(user2);
        
        assertFalse(governor.nonCirculatingAddresses(user2));
        assertEq(governor.getNonCirculatingAddressesCount(), 2);
        // Should have [user1, user3]
        vm.stopPrank();
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

    // ============ Governor Overrides Tests ============

    function test_votingDelay() public {
        assertEq(governor.votingDelay(), 1);
    }

    function test_votingPeriod() public {
        assertEq(governor.votingPeriod(), 50400);
    }

    function test_proposalThreshold() public {
        assertEq(governor.proposalThreshold(), 1000e18);
    }

    function test_supportsInterface() public {
        assertTrue(governor.supportsInterface(0x01ffc9a7)); // IERC165
        // IGovernor interfaceId is 0x438595a1? Let's check if it's correct.
        // Or just check IERC6372 / IVotes
        assertTrue(governor.supportsInterface(type(IGovernor).interfaceId));
        assertFalse(governor.supportsInterface(0x12345678));
    }

    function test_executor() public {
        assertEq(address(governor.timelock()), address(timelock));
    }

    function test_proposalLifeCycle_Simple() public {
        // Need to give some tokens to proposer and delegate to self
        // Quorum is 4M. Give 5M.
        token.transfer(user2, 5000000e18);
        vm.startPrank(user2);
        token.delegate(user2);
        vm.roll(block.number + 1);
        
        address[] memory targets = new address[](1);
        targets[0] = address(governor);
        uint256[] memory values = new uint256[](1);
        values[0] = 0;
        bytes[] memory calldatas = new bytes[](1);
        // Call setAbsoluteQuorum(6M)
        calldatas[0] = abi.encodeWithSelector(GovGovernor.setAbsoluteQuorum.selector, 6000000e18);
        string memory description = "Set quorum to 6M";
        
        uint256 proposalId = governor.propose(targets, values, calldatas, description);
        assertEq(uint256(governor.state(proposalId)), uint256(IGovernor.ProposalState.Pending));
        
        vm.roll(block.number + governor.votingDelay() + 1);
        assertEq(uint256(governor.state(proposalId)), uint256(IGovernor.ProposalState.Active));
        
        governor.castVote(proposalId, 1); // For
        
        vm.roll(block.number + governor.votingPeriod() + 1);
        assertEq(uint256(governor.state(proposalId)), uint256(IGovernor.ProposalState.Succeeded));
        
        bytes32 descriptionHash = keccak256(bytes(description));
        governor.queue(targets, values, calldatas, descriptionHash);
        assertEq(uint256(governor.state(proposalId)), uint256(IGovernor.ProposalState.Queued));
        
        vm.warp(block.timestamp + timelock.getMinDelay() + 1);
        governor.execute(targets, values, calldatas, descriptionHash);
        assertEq(uint256(governor.state(proposalId)), uint256(IGovernor.ProposalState.Executed));
        
        assertEq(governor.absoluteQuorum(), 6000000e18);
        vm.stopPrank();
    }

    function test_cancelProposal() public {
        token.transfer(user2, 2000e18);
        vm.startPrank(user2);
        token.delegate(user2);
        vm.roll(block.number + 1);
        
        address[] memory targets = new address[](1);
        targets[0] = address(governor);
        uint256[] memory values = new uint256[](1);
        values[0] = 0;
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(GovGovernor.setAbsoluteQuorum.selector, 6000000e18);
        string memory description = "Cancel me";
        
        uint256 proposalId = governor.propose(targets, values, calldatas, description);
        
        governor.cancel(targets, values, calldatas, keccak256(bytes(description)));
        assertEq(uint256(governor.state(proposalId)), uint256(IGovernor.ProposalState.Canceled));
        vm.stopPrank();
    }

    function test_proposalNeedsQueuing() public {
        assertTrue(governor.proposalNeedsQueuing(1));
    }
}
