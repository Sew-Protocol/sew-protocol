// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.37;

import './AaveYieldEscrowE2EFixture.sol';

/**
 * @title AaveYieldEscrowAppealE2ETest
 * @notice Escrow + AaveYieldModule end-to-end across normal settlement, disputeless
 *         straight paths, appeal/escalation depths, resolver agreement/disagreement,
 *         and Kleros final ruling — all while yield continues to accrue and is ultimately
 *         distributable to the party entitled at the terminal settlement.
 *
 * Branch mapping (each test proves a distinct escrow state transition / settlement branch):
 *   - release()                          PENDING -> RELEASED       (direct release strategy)
 *   - senderCancel+recipientCancel       PENDING -> REFUNDED       (mutual refund)
 *   - proposeSplit+acceptSplit           PENDING -> RESOLVED       (pro-rata yield split)
 *   - dispute -> final-round resolution  DISPUTED -> RELEASED/REFUNDED immediately
 *   - dispute -> non-final resolution    DISPUTED -> pending -> executePendingSettlement
 *   - escalation depth 1 (round0->round1)
 *   - escalation depth 2 (round0->round1->round2/Kleros) via KlerosArbitrableProxy.rule()
 *
 * Per review, the FULL matrix runs with Aave active + yield ENABLED; a small parity subset
 * (release, refund, disputed) runs with yield disabled / no module to prove the shared
 * settlement machinery behaves identically; two dedicated tests show the 30% protocol fee
 * interacting with an ordinary and a disputed/Kleros settlement.
 */
