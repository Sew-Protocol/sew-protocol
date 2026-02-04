// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import 'forge-std/Test.sol';
import '../../../contracts/modules/decentralized-resolution-module/ResolverIncentiveModuleV2.sol';
import '../../../contracts/modules/decentralized-resolution-module/PaymentCalculationLibraryV1.sol';
import '../../../contracts/core/EscrowVault.sol';
import '../../../contracts/mocks/ERC20Mock.sol';
import '../../../contracts/YieldOps.sol';
import '../../../contracts/DisputeOps.sol';
import '../../../contracts/core/ModuleSnapshotRegistry.sol';
import '../../../contracts/admin/EscrowGovernanceTimelock.sol';
import '@openzeppelin/contracts/token/ERC20/IERC20.sol';

/**
 * @title EscalationDepthHistogram Unit Tests
 * @notice Unit tests for escalationDepthHistogram in ResolverIncentiveModuleV2
 * @dev Tests histogram updates in isolation, independent of full escalation flow
 */
contract EscalationDepthHistogramTest is Test {
    ResolverIncentiveModuleV2 public incentiveModule;
    PaymentCalculationLibraryV1 public paymentLib;
    ERC20Mock public token;
    EscrowVault public escrow;
    YieldOps public yieldOps;
    DisputeOps public disputeOps;
    ModuleSnapshotRegistry public moduleManagement;
    EscrowGovernanceTimelock public adminContract;

    address public deployer;
    address public depositor;
    address public timelock;
    address public feeAddress;

    uint256 constant WORKFLOW_ID_1 = 1;
    uint256 constant WORKFLOW_ID_2 = 2;
    uint256 constant WORKFLOW_ID_3 = 3;
    uint256 constant BOND_AMOUNT = 0.01 ether;
    uint256 public constant INITIAL_BALANCE = 10000 ether;

    function setUp() public {
        deployer = address(this);
        depositor = makeAddr('depositor');
        timelock = makeAddr('timelock');
        feeAddress = makeAddr('feeAddress');

        // Deploy contracts
        paymentLib = new PaymentCalculationLibraryV1();
        incentiveModule = new ResolverIncentiveModuleV2(deployer, address(paymentLib));
        token = new ERC20Mock('Test Token', 'TEST', address(this), 0);
        incentiveModule.grantRole(incentiveModule.ROLE_TIMELOCK(), address(this));
        incentiveModule.registerEscrowContract(address(this));
        yieldOps = new YieldOps(address(this));
        disputeOps = new DisputeOps(address(this));
        moduleManagement = new ModuleSnapshotRegistry(address(this));
        adminContract = new EscrowGovernanceTimelock(address(this));
        escrow = new EscrowVault(100, feeAddress, address(yieldOps), address(disputeOps), address(moduleManagement));

        // Setup tokens
        token.mint(depositor, INITIAL_BALANCE);

        // Grant roles
        incentiveModule.grantRole(incentiveModule.ROLE_TIMELOCK(), timelock);

        // Register escrow contract
        vm.prank(timelock);
        incentiveModule.registerEscrowContract(address(escrow));
    }
    
    // ============ Test: Basic Increment Operations ============

    /**
     * @notice Test histogram increments correctly when recording bond at round 1
     */
    function test_histogramIncrementOnRecordBond_Round1() public {
        // Verify initial state
        (uint256 round0, uint256 round1, uint256 round2) = incentiveModule.getEscalationDepthHistogram();
        assertEq(round0, 0, "Round 0 should start at 0");
        assertEq(round1, 0, "Round 1 should start at 0");
        assertEq(round2, 0, "Round 2 should start at 0");

        // Record bond at round 1
        vm.deal(address(escrow), BOND_AMOUNT);
        _recordBond(WORKFLOW_ID_1, depositor, BOND_AMOUNT, address(0), 1);

        // Verify histogram updated
        (round0, round1, round2) = incentiveModule.getEscalationDepthHistogram();
        assertEq(round0, 0, "Round 0 should remain 0");
        assertEq(round1, 1, "Round 1 should increment to 1");
        assertEq(round2, 0, "Round 2 should remain 0");

        // Verify direct mapping access matches getter
        assertEq(incentiveModule.escalationDepthHistogram(0), round0, "Direct access should match getter round 0");
        assertEq(incentiveModule.escalationDepthHistogram(1), round1, "Direct access should match getter round 1");
        assertEq(incentiveModule.escalationDepthHistogram(2), round2, "Direct access should match getter round 2");
    }

    /**
     * @notice Test histogram increments correctly when recording bond at round 2
     */
    function test_histogramIncrementOnRecordBond_Round2() public {
        // Record bond at round 2
        _recordBond(WORKFLOW_ID_1, depositor, BOND_AMOUNT, address(0), 2);

        // Verify histogram updated
        (uint256 round0, uint256 round1, uint256 round2) = incentiveModule.getEscalationDepthHistogram();
        assertEq(round0, 0, "Round 0 should remain 0");
        assertEq(round1, 0, "Round 1 should remain 0");
        assertEq(round2, 1, "Round 2 should increment to 1");
    }

    /**
     * @notice Test histogram increments correctly with multiple bonds at same round
     */
    function test_histogramIncrementMultipleBonds_SameRound() public {
        // Record multiple bonds at round 1
        vm.deal(address(escrow), BOND_AMOUNT * 3);
        _recordBond(WORKFLOW_ID_1, depositor, BOND_AMOUNT, address(0), 1);
        _recordBond(WORKFLOW_ID_2, depositor, BOND_AMOUNT, address(0), 1);
        _recordBond(WORKFLOW_ID_3, depositor, BOND_AMOUNT, address(0), 1);

        // Verify histogram
        (uint256 round0, uint256 round1, uint256 round2) = incentiveModule.getEscalationDepthHistogram();
        assertEq(round0, 0, "Round 0 should remain 0");
        assertEq(round1, 3, "Round 1 should be 3");
        assertEq(round2, 0, "Round 2 should remain 0");

        // Verify each bond is recorded correctly
        assertTrue(incentiveModule.hasAppealBond(WORKFLOW_ID_1, address(this), 1), "Workflow 1 should have bond");
        assertTrue(incentiveModule.hasAppealBond(WORKFLOW_ID_2, address(this), 1), "Workflow 2 should have bond");
        assertTrue(incentiveModule.hasAppealBond(WORKFLOW_ID_3, address(this), 1), "Workflow 3 should have bond");
    }

    /**
     * @notice Test histogram increments correctly with multiple bonds at different rounds
     */
    function test_histogramIncrementMultipleBonds_DifferentRounds() public {
        // Record bond at round 1 (workflow 1) - fund escrow with enough ETH for all bonds
        vm.deal(address(escrow), BOND_AMOUNT * 3);
        _recordBond(WORKFLOW_ID_1, depositor, BOND_AMOUNT, address(0), 1);

        // Record bond at round 2 (workflow 2)
        _recordBond(WORKFLOW_ID_2, depositor, BOND_AMOUNT, address(0), 2);

        // Record another bond at round 1 (workflow 3)
        _recordBond(WORKFLOW_ID_3, depositor, BOND_AMOUNT, address(0), 1);

        // Verify histogram
        (uint256 round0, uint256 round1, uint256 round2) = incentiveModule.getEscalationDepthHistogram();
        assertEq(round0, 0, "Round 0 should remain 0");
        assertEq(round1, 2, "Round 1 should be 2");
        assertEq(round2, 1, "Round 2 should be 1");
    }

    // ============ Test: Round Validation ============

    /**
     * @notice Test that histogram never increments for round 0
     */
    function test_histogramNeverIncrementsRound0() public {
        // Attempt to record bond at round 0 (should revert)
        vm.deal(address(escrow), BOND_AMOUNT);
        vm.prank(address(this));
        vm.expectRevert("Invalid round");
        incentiveModule.recordAppealBond{value: BOND_AMOUNT}(
            WORKFLOW_ID_1,
            address(this),
            depositor,
            depositor,
            BOND_AMOUNT,
            address(0),
            0
        );

        // Verify histogram unchanged
        (uint256 round0, uint256 round1, uint256 round2) = incentiveModule.getEscalationDepthHistogram();
        assertEq(round0, 0, "Round 0 should remain 0");
        assertEq(round1, 0, "Round 1 should remain 0");
        assertEq(round2, 0, "Round 2 should remain 0");
    }

    /**
     * @notice Test that histogram rejects round 3 (out of bounds)
     */
    function test_histogramRound3Rejected() public {
        // Attempt to record bond at round 3 (should revert)
        vm.deal(address(escrow), BOND_AMOUNT);
        vm.prank(address(this));
        vm.expectRevert("Invalid round");
        incentiveModule.recordAppealBond{value: BOND_AMOUNT}(
            WORKFLOW_ID_1,
            address(this),
            depositor,
            depositor,
            BOND_AMOUNT,
            address(0),
            3
        );

        // Verify histogram unchanged
        (uint256 round0, uint256 round1, uint256 round2) = incentiveModule.getEscalationDepthHistogram();
        assertEq(round0, 0, "Round 0 should remain 0");
        assertEq(round1, 0, "Round 1 should remain 0");
        assertEq(round2, 0, "Round 2 should remain 0");
    }

    /**
     * @notice Test that histogram rejects round > 2 (out of bounds)
     */
    function test_histogramRejectsInvalidHighRounds() public {
        // Attempt to record bond at round 255 (maximum uint8, should revert)
        // Round must be > 0 && <= 2, so 255 should revert with "Invalid round"
        vm.deal(address(escrow), BOND_AMOUNT);
        vm.prank(address(this));
        vm.expectRevert("Invalid round");
        incentiveModule.recordAppealBond{value: BOND_AMOUNT}(
            WORKFLOW_ID_1,
            address(this),
            depositor,
            depositor,
            BOND_AMOUNT,
            address(0),
            255
        );

        // Verify histogram unchanged
        (uint256 round0, uint256 round1, uint256 round2) = incentiveModule.getEscalationDepthHistogram();
        assertEq(round0, 0, "Round 0 should remain 0");
        assertEq(round1, 0, "Round 1 should remain 0");
        assertEq(round2, 0, "Round 2 should remain 0");
    }

    // ============ Test: Histogram Persistence ============

    /**
     * @notice Test that histogram persists across bond distributions (histogram is cumulative)
     */
    function test_histogramPersistsAcrossDistributions() public {
        // Record bond at round 1
        _recordBond(WORKFLOW_ID_1, depositor, BOND_AMOUNT, address(0), 1);

        // Verify histogram updated
        (uint256 round0, uint256 round1, uint256 round2) = incentiveModule.getEscalationDepthHistogram();
        assertEq(round1, 1, "Round 1 should be 1");

        // Distribute bond (refund)
        vm.prank(address(this));
        incentiveModule.distributeAppealBond(WORKFLOW_ID_1, address(this), 0, true); // outcomeFlipped = true (refund)

        // Verify histogram unchanged (histogram is cumulative, doesn't decrease)
        (round0, round1, round2) = incentiveModule.getEscalationDepthHistogram();
        assertEq(round0, 0, "Round 0 should remain 0");
        assertEq(round1, 1, "Round 1 should remain 1 (histogram is cumulative)");
        assertEq(round2, 0, "Round 2 should remain 0");
    }

    /**
     * @notice Test that histogram never decreases (monotonicity)
     */
    function test_histogramNeverDecreases() public {
        // Record multiple bonds and verify monotonicity
        uint256 previousRound1 = 0;
        uint256 previousRound2 = 0;
        
        // Fund escrow with enough ETH for all bonds
        vm.deal(address(escrow), BOND_AMOUNT * 10);

        for (uint256 i = 1; i <= 10; i++) {
            _recordBond(i, depositor, BOND_AMOUNT, address(0), i % 2 == 0 ? uint8(1) : uint8(2));

            (uint256 round0, uint256 round1, uint256 round2) = incentiveModule.getEscalationDepthHistogram();
            
            // Verify monotonicity
            assertGe(round1, previousRound1, "Round 1 should never decrease");
            assertGe(round2, previousRound2, "Round 2 should never decrease");
            assertEq(round0, 0, "Round 0 should always be 0");

            previousRound1 = round1;
            previousRound2 = round2;
        }
    }

    // ============ Test: Getter Function Accuracy ============

    /**
     * @notice Test that getter returns correct values matching direct mapping access
     */
    function test_histogramGetterReturnsCorrectValues() public {
        // Record bonds at various rounds
        vm.deal(address(escrow), BOND_AMOUNT * 3);
        _recordBond(WORKFLOW_ID_1, depositor, BOND_AMOUNT, address(0), 1);
        _recordBond(WORKFLOW_ID_2, depositor, BOND_AMOUNT, address(0), 2);
        _recordBond(WORKFLOW_ID_3, depositor, BOND_AMOUNT, address(0), 1);

        // Get values via getter
        (uint256 round0, uint256 round1, uint256 round2) = incentiveModule.getEscalationDepthHistogram();

        // Verify getter matches direct mapping access
        assertEq(incentiveModule.escalationDepthHistogram(0), round0, "Getter round 0 should match mapping");
        assertEq(incentiveModule.escalationDepthHistogram(1), round1, "Getter round 1 should match mapping");
        assertEq(incentiveModule.escalationDepthHistogram(2), round2, "Getter round 2 should match mapping");

        // Verify expected values
        assertEq(round0, 0, "Round 0 should be 0");
        assertEq(round1, 2, "Round 1 should be 2");
        assertEq(round2, 1, "Round 2 should be 1");
    }

    // ============ Test: Edge Cases ============

    /**
     * @notice Test histogram with ERC20 tokens (not just ETH)
     */
    function test_histogramWithERC20Token() public {
        // Mint tokens to depositor and approve incentive module (pull-based pattern)
        token.mint(depositor, BOND_AMOUNT * 10);
        vm.prank(depositor);
        token.approve(address(incentiveModule), BOND_AMOUNT);

        // Record bond with ERC20 token - incentive module will pull tokens
        vm.prank(address(this));
        incentiveModule.recordAppealBond(
            WORKFLOW_ID_1,
            address(this),
            depositor,
            depositor,
            BOND_AMOUNT,
            address(token),
            1
        );

        // Verify histogram updated
        (uint256 round0, uint256 round1, uint256 round2) = incentiveModule.getEscalationDepthHistogram();
        assertEq(round1, 1, "Round 1 should increment with ERC20 bond");
        assertEq(round0, 0, "Round 0 should remain 0");
        assertEq(round2, 0, "Round 2 should remain 0");
    }

    /**
     * @notice Test histogram accuracy with maximum workflow ID
     */
    function test_histogramWithMaxWorkflowId() public {
        uint256 maxWorkflowId = type(uint256).max;

        // Record bond with maximum workflow ID
        _recordBond(maxWorkflowId, depositor, BOND_AMOUNT, address(0), 1);

        // Verify histogram increments correctly
        (uint256 round0, uint256 round1, uint256 round2) = incentiveModule.getEscalationDepthHistogram();
        assertEq(round1, 1, "Round 1 should increment even with max workflow ID");
        
        // Verify bond exists
        assertTrue(incentiveModule.hasAppealBond(maxWorkflowId, address(this), 1), "Bond should exist at max workflow ID");
    }

    /**
     * @notice Test histogram with many bonds (verify no overflow or precision issues)
     */
    function test_histogramWithManyBonds() public {
        uint256 numBonds = 100;

        // Record many bonds at round 1 - fund escrow with enough ETH for all bonds
        vm.deal(address(escrow), BOND_AMOUNT * numBonds);
        for (uint256 i = 1; i <= numBonds; i++) {
            _recordBond(i, depositor, BOND_AMOUNT, address(0), 1);
        }

        // Verify histogram
        (uint256 round0, uint256 round1, uint256 round2) = incentiveModule.getEscalationDepthHistogram();
        assertEq(round1, numBonds, "Round 1 should equal number of bonds");
        assertEq(round0, 0, "Round 0 should remain 0");
        assertEq(round2, 0, "Round 2 should remain 0");
    }

    /**
     * @notice Test that failed bond recording doesn't affect histogram
     */
    function test_histogramUnaffectedByFailedBondRecording() public {
        // Attempt to record bond with invalid parameters (should revert)
        vm.deal(address(escrow), 0);
        vm.prank(address(this));
        vm.expectRevert("Invalid amount");
        incentiveModule.recordAppealBond{value: 0}(
            WORKFLOW_ID_1,
            address(this),
            depositor,
            depositor,
            0, // Invalid: zero amount
            address(0),
            1
        );

        // Verify histogram unchanged
        (uint256 round0, uint256 round1, uint256 round2) = incentiveModule.getEscalationDepthHistogram();
        assertEq(round0, 0, "Round 0 should remain 0");
        assertEq(round1, 0, "Round 1 should remain 0");
        assertEq(round2, 0, "Round 2 should remain 0");

        // Attempt duplicate bond recording (should revert)
        _recordBond(WORKFLOW_ID_1, depositor, BOND_AMOUNT, address(0), 1);

        vm.deal(address(escrow), BOND_AMOUNT);
        vm.prank(address(this));
        vm.expectRevert("Bond already exists");
        incentiveModule.recordAppealBond{value: BOND_AMOUNT}(
            WORKFLOW_ID_1,
            address(this),
            depositor,
            depositor,
            BOND_AMOUNT,
            address(0),
            1
        );

        // Verify histogram only incremented once
        (round0, round1, round2) = incentiveModule.getEscalationDepthHistogram();
        assertEq(round1, 1, "Round 1 should only increment once");
    }

    // ============ Helper Functions ============

    /**
     * @notice Helper function to record a bond
     * @param workflowId The workflow ID
     * @param depositorAddr The bond depositor address
     * @param amount The bond amount
     * @param tokenAddr The token address (address(0) for ETH)
     * @param round The round number
     */
    function _recordBond(
        uint256 workflowId,
        address depositorAddr,
        uint256 amount,
        address tokenAddr,
        uint8 round
    ) internal {
        if (tokenAddr == address(0)) {
            // ETH bond - fund escrow first
            vm.deal(address(escrow), amount);
            vm.prank(address(this));
            incentiveModule.recordAppealBond{value: amount}(
                workflowId,
                address(this),
                depositorAddr,
                depositorAddr,
                amount,
                address(0),
                round
            );
        } else {
            // ERC20 bond - approve incentive module to pull tokens
            vm.prank(depositorAddr);
            IERC20(tokenAddr).approve(address(incentiveModule), amount);

            // Record bond - incentive module will pull tokens from depositor
            vm.prank(address(this));
            incentiveModule.recordAppealBond(
                workflowId,
                address(this),
                depositorAddr,
                depositorAddr,
                amount,
                tokenAddr,
                round
            );
        }
    }
}
