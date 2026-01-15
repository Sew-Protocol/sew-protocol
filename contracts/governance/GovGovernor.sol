// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import "@openzeppelin/contracts/governance/Governor.sol";
import "@openzeppelin/contracts/governance/extensions/GovernorSettings.sol";
import "@openzeppelin/contracts/governance/extensions/GovernorCountingSimple.sol";
import "@openzeppelin/contracts/governance/extensions/GovernorVotes.sol";
import "@openzeppelin/contracts/governance/extensions/GovernorVotesQuorumFraction.sol";
import "@openzeppelin/contracts/governance/extensions/GovernorTimelockControl.sol";
import "@openzeppelin/contracts/governance/TimelockController.sol";

/**
 * @title GovGovernor
 * @notice OpenZeppelin Governor with TimelockControl for Sew Protocol DAO
 * @dev Combines multiple Governor extensions:
 * - GovernorSettings: voting delay, voting period, proposal threshold
 * - GovernorVotes: token-weighted voting
 * - GovernorVotesQuorumFraction: quorum based on token supply
 * - GovernorTimelockControl: execution via TimelockController
 * 
 * Configuration:
 * - Voting delay: 1 block (configurable, longer for mainnet)
 * - Voting period: ~1 week (configurable)
 * - Proposal threshold: 10M tokens (1% of supply, configurable)
 * - Quorum: 4% (configurable)
 * - Timelock: 48h delay for all executions
 */
contract GovGovernor is
    Governor,
    GovernorSettings,
    GovernorCountingSimple,
    GovernorVotes,
    GovernorVotesQuorumFraction,
    GovernorTimelockControl
{
    /**
     * @notice Deploy Governor with all extensions
     * @param token ERC20Votes token address (SewToken)
     * @param timelock TimelockController contract instance
     * @param votingDelayBlocks Voting delay in blocks
     * @param votingPeriodBlocks Voting period in blocks
     * @param proposalThresholdTokens Minimum tokens needed to propose
     * @param quorumBps Quorum numerator (denominator is 100, so 4 = 4%)
     */
    constructor(
        address token,
        TimelockController timelock,
        uint48 votingDelayBlocks,
        uint32 votingPeriodBlocks,
        uint256 proposalThresholdTokens,
        uint256 quorumBps
    )
        Governor("Sew Protocol DAO")
        GovernorSettings(votingDelayBlocks, votingPeriodBlocks, proposalThresholdTokens)
        GovernorVotes(IVotes(token))
        GovernorVotesQuorumFraction(quorumBps)
        GovernorTimelockControl(timelock)
    {
        // All configuration done via parent constructors
    }

    /**
     * @notice Required overrides for multiple inheritance
     */
    function votingDelay() public view override(Governor, GovernorSettings) returns (uint256) {
        return super.votingDelay();
    }

    function votingPeriod() public view override(Governor, GovernorSettings) returns (uint256) {
        return super.votingPeriod();
    }

    function proposalThreshold() public view override(Governor, GovernorSettings) returns (uint256) {
        return super.proposalThreshold();
    }

    function quorum(uint256 blockNumber)
        public
        view
        override(Governor, GovernorVotesQuorumFraction)
        returns (uint256)
    {
        return super.quorum(blockNumber);
    }

    function state(uint256 proposalId)
        public
        view
        override(Governor, GovernorTimelockControl)
        returns (ProposalState)
    {
        return super.state(proposalId);
    }

    function propose(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        string memory description
    ) public override(Governor) returns (uint256) {
        return super.propose(targets, values, calldatas, description);
    }

    function queue(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) public override returns (uint256) {
        return super.queue(targets, values, calldatas, descriptionHash);
    }

    function execute(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) public payable override returns (uint256) {
        return super.execute(targets, values, calldatas, descriptionHash);
    }

    function cancel(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) public override(Governor) returns (uint256) {
        return super.cancel(targets, values, calldatas, descriptionHash);
    }

    function proposalNeedsQueuing(uint256) public view override(Governor, GovernorTimelockControl) returns (bool) {
        return super.proposalNeedsQueuing(0);
    }

    function _queueOperations(
        uint256 proposalId,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(Governor, GovernorTimelockControl) returns (uint48) {
        return super._queueOperations(proposalId, targets, values, calldatas, descriptionHash);
    }

    function _executeOperations(
        uint256 proposalId,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(Governor, GovernorTimelockControl) {
        super._executeOperations(proposalId, targets, values, calldatas, descriptionHash);
    }

    function _cancel(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(Governor, GovernorTimelockControl) returns (uint256) {
        return super._cancel(targets, values, calldatas, descriptionHash);
    }

    function _executor() internal view override(Governor, GovernorTimelockControl) returns (address) {
        return super._executor();
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(Governor)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}

