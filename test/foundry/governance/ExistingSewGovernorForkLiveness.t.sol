// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import 'forge-std/Test.sol';
import '@openzeppelin/contracts/governance/IGovernor.sol';
import '@openzeppelin/contracts/governance/TimelockController.sol';
import '../../../contracts/governance/GovGovernor.sol';
import '../../../contracts/token/SewToken.sol';

/// @notice Local-only rehearsal against a pinned Base Sepolia fork.
/// @dev vm.prank changes only the fork's ephemeral state; no owner private key
///      is loaded and this test cannot broadcast transactions to Base Sepolia.
contract ExistingSewGovernorForkLivenessTest is Test {
    uint256 private constant BASE_SEPOLIA_CHAIN_ID = 84532;
    uint256 private constant FORK_BLOCK = 53_114_463;
    address private constant GOVERNOR_ADDRESS = 0xa9d598AE5b185dd249A1E4b64c32f18f4500d2fA;
    address private constant TOKEN_ADDRESS = 0x62BD47154D0b5Fe435F220E1294405040102b2ba;
    address private constant TIMELOCK_ADDRESS = 0xD62A6C62233357B6681F9410218FE53BA931fDD1;
    address private constant TOKEN_OWNER = 0xE8d7Fbd5Db3ad910370Be315f21D4596ed45122f;
    bytes32 private constant TIMELOCK_RUNTIME_HASH = 0x84e66431de7ae75cc22934e986105312a1640ebb89dd4ac566c4302e8e552078;

    uint256 private constant PROPOSAL_THRESHOLD = 5_000 ether;
    uint256 private constant ABSOLUTE_QUORUM = 4_000_000 ether;
    uint256 private constant VOTING_DELAY = 1;
    uint256 private constant VOTING_PERIOD = 45_818;
    uint256 private constant TIMELOCK_DELAY = 172_800;

    function test_existingGovernorDelegationProposalQuorumAndTimelockPathOnFork() public {
        vm.createSelectFork('https://sepolia.base.org', FORK_BLOCK);
        assertEq(block.chainid, BASE_SEPOLIA_CHAIN_ID, 'fork must retain Base Sepolia chain ID');
        assertEq(block.number, FORK_BLOCK, 'fork must use the pinned observation block');

        GovGovernor governor = GovGovernor(payable(GOVERNOR_ADDRESS));
        SewToken token = SewToken(TOKEN_ADDRESS);
        TimelockController timelock = TimelockController(payable(TIMELOCK_ADDRESS));

        assertEq(address(governor.token()), TOKEN_ADDRESS, 'Governor.token getter mismatch');
        assertEq(address(governor.timelock()), TIMELOCK_ADDRESS, 'Governor.timelock getter mismatch');
        assertEq(token.owner(), TOKEN_OWNER, 'token owner changed; refresh the liveness review');
        assertEq(token.totalSupply(), 1_000_000_000 ether, 'token supply changed');
        assertEq(token.balanceOf(TOKEN_OWNER), 999_992_120 ether, 'owner balance changed; refresh the liveness review');
        assertEq(token.delegates(TOKEN_OWNER), address(0), 'owner already delegates; refresh the expected initial state');
        assertEq(token.getVotes(TOKEN_OWNER), 0, 'owner already has votes; refresh the expected initial state');
        assertEq(governor.proposalThreshold(), PROPOSAL_THRESHOLD, 'proposal threshold changed');
        assertEq(governor.absoluteQuorum(), ABSOLUTE_QUORUM, 'absolute quorum changed');
        assertEq(governor.votingDelay(), VOTING_DELAY, 'voting delay changed');
        assertEq(governor.votingPeriod(), VOTING_PERIOD, 'voting period changed');
        assertEq(timelock.getMinDelay(), TIMELOCK_DELAY, 'Timelock delay changed');
        assertEq(keccak256(TIMELOCK_ADDRESS.code), TIMELOCK_RUNTIME_HASH, 'Timelock runtime pin changed');
        assertTrue(timelock.hasRole(timelock.PROPOSER_ROLE(), GOVERNOR_ADDRESS), 'Governor lacks Timelock proposer role');
        assertTrue(timelock.hasRole(timelock.CANCELLER_ROLE(), GOVERNOR_ADDRESS), 'Governor lacks Timelock canceller role');
        assertTrue(timelock.hasRole(timelock.EXECUTOR_ROLE(), address(0)), 'Timelock executor is no longer open');
        assertTrue(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), TIMELOCK_ADDRESS), 'Timelock is not self-administered');

        uint256 ownerBalance = token.balanceOf(TOKEN_OWNER);
        assertGe(ownerBalance, PROPOSAL_THRESHOLD, 'owner balance cannot meet proposal threshold');
        assertGe(ownerBalance, ABSOLUTE_QUORUM, 'owner balance cannot meet quorum');

        // This impersonation and state change exist only inside the fork.
        vm.startPrank(TOKEN_OWNER);
        token.delegate(TOKEN_OWNER);
        vm.stopPrank();
        vm.roll(block.number + 2);
        assertEq(token.getVotes(TOKEN_OWNER), ownerBalance, 'self-delegation did not checkpoint the owner balance');

        address[] memory targets = new address[](1);
        targets[0] = GOVERNOR_ADDRESS;
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        // A no-op governance action proves successful execution through both
        // Governor and Timelock without changing governance settings.
        calldatas[0] = abi.encodeCall(GovGovernor.setAbsoluteQuorum, (ABSOLUTE_QUORUM));
        string memory description = 'Local fork liveness rehearsal: retain the existing quorum';
        bytes32 descriptionHash = keccak256(bytes(description));
        uint256 proposalId = governor.hashProposal(targets, values, calldatas, descriptionHash);

        vm.prank(TOKEN_OWNER);
        governor.propose(targets, values, calldatas, description);
        vm.roll(governor.proposalSnapshot(proposalId) + 1);
        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Active), 'proposal did not become active');

        vm.prank(TOKEN_OWNER);
        governor.castVote(proposalId, 1); // GovernorCountingSimple.VoteType.For
        vm.roll(governor.proposalDeadline(proposalId) + 1);
        (uint256 againstVotes, uint256 forVotes, uint256 abstainVotes) = governor.proposalVotes(proposalId);
        assertEq(againstVotes, 0, 'unexpected against votes in isolated rehearsal');
        assertGe(forVotes + abstainVotes, ABSOLUTE_QUORUM, 'cast votes did not reach quorum');
        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Succeeded), 'proposal did not succeed');

        governor.queue(targets, values, calldatas, descriptionHash);
        vm.warp(block.timestamp + TIMELOCK_DELAY + 1);
        governor.execute(targets, values, calldatas, descriptionHash);
        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Executed), 'Timelocked proposal did not execute');
        assertEq(governor.absoluteQuorum(), ABSOLUTE_QUORUM, 'no-op proposal changed the configured quorum');
    }
}