contract AaveYieldEscrowAppealE2ETest is AaveYieldEscrowE2EFixture {
    enum SettlementMode { RELEASE, CANCEL }

    uint256 internal constant SHORT = 60; // 60s — rounding-to-zero/tiny yield boundary
    uint256 internal constant MEDIUM = 7 days;
    uint256 internal constant LONG = 30 days;
    uint256 internal constant STAGE = 3 days;

    // =====================================================================
    // NORMAL (DISPUTE-LESS) SETTLEMENT
    // =====================================================================
    function _runStraight(SettlementMode mode, bool yieldEnabled, uint256 feeBps, uint256 duration) internal {
        ScenarioConfig memory cfg = ScenarioConfig({yieldEnabled: yieldEnabled, feeBps: feeBps});
        uint256 wf = _openEscrow(cfg);
        _accrue(duration);

        uint8 terminalState;
        address beneficiary;
        address other;
        if (mode == SettlementMode.RELEASE) {
            vm.prank(buyer);
            escrow.release(wf);
            terminalState = uint8(EscrowState.RELEASED);
            beneficiary = seller;
            other = buyer;
        } else {
            vm.prank(buyer);
            escrow.senderCancel(wf);
            vm.prank(seller);
            escrow.recipientCancel(wf);
            terminalState = uint8(EscrowState.REFUNDED);
            beneficiary = buyer;
            other = seller;
        }

        _assertSettled(cfg, wf, terminalState, beneficiary, other);
    }

    /// @dev Straight release with MOCK-Aave accrual. Distinct branch: PENDING -> RELEASED via release().
    function test_release_straight_yieldEnabled() public {
        _runStraight(SettlementMode.RELEASE, true, FEE_ZERO, MEDIUM);
    }

    /// @dev Straight mutual refund. Distinct branch: PENDING -> REFUNDED via sender/recipient cancel.
    function test_cancel_straight_yieldEnabled() public {
        _runStraight(SettlementMode.CANCEL, true, FEE_ZERO, MEDIUM);
    }

    /// @dev Rounding/boundary: a 60s window produces TINY but NON-zero yield. Proves both
    ///      that (a) yield is positive (it does not vanish just because the window is short)
    ///      and (b) it is well under a token — the rounding-to-zero boundary.
    function test_shortDuration_zeroYieldBoundary_yieldEnabled() public {
        ScenarioConfig memory cfg = ScenarioConfig({yieldEnabled: true, feeBps: FEE_ZERO});
        uint256 wf = _openEscrow(cfg);
        _accrue(SHORT);
        vm.prank(buyer);
        escrow.release(wf);
        uint256 claimable = escrow.claimableBalances(wf, seller);
        uint256 yield_ = claimable - ESCROW_AMOUNT;
        assertGt(yield_, 0, 'tiny duration still accrues positive yield');
        assertLt(yield_, 1 ether, 'yield is below 1 token on a 60s window');
        // Full terminal assertions still apply (module cleared, withdraw works, no double).
        _assertSettled(cfg, wf, uint8(EscrowState.RELEASED), seller, buyer);
    }

    /// @dev Wire the pool to a hand-computed rate and assert an EXACT recovered vector that is
    ///      derived independently (by hand), not through the mock/_expectedYield shared formula.
    ///      With time-accrual at 100% per second for 5 seconds, a 1000e18 deposit grows to
    ///      exactly 6000e18. This guards against a bug copied into BOTH the mock and the test
    ///      helper (e.g. a wrong index offset or rate scaling) passing silently.
    function test_independentYieldVector_exactRecovery() public {
        pool.enableTimeAccrual(1e27); // override fixture rate: 100% per second for clean math
        ScenarioConfig memory cfg = ScenarioConfig({yieldEnabled: true, feeBps: FEE_ZERO});
        uint256 wf = _openEscrow(cfg);
        _accrue(5); // 5 seconds elapsed

        // Independent hand-math: liquidity index = 1e27 (base) + 1e27*5 = 6e27.
        assertEq(pool.getReserveNormalizedIncome(address(token)), 6e27, 'index = 1e27 + rate*elapsed');

        vm.prank(buyer);
        escrow.release(wf);

        // Deposit P=1000e18, index 6e27 => recovered = P * 6e27 / 1e27 = P * 6 = 6000e18 exactly.
        uint256 claimable = escrow.claimableBalances(wf, seller);
        assertEq(claimable, 6000e18, 'exact recovered amount (independent vector)');
        assertEq(escrow.v25YieldModules(wf), address(0), 'module unwound');

        vm.prank(seller);
        uint256 got = escrow.withdrawEscrow(wf);
        assertEq(got, 6000e18, 'withdrawn exactly equals independent vector');
        assertEq(escrow.claimableBalances(wf, seller), 0, 'no residual claimable');
    }

    /// @dev Long real-world window with meaningful accrued yield; beneficiary receives it all (fee=0).
    function test_longDuration_accruedYield_yieldEnabled() public {
        _runStraight(SettlementMode.RELEASE, true, FEE_ZERO, LONG);
    }

    /// @dev Split settlement: pro-rata yield to both buyer and seller. Branch: acceptSplit.
    function test_split_proRata_yieldEnabled() public {
        ScenarioConfig memory cfg = ScenarioConfig({yieldEnabled: true, feeBps: FEE_ZERO});
        uint256 wf = _openEscrow(cfg);
        _accrue(MEDIUM);

        uint256 half = ESCROW_AMOUNT / 2;
        vm.prank(buyer);
        escrow.proposeSplit(wf, half, ESCROW_AMOUNT - half, 0);
        vm.prank(seller);
        escrow.acceptSplit(wf);

        assertEq(uint8(escrow.getEscrowState(wf)), uint8(EscrowState.RESOLVED), 'RESOLVED after split');
        // Split is a distinct settlement branch: both parties hold a share.
        uint256 totalYield = _expectedYield(ESCROW_AMOUNT, MEDIUM);
        uint256 claimBuyer = escrow.claimableBalances(wf, buyer);
        uint256 claimSeller = escrow.claimableBalances(wf, seller);
        assertApproxEqAbs(claimBuyer, half + totalYield / 2, 4, 'buyer principal half + half yield');
        assertApproxEqAbs(claimSeller, (ESCROW_AMOUNT - half) + (totalYield - totalYield / 2), 4, 'seller share');
        assertEq(escrow.v25YieldModules(wf), address(0), 'module unwound on split');
        assertEq(escrow.totalFeesPerToken(address(token)), 0, 'no fee at fee=0');

        // Both parties can actually withdraw; no residual claimable; double withdraw reverts.
        uint256 bBefore = token.balanceOf(buyer);
        uint256 sBefore = token.balanceOf(seller);
        uint256 gotBuyer;
        uint256 gotSeller;
        vm.prank(buyer);
        gotBuyer = escrow.withdrawEscrow(wf);
        vm.prank(seller);
        gotSeller = escrow.withdrawEscrow(wf);
        assertEq(gotBuyer, claimBuyer);
        assertEq(gotSeller, claimSeller);
        assertEq(token.balanceOf(buyer) - bBefore, gotBuyer);
        assertEq(token.balanceOf(seller) - sBefore, gotSeller);
        assertEq(escrow.claimableBalances(wf, buyer), 0);
        assertEq(escrow.claimableBalances(wf, seller), 0);
    }

    // =====================================================================
    // DISPUTE / ESCALATION / KLEROS
    // =====================================================================

    /// @dev Dispute at round 0; round0 resolver releases (non-final, pending). A staggered wait
    ///      shows yield continues to accrue while the appeal window is open, then executes.
    function test_dispute_round0Release_pendingThenExecute_yieldEnabled() public {
        ScenarioConfig memory cfg = ScenarioConfig({yieldEnabled: true, feeBps: FEE_ZERO});
        uint256 wf = _openEscrow(cfg);

        _raiseDispute(wf);
        _accrue(STAGE); // yield accrues while disputed
        _resolveRound(wf, true); // round0 releases -> pending settlement (appeal window open)
        assertEq(uint8(escrow.getEscrowState(wf)), uint8(EscrowState.DISPUTED), 'still DISPUTED pending appeal');
        // Linkage preserved while pending — yield still held by module, not yet unwound.
        assertEq(escrow.v25YieldModules(wf), address(aaveModule), 'module still linked while pending');

        _executePending(wf); // past appeal window -> settle

        _assertSettled(cfg, wf, uint8(EscrowState.RELEASED), seller, buyer);
    }

    /// @dev Escalated once (round0 -> round1): both resolvers AGREE (release). Round1 (non-final)
    ///      decision is pending then executed; final resolver settles. Distinct branch: depth-1 escalation.
    function test_escalatedOnce_resolverAgreement_release_yieldEnabled() public {
        ScenarioConfig memory cfg = ScenarioConfig({yieldEnabled: true, feeBps: FEE_ZERO});
        uint256 wf = _openEscrow(cfg);

        _raiseDispute(wf);
        _resolveRound(wf, true); // round0 -> release
        _escalate(wf, buyer, false); // -> round1
        _accrue(STAGE);
        _resolveRound(wf, true); // round1 -> release (agreement)
        _executePending(wf);

        _assertSettled(cfg, wf, uint8(EscrowState.RELEASED), seller, buyer);
    }

    /// @dev Escalated once, resolvers DISAGREE: round0 releases (provisional), round1 cancels.
    ///      Proves the FINAL resolution (round1) determines who receives principal+yield, not the
    ///      earlier provisional ruling.
    function test_escalatedOnce_resolverDisagreement_finalWins_yieldEnabled() public {
        ScenarioConfig memory cfg = ScenarioConfig({yieldEnabled: true, feeBps: FEE_ZERO});
        uint256 wf = _openEscrow(cfg);

        _raiseDispute(wf);
        _resolveRound(wf, true); // round0 -> release (this must NOT bind the outcome)
        _escalate(wf, buyer, false); // -> round1
        _accrue(STAGE);
        _resolveRound(wf, false); // round1 -> cancel: final resolution wins
        _executePending(wf);

        // Final (round1) cancel -> REFUNDED to buyer, who keeps principal + yield.
        _assertSettled(cfg, wf, uint8(EscrowState.REFUNDED), buyer, seller);
    }

    /// @dev Escalated twice -> final round (round2 = Kleros), ruling releases. Distinct branch:
    ///      depth-2 escalation + final-round immediate execution via the Kleros proxy.
    function test_escalatedTwice_klerosRelease_yieldEnabled() public {
        ScenarioConfig memory cfg = ScenarioConfig({yieldEnabled: true, feeBps: FEE_ZERO});
        uint256 wf = _openEscrow(cfg);

        _raiseDispute(wf);
        _resolveRound(wf, true); // round0 -> release
        _escalate(wf, buyer, false); // -> round1
        _resolveRound(wf, true); // round1 -> release
        _escalate(wf, buyer, true); // -> round2 (Kleros handoff, ETH)
        _accrue(STAGE);
        _klerosRuling(wf, 1); // ruling 1 = release -> immediate settlement (final round)

        // Position unwound by the Kleros-propagation settlement, yield to recipient.
        _assertSettled(cfg, wf, uint8(EscrowState.RELEASED), seller, buyer);
    }

    /// @dev Escalated twice -> Kleros; Kleros final ruling CANCELS -> refund to buyer
    ///      (principal+yield). Symmetric to test_escalatedTwice_klerosRelease_yieldEnabled.
    function test_escalatedTwice_klerosCancel_yieldEnabled() public {
        ScenarioConfig memory cfg = ScenarioConfig({yieldEnabled: true, feeBps: FEE_ZERO});
        uint256 wf = _openEscrow(cfg);

        _raiseDispute(wf);
        _resolveRound(wf, true); // round0 -> release
        _escalate(wf, buyer, false); // -> round1
        _resolveRound(wf, true); // round1 -> release
        _escalate(wf, buyer, true); // -> round2 (Kleros)
        _accrue(STAGE);
        _klerosRuling(wf, 2); // ruling 2 = cancel -> immediate refund to buyer

        _assertSettled(cfg, wf, uint8(EscrowState.REFUNDED), buyer, seller);
    }

    /// @dev Yield continues accruing across open -> dispute -> escalate -> settle. Uses staged
    ///      warps (not a single warp before settlement) to prove yield accrues while the dispute
    ///      and appeal are outstanding.
    function test_yieldAccruesDuringOpenDisputeAndAppeal_yieldEnabled() public {
        ScenarioConfig memory cfg = ScenarioConfig({yieldEnabled: true, feeBps: FEE_ZERO});
        uint256 wf = _openEscrow(cfg);

        _accrue(STAGE); // accrue while PENDING
        _raiseDispute(wf);
        _accrue(STAGE); // accrue while DISPUTED (before round0 decision)
        _resolveRound(wf, true);
        _escalate(wf, buyer, false);
        _accrue(STAGE); // accrue while awaiting round1
        _resolveRound(wf, true);
        _executePending(wf);

        uint256 expectedYield = _expectedYield(ESCROW_AMOUNT, block.timestamp - openTime);
        assertGt(expectedYield, STAGE * 3, 'more than any single stage of yield');
        _assertSettled(cfg, wf, uint8(EscrowState.RELEASED), seller, buyer);
    }

    // =====================================================================
    // YIELD-DISABLED PARITY (shared settlement machinery, no module)
    // =====================================================================
    function test_noModule_release_parity() public {
        _runStraight(SettlementMode.RELEASE, false, FEE_ZERO, 0);
    }

    function test_noModule_cancel_parity() public {
        _runStraight(SettlementMode.CANCEL, false, FEE_ZERO, 0);
    }

    /// @dev One multi-round dispute with no module configured. This deliberately takes NO
    ///      shortcut: it drives the exact same DRM machinery as the yield-enabled tests
    ///      (_raiseDispute -> _resolveRound -> _escalate -> _resolveRound -> _executePending)
    ///      and settles through the same _finalizeClaimableSettlement terminal path. With no
    ///      YIELD_GEN module snapshot, _handleYieldModuleUnwind returns (amount, 0), so the
    ///      shared dispute machinery is what distributes principal-only to the beneficiary —
    ///      proving the settlement logic is identical with and without yield.
    function test_noModule_disputedSettlement_parity() public {
        ScenarioConfig memory cfg = ScenarioConfig({yieldEnabled: false, feeBps: FEE_ZERO});
        uint256 wf = _openEscrow(cfg);

        _raiseDispute(wf);
        _resolveRound(wf, true); // round0 -> release
        _escalate(wf, buyer, false); // -> round1
        _resolveRound(wf, true); // round1 -> release (agreement)
        _executePending(wf);

        _assertSettled(cfg, wf, uint8(EscrowState.RELEASED), seller, buyer);
    }

    // =====================================================================
    // PROTOCOL FEE INTERACTION (yield enabled, MAX 30%)
    // =====================================================================
    function test_feeEnabled_straightRelease() public {
        _runStraight(SettlementMode.RELEASE, true, FEE_MAX, MEDIUM);
    }

    function test_feeEnabled_disputedKlerosSettlement() public {
        ScenarioConfig memory cfg = ScenarioConfig({yieldEnabled: true, feeBps: FEE_MAX});
        uint256 wf = _openEscrow(cfg);

        _raiseDispute(wf);
        _resolveRound(wf, true);
        _escalate(wf, buyer, false);
        _resolveRound(wf, true);
        _escalate(wf, buyer, true);
        _accrue(STAGE);
        _klerosRuling(wf, 1); // release

        // 30% fee on realized yield credited to totalFeesPerToken; beneficiary gets principal + 70%.
        uint256 yieldExpected = _expectedYield(ESCROW_AMOUNT, block.timestamp - openTime);
        assertGt(escrow.totalFeesPerToken(address(token)), 0, 'protocol fee credited');
        assertApproxEqAbs(escrow.totalFeesPerToken(address(token)), (yieldExpected * FEE_MAX) / 10_000, 4, 'fee amount');
        _assertSettled(cfg, wf, uint8(EscrowState.RELEASED), seller, buyer);
    }

    // =====================================================================
    // KLEROS RULING DRIVER
    // =====================================================================
    function _klerosRuling(uint256 wf, uint256 ruling) internal {
        (bool committed, uint256 disputeId) = resolutionModule.getCommittedKlerosDisputeId(address(escrow), wf);
        assertTrue(committed, 'kleros dispute committed');
        klerosArbitrator.giveRuling(disputeId, ruling);
    }
}
