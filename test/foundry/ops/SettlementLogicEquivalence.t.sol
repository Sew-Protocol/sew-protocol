// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.37;

import 'forge-std/Test.sol';
import '../../mocks/legacy/SettlementOpsReference.sol';
import '../../../contracts/libraries/EscrowSettlementLogic.sol';
import '../../../contracts/types/EscrowTypes.sol';

/// @notice Minimal module returning a fixed appeal deadline/round response.
contract DeadlineModule {
    uint256 internal immutable dl;
    uint8 internal immutable round;
    bool internal immutable finalRound;

    constructor(uint256 _dl, uint8 _round, bool _finalRound) {
        dl = _dl;
        round = _round;
        finalRound = _finalRound;
    }

    function getAppealDeadlineAndRound(uint256, address) external view returns (uint256, uint8, bool) {
        return (dl, round, finalRound);
    }
}

/// @notice Differential coverage: EscrowSettlementLogic must match the legacy
///         externally deployed SettlementOpsReference for all derived results.
contract SettlementLogicEquivalenceTest is Test {
    SettlementOpsReference internal ops;

    function setUp() public {
        ops = new SettlementOpsReference(address(this));
        ops.grantRole(ops.ROLE_ESCROW_CONTRACT(), address(this));
    }

    function _opsPending(bool exists, bool isRelease, uint256 deadline)
        internal
        pure
        returns (SettlementOpsReference.SettlementPendingSettlement memory p)
    {
        p = SettlementOpsReference.SettlementPendingSettlement({
            exists: exists,
            isRelease: isRelease,
            appealDeadline: deadline,
            resolutionHash: bytes32(0)
        });
    }

    function _libPending(bool exists, bool isRelease, uint256 deadline)
        internal
        pure
        returns (EscrowSettlementLogic.SettlementPendingSettlement memory q)
    {
        q = EscrowSettlementLogic.SettlementPendingSettlement({
            exists: exists,
            isRelease: isRelease,
            appealDeadline: deadline,
            resolutionHash: bytes32(0)
        });
    }

    function _et(EscrowState state, uint64 rel, uint64 canc) internal pure returns (EscrowTransfer memory et) {
        et = EscrowTransfer({
            token: address(0),
            to: address(0),
            from: address(0),
            disputeResolver: address(0),
            amountAfterFee: 0,
            autoReleaseTime: rel,
            autoCancelTime: canc,
            escrowState: state,
            senderStatus: SenderStatus.NONE,
            recipientStatus: RecipientStatus.NONE
        });
    }

    function testFuzz_equiv_computeTimedActions(
        uint8 stateRaw,
        uint64 autoReleaseTime,
        uint64 autoCancelTime,
        bool pendingExists,
        bool pendingIsRelease,
        uint64 appealDeadline,
        uint256 maxDisputeDuration,
        uint256 disputeRaisedTimestamp,
        bool pendingAutoCancelEnabled
    ) public {
        vm.warp(1_000_000);
        EscrowState state = EscrowState(stateRaw % 6);
        maxDisputeDuration = bound(maxDisputeDuration, 0, 3650 days);
        disputeRaisedTimestamp = bound(disputeRaisedTimestamp, 0, 1e12);
        TimeoutConfig memory cfg = TimeoutConfig(0, 0, maxDisputeDuration, 0);
        EscrowTransfer memory et = _et(state, autoReleaseTime, autoCancelTime);

        (uint8 a1, bool r1) = ops.computeTimedActions(
            1, et, _opsPending(pendingExists, pendingIsRelease, appealDeadline), cfg,
            pendingAutoCancelEnabled, disputeRaisedTimestamp
        );
        (uint8 a2, bool r2) = EscrowSettlementLogic.computeTimedActions(
            1, et, _libPending(pendingExists, pendingIsRelease, appealDeadline), cfg,
            pendingAutoCancelEnabled, disputeRaisedTimestamp
        );
        assertEq(a1, a2, 'actionType mismatch');
        assertEq(r1, r2, 'isRelease mismatch');
    }

    function testFuzz_equiv_computeTimedActions_legacyOverload(
        uint8 stateRaw,
        uint64 autoReleaseTime,
        uint64 autoCancelTime,
        bool pendingExists,
        bool pendingIsRelease,
        uint64 appealDeadline,
        uint8 defaultAutoCancelDelay
    ) public {
        vm.warp(1_000_000);
        EscrowState state = EscrowState(stateRaw % 6);
        TimeoutConfig memory cfg = TimeoutConfig(0, defaultAutoCancelDelay, 0, 0);
        EscrowTransfer memory et = _et(state, autoReleaseTime, autoCancelTime);

        (uint8 a1, bool r1) =
            ops.computeTimedActions(1, et, _opsPending(pendingExists, pendingIsRelease, appealDeadline), cfg);
        (uint8 a2, bool r2) =
            EscrowSettlementLogic.computeTimedActions(1, et, _libPending(pendingExists, pendingIsRelease, appealDeadline), cfg);
        assertEq(a1, a2, 'actionType mismatch');
        assertEq(r1, r2, 'isRelease mismatch');
    }

    function testFuzz_equiv_computePendingSettlementExecution(
        uint8 stateRaw,
        bool exists,
        bool isRelease,
        uint64 appealDeadline
    ) public {
        vm.warp(1_000_000);
        EscrowState state = EscrowState(stateRaw % 6);
        (bool c1, bool r1) =
            ops.computePendingSettlementExecution(1, _opsPending(exists, isRelease, appealDeadline), state);
        (bool c2, bool r2) =
            EscrowSettlementLogic.computePendingSettlementExecution(1, _libPending(exists, isRelease, appealDeadline), state);
        assertEq(c1, c2, 'canExecute mismatch');
        assertEq(r1, r2, 'isRelease mismatch');
    }

    function testFuzz_equiv_computeResolutionExecution_noModule(bool isRelease, uint256 appealWindowDuration) public {
        vm.warp(1_000_000);
        appealWindowDuration = bound(appealWindowDuration, 0, 3650 days);
        TimeoutConfig memory cfg = TimeoutConfig(0, 0, 0, appealWindowDuration);
        SettlementOpsReference.ResolutionResult memory r1 = ops.computeResolutionExecution(address(0), 1, isRelease, cfg);
        EscrowSettlementLogic.ResolutionResult memory r2 =
            EscrowSettlementLogic.computeResolutionExecution(address(0), 1, isRelease, cfg, address(this));
        _assertResolutionEq(r1, r2);
    }

    function testFuzz_equiv_computeResolutionExecution_nonModuleContract(bool isRelease, uint256 appealWindowDuration)
        public
    {
        vm.warp(1_000_000);
        appealWindowDuration = bound(appealWindowDuration, 0, 3650 days);
        TimeoutConfig memory cfg = TimeoutConfig(0, 0, 0, appealWindowDuration);
        SettlementOpsReference.ResolutionResult memory r1 = ops.computeResolutionExecution(address(this), 1, isRelease, cfg);
        EscrowSettlementLogic.ResolutionResult memory r2 =
            EscrowSettlementLogic.computeResolutionExecution(address(this), 1, isRelease, cfg, address(this));
        _assertResolutionEq(r1, r2);
    }

    function testFuzz_equiv_computeResolutionExecution_moduleResponse(
        bool isRelease,
        uint64 deadlineOffset,
        uint8 roundRaw,
        bool finalRound,
        uint256 appealWindowDuration
    ) public {
        vm.warp(1_000_000);
        uint256 deadline = block.timestamp + uint64(deadlineOffset);
        DeadlineModule module = new DeadlineModule(deadline, roundRaw, finalRound);
        appealWindowDuration = bound(appealWindowDuration, 0, 3650 days);
        TimeoutConfig memory cfg = TimeoutConfig(0, 0, 0, appealWindowDuration);
        SettlementOpsReference.ResolutionResult memory r1 = ops.computeResolutionExecution(address(module), 1, isRelease, cfg);
        EscrowSettlementLogic.ResolutionResult memory r2 =
            EscrowSettlementLogic.computeResolutionExecution(address(module), 1, isRelease, cfg, address(this));
        _assertResolutionEq(r1, r2);
    }

    function _assertResolutionEq(
        SettlementOpsReference.ResolutionResult memory r1,
        EscrowSettlementLogic.ResolutionResult memory r2
    ) internal pure {
        assertEq(r1.shouldExecute, r2.shouldExecute, 'shouldExecute mismatch');
        assertEq(r1.isRelease, r2.isRelease, 'isRelease mismatch');
        assertEq(r1.appealDeadline, r2.appealDeadline, 'appealDeadline mismatch');
        assertEq(r1.isFinalRound, r2.isFinalRound, 'isFinalRound mismatch');
    }
}
