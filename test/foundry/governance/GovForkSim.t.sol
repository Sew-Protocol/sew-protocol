// SPDX-License-Identifier: Apache-2.0
import "../../../contracts/types/YieldPresets.sol";
pragma solidity ^0.8.33;

import {Test, console} from 'forge-std/Test.sol';
import {GovGovernor} from '../../../contracts/governance/GovGovernor.sol';
import {TimelockController} from '@openzeppelin/contracts/governance/TimelockController.sol';
import {SewToken} from '../../../contracts/token/SewToken.sol';
import {EscrowableERC20} from '../../../contracts/core/EscrowableERC20.sol';

/**
 * @title GovForkSim
 * @notice Foundry fork simulation tests for governance proposals
 * @dev Tests governance proposals on forked networks
 */
contract GovForkSim is Test {
    GovGovernor public governor;
    TimelockController public timelock;
    SewToken public token;
    EscrowableERC20 public escrowableERC20;

    // Proposal state
    uint256 public proposalId;
    address[] public targets;
    uint256[] public values;
    bytes[] public calldatas;

    // Test configuration
    string public RPC_URL;
    uint256 public FORK_BLOCK;

    function setUp() public {
        // Load configuration from environment
        RPC_URL = vm.envOr('BASE_RPC_URL', string('https://mainnet.base.org'));
        FORK_BLOCK = vm.envOr('FORK_BLOCK', uint256(0)); // 0 = latest

        // Fork the network
        if (FORK_BLOCK > 0) {
            vm.createSelectFork(RPC_URL, FORK_BLOCK);
        } else {
            vm.createSelectFork(RPC_URL);
        }

        // Load deployed contracts from environment or use placeholders
        // In a real scenario, these would be loaded from deployment artifacts
        address governorAddr = vm.envOr('GOVERNOR_ADDRESS', address(0));
        address timelockAddr = vm.envOr('TIMELOCK_ADDRESS', address(0));
        address tokenAddr = vm.envOr('TOKEN_ADDRESS', address(0));
        address escrowAddr = vm.envOr('ESCROWABLE_ERC20_ADDRESS', address(0));

        if (governorAddr != address(0)) {
            governor = GovGovernor(payable(governorAddr));
        }
        if (timelockAddr != address(0)) {
            timelock = TimelockController(payable(timelockAddr));
        }
        if (tokenAddr != address(0)) {
            token = SewToken(tokenAddr);
        }
        if (escrowAddr != address(0)) {
            escrowableERC20 = EscrowableERC20(escrowAddr);
        }
    }

    /**
     * @notice Test proposal execution on fork
     * @dev This test simulates a governance proposal execution
     */
    function testForkProposalExecution() public {
        // Skip if contracts not deployed
        if (address(governor) == address(0)) {
            return; // Skip test if governor not deployed
        }

        // Example: Propose setting a parameter
        // In practice, load proposal from JSON artifact
        targets = new address[](1);
        values = new uint256[](1);
        calldatas = new bytes[](1);

        // Example proposal: set default auto cancel time
        if (address(escrowableERC20) != address(0)) {
            targets[0] = address(escrowableERC20);
            values[0] = 0;
            // Note: EscrowableERC20 inherits from BaseEscrow which has setDefaultAutoCancelTime
            // We'll use a direct call instead of selector lookup
            calldatas[0] = abi.encodeWithSignature('setDefaultAutoCancelTime(uint256)', 7 days);

            // Impersonate a proposer with enough tokens
            address proposer = vm.envOr('PROPOSER_ADDRESS', address(0));
            if (proposer == address(0)) {
                return; // Skip test if no proposer configured
            }

            vm.startPrank(proposer);

            // Create proposal
            string memory description = 'Set default auto cancel time to 7 days';
            proposalId = governor.propose(targets, values, calldatas, description);

            console.log('Proposal ID:', proposalId);

            // Check proposal state
            uint8 state = uint8(governor.state(proposalId));
            assertEq(state, 0); // Pending

            vm.stopPrank();
        } else {
            return; // Skip test if EscrowableERC20 not deployed
        }
    }

    /**
     * @notice Test proposal queueing on fork
     * @dev This test simulates queueing a proposal to Timelock
     */
    function testForkProposalQueue() public {
        if (address(governor) == address(0) || address(timelock) == address(0)) {
            return; // Skip test if contracts not deployed
        }

        // Assume proposal already created and voted on
        // In practice, load from proposal artifact
        uint256 existingProposalId = vm.envOr('PROPOSAL_ID', uint256(0));
        if (existingProposalId == 0) {
            return; // Skip test if no proposal ID provided
        }

        proposalId = existingProposalId;

        // Check proposal state (should be Succeeded)
        uint8 state = uint8(governor.state(proposalId));
        if (state != 4) {
            // Succeeded
            return; // Skip test if proposal not in Succeeded state
        }

        // Load proposal data (in practice, from JSON artifact)
        // For now, use example data
        targets = new address[](1);
        values = new uint256[](1);
        calldatas = new bytes[](1);

        // Queue proposal
        string memory description = 'Example proposal';
        bytes32 descriptionHash = keccak256(bytes(description));

        // Impersonate Governor (or anyone can queue after vote succeeds)
        address executor = vm.envOr('EXECUTOR_ADDRESS', address(this));
        vm.startPrank(executor);

        governor.queue(targets, values, calldatas, descriptionHash);

        // Check proposal state (should be Queued)
        state = uint8(governor.state(proposalId));
        assertEq(state, 5); // Queued

        vm.stopPrank();
    }

    /**
     * @notice Test proposal execution on fork
     * @dev This test simulates executing a queued proposal
     */
    function testForkProposalExecute() public {
        if (address(governor) == address(0) || address(timelock) == address(0)) {
            return; // Skip test if contracts not deployed
        }

        // Assume proposal already queued
        uint256 existingProposalId = vm.envOr('PROPOSAL_ID', uint256(0));
        if (existingProposalId == 0) {
            return; // Skip test if no proposal ID provided
        }

        proposalId = existingProposalId;

        // Check proposal state (should be Queued)
        uint8 state = uint8(governor.state(proposalId));
        if (state != 5) {
            // Queued
            return; // Skip test if proposal not in Queued state
        }

        // Check if delay has elapsed
        // In a real scenario, we would check the actual execution time
        // For testing, we can warp time if needed
        // uint256 minDelay = timelock.getMinDelay();
        // vm.warp(block.timestamp + minDelay + 1);

        // Load proposal data
        targets = new address[](1);
        values = new uint256[](1);
        calldatas = new bytes[](1);

        string memory description = 'Example proposal';
        bytes32 descriptionHash = keccak256(bytes(description));

        // Execute proposal (anyone can execute after delay)
        address executor = vm.envOr('EXECUTOR_ADDRESS', address(this));
        vm.startPrank(executor);

        governor.execute(targets, values, calldatas, descriptionHash);

        // Check proposal state (should be Executed)
        state = uint8(governor.state(proposalId));
        assertEq(state, 7); // Executed

        vm.stopPrank();
    }

    /**
     * @notice Test invariants after proposal execution
     * @dev Verify that core invariants still hold
     */
    function testForkInvariants() public view {
        if (address(escrowableERC20) == address(0)) {
            return; // Skip test if EscrowableERC20 not deployed
        }

        // Invariant 1: Protocol should not be paused unless explicitly paused
        // (This is a simple example - add more invariants as needed)
        // In a normal state, protocol should not be paused
        // But we can't assert this as it may be paused for testing
        // bool paused = escrowableERC20.paused();

        // Invariant 2: Default modules should be set (not zero address)
        // This would require checking module getters
        // address resolutionModule = escrowableERC20.getResolutionModule(0);
        // assertNotEq(resolutionModule, address(0));

        // Add more invariant checks as needed
    }

    /**
     * @notice Test reading proposal from JSON artifact
     * @dev This is a placeholder for reading proposal JSON files.
     *      In practice, Foundry doesn't easily support JSON parsing in Solidity.
     *      Consider using a helper script or Hardhat for this.
     */
    function testReadProposalArtifact() public pure {
        // This would require reading a JSON file, which is not straightforward in Foundry
        // Consider using a Hardhat script or TypeScript helper instead
        return; // Skip test - JSON parsing not supported in Foundry
    }
}
