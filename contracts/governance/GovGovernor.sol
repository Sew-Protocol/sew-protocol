// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import '@openzeppelin/contracts/governance/Governor.sol';
import '@openzeppelin/contracts/governance/extensions/GovernorSettings.sol';
import '@openzeppelin/contracts/governance/extensions/GovernorCountingSimple.sol';
import '@openzeppelin/contracts/governance/extensions/GovernorVotes.sol';
import '@openzeppelin/contracts/governance/extensions/GovernorTimelockControl.sol';
import '@openzeppelin/contracts/governance/TimelockController.sol';
import '@openzeppelin/contracts/token/ERC20/IERC20.sol';

/**
 * @title GovGovernor
 * @notice OpenZeppelin Governor with TimelockControl for Sew Protocol DAO
 * @dev Combines multiple Governor extensions:
 * - GovernorSettings: voting delay, voting period, proposal threshold
 * - GovernorVotes: token-weighted voting
 * - GovernorTimelockControl: execution via TimelockController
 *
 * Quorum Calculation:
 * - Launch configuration uses an absolute quorum amount (e.g., 4,000,000 SEW).
 * - This avoids ambiguity around "circulating supply" definitions for quorum during launch.
 * - Non-circulating addresses are still tracked for transparency/APIs and future governance upgrades.
 *
 * Non-Circulating Token Tracking:
 * - Tracks addresses that hold non-circulating tokens (vesting, treasury, etc.)
 * - Used for external APIs (CoinGecko, CoinMarketCap) and transparency
 * - getCirculatingSupply() provides accurate circulating supply for reporting
 * - Can be migrated to circulating-based quorum later if desired (without losing tracking data)
 *
 * Configuration:
 * - Voting delay: 1 block (configurable, longer for mainnet)
 * - Voting period: ~1 week (configurable)
 * - Proposal threshold: 500k tokens (0.05% of supply, configurable)
 * - Quorum: Absolute amount (e.g., 4M tokens, configurable via governance)
 * - Timelock: 48h delay for all executions
 */
