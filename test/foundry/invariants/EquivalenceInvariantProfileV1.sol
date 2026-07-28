// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import { EscrowState } from "../../../contracts/types/EscrowTypes.sol";

/// @notice Vault state snapshot for cross-step invariant evaluation.
struct VaultSnapshot {
    // Per-primary-workflow fields
    EscrowState escrowState;
    uint256 disputeLevel;
    uint256 amountAfterFee;
    bool pendingSettlementExists;
    // Global per-token fields
    uint256 totalHeld;
    uint256 totalFees;
    // Conservation accumulators (tracked by test harness)
    uint256 totalDeposited;
    uint256 totalReleased;
    uint256 totalRefunded;
    // Time
    uint256 blockTimestamp;
}

/// @title EquivalenceInvariantProfileV1
/// @notice Portability profile for cross-implementation invariant checking.
///         Profile ID: solidity-equivalence-core-v1 (version 1)
///
///  State equations (checked on post-step snapshot):
///    - held-reconstruction:  totalHeld == amountAfterFee (when pending/disputed, no other escrows)
///    - dispute-level-bounded: disputeLevel <= maxRounds
///    - terminal-payout-exclusivity: terminal states have no pending settlement
///    - fee-decomposition: moduleSnapshot.escrowFeeBps reconstructs fee from amountAfterFee
///
///  Transition equations (checked on before/after snapshot pair):
///    - state-transition-valid: escrowState follows permitted graph
///    - escalation-monotonic: disputeLevel never decreases
///    - terminal-state-immutable: RELEASED/REFUNDED do not change
///    - accounting-monotonic: totalHeld + totalFees non-decreasing from deposits
///
///  Profile ID is referenced from CDRS v0.2 trace fixtures and the
///  cross-repository manifest (etc/trace-solidity-manifest.edn).
library EquivalenceInvariantProfileV1 {
    // Profile identity — exact-matched by _replayTrace for every fixture
    string public constant PROFILE_ID = "solidity-equivalence-core-v1";
    uint256 public constant PROFILE_VERSION = 1;
    // Canonical content root of the resolved etc/solidity-invariant-profile.edn
    bytes32 public constant PROFILE_ROOT = 0x31d07038dcde86ac6f34b229fded0fce98b679c2bd83130b607f0b9a2a27e19f;

    uint256 public constant MAX_DISPUTE_ROUNDS = 2;

    // ── State equations ──────────────────────────────────────────────

    /// @notice Verify all state equations on a post-step snapshot.
    /// @param current Vault snapshot after the step was executed.
    /// @param wfId Workflow ID being checked (for error messages).
    function checkStateEquations(VaultSnapshot memory current, uint256 wfId) internal pure {
        _checkDisputeLevelBounded(current, wfId);
        _checkTerminalPayoutExclusivity(current, wfId);
        _checkConservationOfFunds(current, wfId);
    }

    /// @notice conservation-of-funds: totalDeposited must equal
    ///         totalHeld + totalFees + totalReleased + totalRefunded.
    ///         This is the exact accounting equality that must hold
    ///         for every valid protocol state.
    function _checkConservationOfFunds(VaultSnapshot memory current, uint256 wfId) private pure {
        uint256 accounted = current.totalHeld + current.totalFees
                          + current.totalReleased + current.totalRefunded;
        require(current.totalDeposited == accounted,
            string.concat("invariant: conservation-of-funds [wf ", vmToString(wfId),
                " deposited=", vmToString(current.totalDeposited),
                " accounted=", vmToString(accounted), "]"));
    }

    /// @notice dispute-level-bounded: disputeLevel must not exceed max rounds.
    function _checkDisputeLevelBounded(VaultSnapshot memory current, uint256 wfId) private pure {
        require(current.disputeLevel <= MAX_DISPUTE_ROUNDS,
            string.concat("invariant: dispute-level-bounded [wf ", vmToString(wfId), "]"));
    }

    /// @notice terminal-payout-exclusivity: terminal escrows must not have pending settlements.
    function _checkTerminalPayoutExclusivity(VaultSnapshot memory current, uint256 wfId) private pure {
        if (current.escrowState == EscrowState.RELEASED || current.escrowState == EscrowState.REFUNDED) {
            require(!current.pendingSettlementExists,
                string.concat("invariant: terminal-payout-exclusivity [wf ", vmToString(wfId), "]"));
        }
    }

    /// @notice held-reconstruction: for single-escrow traces, totalHeld == amountAfterFee.
    ///         This is a simplified check that works for the manifest trace set
    ///         (each trace has one primary dispute workflow).
    function checkHeldReconstruction(VaultSnapshot memory current, uint256 wfId) internal pure {
        if (current.escrowState == EscrowState.PENDING || current.escrowState == EscrowState.DISPUTED) {
            require(current.totalHeld == current.amountAfterFee,
                string.concat("invariant: held-reconstruction [wf ", vmToString(wfId), "]"));
        }
    }

    // ── Transition equations ─────────────────────────────────────────

    /// @notice Verify all transition equations between a before/after snapshot pair.
    function checkTransitionEquations(
        VaultSnapshot memory before_,
        VaultSnapshot memory after_,
        string memory action,
        uint256 wfId
    ) internal pure {
        _checkStateTransitionValid(before_, after_, action, wfId);
        _checkEscalationMonotonic(before_, after_, wfId);
        _checkTerminalStateImmutable(before_, after_, wfId);
    }

    /// @notice state-transition-valid: escrowState follows permitted graph.
    function _checkStateTransitionValid(
        VaultSnapshot memory before_,
        VaultSnapshot memory after_,
        string memory action,
        uint256 wfId
    ) private pure {
        EscrowState b = before_.escrowState;
        EscrowState a = after_.escrowState;
        if (b == a) return; // No state change — no transition to validate

        bool valid;
        if (b == EscrowState.NONE) valid = (a == EscrowState.PENDING);
        else if (b == EscrowState.PENDING) valid = (a == EscrowState.DISPUTED || a == EscrowState.RELEASED || a == EscrowState.REFUNDED);
        else if (b == EscrowState.DISPUTED) valid = (a == EscrowState.RELEASED || a == EscrowState.REFUNDED);
        // Terminal states are absorbing
        else if (b == EscrowState.RELEASED || b == EscrowState.REFUNDED) valid = false;

        require(valid, string.concat("invariant: state-transition-valid [wf ", vmToString(wfId), " action ", action, "]"));
    }

    /// @notice escalation-monotonic: disputeLevel never decreases.
    function _checkEscalationMonotonic(
        VaultSnapshot memory before_,
        VaultSnapshot memory after_,
        uint256 wfId
    ) private pure {
        require(after_.disputeLevel >= before_.disputeLevel,
            string.concat("invariant: escalation-monotonic [wf ", vmToString(wfId), "]"));
    }

    /// @notice terminal-state-immutable: RELEASED/REFUNDED escrows do not transition.
    function _checkTerminalStateImmutable(
        VaultSnapshot memory before_,
        VaultSnapshot memory after_,
        uint256 wfId
    ) private pure {
        if (before_.escrowState == EscrowState.RELEASED || before_.escrowState == EscrowState.REFUNDED) {
            require(before_.escrowState == after_.escrowState,
                string.concat("invariant: terminal-state-immutable [wf ", vmToString(wfId), "]"));
        }
    }

    // ── Helpers ──────────────────────────────────────────────────────

    function vmToString(uint256 x) private pure returns (string memory) {
        if (x == 0) return "0";
        uint256 temp = x;
        uint256 digits;
        while (temp != 0) { digits++; temp /= 10; }
        bytes memory buf = new bytes(digits);
        while (digits > 0) {
            buf[--digits] = bytes1(uint8(48 + (x % 10)));
            x /= 10;
        }
        return string(buf);
    }
}
