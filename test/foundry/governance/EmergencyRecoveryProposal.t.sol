// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;

import 'forge-std/Test.sol';
import '../../../contracts/core/EscrowVault.sol';
import '../../../contracts/core/BaseEscrow.sol';
import '../../../contracts/admin/EscrowAdminContract.sol';
import '../../../contracts/core/ModuleManagementContract.sol';
import '../../../contracts/mocks/ERC20Mock.sol';
import '../../../contracts/core/modules/DefaultResolutionModule.sol';
import '../../../contracts/modules/DefaultReleaseStrategy.sol';
import '../../../contracts/types/EscrowTypes.sol';
import '../../../contracts/types/YieldPresets.sol';
import '../../../contracts/libraries/SettingsValidationLibrary.sol';
import '../../../contracts/YieldOps.sol';
import '../../../contracts/DisputeOps.sol';
import '../../../contracts/SettlementOps.sol';
import '../../../contracts/CreateOps.sol';
import '../../../contracts/ops/GuardianOps.sol';
import '../../../contracts/governance/EmergencyRecoveryProposal.sol';

/**
 * @title EmergencyRecoveryProposalTest
 * @notice Tests for DAO recovery proposal framework
 * @dev Phase 3: Verify governance can propose and execute recovery actions
 */
contract EmergencyRecoveryProposalTest is Test {
    EscrowVault public vault;
    EscrowAdminContract public adminContract;
    ModuleManagementContract public moduleManagement;
    ERC20Mock public token;
    DefaultResolutionModule public resolutionModule;
    DefaultReleaseStrategy public releaseStrategy;
    YieldOps public yieldOps;
    DisputeOps public disputeOps;
    SettlementOps public settlementOps;
    CreateOps public createOps;
    GuardianOps public guardianOps;
    EmergencyRecoveryProposal public recoveryProposal;

    address public owner;
    address public timelock;
    address public guardian;
    address public feeAddress;
    address public resolver;
    address public buyer;
    address public seller;

    uint256 public constant ESCROW_FEE = 100;
    uint256 public constant INITIAL_BALANCE = 1_000_000e18;

    function _getDefaultSettings() internal pure returns (EscrowSettings memory) {
        return SettingsValidationLibrary.getDefaultSettings();
    }

    function setUp() public {
        owner = address(this);
        timelock = address(0x1111);
        guardian = address(0x2222);
        feeAddress = address(0xFEE);
        resolver = address(0x1234);
        buyer = address(0x1001);
        seller = address(0x1002);

        // Deploy resolution module
        resolutionModule = new DefaultResolutionModule(owner, resolver);
        releaseStrategy = new DefaultReleaseStrategy();

        // Deploy mock token
        token = new ERC20Mock('Test Token', 'TEST', owner, 10000000e18);

        // Deploy ops contracts
        yieldOps = new YieldOps(owner);
        disputeOps = new DisputeOps(owner);
        settlementOps = new SettlementOps(owner);
        createOps = new CreateOps(owner);
        moduleManagement = new ModuleManagementContract(owner);

        // Deploy vault
        vault = new EscrowVault(ESCROW_FEE, feeAddress, address(yieldOps), address(disputeOps), address(moduleManagement));

        // Deploy admin contract
        adminContract = new EscrowAdminContract(owner);
        adminContract.grantRole(adminContract.ROLE_TIMELOCK(), timelock);

        // Grant roles
        bytes32 ROLE_TIMELOCK = vault.ROLE_TIMELOCK();
        bytes32 ROLE_GUARDIAN = vault.ROLE_GUARDIAN();
        vault.grantRole(ROLE_TIMELOCK, owner);
        vault.grantRole(ROLE_TIMELOCK, timelock);
        vault.grantRole(ROLE_GUARDIAN, guardian);

        // Wire ops contracts
        yieldOps.registerEscrowContract(address(vault));
        disputeOps.registerEscrowContract(address(vault));
        settlementOps.registerEscrowContract(address(vault));
        createOps.registerEscrowContract(address(vault));
        vault.grantRole(vault.ROLE_ADMIN_CONTRACT(), owner);
        vault.grantRole(vault.ROLE_ADMIN_CONTRACT(), address(adminContract));
        vault.setCreateOps(address(createOps));
        vault.setSettlementOps(address(settlementOps));

        moduleManagement.registerEscrowContract(address(vault));

        // Queue and activate modules
        adminContract.queueResolutionModule(address(vault), address(resolutionModule));
        vm.prank(address(this));
        moduleManagement.queueModule(address(vault), BaseEscrow.ModuleType.RELEASE, address(releaseStrategy));
        vm.warp(block.timestamp + 14 days + 1);
        adminContract.activateResolutionModule(address(vault));
        vm.prank(address(this));
        moduleManagement.activateModule(address(vault), BaseEscrow.ModuleType.RELEASE);

        // Deploy guardian ops and recovery proposal
        guardianOps = new GuardianOps(address(vault));
        recoveryProposal = new EmergencyRecoveryProposal(address(vault), address(guardianOps), owner);

        // Grant proposer and executor roles to timelock
        vm.prank(owner);
        recoveryProposal.grantRole(recoveryProposal.ROLE_PROPOSER(), timelock);
        vm.prank(owner);
        recoveryProposal.grantRole(recoveryProposal.ROLE_EXECUTOR(), timelock);

        // Mint tokens
        token.mint(buyer, INITIAL_BALANCE);
        token.mint(seller, INITIAL_BALANCE);

        // Approve vault
        vm.prank(buyer);
        token.approve(address(vault), type(uint256).max);
        vm.prank(seller);
        token.approve(address(vault), type(uint256).max);
    }

    // ============ Test 1: Can only propose when paused ============
    function test_RecoveryProposalRequiresPausedSystem() public {
        // System not paused yet
        assertFalse(vault.paused());

        // Try to propose recovery
        vm.prank(timelock);
        vm.expectRevert();
        recoveryProposal.proposeRecovery(
            EmergencyRecoveryProposal.RecoveryAction.EMERGENCY_UNWIND_AAVE,
            "Test recovery"
        );
    }

    // ============ Test 2: Can propose recovery when paused ============
    function test_CanProposeRecoveryWhenPaused() public {
        // Guardian pauses system
        vm.prank(guardian);
        vault.pause("Emergency incident");
        assertTrue(vault.paused());

        // Timelock can propose recovery
        vm.prank(timelock);
        uint256 proposalId = recoveryProposal.proposeRecovery(
            EmergencyRecoveryProposal.RecoveryAction.EMERGENCY_UNWIND_AAVE,
            "Unwind Aave positions to recover funds"
        );

        assertEq(proposalId, 0);
        
        // Verify proposal was created
        EmergencyRecoveryProposal.RecoveryProposal memory proposal = recoveryProposal.getRecoveryProposal(proposalId);
        assertEq(uint8(proposal.status), uint8(EmergencyRecoveryProposal.RecoveryStatus.PROPOSED));
        assertEq(uint8(proposal.action), uint8(EmergencyRecoveryProposal.RecoveryAction.EMERGENCY_UNWIND_AAVE));
    }

    // ============ Test 3: Only proposer can create proposals ============
    function test_OnlyProposerCanProposeRecovery() public {
        // Guardian pauses system
        vm.prank(guardian);
        vault.pause("Emergency incident");

        // Non-proposer cannot create proposal
        address nonProposer = address(0x9999);
        vm.prank(nonProposer);
        vm.expectRevert();
        recoveryProposal.proposeRecovery(
            EmergencyRecoveryProposal.RecoveryAction.EMERGENCY_UNWIND_AAVE,
            "Test"
        );
    }

    // ============ Test 4: Recovery proposal approval ============
    function test_CanApproveRecoveryProposal() public {
        // Setup: pause and propose
        vm.prank(guardian);
        vault.pause("Emergency incident");

        vm.prank(timelock);
        uint256 proposalId = recoveryProposal.proposeRecovery(
            EmergencyRecoveryProposal.RecoveryAction.EMERGENCY_UNWIND_AAVE,
            "Unwind Aave"
        );

        // Timelock approves the proposal
        vm.prank(timelock);
        recoveryProposal.approveRecovery(proposalId);

        // Verify approval
        EmergencyRecoveryProposal.RecoveryProposal memory proposal = recoveryProposal.getRecoveryProposal(proposalId);
        assertEq(uint8(proposal.status), uint8(EmergencyRecoveryProposal.RecoveryStatus.APPROVED));
        assertGt(proposal.approvedAt, 0);
    }

    // ============ Test 5: Timelock delay enforcement ============
    function test_TimelockDelayEnforced() public {
        // Setup: pause, propose, and approve
        vm.prank(guardian);
        vault.pause("Emergency incident");

        vm.prank(timelock);
        uint256 proposalId = recoveryProposal.proposeRecovery(
            EmergencyRecoveryProposal.RecoveryAction.EMERGENCY_UNWIND_AAVE,
            "Unwind Aave"
        );

        vm.prank(timelock);
        recoveryProposal.approveRecovery(proposalId);

        // Try to execute immediately (should fail)
        vm.prank(timelock);
        vm.expectRevert();
        recoveryProposal.executeRecovery(proposalId);

        // Verify delay is calculated correctly
        uint256 remainingDelay = recoveryProposal.getExecutionDelay(proposalId);
        assertEq(remainingDelay, 2 days);
    }

    // ============ Test 6: Can execute after delay ============
    function test_CanExecuteAfterDelay() public {
        // Setup: pause, propose, and approve
        vm.prank(guardian);
        vault.pause("Emergency incident");

        vm.prank(timelock);
        uint256 proposalId = recoveryProposal.proposeRecovery(
            EmergencyRecoveryProposal.RecoveryAction.EMERGENCY_UNWIND_AAVE,
            "Unwind Aave"
        );

        vm.prank(timelock);
        recoveryProposal.approveRecovery(proposalId);

        // Advance time by 2 days + 1 second
        vm.warp(block.timestamp + 2 days + 1);

        // Now execution should work
        vm.prank(timelock);
        recoveryProposal.executeRecovery(proposalId);

        // Verify execution
        EmergencyRecoveryProposal.RecoveryProposal memory proposal = recoveryProposal.getRecoveryProposal(proposalId);
        assertEq(uint8(proposal.status), uint8(EmergencyRecoveryProposal.RecoveryStatus.EXECUTED));
        assertGt(proposal.executedAt, 0);
    }

    // ============ Test 7: Multiple recovery proposals ============
    function test_MultipleRecoveryProposalsSupported() public {
        // Setup: pause
        vm.prank(guardian);
        vault.pause("Emergency incident");

        // Create multiple proposals
        vm.prank(timelock);
        uint256 proposalId1 = recoveryProposal.proposeRecovery(
            EmergencyRecoveryProposal.RecoveryAction.EMERGENCY_UNWIND_AAVE,
            "Unwind Aave"
        );

        vm.prank(timelock);
        uint256 proposalId2 = recoveryProposal.proposeRecovery(
            EmergencyRecoveryProposal.RecoveryAction.WITHDRAW_PAUSED_ESCROWS,
            "Withdraw paused escrows"
        );

        assertEq(proposalId1, 0);
        assertEq(proposalId2, 1);

        // Verify both exist
        EmergencyRecoveryProposal.RecoveryProposal memory proposal1 = recoveryProposal.getRecoveryProposal(proposalId1);
        EmergencyRecoveryProposal.RecoveryProposal memory proposal2 = recoveryProposal.getRecoveryProposal(proposalId2);

        assertEq(uint8(proposal1.action), uint8(EmergencyRecoveryProposal.RecoveryAction.EMERGENCY_UNWIND_AAVE));
        assertEq(uint8(proposal2.action), uint8(EmergencyRecoveryProposal.RecoveryAction.WITHDRAW_PAUSED_ESCROWS));
    }

    // ============ Test 8: Recovery can be cancelled ============
    function test_RecoveryCanBeCancelled() public {
        // Setup: pause and propose
        vm.prank(guardian);
        vault.pause("Emergency incident");

        vm.prank(timelock);
        uint256 proposalId = recoveryProposal.proposeRecovery(
            EmergencyRecoveryProposal.RecoveryAction.EMERGENCY_UNWIND_AAVE,
            "Unwind Aave"
        );

        // Cancel the proposal
        vm.prank(timelock);
        recoveryProposal.cancelRecovery(proposalId, "Incident resolved, cancelling recovery");

        // Verify cancellation
        EmergencyRecoveryProposal.RecoveryProposal memory proposal = recoveryProposal.getRecoveryProposal(proposalId);
        assertEq(uint8(proposal.status), uint8(EmergencyRecoveryProposal.RecoveryStatus.CANCELLED));
    }

    // ============ Test 9: Recovery readiness check ============
    function test_RecoveryReadinessCheck() public {
        // Setup: pause, propose, approve
        vm.prank(guardian);
        vault.pause("Emergency incident");

        vm.prank(timelock);
        uint256 proposalId = recoveryProposal.proposeRecovery(
            EmergencyRecoveryProposal.RecoveryAction.EMERGENCY_UNWIND_AAVE,
            "Unwind Aave"
        );

        vm.prank(timelock);
        recoveryProposal.approveRecovery(proposalId);

        // Not ready yet
        assertFalse(recoveryProposal.isRecoveryReady(proposalId));

        // Advance time
        vm.warp(block.timestamp + 2 days + 1);

        // Now ready
        assertTrue(recoveryProposal.isRecoveryReady(proposalId));
    }

    // ============ Test 10: Different recovery actions supported ============
    function test_AllRecoveryActionsSupported() public {
        // Setup: pause
        vm.prank(guardian);
        vault.pause("Emergency incident");

        // Test each recovery action type
        EmergencyRecoveryProposal.RecoveryAction[] memory actions = new EmergencyRecoveryProposal.RecoveryAction[](4);
        actions[0] = EmergencyRecoveryProposal.RecoveryAction.EMERGENCY_UNWIND_AAVE;
        actions[1] = EmergencyRecoveryProposal.RecoveryAction.WITHDRAW_PAUSED_ESCROWS;
        actions[2] = EmergencyRecoveryProposal.RecoveryAction.RESET_YIELD_MODULES;
        actions[3] = EmergencyRecoveryProposal.RecoveryAction.UPDATE_GUARDIAN_ADDRESS;

        for (uint i = 0; i < actions.length; i++) {
            vm.prank(timelock);
            uint256 proposalId = recoveryProposal.proposeRecovery(
                actions[i],
                "Recovery action"
            );

            EmergencyRecoveryProposal.RecoveryProposal memory proposal = recoveryProposal.getRecoveryProposal(proposalId);
            assertEq(uint8(proposal.action), uint8(actions[i]));
        }
    }

    // ============ Test 11: Recovery proposal persistence ============
    function test_RecoveryProposalPersistence() public {
        // Setup: pause and propose
        vm.prank(guardian);
        vault.pause("Emergency incident");

        string memory reason = "Unwind Aave positions due to oracle failure";
        
        vm.prank(timelock);
        uint256 proposalId = recoveryProposal.proposeRecovery(
            EmergencyRecoveryProposal.RecoveryAction.EMERGENCY_UNWIND_AAVE,
            reason
        );

        // Verify all proposal data is stored correctly
        EmergencyRecoveryProposal.RecoveryProposal memory proposal = recoveryProposal.getRecoveryProposal(proposalId);

        assertEq(proposal.proposalId, proposalId);
        assertEq(uint8(proposal.action), uint8(EmergencyRecoveryProposal.RecoveryAction.EMERGENCY_UNWIND_AAVE));
        assertEq(uint8(proposal.status), uint8(EmergencyRecoveryProposal.RecoveryStatus.PROPOSED));
        assertEq(proposal.reason, reason);
        assertEq(proposal.proposedBy, timelock);
        assertGt(proposal.createdAt, 0);
    }

    // ============ Test 12: Recovery timeline validation ============
    function test_RecoveryTimelineValidation() public {
        // Setup: pause and propose
        vm.prank(guardian);
        vault.pause("Emergency incident");

        vm.prank(timelock);
        uint256 proposalId = recoveryProposal.proposeRecovery(
            EmergencyRecoveryProposal.RecoveryAction.EMERGENCY_UNWIND_AAVE,
            "Recovery"
        );

        // Approve after short delay
        vm.warp(block.timestamp + 1 hours);
        vm.prank(timelock);
        recoveryProposal.approveRecovery(proposalId);

        uint256 approvedAt = block.timestamp;

        // Can't execute immediately
        vm.prank(timelock);
        vm.expectRevert();
        recoveryProposal.executeRecovery(proposalId);

        // Execute after full delay
        vm.warp(approvedAt + 2 days + 1);
        vm.prank(timelock);
        recoveryProposal.executeRecovery(proposalId);

        // Verify timeline (order and approximate delay)
        EmergencyRecoveryProposal.RecoveryProposal memory proposal = recoveryProposal.getRecoveryProposal(proposalId);
        assertLt(proposal.createdAt, proposal.approvedAt);
        assertLt(proposal.approvedAt, proposal.executedAt);
        // Delay should be approximately 2 days
        uint256 actualDelay = proposal.executedAt - proposal.approvedAt;
        assertTrue(actualDelay >= 2 days && actualDelay <= 2 days + 1 hours);
    }

    // ============ Test 13: Recovery cannot be executed twice ============
    function test_RecoveryCannotExecuteTwice() public {
        // Setup and execute recovery
        vm.prank(guardian);
        vault.pause("Emergency incident");

        vm.prank(timelock);
        uint256 proposalId = recoveryProposal.proposeRecovery(
            EmergencyRecoveryProposal.RecoveryAction.EMERGENCY_UNWIND_AAVE,
            "Recovery"
        );

        vm.prank(timelock);
        recoveryProposal.approveRecovery(proposalId);

        vm.warp(block.timestamp + 2 days + 1);

        vm.prank(timelock);
        recoveryProposal.executeRecovery(proposalId);

        // Try to execute again
        vm.prank(timelock);
        vm.expectRevert();
        recoveryProposal.executeRecovery(proposalId);
    }

    // ============ Test 14: Delay calculation accuracy ============
    function test_DelayCalculationAccuracy() public {
        vm.prank(guardian);
        vault.pause("Emergency incident");

        vm.prank(timelock);
        uint256 proposalId = recoveryProposal.proposeRecovery(
            EmergencyRecoveryProposal.RecoveryAction.EMERGENCY_UNWIND_AAVE,
            "Recovery"
        );

        vm.prank(timelock);
        recoveryProposal.approveRecovery(proposalId);

        uint256 approvedAt = block.timestamp;

        // Check delay at various points
        assertEq(recoveryProposal.getExecutionDelay(proposalId), 2 days);

        vm.warp(approvedAt + 1 days);
        assertEq(recoveryProposal.getExecutionDelay(proposalId), 1 days);

        vm.warp(approvedAt + 2 days);
        assertEq(recoveryProposal.getExecutionDelay(proposalId), 0);

        vm.warp(approvedAt + 3 days);
        assertEq(recoveryProposal.getExecutionDelay(proposalId), 0);
    }

    // ============ Test 15: Recovery proposal access control ============
    function test_RecoveryProposalAccessControl() public {
        vm.prank(guardian);
        vault.pause("Emergency incident");

        address nonProposer = address(0x9999);

        // Non-proposer cannot propose
        vm.prank(nonProposer);
        vm.expectRevert();
        recoveryProposal.proposeRecovery(
            EmergencyRecoveryProposal.RecoveryAction.EMERGENCY_UNWIND_AAVE,
            "Attempt"
        );

        // Proposer can propose
        vm.prank(timelock);
        uint256 proposalId = recoveryProposal.proposeRecovery(
            EmergencyRecoveryProposal.RecoveryAction.EMERGENCY_UNWIND_AAVE,
            "Recovery"
        );

        // Non-executor cannot approve
        vm.prank(nonProposer);
        vm.expectRevert();
        recoveryProposal.approveRecovery(proposalId);

        // Executor can approve
        vm.prank(timelock);
        recoveryProposal.approveRecovery(proposalId);
    }
}