contract GovGovernor is
    Governor,
    GovernorSettings,
    GovernorCountingSimple,
    GovernorVotes,
    GovernorTimelockControl
{
    /// @notice Maximum number of non-circulating addresses (prevents DoS)
    uint256 public constant MAX_NON_CIRCULATING_ADDRESSES = 100;

    /// @notice Mapping of addresses that are considered non-circulating
    mapping(address => bool) public nonCirculatingAddresses;

    /// @notice Array of non-circulating addresses (for iteration)
    address[] public nonCirculatingAddressesList;

    /// @notice Event emitted when a non-circulating address is added
    event NonCirculatingAddressAdded(address indexed addr);

    /// @notice Event emitted when a non-circulating address is removed
    event NonCirculatingAddressRemoved(address indexed addr);

    /// @notice Absolute quorum amount in token units (e.g., 4,000,000e18 for 4M tokens).
    /// @dev Kept as `absoluteQuorum` for backwards compatibility with earlier naming.
    uint256 public absoluteQuorum;

    /// @notice Event emitted when absolute quorum amount is updated
    event AbsoluteQuorumUpdated(uint256 oldQuorum, uint256 newQuorum);

    // Custom errors
    error QuorumMustBePositive();
    error TooManyInitialAddresses(uint256 length, uint256 max);
    error ZeroAddress();
    error DuplicateAddress(address addr);
    error MaxAddressesReached();
    error AddressNotInList(address addr);
    error OnlyTimelock(address caller, address timelock);

    /**
     * @notice Deploy Governor with all extensions
     * @param token ERC20Votes token address (SewToken)
     * @param timelock TimelockController contract instance
     * @param votingDelayBlocks Voting delay in blocks
     * @param votingPeriodBlocks Voting period in blocks
     * @param proposalThresholdTokens Minimum tokens needed to propose
     * @param absoluteQuorumTokens Absolute quorum amount in token units (e.g., 4,000,000e18 for 4M tokens)
     * @param initialNonCirculatingAddresses Initial addresses to track for transparency/APIs (e.g., vesting contracts)
     */
    constructor(
        address token,
        TimelockController timelock,
        uint48 votingDelayBlocks,
        uint32 votingPeriodBlocks,
        uint256 proposalThresholdTokens,
        uint256 absoluteQuorumTokens,
        address[] memory initialNonCirculatingAddresses
    )
        Governor('Sew Protocol DAO')
        GovernorSettings(votingDelayBlocks, votingPeriodBlocks, proposalThresholdTokens)
        GovernorVotes(IVotes(token))
        GovernorTimelockControl(timelock)
    {
        if (absoluteQuorumTokens == 0) revert QuorumMustBePositive();
        absoluteQuorum = absoluteQuorumTokens;
        // Add initial non-circulating addresses
        uint256 length = initialNonCirculatingAddresses.length;
        if (length > MAX_NON_CIRCULATING_ADDRESSES) {
            revert TooManyInitialAddresses(length, MAX_NON_CIRCULATING_ADDRESSES);
        }
        
        for (uint256 i = 0; i < length; i++) {
            address addr = initialNonCirculatingAddresses[i];
            if (addr == address(0)) revert ZeroAddress();
            if (nonCirculatingAddresses[addr]) revert DuplicateAddress(addr);
            
            nonCirculatingAddresses[addr] = true;
            nonCirculatingAddressesList.push(addr);
            emit NonCirculatingAddressAdded(addr);
        }
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

    function proposalThreshold()
        public
        view
        override(Governor, GovernorSettings)
        returns (uint256)
    {
        return super.proposalThreshold();
    }

    /**
     * @notice Return the absolute quorum amount.
     * @return Quorum amount in token units
     * @dev For launch, quorum is an absolute amount (e.g., 4M tokens).
     *      Non-circulating tracking is preserved for reporting and future upgrades.
     */
    function quorum(
        uint256 blockNumber
    ) public view override(Governor) returns (uint256) {
        blockNumber; // silence unused warning; absolute quorum is block-independent
        return absoluteQuorum;
    }

    /**
     * @notice Get circulating supply at a specific block number
     * @param blockNumber Block number to calculate circulating supply for
     * @return Circulating supply = total supply - sum of tokens in non-circulating addresses
     * @dev Used for external APIs (CoinGecko, CoinMarketCap) and transparency
     *      NOT used for quorum calculation (quorum uses `absoluteQuorum`)
     *      For current block: uses balanceOf() (more accurate, works even if not delegated)
     *      For historical blocks: uses getPastVotes() (limitation of ERC20Votes)
     */
    function getCirculatingSupply(uint256 blockNumber) public view returns (uint256) {
        IVotes token = token();
        uint256 totalSupply;
        if (blockNumber >= block.number) {
            // Current (or future) block: use live ERC20 totalSupply to avoid ERC5805FutureLookup
            totalSupply = IERC20(address(token)).totalSupply();
            blockNumber = block.number;
        } else {
            totalSupply = token.getPastTotalSupply(blockNumber);
        }
        uint256 nonCirculating = 0;

        uint256 length = nonCirculatingAddressesList.length;
        for (uint256 i = 0; i < length; i++) {
            address addr = nonCirculatingAddressesList[i];
            if (nonCirculatingAddresses[addr]) {
                if (blockNumber == block.number) {
                    // For current block, use balance (more accurate)
                    // Works even if address hasn't delegated
                    nonCirculating += IERC20(address(token)).balanceOf(addr);
                } else {
                    // For historical blocks, use voting power (only available historical data)
                    // Limitation: If address didn't delegate at that block, tokens won't be excluded
                    nonCirculating += token.getPastVotes(addr, blockNumber);
                }
            }
        }

        // Circulating supply = total supply - non-circulating
        // Use unchecked for gas efficiency (nonCirculating <= totalSupply by design)
        unchecked {
            return totalSupply - nonCirculating;
        }
    }

    /**
     * @notice Get current circulating supply
     * @return Current circulating supply
     */
    function getCurrentCirculatingSupply() public view returns (uint256) {
        return getCirculatingSupply(block.number);
    }

    /**
     * @notice Add a non-circulating address (e.g., vesting contract, locked tokens)
     * @param addr Address to mark as non-circulating
     * @dev Can only be called by the timelock (via governance proposal)
     * @dev Reverts if address is zero, already added, or would exceed MAX_NON_CIRCULATING_ADDRESSES
     */
    function addNonCirculatingAddress(address addr) external {
        if (msg.sender != address(timelock())) {
            revert OnlyTimelock(msg.sender, address(timelock()));
        }
        if (addr == address(0)) revert ZeroAddress();
        if (nonCirculatingAddresses[addr]) revert DuplicateAddress(addr);
        if (nonCirculatingAddressesList.length >= MAX_NON_CIRCULATING_ADDRESSES) {
            revert MaxAddressesReached();
        }

        nonCirculatingAddresses[addr] = true;
        nonCirculatingAddressesList.push(addr);
        emit NonCirculatingAddressAdded(addr);
    }

    /**
     * @notice Remove a non-circulating address
     * @param addr Address to remove from non-circulating list
     * @dev Can only be called by the timelock (via governance proposal)
     * @dev Removes from mapping and array (swaps with last element for gas efficiency)
     */
    function removeNonCirculatingAddress(address addr) external {
        if (msg.sender != address(timelock())) {
            revert OnlyTimelock(msg.sender, address(timelock()));
        }
        if (!nonCirculatingAddresses[addr]) revert AddressNotInList(addr);

        // Remove from mapping
        delete nonCirculatingAddresses[addr];

        // Remove from array (swap with last element and pop)
        uint256 length = nonCirculatingAddressesList.length;
        for (uint256 i = 0; i < length; i++) {
            if (nonCirculatingAddressesList[i] == addr) {
                // Swap with last element
                nonCirculatingAddressesList[i] = nonCirculatingAddressesList[length - 1];
                // Pop last element
                nonCirculatingAddressesList.pop();
                break;
            }
        }

        emit NonCirculatingAddressRemoved(addr);
    }

    /**
     * @notice Get the number of non-circulating addresses
     * @return Number of addresses marked as non-circulating
     */
    function getNonCirculatingAddressesCount() external view returns (uint256) {
        return nonCirculatingAddressesList.length;
    }

    /**
     * @notice Update absolute quorum amount
     * @param newQuorum New absolute quorum amount in tokens
     * @dev Can only be called by the timelock (via governance proposal)
     * @dev Reverts if new quorum is zero
     */
    function setAbsoluteQuorum(uint256 newQuorum) external {
        if (msg.sender != address(timelock())) {
            revert OnlyTimelock(msg.sender, address(timelock()));
        }
        if (newQuorum == 0) revert QuorumMustBePositive();

        uint256 oldQuorum = absoluteQuorum;
        absoluteQuorum = newQuorum;
        emit AbsoluteQuorumUpdated(oldQuorum, newQuorum);
    }

    function state(
        uint256 proposalId
    ) public view override(Governor, GovernorTimelockControl) returns (ProposalState) {
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

    function proposalNeedsQueuing(
        uint256
    ) public view override(Governor, GovernorTimelockControl) returns (bool) {
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

    function _executor()
        internal
        view
        override(Governor, GovernorTimelockControl)
        returns (address)
    {
        return super._executor();
    }

    function supportsInterface(bytes4 interfaceId) public view override(Governor) returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}
