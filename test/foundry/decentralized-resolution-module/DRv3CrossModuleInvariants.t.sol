// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.33;

import 'forge-std/Test.sol';
import '../../../contracts/modules/decentralized-resolution-module/DecentralizedResolutionModule.sol';
import '../../../contracts/modules/decentralized-resolution-module/ResolverStakingModuleV1.sol';
import '../../../contracts/modules/decentralized-resolution-module/ResolverSlashingModuleV1.sol';
import '../../../contracts/modules/decentralized-resolution-module/InsurancePoolVault.sol';
import '../../../contracts/modules/decentralized-resolution-module/ISlashingModule.sol';
import '../../../contracts/modules/decentralized-resolution-module/IStakingModule.sol';
import '../../../contracts/types/EscrowTypes.sol';
import '@openzeppelin/contracts/token/ERC20/ERC20.sol';
import '@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol';

// ─── Minimal mock tokens ─────────────────────────────────────────────────────

contract XMockStable is ERC20 {
    constructor() ERC20('Mock USDC', 'USDC') { _mint(msg.sender, 100_000_000e6); }
    function decimals() public pure override returns (uint8) { return 6; }
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

contract XMockSEW is ERC20, ERC20Burnable {
    constructor() ERC20('Mock SEW', 'SEW') { _mint(msg.sender, 100_000_000e18); }
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

/**
 * @title DRv3CrossModuleInvariantsTest
 * @notice Cross-module invariant tests for the DR v3 system.
 *
 * These tests probe properties that span multiple contracts and cannot be
 * verified by looking at any single module in isolation.  Each test documents
 * a specific cross-cutting invariant and calls out where a real vulnerability
 * or design gap was found.
 *
 * Invariants under test:
 *   1. bond.effectiveBondUSD >= totalLockedStake  (always; violated by the
 *      unstake-during-unbond-window race)
 *   2. completeUnstake must revert if stake is locked in active disputes
 *   3. resolverActiveDisputes / capacity.currentDisputes decrement semantics
 *      — forceProgress does NOT auto-decrement; escrow must call
 *      decrementResolverActiveDisputes manually
 *   4. Slash stable-token distribution: 50% goes to InsurancePoolVault;
 *      the remaining 50% accumulates in the SlashingModule (30% labelled
 *      "toProtocol" + 20% implicitly retained) with no on-chain withdraw path
 *   5. Epoch slash tracker resets exactly at each 7-day boundary; slashes
 *      in epoch N do not count against the cap in epoch N+1
 *   6. Multiple waterfall slashes: InsurancePoolVault balance equals the sum
 *      of all insurance-pool transfers (50% of each USD-denominated slash)
 */
contract DRv3CrossModuleInvariantsTest is Test {
    DecentralizedResolutionModule public drm;
    ResolverStakingModuleV1      public staking;
    ResolverSlashingModuleV1     public slashing;
    InsurancePoolVault           public insurance;
    XMockStable                  public stable;
    XMockSEW                     public sew;

    address public admin    = address(this);
    address public timelock = makeAddr('timelock');
    address public escrow   = makeAddr('escrow');

    // Track the real current timestamp (block.timestamp cached value is stale after vm.warp)
    uint256 internal _ts;

    function setUp() public {
        stable    = new XMockStable();
        sew       = new XMockSEW();
        staking   = new ResolverStakingModuleV1(admin, address(stable), address(sew));
        insurance = new InsurancePoolVault(admin, address(stable));
        slashing  = new ResolverSlashingModuleV1(admin, address(staking), address(insurance), address(stable));
        drm       = new DecentralizedResolutionModule(admin);

        staking.grantRole(staking.ROLE_TIMELOCK(), admin);
        staking.grantRole(staking.ROLE_TIMELOCK(), timelock);
        staking.setResolutionModule(address(drm));
        staking.setSlashingModule(address(slashing));

        insurance.grantRole(insurance.ROLE_SLASHING_MODULE(), address(slashing));
        insurance.grantRole(insurance.ROLE_TIMELOCK(), admin);

        slashing.grantRole(slashing.ROLE_TIMELOCK(), timelock);
        slashing.grantRole(slashing.ROLE_RESOLUTION_MODULE(), address(drm));

        drm.grantRole(drm.ROLE_TIMELOCK(), timelock);

        vm.startPrank(timelock);
        drm.registerEscrowContract(escrow);
        drm.queueStakingModule(address(staking));
        drm.queueSlashingModule(address(slashing));
        vm.stopPrank();

        _ts = block.timestamp + 7 days + 1;
        vm.warp(_ts);
        vm.startPrank(timelock);
        drm.activateStakingModule();
        drm.activateSlashingModule();
        vm.stopPrank();
    }

    // ── helpers ──────────────────────────────────────────────────────────────

    function _makeResolver(string memory label, uint256 stableAmt) internal returns (address r) {
        r = makeAddr(label);
        stable.mint(r, stableAmt);
        vm.startPrank(r);
        stable.approve(address(staking), type(uint256).max);
        staking.stakeWithMix(stableAmt, 0);
        vm.stopPrank();
        vm.startPrank(timelock);
        drm.setResolverActive(r, true);
        drm.setResolverCapacity(r, 10, true);
        vm.stopPrank();
    }

    function _assign(uint256 wfId, address r) internal {
        bytes32 cat = drm.autoCategorizeEscrow(abi.encode(wfId));
        vm.prank(escrow);
        drm.initializeDispute(wfId, escrow, r, cat);
    }

    function _timeout(uint256 wfId) internal {
        _ts += 25 hours;
        vm.warp(_ts);
        drm.forceProgress(wfId, escrow);
    }

    // =========================================================================
    // 1. Bond >= LockedStake invariant — and the race that can break it
    // =========================================================================

    /**
     * @notice INVARIANT: bond.effectiveBondUSD must always be >= totalLockedStake.
     *
     * Race condition (GAP-1):
     *   t=0  resolver calls requestUnstakeWithMix — passes because totalLockedStake==0
     *   t=1  escrow calls initializeDispute — DRM / staking do not check UNSTAKING status;
     *        onResolverAssigned locks stake, making totalLockedStake > 0
     *   t=14d resolver calls completeUnstake — NO check for totalLockedStake > 0
     *         → bond drained to zero while lock is still active
     *         → subsequent slash call finds bond==0 and either reverts (InsufficientBond)
     *           or no-ops, so the resolver escapes punishment
     *
     * Expected (desired) behaviour: completeUnstake SHOULD revert with StakeLockedInDisputes.
     * Actual behaviour: completeUnstake succeeds → invariant violated.
     *
     * This test documents the current (broken) state so the gap is visible.
     * Fix: add `if (totalLockedStake[resolver] > 0) revert StakeLockedInDisputes(...)` to
     * completeUnstake(), mirroring the guard already present in requestUnstakeWithMix().
     */
    /**
     * @notice REGRESSION GUARD (GAP-1 FIX applied):
     * completeUnstake MUST revert with StakeLockedInDisputes when totalLockedStake > 0.
     *
     * The fix adds the guard to ResolverStakingModuleV1.completeUnstake(), mirroring
     * the check already present in requestUnstakeWithMix().  This test was previously
     * a passive observation (emit log); it is now a hard assertion that fails if the
     * guard is missing or removed.
     */
    function test_crossModule_unstakeRace_bondDrainedWhileLocked() public {
        address r = _makeResolver('racer', 10_000e6);

        // ── Step 1: resolver requests full unstake (no disputes yet) ──────────
        vm.prank(r);
        staking.requestUnstakeWithMix(10_000e6, 0);
        assertEq(
            uint8(staking.getStakeInfo(r).status),
            uint8(IStakingModule.StakeStatus.UNSTAKING),
            'should be UNSTAKING'
        );

        // ── Step 2: escrow assigns a dispute during the 14-day window ─────────
        _assign(101, r);
        uint256 locked = staking.totalLockedStake(r);
        assertGt(locked, 0, 'stake should be locked despite UNSTAKING status');

        // ── Step 3: complete unstake after delay — MUST REVERT (fix applied) ──
        _ts += 15 days;
        vm.warp(_ts);

        vm.prank(r);
        vm.expectRevert(
            abi.encodeWithSelector(
                ResolverStakingModuleV1.StakeLockedInDisputes.selector,
                r,
                locked
            )
        );
        staking.completeUnstake();

        // Invariant holds: bond >= lockedStake because completeUnstake was rejected.
        uint256 bondAfter   = staking.getStakeInfo(r).totalStake;
        uint256 lockedAfter = staking.totalLockedStake(r);
        assertGe(bondAfter, lockedAfter, 'INVARIANT: bond must be >= lockedStake');
    }

    /**
     * @notice After the lock is released (e.g. forceProgress), completeUnstake
     * now succeeds — confirms the guard does not permanently block valid unstakes.
     */
    function test_crossModule_unstakeAllowed_afterLockReleased() public {
        // Stake 20_000e6 but only request to unbond 10_000e6.
        // forceProgress calls the slashing module (2% timeout penalty ≈ 400e6),
        // so the remaining bond (~19_600e6) still exceeds the 10_000e6 unbond request.
        address r = _makeResolver('racer2', 20_000e6);

        // Request a PARTIAL unstake — leaves enough bond to survive the timeout slash.
        vm.prank(r);
        staking.requestUnstakeWithMix(10_000e6, 0);

        // Assign a dispute and let it time out (releases the lock via forceProgress)
        _assign(102, r);
        assertGt(staking.totalLockedStake(r), 0, 'stake locked');

        _ts += 25 hours; // past dispute deadline
        vm.warp(_ts);
        drm.forceProgress(102, escrow); // unlocks stake

        // Lock cleared
        assertEq(staking.totalLockedStake(r), 0, 'stake unlocked after forceProgress');

        // completeUnstake may still fail due to unbond delay — warp further
        _ts += 15 days;
        vm.warp(_ts);

        vm.prank(r);
        staking.completeUnstake(); // must not revert once lock is cleared
    }

    /**
     * @notice The invariant `bond >= lockedStake` in the happy path:
     * after a full assign → forceProgress(timeout) → stake-unlock cycle the
     * invariant is restored to `lockedStake == 0 <= bond`.
     */
    function test_crossModule_bondGteLockedStake_happyPath() public {
        address r = _makeResolver('bgl', 10_000e6);

        uint256 bondBefore = staking.getStakeInfo(r).totalStake;
        assertGt(bondBefore, 0);
        assertEq(staking.totalLockedStake(r), 0);

        // Assign → stake locked
        _assign(201, r);
        uint256 locked = staking.totalLockedStake(r);
        assertGt(locked, 0);
        assertGe(staking.getStakeInfo(r).totalStake, locked, 'bond >= lockedStake after assign');

        // Timeout -> slash + unlock
        _ts += 25 hours;
        vm.warp(_ts);
        drm.forceProgress(201, escrow);

        // After forceProgress the stake is unlocked (either via unlockStake or slashForTimeout path)
        uint256 lockedAfter = staking.totalLockedStake(r);
        uint256 bondAfter   = staking.getStakeInfo(r).totalStake;
        assertEq(lockedAfter, 0, 'stake fully unlocked after resolution');
        assertGe(bondAfter, lockedAfter, 'bond >= lockedStake invariant holds post-resolution');
    }

    // =========================================================================
    // 2. resolverActiveDisputes / capacity.currentDisputes decrement semantics
    // =========================================================================

    /**
     * @notice INVARIANT (design documentation):
     * forceProgress(→ Final) does NOT auto-decrement resolverActiveDisputes or
     * capacity.currentDisputes.  The external escrow contract is responsible for
     * calling decrementResolverActiveDisputes() after the dispute workflow
     * completes (RELEASED / REFUNDED / RESOLVED in EscrowVault).
     *
     * Consequence: in a DRM-only test harness (no real EscrowVault), counters
     * accumulate monotonically.  A resolver who has timed out N disputes appears
     * to have N active disputes from the DRM perspective until the escrow
     * explicitly decrements.
     *
     * This test documents the expected call sequence and asserts both the
     * pre-decrement (leaked) and post-decrement (correct) states.
     */
    function test_crossModule_resolverActiveDisputes_mustBeDecrementedByEscrow() public {
        address r = _makeResolver('counter', 10_000e6);

        assertEq(drm.resolverActiveDisputes(r), 0, 'starts at zero');
        (, uint256 cap0,) = drm.resolverCapacity(r);
        assertEq(cap0, 0, 'capacity starts at zero');

        // Assign -> counters incremented
        _assign(301, r);
        assertEq(drm.resolverActiveDisputes(r), 1);
        (, uint256 cap1,) = drm.resolverCapacity(r);
        assertEq(cap1, 1);

        // Timeout (Final) -- forceProgress does NOT decrement
        _timeout(301);

        assertEq(
            drm.resolverActiveDisputes(r),
            1,
            'resolverActiveDisputes NOT auto-decremented by forceProgress (design: escrow must decrement)'
        );
        (, uint256 capAfterTimeout,) = drm.resolverCapacity(r);
        assertEq(
            capAfterTimeout,
            1,
            'capacity.currentDisputes NOT auto-decremented by forceProgress'
        );

        // After escrow confirms closure, both counters reach zero
        vm.prank(escrow);
        drm.decrementResolverActiveDisputes(r);

        assertEq(drm.resolverActiveDisputes(r), 0, 'zero after explicit decrement');
        (, uint256 capAfterDecrement,) = drm.resolverCapacity(r);
        assertEq(capAfterDecrement, 0, 'capacity zero after decrement');
    }

    /**
     * @notice Capacity gate: if the escrow never calls decrementResolverActiveDisputes,
     * a resolver's capacity.currentDisputes reaches maxConcurrentDisputes and the
     * resolver becomes unassignable — even with no live disputes.
     *
     * This test exposes the operational risk: governance must always coordinate
     * decrementResolverActiveDisputes after each completed workflow.
     */
    function test_crossModule_capacityExhaustedWithoutDecrement() public {
        address r = _makeResolver('cap', 50_000e6);
        // Override: small capacity so exhaustion is easy to trigger
        vm.prank(timelock);
        drm.setResolverCapacity(r, 2, true);

        _assign(401, r);
        _timeout(401);
        _assign(402, r);
        _timeout(402);

        // Both slots consumed (no decrements), resolver should be at capacity
        (, uint256 capExhausted,) = drm.resolverCapacity(r);
        assertEq(capExhausted, 2);

        // Third assignment reverts
        bytes32 cat = drm.autoCategorizeEscrow(abi.encode(uint256(403)));
        vm.prank(escrow);
        vm.expectRevert();
        drm.initializeDispute(403, escrow, r, cat);
    }

    // =========================================================================
    // 3. Slash stable-token distribution accounting
    // =========================================================================

    /**
     * @notice Distribution invariant:
     *   stableTransferredToSlashing == stableOut_toInsurance + stableRetained
     *
     * The slash distribution splits as:
     *   50% → InsurancePoolVault (transferred immediately)
     *   30% → "toProtocol" (set in SlashDistribution struct but NEVER transferred)
     *   20% → implicitly retained (BASIS_POINTS rounding residual)
     *
     * In total, 50% of slashed stable accumulates in the SlashingModule with no
     * on-chain withdrawal path currently deployed.  This test documents that
     * accounting gap by asserting the exact token balances before/after a slash.
     */
    function test_crossModule_slashDistribution_stableRetainedInSlashingContract() public {
        address r = _makeResolver('dist', 10_000e6);

        uint256 slashingBefore  = stable.balanceOf(address(slashing));
        uint256 insuranceBefore = stable.balanceOf(address(insurance));

        // Trigger a timeout slash
        _assign(501, r);
        _ts += 25 hours;
        vm.warp(_ts);
        drm.forceProgress(501, escrow);

        uint256 slashingAfter  = stable.balanceOf(address(slashing));
        uint256 insuranceAfter = stable.balanceOf(address(insurance));

        uint256 slashedUSD   = staking.getStakeInfo(r).slashedAmount; // 18-dec USD
        assertGt(slashedUSD, 0, 'slash should have occurred');

        // staking transferred stableSlashed (6-dec) to slashing; compute expected
        // stable amount.  The slash is 200 bps of bond in USD units; bond is 100%
        // stable so: stableSlashed ≈ slashedUSD / 1e12 (18→6 dec conversion).
        uint256 expectedStableSlashed = slashedUSD / 1e12;

        // Insurance received 50%
        uint256 insuranceDelta = insuranceAfter - insuranceBefore;
        assertApproxEqAbs(
            insuranceDelta,
            expectedStableSlashed / 2,
            1, // 1 wei tolerance for rounding
            'insurance received ~50% of slashed stable'
        );

        // Slashing contract received all slashed stable from staking, then paid out 50%.
        // Net position: +(stableSlashed) - (50% toInsurance) = +50% retained.
        int256 slashingDelta = int256(slashingAfter) - int256(slashingBefore);
        // The contract should have a positive balance change of ~50% of slashedStable.
        // (It received 100%, sent 50% to insurance.)
        assertApproxEqAbs(
            uint256(slashingDelta),
            expectedStableSlashed / 2,
            1,
            'slashing contract retains ~50% of slashed stable (30% protocol + 20% unaccounted, no withdraw path)'
        );
    }

    /**
     * @notice Distribution conservation: tokens flow in (from staking), tokens flow out
     * (to insurance); slashing contract balance change equals the difference.
     * `stableInFromStaking == insuranceDelta + slashingRetained` must hold exactly.
     */
    function test_crossModule_slashDistribution_tokenConservation() public {
        address r = _makeResolver('cons', 10_000e6);

        uint256 stakingBefore   = stable.balanceOf(address(staking));
        uint256 slashingBefore  = stable.balanceOf(address(slashing));
        uint256 insuranceBefore = stable.balanceOf(address(insurance));

        _assign(601, r);
        _ts += 25 hours;
        vm.warp(_ts);
        drm.forceProgress(601, escrow);

        uint256 stakingAfter   = stable.balanceOf(address(staking));
        uint256 slashingAfter  = stable.balanceOf(address(slashing));
        uint256 insuranceAfter = stable.balanceOf(address(insurance));

        // Tokens left staking
        uint256 outOfStaking = stakingBefore - stakingAfter;
        assertGt(outOfStaking, 0, 'staking balance decreased by slash');

        // All tokens leaving staking must appear in slashing + insurance
        uint256 intoSlashing  = slashingAfter  > slashingBefore  ? slashingAfter  - slashingBefore  : 0;
        uint256 intoInsurance = insuranceAfter > insuranceBefore ? insuranceAfter - insuranceBefore : 0;

        // Conservation: outOfStaking == intoSlashing + intoInsurance
        // (slashing acts as intermediary; it receives all then forwards 50%)
        assertEq(
            outOfStaking,
            intoSlashing + intoInsurance,
            'token conservation: staking outflow == slashing retained + insurance received'
        );
    }

    // =========================================================================
    // 4. Epoch slash tracker resets at the 7-day boundary
    // =========================================================================

    /**
     * @notice Epoch boundary invariant: a slash in epoch N does not count
     * against the slash cap in epoch N+1.
     *
     * Test scenario:
     *   - Epoch 0: slash resolver at 15% (under 20% cap) → 5% remaining this epoch
     *   - Warp to epoch 1 (cross the 7-day boundary)
     *   - Epoch 1: slash resolver at 15% again → should apply fully (cap reset)
     */
    function test_crossModule_epochBoundary_slashCapResetsAcrossEpoch() public {
        address r = _makeResolver('epochBound', 10_000e6);

        // Enable fraud slash at 1500 bps (15%)
        vm.prank(timelock);
        slashing.setSlashPercentage(ISlashingModule.SlashReason.FRAUD, 1500);

        uint256 bondBefore = staking.getStakeInfo(r).totalStake; // ~10 000e18 USD

        // ── Epoch 0 slash ────────────────────────────────────────────────────
        vm.prank(timelock);
        slashing.slashForFraud(0, address(0), r, '');
        uint256 after0 = staking.getStakeInfo(r).slashedAmount;
        uint256 slash0 = after0; // first slash
        assertApproxEqAbs(slash0, (bondBefore * 1500) / 10000, 1, 'epoch-0 slash applied at 15%');

        // ── Cross 7-day epoch boundary ────────────────────────────────────────
        uint256 epochLen = slashing.EPOCH_LENGTH();
        _ts = ((_ts / epochLen) + 1) * epochLen + 1;
        vm.warp(_ts);

        // ── Epoch 1 slash ────────────────────────────────────────────────────
        uint256 bondAfterE0 = staking.getStakeInfo(r).totalStake;
        vm.prank(timelock);
        slashing.slashForFraud(1, address(0), r, '');
        uint256 after1 = staking.getStakeInfo(r).slashedAmount;
        uint256 slash1 = after1 - after0;

        // Cap resets: 15% of current bond should apply in full (not be constrained by epoch-0's 15%)
        uint256 expectedSlash1 = (bondAfterE0 * 1500) / 10000;
        assertApproxEqAbs(slash1, expectedSlash1, 1, 'epoch-1 slash applied fully (epoch cap reset)');
    }

    /**
     * @notice Slashes within the SAME epoch accumulate toward the cap; a
     * third slash after the cap is reached is zero.
     */
    function test_crossModule_epochCap_accumulationWithinEpoch() public {
        address r = _makeResolver('epochAcc', 100_000e6); // large bond to keep rounding clean

        vm.prank(timelock);
        slashing.setSlashPercentage(ISlashingModule.SlashReason.FRAUD, 1500); // 15%

        uint256 bond0 = staking.getStakeInfo(r).totalStake;

        // Slash 1: 15% → ok (under 20% cap)
        vm.prank(timelock);
        slashing.slashForFraud(0, address(0), r, '');
        uint256 slashed1 = staking.getStakeInfo(r).slashedAmount;
        assertApproxEqAbs(slashed1, (bond0 * 1500) / 10000, 1, 'first slash 15%');

        // Slash 2: cap kicks in; only ~5% more allowed (to reach 20% of current bond)
        vm.prank(timelock);
        slashing.slashForFraud(1, address(0), r, '');
        uint256 slashed2 = staking.getStakeInfo(r).slashedAmount;
        uint256 delta2 = slashed2 - slashed1;
        assertGt(delta2, 0, 'partial second slash still applied');
        assertLt(delta2, slashed1, 'second slash reduced by epoch cap');

        // Slash 3 (same epoch): resolver already at cap → zero
        vm.prank(timelock);
        slashing.slashForFraud(2, address(0), r, '');
        uint256 slashed3 = staking.getStakeInfo(r).slashedAmount;
        assertEq(slashed3, slashed2, 'third slash zero: epoch cap exhausted');
    }

    // =========================================================================
    // 5. Insurance pool solvency across multiple waterfall slashes
    // =========================================================================

    /**
     * @notice InsurancePool balance invariant across multiple timeout slashes:
     *   insurancePool.balance == sum(50% of each stableSlashed_i)
     *
     * Uses three independent resolvers each timing out in the same test to
     * simulate concurrent defaults.
     */
    function test_crossModule_insurancePool_balanceEqualsSlashDistributions() public {
        address r1 = _makeResolver('ip1', 10_000e6);
        address r2 = _makeResolver('ip2', 20_000e6);
        address r3 = _makeResolver('ip3', 5_000e6);

        uint256 insuranceBefore = stable.balanceOf(address(insurance));

        // Assign all three disputes
        _assign(701, r1);
        _assign(702, r2);
        _assign(703, r3);

        // Advance time past deadline for all three
        _ts += 25 hours;
        vm.warp(_ts);
        drm.forceProgress(701, escrow);
        drm.forceProgress(702, escrow);
        drm.forceProgress(703, escrow);

        uint256 insuranceAfter = stable.balanceOf(address(insurance));

        // Compute total USD slashed
        uint256 totalSlashedUSD = staking.getStakeInfo(r1).slashedAmount
            + staking.getStakeInfo(r2).slashedAmount
            + staking.getStakeInfo(r3).slashedAmount;
        assertGt(totalSlashedUSD, 0, 'at least one resolver was slashed');

        // Expected insurance inflow = 50% of total slashed stable
        // Convert 18-dec USD → 6-dec stable: divide by 1e12
        uint256 expectedInsuranceInflow = (totalSlashedUSD / 1e12) / 2;
        uint256 actualInsuranceInflow = insuranceAfter - insuranceBefore;

        assertApproxEqAbs(
            actualInsuranceInflow,
            expectedInsuranceInflow,
            3, // 1 wei per slash for rounding
            'insurance pool received exactly 50% of all slashed stable'
        );
    }

    /**
     * @notice InsurancePoolVault must never go insolvent (negative balance).
     * This test verifies that slashes only ADD to the pool; pool balance is
     * monotonically non-decreasing across slashes (no funds flow OUT unless
     * explicitly withdrawn by governance).
     */
    function test_crossModule_insurancePool_monotonicBalance() public {
        address r1 = _makeResolver('mono1', 10_000e6);
        address r2 = _makeResolver('mono2', 10_000e6);

        uint256 b0 = stable.balanceOf(address(insurance));

        _assign(801, r1);
        _ts += 25 hours;
        vm.warp(_ts);
        drm.forceProgress(801, escrow);
        uint256 b1 = stable.balanceOf(address(insurance));
        assertGe(b1, b0, 'pool balance non-decreasing after first slash');

        _assign(802, r2);
        _ts += 25 hours;
        vm.warp(_ts);
        drm.forceProgress(802, escrow);
        uint256 b2 = stable.balanceOf(address(insurance));
        assertGe(b2, b1, 'pool balance non-decreasing after second slash');
    }

    // =========================================================================
    // 6. onResolverAssigned silent-failure in try/catch
    // =========================================================================

    /**
     * @notice When the staking module is deactivated (set to address(0)) AFTER
     * a V3 module was active, `initializeDispute` continues but the staking hook
     * is skipped.  The dispute is created with NO stake locked — this is the
     * intended fallback behaviour but should be explicitly documented/tested.
     */
    function test_crossModule_stakingHookFailure_disputeCreatedWithoutLock() public {
        address r = _makeResolver('nohook', 10_000e6);

        // Forcibly deactivate the staking module by replacing with address(0)
        // (simulates a future emergency deactivation)
        // NOTE: DRM doesn't expose a direct "set staking to zero" — we test via
        // the module swap path: queue + activate a NoOp staking module.
        // For this unit test we instead verify via a resolver whose bond is
        // intentionally too small to cover the lock.  If the hook would revert
        // (e.g. InsufficientAvailableStake), the dispute still succeeds via try/catch.

        address tinyResolver = makeAddr('tiny');
        // Stake exactly the minimum ($250) — lockAmount will also be $250
        stable.mint(tinyResolver, 250e6);
        vm.startPrank(tinyResolver);
        stable.approve(address(staking), type(uint256).max);
        staking.stakeWithMix(250e6, 0);
        vm.stopPrank();
        vm.startPrank(timelock);
        drm.setResolverActive(tinyResolver, true);
        drm.setResolverCapacity(tinyResolver, 10, true);
        vm.stopPrank();

        // Assign one dispute — stake locked (exactly minimum)
        _assign(901, tinyResolver);
        assertEq(staking.totalLockedStake(tinyResolver), staking.getMinimumStake(0), 'first dispute locks min stake');

        // Assign a second dispute — no available stake remains
        // onResolverAssigned will revert (InsufficientAvailableStake) inside the try/catch
        // Dispute should still be created (try/catch swallows the staking revert)
        bytes32 cat = drm.autoCategorizeEscrow(abi.encode(uint256(902)));
        vm.prank(escrow);
        drm.initializeDispute(902, escrow, tinyResolver, cat);

        // Second dispute created but stake NOT additionally locked (hook reverted silently)
        assertEq(
            staking.totalLockedStake(tinyResolver),
            staking.getMinimumStake(0),
            'locked stake unchanged: second staking hook silently failed'
        );

        // Consequence: second dispute has no backing stake — if it times out,
        // slash will be zero (bond == locked == minimum; available == 0)
    }
}
