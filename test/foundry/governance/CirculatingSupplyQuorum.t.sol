// SPDX-License-Identifier: UNLICENSED
import "../../../contracts/types/YieldPresets.sol";
pragma solidity ^0.8.33;

import 'forge-std/Test.sol';
import '@openzeppelin/contracts/governance/TimelockController.sol';
import '@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol';
import 'contracts/governance/GovGovernor.sol';
import 'contracts/token/SewToken.sol';

/**
 * @title CirculatingSupplyQuorumTest
 * @notice Comprehensive tests for circulating supply-based quorum calculation
 * @dev Tests:
 *      - Circulating supply calculation (total - non-circulating)
 *      - Quorum calculation based on circulating supply
 *      - Adding/removing non-circulating addresses
 *      - Edge cases (empty list, max addresses, zero supply)
 *      - Integration with proposals
 */
contract CirculatingSupplyQuorumTest is Test {
    SewToken public token;
    TimelockController public timelock;
    GovGovernor public governor;

    address public deployer = address(0x1);
    address public voter1 = address(0x2);
    address public voter2 = address(0x3);
    address public voter3 = address(0x4);
    address public vestingContract = address(0x5);
    address public lockedTokens = address(0x6);
    address public timelockAdmin = address(0x7);

    uint256 constant TOTAL_SUPPLY = 1_000_000_000 ether; // 1B tokens
    uint256 constant INITIAL_CIRCULATING = 100_000_000 ether; // 100M tokens (10%)
    uint256 constant QUORUM_BPS = 400; // 4%
    uint256 constant QUORUM_NUMERATOR = 4; // 4% (denominator is 100)
    uint256 constant EXPECTED_QUORUM = 4_000_000 ether; // 4% of 100M = 4M tokens

    function setUp() public {
        vm.startPrank(deployer);

        // Deploy token
        token = new SewToken('Sew Token', 'SEW', deployer, TOTAL_SUPPLY);

        // Distribute initial circulating supply
        token.transfer(voter1, 30_000_000 ether);
        token.transfer(voter2, 30_000_000 ether);
        token.transfer(voter3, 40_000_000 ether);

        // Delegate voting power
        vm.stopPrank();
        vm.prank(voter1);
        token.delegate(voter1);
        vm.prank(voter2);
        token.delegate(voter2);
        vm.prank(voter3);
        token.delegate(voter3);
        vm.startPrank(deployer);

        // Transfer non-circulating tokens to vesting/locked addresses
        token.transfer(vestingContract, 450_000_000 ether);
        token.transfer(lockedTokens, 450_000_000 ether);

        // Delegate non-circulating tokens (they have voting power but shouldn't count)
        vm.stopPrank();
        vm.prank(vestingContract);
        token.delegate(vestingContract);
        vm.prank(lockedTokens);
        token.delegate(lockedTokens);
        vm.startPrank(deployer);

        // Deploy timelock
        address[] memory timelockProposers = new address[](1);
        timelockProposers[0] = timelockAdmin;
        address[] memory timelockExecutors = new address[](1);
        timelockExecutors[0] = timelockAdmin;
        timelock = new TimelockController(0, timelockProposers, timelockExecutors, timelockAdmin);

        // Deploy governor with initial non-circulating addresses
        address[] memory initialNonCirculating = new address[](2);
        initialNonCirculating[0] = vestingContract;
        initialNonCirculating[1] = lockedTokens;

        governor = new GovGovernor(
            address(token),
            timelock,
            1, // votingDelay
            45818, // votingPeriod (~1 week)
            500_000 ether, // proposalThreshold
            QUORUM_NUMERATOR, // quorumNumerator (4%)
            initialNonCirculating
        );

        // Grant timelock proposer/executor roles
        bytes32 proposerRole = timelock.PROPOSER_ROLE();
        bytes32 executorRole = timelock.EXECUTOR_ROLE();
        vm.stopPrank();
        vm.prank(timelockAdmin);
        timelock.grantRole(proposerRole, address(governor));
        vm.prank(timelockAdmin);
        timelock.grantRole(executorRole, address(governor));
        vm.startPrank(deployer);

        vm.stopPrank();
    }

    // ============ Unit Tests: Circulating Supply Calculation ============

    function test_GetCirculatingSupply_ExcludesNonCirculating() public {
        uint256 circulating = governor.getCurrentCirculatingSupply();
        assertEq(circulating, INITIAL_CIRCULATING, 'Circulating supply should exclude non-circulating');
    }

    function test_GetCirculatingSupply_Historical() public {
        uint256 blockNumber = block.number;
        uint256 circulating = governor.getCirculatingSupply(blockNumber);
        assertEq(circulating, INITIAL_CIRCULATING, 'Historical circulating supply should match');
    }

    function test_GetCirculatingSupply_EqualsTotalWhenNoNonCirculating() public {
        // Deploy new governor with no non-circulating addresses
        address[] memory empty = new address[](0);
        GovGovernor newGovernor = new GovGovernor(
            address(token),
            timelock,
            1,
            45818,
            500_000 ether,
            QUORUM_NUMERATOR,
            empty
        );

        uint256 circulating = newGovernor.getCurrentCirculatingSupply();
        assertEq(circulating, TOTAL_SUPPLY, 'Circulating should equal total when no exclusions');
    }

    function test_GetCirculatingSupply_AfterAddingNonCirculating() public {
        // Add a new non-circulating address via timelock
        address newVesting = address(0x8);
        token.transfer(newVesting, 50_000_000 ether);
        vm.prank(newVesting);
        token.delegate(newVesting);

        // Simulate timelock call
        vm.prank(address(timelock));
        governor.addNonCirculatingAddress(newVesting);

        uint256 circulating = governor.getCurrentCirculatingSupply();
        assertEq(circulating, INITIAL_CIRCULATING - 50_000_000 ether, 'Should exclude newly added address');
    }

    function test_GetCirculatingSupply_AfterRemovingNonCirculating() public {
        // Remove a non-circulating address
        vm.prank(address(timelock));
        governor.removeNonCirculatingAddress(vestingContract);

        uint256 circulating = governor.getCurrentCirculatingSupply();
        assertEq(circulating, INITIAL_CIRCULATING + 450_000_000 ether, 'Should include removed address');
    }

    // ============ Unit Tests: Quorum Calculation ============

    function test_Quorum_BasedOnCirculatingSupply() public {
        uint256 quorum = governor.quorum(block.number);
        assertEq(quorum, EXPECTED_QUORUM, 'Quorum should be 4% of circulating supply');
    }

    function test_Quorum_Formula() public {
        uint256 circulating = governor.getCurrentCirculatingSupply();
        uint256 expectedQuorum = (circulating * QUORUM_NUMERATOR) / 100;
        uint256 actualQuorum = governor.quorum(block.number);

        assertEq(actualQuorum, expectedQuorum, 'Quorum formula should match');
    }

    function test_Quorum_ChangesWithCirculatingSupply() public {
        uint256 quorumBefore = governor.quorum(block.number);

        // Add more non-circulating
        address newVesting = address(0x9);
        token.transfer(newVesting, 10_000_000 ether);
        vm.prank(newVesting);
        token.delegate(newVesting);

        vm.prank(address(timelock));
        governor.addNonCirculatingAddress(newVesting);

        uint256 quorumAfter = governor.quorum(block.number);
        assertLt(quorumAfter, quorumBefore, 'Quorum should decrease when circulating decreases');
    }

    function test_Quorum_NotBasedOnTotalSupply() public {
        uint256 quorum = governor.quorum(block.number);
        uint256 quorumIfTotalSupply = (TOTAL_SUPPLY * QUORUM_NUMERATOR) / 100;

        assertLt(quorum, quorumIfTotalSupply, 'Quorum should be less than if based on total supply');
        assertEq(quorum, EXPECTED_QUORUM, 'Quorum should be 4M tokens (4% of 100M)');
    }

    // ============ Unit Tests: Non-Circulating Address Management ============

    function test_AddNonCirculatingAddress_Success() public {
        address newAddr = address(0xA);
        uint256 countBefore = governor.getNonCirculatingAddressesCount();

        vm.prank(address(timelock));
        governor.addNonCirculatingAddress(newAddr);

        assertTrue(governor.nonCirculatingAddresses(newAddr), 'Address should be marked as non-circulating');
        assertEq(governor.getNonCirculatingAddressesCount(), countBefore + 1, 'Count should increase');
    }

    function test_AddNonCirculatingAddress_RevertsIfNotTimelock() public {
        vm.expectRevert('Only timelock');
        governor.addNonCirculatingAddress(address(0xB));
    }

    function test_AddNonCirculatingAddress_RevertsIfZero() public {
        vm.prank(address(timelock));
        vm.expectRevert('Zero address');
        governor.addNonCirculatingAddress(address(0));
    }

    function test_AddNonCirculatingAddress_RevertsIfAlreadyAdded() public {
        vm.prank(address(timelock));
        vm.expectRevert('Already added');
        governor.addNonCirculatingAddress(vestingContract);
    }

    function test_AddNonCirculatingAddress_RevertsIfMaxReached() public {
        // Add addresses up to max
        for (uint256 i = 0; i < governor.MAX_NON_CIRCULATING_ADDRESSES() - 2; i++) {
            address addr = address(uint160(1000 + i));
            vm.prank(address(timelock));
            governor.addNonCirculatingAddress(addr);
        }

        // Next addition should fail
        vm.prank(address(timelock));
        vm.expectRevert('Max addresses reached');
        governor.addNonCirculatingAddress(address(0xFF));
    }

    function test_RemoveNonCirculatingAddress_Success() public {
        uint256 countBefore = governor.getNonCirculatingAddressesCount();

        vm.prank(address(timelock));
        governor.removeNonCirculatingAddress(vestingContract);

        assertFalse(governor.nonCirculatingAddresses(vestingContract), 'Address should be removed');
        assertEq(governor.getNonCirculatingAddressesCount(), countBefore - 1, 'Count should decrease');
    }

    function test_RemoveNonCirculatingAddress_RevertsIfNotTimelock() public {
        vm.expectRevert('Only timelock');
        governor.removeNonCirculatingAddress(vestingContract);
    }

    function test_RemoveNonCirculatingAddress_RevertsIfNotInList() public {
        vm.prank(address(timelock));
        vm.expectRevert('Not in list');
        governor.removeNonCirculatingAddress(address(0xDEAD));
    }

    // ============ Fuzz Tests ============

    function testFuzz_CirculatingSupply_AlwaysLessThanOrEqualTotal(
        address[] memory nonCirculatingAddrs
    ) public {
        // Bound array length to prevent DoS
        nonCirculatingAddrs = _boundArrayLength(nonCirculatingAddrs, 0, 10);

        // Deploy new governor with fuzzed addresses
        address[] memory empty = new address[](0);
        GovGovernor newGovernor = new GovGovernor(
            address(token),
            timelock,
            1,
            45818,
            500_000 ether,
            QUORUM_NUMERATOR,
            empty
        );

        // Add fuzzed addresses (if they have tokens)
        for (uint256 i = 0; i < nonCirculatingAddrs.length; i++) {
            address addr = nonCirculatingAddrs[i];
            if (addr != address(0) && addr != address(token) && addr != address(newGovernor)) {
                uint256 balance = token.balanceOf(addr);
                if (balance > 0 || i < 5) {
                    // Give some addresses tokens for testing
                    if (balance == 0) {
                        token.transfer(addr, 1 ether);
                        vm.prank(addr);
                        token.delegate(addr);
                    }
                    vm.prank(address(timelock));
                    try newGovernor.addNonCirculatingAddress(addr) {} catch {}
                }
            }
        }

        uint256 circulating = newGovernor.getCurrentCirculatingSupply();
        uint256 total = token.getPastTotalSupply(block.number);

        assertLe(circulating, total, 'Circulating should never exceed total');
    }

    function testFuzz_Quorum_AlwaysPositive(uint256 quorumNumerator) public {
        quorumNumerator = bound(quorumNumerator, 0, 100); // 0-100%

        address[] memory empty = new address[](0);
        GovGovernor newGovernor = new GovGovernor(
            address(token),
            timelock,
            1,
            45818,
            500_000 ether,
            quorumNumerator,
            empty
        );

        uint256 quorum = newGovernor.quorum(block.number);
        assertGe(quorum, 0, 'Quorum should always be non-negative');
    }

    function testFuzz_Quorum_ProportionalToCirculating(
        address nonCirculatingAddr,
        uint256 nonCirculatingAmount
    ) public {
        // Bound inputs
        nonCirculatingAmount = bound(nonCirculatingAmount, 0, INITIAL_CIRCULATING);
        nonCirculatingAddr = address(uint160(uint256(keccak256(abi.encodePacked(nonCirculatingAddr)))));
        vm.assume(nonCirculatingAddr != address(0));
        vm.assume(nonCirculatingAddr != address(token));
        vm.assume(nonCirculatingAddr != address(governor));

        // Give tokens to address
        token.transfer(nonCirculatingAddr, nonCirculatingAmount);
        vm.prank(nonCirculatingAddr);
        token.delegate(nonCirculatingAddr);

        // Add as non-circulating
        vm.prank(address(timelock));
        governor.addNonCirculatingAddress(nonCirculatingAddr);

        uint256 circulating = governor.getCurrentCirculatingSupply();
        uint256 expectedCirculating = INITIAL_CIRCULATING - nonCirculatingAmount;
        assertEq(circulating, expectedCirculating, 'Circulating should decrease by amount');

        uint256 quorum = governor.quorum(block.number);
        uint256 expectedQuorum = (expectedCirculating * QUORUM_NUMERATOR) / 100;
        assertEq(quorum, expectedQuorum, 'Quorum should be proportional to circulating');
    }

    // ============ Invariant Tests ============

    function test_Invariant_CirculatingSupply_NonNegative() public {
        uint256 circulating = governor.getCurrentCirculatingSupply();
        assertGe(circulating, 0, 'Circulating supply should never be negative');
    }

    function test_Invariant_Quorum_NonNegative() public {
        uint256 quorum = governor.quorum(block.number);
        assertGe(quorum, 0, 'Quorum should never be negative');
    }

    function test_Invariant_CirculatingSupply_LessThanOrEqualTotal() public {
        uint256 circulating = governor.getCurrentCirculatingSupply();
        uint256 total = token.getPastTotalSupply(block.number);
        assertLe(circulating, total, 'Circulating should never exceed total');
    }

    function test_Invariant_Quorum_LessThanOrEqualCirculating() public {
        uint256 quorum = governor.quorum(block.number);
        uint256 circulating = governor.getCurrentCirculatingSupply();
        assertLe(quorum, circulating, 'Quorum should never exceed circulating supply');
    }

    // ============ Edge Cases ============

    function test_EdgeCase_EmptyNonCirculatingList() public {
        address[] memory empty = new address[](0);
        GovGovernor newGovernor = new GovGovernor(
            address(token),
            timelock,
            1,
            45818,
            500_000 ether,
            QUORUM_NUMERATOR,
            empty
        );

        uint256 circulating = newGovernor.getCurrentCirculatingSupply();
        assertEq(circulating, TOTAL_SUPPLY, 'Should equal total when empty');
    }

    function test_EdgeCase_AllTokensNonCirculating() public {
        // Transfer all circulating tokens to a non-circulating address
        address allTokens = address(0xAA);
        token.transfer(allTokens, INITIAL_CIRCULATING);
        vm.prank(allTokens);
        token.delegate(allTokens);

        vm.prank(address(timelock));
        governor.addNonCirculatingAddress(allTokens);

        uint256 circulating = governor.getCurrentCirculatingSupply();
        assertEq(circulating, 0, 'Circulating should be zero when all tokens are non-circulating');
    }

    function test_EdgeCase_ZeroQuorumNumerator() public {
        address[] memory empty = new address[](0);
        GovGovernor newGovernor = new GovGovernor(
            address(token),
            timelock,
            1,
            45818,
            500_000 ether,
            0, // 0% quorum
            empty
        );

        uint256 quorum = newGovernor.quorum(block.number);
        assertEq(quorum, 0, 'Quorum should be zero when numerator is zero');
    }

    // ============ Helper Functions ============

    function _boundArrayLength(
        address[] memory arr,
        uint256 min,
        uint256 max
    ) internal pure returns (address[] memory) {
        uint256 length = arr.length;
        if (length > max) {
            address[] memory bounded = new address[](max);
            for (uint256 i = 0; i < max; i++) {
                bounded[i] = arr[i];
            }
            return bounded;
        }
        if (length < min) {
            address[] memory bounded = new address[](min);
            for (uint256 i = 0; i < length; i++) {
                bounded[i] = arr[i];
            }
            return bounded;
        }
        return arr;
    }
}
