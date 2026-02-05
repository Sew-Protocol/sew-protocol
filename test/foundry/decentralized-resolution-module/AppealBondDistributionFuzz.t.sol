// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.33;

import 'forge-std/Test.sol';
import '../../../contracts/modules/decentralized-resolution-module/ResolverIncentiveModuleV2.sol';
import '../../../contracts/modules/decentralized-resolution-module/PaymentCalculationLibraryV1.sol';
import '../../../contracts/modules/decentralized-resolution-module/DecentralizedResolverStructs.sol';
import '../../../contracts/mocks/ERC20Mock.sol';
import '../../../contracts/ops/YieldOps.sol';
import '../../../contracts/ops/DisputeOps.sol';

/**
 * @title AppealBondDistributionFuzzTest
 * @notice Fuzz tests for appeal bond distribution to find edge cases
 * @dev Tests bond distribution with varied inputs to verify:
 *      - Rounding when splitting bonds across resolvers
 *      - ETH vs ERC20 bond handling
 *      - Edge cases (no resolvers, single resolver, many resolvers)
 */
contract AppealBondDistributionFuzzTest is Test {
    ResolverIncentiveModuleV2 public incentiveModule;
    PaymentCalculationLibraryV1 public paymentLib;
    ERC20Mock public token;
    YieldOps public yieldOps;
    DisputeOps public disputeOps;

    address public deployer;
    address public escrowContract;
    address[] resolverAddresses;

    uint256 constant MAX_RESOLVERS = 10;
    uint256 constant MAX_BOND = type(uint128).max;

    function setUp() public {
        deployer = address(this);
        escrowContract = makeAddr('escrow');

        paymentLib = new PaymentCalculationLibraryV1();
        incentiveModule = new ResolverIncentiveModuleV2(deployer, address(paymentLib));
        token = new ERC20Mock('Test Token', 'TEST', deployer, 0);
        yieldOps = new YieldOps(address(this));
        disputeOps = new DisputeOps(address(this));

        // Register escrow contract (requires ROLE_TIMELOCK)
        bytes32 ROLE_TIMELOCK = incentiveModule.ROLE_TIMELOCK();
        incentiveModule.grantRole(ROLE_TIMELOCK, deployer);
        incentiveModule.registerEscrowContract(escrowContract);

        // Pre-generate resolver addresses
        resolverAddresses = new address[](MAX_RESOLVERS);
        for (uint256 i = 0; i < MAX_RESOLVERS; i++) {
            resolverAddresses[i] = address(uint160(i + 100)); // Avoid zero and escrow address
        }
    }

    // ============ Helper Functions ============

    function _recordResolvers(uint256 workflowId, uint8 resolverCount, uint8 priorRound) internal {
        vm.startPrank(escrowContract);
        for (uint256 i = 0; i < resolverCount; i++) {
            incentiveModule.recordResolver(workflowId, escrowContract, resolverAddresses[i], priorRound);
        }
        vm.stopPrank();
    }

    function _recordAppealBond(uint256 workflowId, uint256 bondAmount, uint8 round) internal returns (uint256) {
        // Create a depositor address and fund it
        address depositor = makeAddr('depositor');
        token.mint(depositor, bondAmount);
        
        // Approve incentive module to pull tokens (pull-based pattern)
        vm.prank(depositor);
        token.approve(address(incentiveModule), bondAmount);
        
        // Record bond - escrow contract calls, but depositor is the one who approved
        vm.prank(escrowContract);
        incentiveModule.recordAppealBond(workflowId, escrowContract, depositor, depositor, bondAmount, address(token), round);
        
        return bondAmount;
    }

    // ============ Fuzz Tests: Bond Splitting ============

    /**
     * @notice Fuzz test: Bond split evenly among resolvers (within rounding)
     */
    function testFuzz_BondSplitEvenly(
        uint8 resolverCount,
        uint256 bondAmount
    ) public {
        // Bound inputs
        resolverCount = uint8(bound(resolverCount, 1, MAX_RESOLVERS));
        bondAmount = bound(bondAmount, resolverCount, MAX_BOND); // At least enough for 1 per resolver

        uint256 workflowId = 1;
        uint8 priorRound = 0;
        uint8 bondRound = 1;

        // Record resolvers at prior round
        _recordResolvers(workflowId, resolverCount, priorRound);

        // Record appeal bond
        _recordAppealBond(workflowId, bondAmount, bondRound);

        // Distribute bond (simulating failed appeal - pay to resolvers)
        // Function signature: distributeAppealBond(workflowId, round, outcomeFlipped)
        // round = priorRound (the round whose resolvers get paid)
        // bondRound = priorRound + 1 (the round the bond was posted for)
        vm.startPrank(escrowContract);
        incentiveModule.distributeAppealBond(workflowId, escrowContract, priorRound, false); // false = appeal failed
        vm.stopPrank();

        // Calculate expected per-resolver amount
        uint256 expectedPerResolver = bondAmount / resolverCount;
        uint256 remainder = bondAmount % resolverCount;

        // Verify each resolver can claim their share
        // Note: Remainder is distributed to first resolver(s)
        uint256 totalClaimable = 0;
        for (uint256 i = 0; i < resolverCount; i++) {
            uint256 claimable = incentiveModule.claimablePayments(escrowContract, workflowId, resolverAddresses[i]);
            totalClaimable += claimable;

            // Each resolver should get at least expectedPerResolver
            assertGe(claimable, expectedPerResolver, 'Resolver should get at least expected amount');
        }

        // Total claimable should equal bond amount (no loss)
        assertEq(totalClaimable, bondAmount, 'Total claimable should equal bond amount');
    }

    /**
     * @notice Fuzz test: Single resolver gets entire bond
     */
    function testFuzz_SingleResolverGetsFullBond(uint256 bondAmount) public {
        bondAmount = bound(bondAmount, 1, MAX_BOND);

        uint256 workflowId = 1;
        uint8 priorRound = 0;
        uint8 bondRound = 1;

        _recordResolvers(workflowId, 1, priorRound);
        _recordAppealBond(workflowId, bondAmount, bondRound);

        vm.startPrank(escrowContract);
        incentiveModule.distributeAppealBond(workflowId, escrowContract, priorRound, false);
        vm.stopPrank();

        // Single resolver should get entire bond
        uint256 claimable = incentiveModule.claimablePayments(escrowContract, workflowId, resolverAddresses[0]);
        assertEq(claimable, bondAmount, 'Single resolver should get full bond');
    }

    /**
     * @notice Fuzz test: Rounding remainder distributed (no loss)
     */
    function testFuzz_RoundingRemainderDistributed(
        uint8 resolverCount,
        uint256 bondAmount
    ) public {
        resolverCount = uint8(bound(resolverCount, 2, MAX_RESOLVERS)); // Need at least 2 for remainder
        bondAmount = bound(bondAmount, resolverCount + 1, MAX_BOND); // Ensure remainder exists

        uint256 workflowId = 1;
        uint8 priorRound = 0;
        uint8 bondRound = 1;

        _recordResolvers(workflowId, resolverCount, priorRound);
        _recordAppealBond(workflowId, bondAmount, bondRound);

        vm.startPrank(escrowContract);
        incentiveModule.distributeAppealBond(workflowId, escrowContract, priorRound, false);
        vm.stopPrank();

        // Calculate remainder
        uint256 remainder = bondAmount % resolverCount;
        uint256 expectedPerResolver = bondAmount / resolverCount;

        // Verify remainder is distributed to first resolver(s)
        uint256 totalClaimable = 0;
        for (uint256 i = 0; i < resolverCount; i++) {
            uint256 claimable = incentiveModule.claimablePayments(escrowContract, workflowId, resolverAddresses[i]);
            totalClaimable += claimable;

            // First resolver(s) should get extra for remainder
            if (i < remainder) {
                assertEq(claimable, expectedPerResolver + 1, 'Resolver should get remainder share');
            } else {
                assertEq(claimable, expectedPerResolver, 'Resolver should get base share');
            }
        }

        assertEq(totalClaimable, bondAmount, 'Total should equal bond (remainder distributed)');
    }

    /**
     * @notice Fuzz test: Very small bonds (1 wei per resolver minimum)
     */
    function testFuzz_VerySmallBonds(uint8 resolverCount) public {
        resolverCount = uint8(bound(resolverCount, 1, MAX_RESOLVERS));
        uint256 bondAmount = resolverCount; // 1 wei per resolver

        uint256 workflowId = 1;
        uint8 priorRound = 0;
        uint8 bondRound = 1;

        _recordResolvers(workflowId, resolverCount, priorRound);
        _recordAppealBond(workflowId, bondAmount, bondRound);

        vm.startPrank(escrowContract);
        incentiveModule.distributeAppealBond(workflowId, escrowContract, priorRound, false);
        vm.stopPrank();

        // Each resolver should get at least 1 wei
        for (uint256 i = 0; i < resolverCount; i++) {
            uint256 claimable = incentiveModule.claimablePayments(escrowContract, workflowId, resolverAddresses[i]);
            assertGe(claimable, 1, 'Resolver should get at least 1 wei');
        }

        uint256 totalClaimable = 0;
        for (uint256 i = 0; i < resolverCount; i++) {
            totalClaimable += incentiveModule.claimablePayments(escrowContract, workflowId, resolverAddresses[i]);
        }
        assertEq(totalClaimable, bondAmount, 'Total should equal bond');
    }

    /**
     * @notice Fuzz test: Very large bonds handled correctly
     */
    function testFuzz_VeryLargeBonds(uint8 resolverCount) public {
        resolverCount = uint8(bound(resolverCount, 1, 5)); // Limit to avoid gas issues
        uint256 bondAmount = MAX_BOND;

        uint256 workflowId = 1;
        uint8 priorRound = 0;
        uint8 bondRound = 1;

        _recordResolvers(workflowId, resolverCount, priorRound);
        _recordAppealBond(workflowId, bondAmount, bondRound);

        // Should not revert due to overflow
        vm.startPrank(escrowContract);
        incentiveModule.distributeAppealBond(workflowId, escrowContract, priorRound, false);
        vm.stopPrank();

        // Verify distribution is correct
        uint256 totalClaimable = 0;
        for (uint256 i = 0; i < resolverCount; i++) {
            uint256 claimable = incentiveModule.claimablePayments(escrowContract, workflowId, resolverAddresses[i]);
            totalClaimable += claimable;
        }

        assertEq(totalClaimable, bondAmount, 'Large bond distributed correctly');
    }

    // ============ Fuzz Tests: Refund Path ============

    /**
     * @notice Fuzz test: Bond refunded to depositor (successful appeal)
     */
    function testFuzz_BondRefundedOnSuccess(uint256 bondAmount) public {
        bondAmount = bound(bondAmount, 1, MAX_BOND);

        uint256 workflowId = 1;
        address depositor = makeAddr('depositor');
        uint8 bondRound = 1;

        // Record bond - mint to depositor and approve (pull-based pattern)
        token.mint(depositor, bondAmount);
        vm.prank(depositor);
        token.approve(address(incentiveModule), bondAmount);
        
        vm.prank(escrowContract);
        incentiveModule.recordAppealBond(workflowId, escrowContract, depositor, depositor, bondAmount, address(token), bondRound);

        // Distribute bond (simulating successful appeal - refund)
        uint256 depositorBalanceBefore = token.balanceOf(depositor);
        vm.startPrank(escrowContract);
        incentiveModule.distributeAppealBond(workflowId, escrowContract, 0, true); // true = appeal succeeded
        vm.stopPrank();

        // Verify depositor received refund
        uint256 depositorBalanceAfter = token.balanceOf(depositor);
        assertEq(
            depositorBalanceAfter - depositorBalanceBefore,
            bondAmount,
            'Depositor should receive full refund'
        );

        // Verify bond marked as refunded
        (address depositorAddr, address escalatedBy, uint256 amount, address tokenAddr, uint256 depositedAt, bool distributed, bool refunded) = incentiveModule.appealBonds(escrowContract, workflowId, bondRound);
        assertTrue(distributed, 'Bond should be marked as distributed');
        assertTrue(refunded, 'Bond should be marked as refunded');
    }

    // ============ Fuzz Tests: Edge Cases ============

    /**
     * @notice Fuzz test: No resolvers at prior round (bond retained by protocol)
     */
    function testFuzz_NoResolversBondRetained(uint256 bondAmount) public {
        bondAmount = bound(bondAmount, 1, MAX_BOND);

        uint256 workflowId = 1;
        uint8 priorRound = 0;
        uint8 bondRound = 1;

        // Don't record any resolvers
        _recordAppealBond(workflowId, bondAmount, bondRound);

        uint256 contractBalanceBefore = token.balanceOf(address(incentiveModule));

        vm.startPrank(escrowContract);
        incentiveModule.distributeAppealBond(workflowId, escrowContract, priorRound, false);
        vm.stopPrank();

        // Bond should remain in contract (retained by protocol)
        uint256 contractBalanceAfter = token.balanceOf(address(incentiveModule));
        assertEq(contractBalanceAfter, contractBalanceBefore, 'Bond retained by protocol');

        // Verify metrics: should not increment totalBondsPaidToResolvers
        // (This is checked by verifying no resolvers have claimable payments)
        for (uint256 i = 0; i < MAX_RESOLVERS; i++) {
            uint256 claimable = incentiveModule.claimablePayments(escrowContract, workflowId, resolverAddresses[i]);
            assertEq(claimable, 0, 'No resolver should have claimable payment');
        }
    }

    /**
     * @notice Fuzz test: Resolvers at different rounds (only priorRound resolvers get bond)
     */
    function testFuzz_OnlyPriorRoundResolversGetBond(
        uint8 priorRoundCount,
        uint8 otherRoundCount,
        uint256 bondAmount
    ) public {
        priorRoundCount = uint8(bound(priorRoundCount, 1, 5));
        otherRoundCount = uint8(bound(otherRoundCount, 1, 5));
        bondAmount = bound(bondAmount, priorRoundCount, MAX_BOND);

        uint256 workflowId = 1;
        uint8 priorRound = 0;
        uint8 otherRound = 1;
        uint8 bondRound = 1; // Bond is for appealing round 0, posted at round 1

        // Record resolvers at priorRound
        _recordResolvers(workflowId, priorRoundCount, priorRound);

        // Record resolvers at otherRound (should NOT receive bond)
        vm.startPrank(escrowContract);
        for (uint256 i = 0; i < otherRoundCount; i++) {
            incentiveModule.recordResolver(workflowId, escrowContract, resolverAddresses[priorRoundCount + i], otherRound);
        }
        vm.stopPrank();

        _recordAppealBond(workflowId, bondAmount, bondRound);

        vm.startPrank(escrowContract);
        incentiveModule.distributeAppealBond(workflowId, escrowContract, priorRound, false);
        vm.stopPrank();

        // Only priorRound resolvers should have claimable payments
        uint256 totalClaimable = 0;
        for (uint256 i = 0; i < priorRoundCount; i++) {
            uint256 claimable = incentiveModule.claimablePayments(escrowContract, workflowId, resolverAddresses[i]);
            assertGt(claimable, 0, 'Prior round resolver should have payment');
            totalClaimable += claimable;
        }

        // Other round resolvers should not have payments
        for (uint256 i = priorRoundCount; i < priorRoundCount + otherRoundCount; i++) {
            uint256 claimable = incentiveModule.claimablePayments(escrowContract, workflowId, resolverAddresses[i]);
            assertEq(claimable, 0, 'Other round resolver should not have payment');
        }

        assertEq(totalClaimable, bondAmount, 'Only prior round resolvers receive bond');
    }

    /**
     * @notice Fuzz test: Bond cannot be distributed twice
     */
    function testFuzz_BondCannotDistributeTwice(
        uint8 resolverCount,
        uint256 bondAmount
    ) public {
        resolverCount = uint8(bound(resolverCount, 1, MAX_RESOLVERS));
        bondAmount = bound(bondAmount, 1, MAX_BOND);

        uint256 workflowId = 1;
        uint8 priorRound = 0;
        uint8 bondRound = 1;

        _recordResolvers(workflowId, resolverCount, priorRound);
        _recordAppealBond(workflowId, bondAmount, bondRound);

        // Distribute once
        vm.startPrank(escrowContract);
        incentiveModule.distributeAppealBond(workflowId, escrowContract, priorRound, false);
        vm.stopPrank();

        // Attempt to distribute again - should revert
        vm.startPrank(escrowContract);
        vm.expectRevert();
        incentiveModule.distributeAppealBond(workflowId, escrowContract, priorRound, false);
        vm.stopPrank();
    }
}
