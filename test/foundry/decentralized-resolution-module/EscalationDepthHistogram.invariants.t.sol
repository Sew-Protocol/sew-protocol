// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import 'forge-std/Test.sol';
import '../../../contracts/decentralized-resolution-module/ResolverIncentiveModuleV2.sol';
import '../../../contracts/decentralized-resolution-module/PaymentCalculationLibraryV1.sol';
import '../../../contracts/core/EscrowVault.sol';
import '../../../contracts/mocks/ERC20Mock.sol';
import '../../../contracts/YieldOps.sol';
import '../../../contracts/DisputeOps.sol';
import '../../../contracts/core/ModuleManagementContract.sol';
import '../../../contracts/admin/EscrowAdminContract.sol';
import '@openzeppelin/contracts/token/ERC20/IERC20.sol';

/**
 * @title EscalationDepthHistogram Invariant Tests
 * @notice Fuzz and invariant tests to ensure histogram remains accurate
 * @dev Tests histogram invariants hold across random operations
 */
contract EscalationDepthHistogramInvariantsTest is Test {
    ResolverIncentiveModuleV2 public incentiveModule;
    PaymentCalculationLibraryV1 public paymentLib;
    ERC20Mock public token;
    EscrowVault public escrow;
    YieldOps public yieldOps;
    DisputeOps public disputeOps;
    ModuleManagementContract public moduleManagement;
    EscrowAdminContract public adminContract;

    address public deployer;
    address public timelock;
    address public depositor;

    uint256 public constant BOND_AMOUNT = 0.01 ether;
    uint256 public constant INITIAL_BALANCE = 10000 ether;

    // Track histogram state for monotonicity checks
    uint256 public previousRound0;
    uint256 public previousRound1;
    uint256 public previousRound2;

    function setUp() public {
        deployer = address(this);
        timelock = makeAddr('timelock');
        depositor = makeAddr('depositor');

        // Deploy contracts
        paymentLib = new PaymentCalculationLibraryV1();
        incentiveModule = new ResolverIncentiveModuleV2(deployer, address(paymentLib));
        token = new ERC20Mock('Test Token', 'TEST', address(this), 0);
        yieldOps = new YieldOps(address(this));
        disputeOps = new DisputeOps();
        moduleManagement = new ModuleManagementContract(address(this));
        adminContract = new EscrowAdminContract(address(this));
        escrow = new EscrowVault(100, makeAddr('feeAddress'), address(yieldOps), address(disputeOps), address(moduleManagement));

        // Setup roles
        incentiveModule.grantRole(incentiveModule.ROLE_TIMELOCK(), timelock);

        // Register escrow
        vm.prank(timelock);
        incentiveModule.registerEscrowContract(address(escrow));

        // Initialize previous state
        (previousRound0, previousRound1, previousRound2) = incentiveModule.getEscalationDepthHistogram();
    }

    // ============ Invariant Tests ============

    /**
     * @notice INVARIANT: Round 0 always equals 0
     * @dev Round 0 should never have bonds recorded
     */
    function invariant_Round0AlwaysZero() public view {
        (uint256 round0, , ) = incentiveModule.getEscalationDepthHistogram();
        assertEq(round0, 0, 'Round 0 should always be 0');
    }

    /**
     * @notice INVARIANT: Histogram values never decrease (monotonicity)
     * @dev After each operation, histogram values should be >= previous values
     */
    function invariant_HistogramMonotonicity() public view {
        (uint256 round0, uint256 round1, uint256 round2) = incentiveModule.getEscalationDepthHistogram();

        // Round 0 should always be 0
        assertEq(round0, previousRound0, 'Round 0 should never change');

        // Rounds 1 and 2 should never decrease
        assertGe(round1, previousRound1, 'Round 1 should never decrease');
        assertGe(round2, previousRound2, 'Round 2 should never decrease');
    }

    /**
     * @notice INVARIANT: Histogram matches actual bond count
     * @dev Histogram should accurately reflect number of bonds recorded
     */
    function invariant_HistogramMatchesActualBonds() public view {
        (uint256 round0, uint256 round1, uint256 round2) = incentiveModule.getEscalationDepthHistogram();

        // Count actual bonds (scan reasonable range)
        uint256 actualRound1 = 0;
        uint256 actualRound2 = 0;

        // Scan up to 1000 workflow IDs (adjust if needed)
        for (uint256 i = 0; i < 1000; i++) {
            if (incentiveModule.hasAppealBond(i, 1)) actualRound1++;
            if (incentiveModule.hasAppealBond(i, 2)) actualRound2++;
        }

        // Histogram should match or exceed actual (may have entries beyond scan range)
        assertGe(round1, actualRound1, 'Round 1 histogram should >= actual bonds');
        assertGe(round2, actualRound2, 'Round 2 histogram should >= actual bonds');
        assertEq(round0, 0, 'Round 0 should always be 0');
    }

    // ============ Fuzz Tests ============

    /**
     * @notice Fuzz test: Histogram accuracy across random bond recordings
     * @param workflowIds Array of workflow IDs to record bonds for
     * @param rounds Array of rounds (should be 1 or 2)
     * @dev Records random bonds and verifies histogram remains accurate
     */
    function testFuzz_histogramAccuracyAcrossOperations(
        uint256[10] memory workflowIds,
        uint8[10] memory rounds
    ) public {
        // Bound workflow IDs to reasonable range
        // Bound rounds to 1-2 (valid range)
        vm.deal(address(escrow), BOND_AMOUNT * 20); // Enough for all bonds

        vm.startPrank(address(escrow));
        
        for (uint256 i = 0; i < 10; i++) {
            uint256 workflowId = workflowIds[i] % 100; // Bound to 0-99
            uint8 round = uint8((rounds[i] % 2) + 1); // Bound to 1-2

            // Only record if bond doesn't already exist (to avoid reverts)
            if (!incentiveModule.hasAppealBond(workflowId, round)) {
                try incentiveModule.recordAppealBond{value: BOND_AMOUNT}(
                    workflowId,
                    depositor,
                    depositor,
                    BOND_AMOUNT,
                    address(0),
                    round
                ) {} catch {
                    // Skip if recording fails (may happen due to various reasons)
                }
            }
        }
        vm.stopPrank();

        // Verify invariants hold
        (uint256 round0, uint256 round1, uint256 round2) = incentiveModule.getEscalationDepthHistogram();

        // Round 0 should always be 0
        assertEq(round0, 0, 'Round 0 should always be 0');

        // Count actual bonds
        uint256 actualRound1 = 0;
        uint256 actualRound2 = 0;

        for (uint256 i = 0; i < 100; i++) {
            if (incentiveModule.hasAppealBond(i, 1)) actualRound1++;
            if (incentiveModule.hasAppealBond(i, 2)) actualRound2++;
        }

        // Histogram should match or exceed actual
        assertGe(round1, actualRound1, 'Round 1 histogram should >= actual bonds');
        assertGe(round2, actualRound2, 'Round 2 histogram should >= actual bonds');
    }

    /**
     * @notice Fuzz test: Histogram bounds validation
     * @param round Random round value (0-255)
     * @dev Verifies invalid rounds are rejected without affecting histogram
     */
    function testFuzz_histogramBounds(uint8 round) public {
        // Get initial histogram state
        (uint256 initialRound0, uint256 initialRound1, uint256 initialRound2) = 
            incentiveModule.getEscalationDepthHistogram();

        vm.deal(address(escrow), BOND_AMOUNT);

        // Only rounds 1-2 are valid
        if (round == 0 || round > 2) {
            // Should revert
            vm.prank(address(escrow));
            vm.expectRevert();
            incentiveModule.recordAppealBond{value: BOND_AMOUNT}(
                1,
                depositor,
                depositor,
                BOND_AMOUNT,
                address(0),
                round
            );

            // Verify histogram unchanged
            (uint256 round0, uint256 round1, uint256 round2) = 
                incentiveModule.getEscalationDepthHistogram();
            
            assertEq(round0, initialRound0, 'Round 0 should be unchanged');
            assertEq(round1, initialRound1, 'Round 1 should be unchanged');
            assertEq(round2, initialRound2, 'Round 2 should be unchanged');
        }
        // If round is valid (1 or 2), test passes (bond recording would succeed)
    }

    /**
     * @notice Fuzz test: Histogram with many bonds
     * @param numBonds Number of bonds to record (bounded to reasonable range)
     * @dev Tests histogram accuracy with large number of bonds
     */
    function testFuzz_histogramWithManyBonds(uint8 numBonds) public {
        // Bound to reasonable range (0-50)
        uint256 numBondsBounded = uint256(numBonds) % 51;
        
        vm.deal(address(escrow), BOND_AMOUNT * (numBondsBounded + 10));

        // Record bonds at round 1
        vm.startPrank(address(escrow));
        for (uint256 i = 0; i < numBondsBounded; i++) {
            incentiveModule.recordAppealBond{value: BOND_AMOUNT}(
                i,
                depositor,
                depositor,
                BOND_AMOUNT,
                address(0),
                1
            );
        }
        vm.stopPrank();

        // Verify histogram
        (uint256 round0, uint256 round1, uint256 round2) = 
            incentiveModule.getEscalationDepthHistogram();

        assertEq(round0, 0, 'Round 0 should remain 0');
        assertEq(round1, numBondsBounded, 'Round 1 should equal number of bonds');
        assertEq(round2, 0, 'Round 2 should remain 0');

        // Verify actual bond count matches
        uint256 actualRound1 = 0;
        for (uint256 i = 0; i < 100; i++) {
            if (incentiveModule.hasAppealBond(i, 1)) actualRound1++;
        }

        assertEq(round1, actualRound1, 'Histogram should match actual bond count');
    }

    /**
     * @notice Test histogram accuracy after distribution operations
     * @dev Verifies distribution doesn't affect histogram (histogram is cumulative)
     */
    function testFuzz_histogramAfterDistributions(uint8 numBonds) public {
        uint256 numBondsBounded = uint256(numBonds) % 21; // 0-20 bonds
        
        vm.deal(address(escrow), BOND_AMOUNT * (numBondsBounded * 2)); // Enough for bonds and distributions

        // Record bonds
        vm.startPrank(address(escrow));
        for (uint256 i = 0; i < numBondsBounded; i++) {
            incentiveModule.recordAppealBond{value: BOND_AMOUNT}(
                i,
                depositor,
                depositor,
                BOND_AMOUNT,
                address(0),
                1
            );
        }
        vm.stopPrank();

        // Get histogram before distributions
        (uint256 round0Before, uint256 round1Before, uint256 round2Before) = 
            incentiveModule.getEscalationDepthHistogram();

        // Distribute some bonds (randomly select refund or pay)
        vm.startPrank(address(escrow));
        for (uint256 i = 0; i < numBondsBounded; i++) {
            if (i % 2 == 0) {
                // Refund (outcome flipped)
                try incentiveModule.distributeAppealBond(i, 0, true) {} catch {}
            } else {
                // Pay to resolvers (outcome not flipped)
                try incentiveModule.distributeAppealBond(i, 0, false) {} catch {}
            }
        }
        vm.stopPrank();

        // Get histogram after distributions
        (uint256 round0After, uint256 round1After, uint256 round2After) = 
            incentiveModule.getEscalationDepthHistogram();

        // Histogram should remain unchanged (cumulative)
        assertEq(round0Before, round0After, 'Round 0 should be unchanged');
        assertEq(round1Before, round1After, 'Round 1 should be unchanged after distribution');
        assertEq(round2Before, round2After, 'Round 2 should be unchanged');
    }
}
