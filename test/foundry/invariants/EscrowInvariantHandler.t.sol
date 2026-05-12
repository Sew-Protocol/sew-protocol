// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import "forge-std/Test.sol";
import "../../../contracts/core/EscrowVault.sol";
import "../../../contracts/core/EscrowVaultAnalytics.sol";
import "../../../contracts/core/modules/DefaultResolutionModule.sol";
import "../../../contracts/core/ModuleSnapshotRegistry.sol";
import "../../../contracts/admin/EscrowGovernanceTimelock.sol";
import "../../../contracts/ops/YieldOps.sol";
import "../../../contracts/ops/DisputeOps.sol";
import "../../../contracts/ops/SettlementOps.sol";
import "../../../contracts/ops/CreateOps.sol";
import "../../../contracts/core/BondCollector.sol";
import "../../../contracts/mocks/ERC20Mock.sol";
import "../../../contracts/libraries/SettingsValidationLibrary.sol";
import "../../../contracts/types/EscrowTypes.sol";

/// @title EscrowInvariantHandler
/// @notice Comprehensive action handler for Foundry invariant fuzzing of EscrowVault.
///
/// Covers all lifecycle paths derived from the contract model (invariants.clj):
///   create → release / cancel (sender+recipient) / raiseDispute
///   raiseDispute → resolveRelease / resolveRefund / autoCancelDisputed
///   resolve → executePendingSettlement
///   any state → automateTimedActions
///
/// Ghost variables track state that is invisible to the invariant checkers:
///   ghostTotalFeesBefore   — fee snapshot before last non-withdraw call
///   ghostTerminalIds       — set of workflowIds known to be in terminal state
///   ghostTerminalStates    — their recorded terminal state at time of detection
///
/// All handler functions bound random inputs and skip when preconditions can't
/// be satisfied cheaply (rather than trying to set them up — the fuzzer will
/// find the reachable paths).
contract EscrowInvariantHandler is Test {
    // ---------------------------------------------------------------------------
    // Deployed contracts
    // ---------------------------------------------------------------------------
    EscrowVault     public vault;
    ERC20Mock       public token;
    DefaultResolutionModule public resModule;

    // ---------------------------------------------------------------------------
    // Actors
    // ---------------------------------------------------------------------------
    address public sender    = address(0x1001);
    address public recipient = address(0x1002);
    address public resolver  = address(0x1003);
    address public feeAddr   = address(0x1004);
    address public keeper    = address(0x1005);

    // ---------------------------------------------------------------------------
    // Ghost variables
    // ---------------------------------------------------------------------------
    uint256 public ghostFeesBefore;
    mapping(uint256 => bool)        public ghostIsTerminal;
    mapping(uint256 => EscrowState) public ghostTerminalState;

    // ---------------------------------------------------------------------------
    // Constructor — receives the fully wired vault
    // ---------------------------------------------------------------------------
    constructor(EscrowVault _vault, ERC20Mock _token, DefaultResolutionModule _rm) {
        vault    = _vault;
        token    = _token;
        resModule = _rm;
        // Snapshot initial fees (zero)
        ghostFeesBefore = vault.totalFeesPerToken(address(token));
    }

    // ---------------------------------------------------------------------------
    // Internal: ghost bookkeeping
    // ---------------------------------------------------------------------------

    function _snapshotFees() internal {
        ghostFeesBefore = vault.totalFeesPerToken(address(token));
    }

    function _recordTerminalIfNeeded(uint256 workflowId) internal {
        if (workflowId >= vault.getEscrowCount()) return;
        (,,,,,,, EscrowState st,,) = vault.escrowTransfers(workflowId);
        bool isTerminal = (st == EscrowState.RELEASED ||
                           st == EscrowState.REFUNDED  ||
                           st == EscrowState.RESOLVED);
        if (isTerminal && !ghostIsTerminal[workflowId]) {
            ghostIsTerminal[workflowId]   = true;
            ghostTerminalState[workflowId] = st;
        }
    }

    // ---------------------------------------------------------------------------
    // ACTION: createEscrow
    // ---------------------------------------------------------------------------
    function createEscrow(uint256 amount) external {
        _snapshotFees();
        amount = bound(amount, 1e4, 1_000_000e18);
        token.mint(sender, amount);

        EscrowSettings memory settings = SettingsValidationLibrary.getDefaultSettings();

        vm.startPrank(sender);
        token.approve(address(vault), amount);
        try vault.createEscrow(address(token), recipient, amount, settings) {}
        catch {}
        vm.stopPrank();
    }

    // ---------------------------------------------------------------------------
    // ACTION: release (via releaseEscrowTransfer — sender calls with default strategy)
    // ---------------------------------------------------------------------------
    function releaseEscrow(uint256 seed) external {
        _snapshotFees();
        uint256 count = vault.getEscrowCount();
        if (count == 0) return;
        uint256 wf = bound(seed, 0, count - 1);
        _recordTerminalIfNeeded(wf);

        vm.prank(sender);
        try vault.release(wf) {} catch {}

        _recordTerminalIfNeeded(wf);
    }

    // ---------------------------------------------------------------------------
    // ACTION: senderCancel
    // ---------------------------------------------------------------------------
    function senderCancel(uint256 seed) external {
        _snapshotFees();
        uint256 count = vault.getEscrowCount();
        if (count == 0) return;
        uint256 wf = bound(seed, 0, count - 1);

        vm.prank(sender);
        try vault.senderCancel(wf) {} catch {}

        _recordTerminalIfNeeded(wf);
    }

    // ---------------------------------------------------------------------------
    // ACTION: recipientCancel
    // ---------------------------------------------------------------------------
    function recipientCancel(uint256 seed) external {
        _snapshotFees();
        uint256 count = vault.getEscrowCount();
        if (count == 0) return;
        uint256 wf = bound(seed, 0, count - 1);

        vm.prank(recipient);
        try vault.recipientCancel(wf) {} catch {}

        _recordTerminalIfNeeded(wf);
    }

    // ---------------------------------------------------------------------------
    // ACTION: raiseDispute
    // ---------------------------------------------------------------------------
    function raiseDispute(uint256 seed) external {
        _snapshotFees();
        uint256 count = vault.getEscrowCount();
        if (count == 0) return;
        uint256 wf = bound(seed, 0, count - 1);

        vm.prank(sender);
        try vault.raiseDispute(wf) {} catch {}
    }

    // ---------------------------------------------------------------------------
    // ACTION: resolveWithRelease (dispute resolver)
    // ---------------------------------------------------------------------------
    function resolveWithRelease(uint256 seed) external {
        _snapshotFees();
        uint256 count = vault.getEscrowCount();
        if (count == 0) return;
        uint256 wf = bound(seed, 0, count - 1);

        vm.prank(resolver);
        try vault.releaseAsDisputeResolver(wf, bytes32(0)) {} catch {}

        _recordTerminalIfNeeded(wf);
    }

    // ---------------------------------------------------------------------------
    // ACTION: resolveWithRefund (dispute resolver)
    // ---------------------------------------------------------------------------
    function resolveWithRefund(uint256 seed) external {
        _snapshotFees();
        uint256 count = vault.getEscrowCount();
        if (count == 0) return;
        uint256 wf = bound(seed, 0, count - 1);

        vm.prank(resolver);
        try vault.cancelAsDisputeResolver(wf, bytes32(0)) {} catch {}

        _recordTerminalIfNeeded(wf);
    }

    // ---------------------------------------------------------------------------
    // ACTION: executePendingSettlement
    // ---------------------------------------------------------------------------
    function executePendingSettlement(uint256 seed) external {
        _snapshotFees();
        uint256 count = vault.getEscrowCount();
        if (count == 0) return;
        uint256 wf = bound(seed, 0, count - 1);

        try vault.executePendingSettlement(wf) {} catch {}

        _recordTerminalIfNeeded(wf);
    }

    // ---------------------------------------------------------------------------
    // ACTION: autoCancelDisputedEscrow
    // ---------------------------------------------------------------------------
    function autoCancelDisputed(uint256 seed) external {
        _snapshotFees();
        uint256 count = vault.getEscrowCount();
        if (count == 0) return;
        uint256 wf = bound(seed, 0, count - 1);

        try vault.autoCancelDisputedEscrow(wf) {} catch {}

        _recordTerminalIfNeeded(wf);
    }

    // ---------------------------------------------------------------------------
    // ACTION: automateTimedActions
    // ---------------------------------------------------------------------------
    function automateTimedActions(uint256 seed) external {
        _snapshotFees();
        uint256 count = vault.getEscrowCount();
        if (count == 0) return;
        uint256 wf = bound(seed, 0, count - 1);

        try vault.automateTimedActions(wf) {} catch {}

        _recordTerminalIfNeeded(wf);
    }

    // ---------------------------------------------------------------------------
    // ACTION: warpTime (allows timed actions to become eligible)
    // ---------------------------------------------------------------------------
    function warpTime(uint256 delta) external {
        delta = bound(delta, 0, 30 days);
        vm.warp(block.timestamp + delta);
    }

    // ---------------------------------------------------------------------------
    // Non-fee-snapshot action: withdrawFees (explicitly exempt from monotonicity)
    // ---------------------------------------------------------------------------
    function withdrawFees() external {
        // NOTE: does NOT snapshot ghostFeesBefore — callers check monotonicity
        // only between non-withdraw operations. This action resets the baseline.
        vm.prank(feeAddr);
        try vault.withdrawFees(address(token)) {} catch {}
        // Reset snapshot so the invariant measures from the new baseline.
        ghostFeesBefore = vault.totalFeesPerToken(address(token));
    }
}
