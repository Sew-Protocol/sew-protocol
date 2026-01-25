Aave Integration Testing Guide (Foundry / forge-std)
====================================================

**Audience:** Cursor (automated PR/test generation & review)

0) Scope definition (Cursor should ask/confirm)
-----------------------------------------------

Before writing tests, Cursor should pin:

-   Which Aave market (Base mainnet / Base Sepolia)

-   Which assets (USDC only vs multiple)

-   Custody model (aTokens held by Escrow vs module)

-   Yield lifecycle states (deposit/withdraw, failure handling, pause semantics)

-   Limits model (global caps, per-escrow caps, ramp schedule)

* * * * *

1) Coverage checklist (what "good" looks like)
==============================================

### A. Statement/branch coverage targets

-   **Critical modules (Aave + accounting + settlement):** aim for **90%+ lines**, **80%+ branches** (branches matter more than lines)

-   Separate metrics:

    -   **Unit tests** (pure logic)

    -   **Fork tests** (integration)

    -   **Invariant/stateful** (property coverage)

### B. Coverage must-hit list (by feature)

**Registration / configuration**

-   Validate pool/provider addresses (and failure modes)

-   Validate aToken ↔ underlying mapping (support both `UNDERLYING_ASSET_ADDRESS()` and any alternate getter if you decided to)

-   Reject wrong token, wrong market, wrong aToken

**Deposit into Aave**

-   Happy path

-   Supply fails (pool paused/frozen, cap reached, bad approval)

-   Rounding edge cases (1 wei, tiny amounts)

-   Fee-on-transfer / non-standard ERC20 behavior (if you ever allow it, else explicitly revert)

**Withdrawal from Aave**

-   Happy path (partial + full)

-   Withdraw fails / insufficient liquidity (simulate by draining reserve in fork or mocking pool)

-   Interest accrual (aToken balance grows) and distribution logic

**Accounting**

-   Principal tracked correctly across deposit/withdraw cycles

-   No leakage between escrows

-   Protocol fee accounting doesn't accidentally enter/leave yield bucket

**Emergency controls**

-   Pause prevents "enter yield" but allows "exit/unwind" (recommended)

-   Guardian/timelock actions: caps changes, module disable, emergency withdraw (if present)

**Telemetry**

-   All "soft-fail" flows emit the correct failure reasons (your OperationFailure/YieldHandlingFailed taxonomy)

* * * * *

2) Invariants checklist (properties that must always hold)
==========================================================

> Implement these as Foundry invariants (`invariant_*`) plus stateful handlers.

### A. Funds safety invariants

-   **No phantom funds:** total user-entitled value never exceeds total assets held (underlying + aTokens valued at 1:1 underlying for accounting)

-   **No stuck funds (when not paused):** every escrow in terminal state has a realizable claim path

-   **No cross-escrow contamination:** escrow A actions cannot change escrow B balances/claims

### B. Yield accounting invariants

-   **Principal monotonicity:** principal for an escrow only changes on explicit deposit/withdraw decisions

-   **Interest attribution correctness:** interest (aToken growth) is allocated exactly according to your spec (user/protocol split, or user-only)\
    (Aave aTokens increase balance automatically; ensure you don't strand interest unintentionally.)

-   **Caps enforced:** total in yield per token ≤ global cap; per-escrow ≤ per-escrow cap

### C. Authorization invariants

-   Only authorized roles can:

    -   activate/disable yield

    -   change caps

    -   swap modules

-   If using allowances: allowance after operation is either 0 or bounded to the minimal expected value (no lingering infinite approvals)

### D. Pause / emergency invariants

-   When paused:

    -   "enter yield" blocked

    -   "exit/unwind" allowed (or explicitly documented if not)

-   Emergency withdraw cannot route funds to arbitrary addresses (only escrow/vault)

* * * * *

3) Fuzz tests checklist (stateless fuzz)
========================================

### A. Input fuzz domains (must include bounds)

Fuzz:

-   amounts: `[0, 1, dust, 1e6, max]` with realistic caps

-   sequences: deposit → withdraw partial → withdraw full

-   multiple escrows: interleaved actions across N escrows

-   time: warp by random intervals to simulate interest accrual (fork or mock)

-   token decimals mismatch scenarios (USDC 6 decimals vs 18-dec tokens)

### B. Must-have fuzz assertions

-   No revert on valid ranges (and revert on invalid ranges)

-   Postconditions hold:

    -   balances conserved

    -   caps respected

    -   state machine valid

-   "No unexpected approvals" if you use `transferFrom` patterns (avoid approval race condition; best practice is approve-to-zero-then-set / bounded allowance).

### C. Negative fuzz (malicious/edge tokens)

If your protocol could ever interact with non-standard ERC20s, fuzz with:

-   ERC20 that returns `false` on transfer

-   ERC20 that reverts on approve unless allowance is zero-first (USDT-like behavior)

-   fee-on-transfer token

Even if you **don't** support these, fuzz tests should confirm you **fail fast** with clear errors.

* * * * *

4) Stateful fuzz / invariant harness (Foundry "handlers")
=========================================================

### Handler design (Cursor pattern)

Create a `Handler` contract with actions:

-   `openEscrow(amount)`

-   `enterYield(escrowId, amount)`

-   `exitYield(escrowId, amount)`

-   `settle(escrowId)`

-   `pause/unpause` (if exposed)

-   `changeCaps` (role-gated; use a "governance actor")

Then:

-   Randomize actors: buyer/seller/guardian/timelock/attacker

-   Track a shadow accounting model in the handler for expected principal and claims

This is where you catch:

-   forgotten state transitions

-   edge-case accounting drift

-   unexpected revert combinations

* * * * *

5) Fork tests against Aave testnet (Base Sepolia)
=================================================

### A. Fork test setup checklist

-   Pin fork block that you know has the reserve initialized

-   Derive addresses **onchain**, don't copy from UI:

    -   PoolAddressesProvider → Pool

    -   Pool.getReserveData(USDC).aTokenAddress

-   Verify:

    -   `aToken.UNDERLYING_ASSET_ADDRESS()` == USDC\
        (Calling the implementation directly can read zeroed storage; always call via proxy.)

-   Ensure your module tolerates ABI differences (aToken commonly exposes `UNDERLYING_ASSET_ADDRESS()`; requiring a different getter can break registration).

Aave's recommended pattern is to fetch addresses via the PoolAddressesProvider rather than hardcoding.

### B. Fork tests you should include (specific)

1.  **Supply USDC and verify aToken minted**

    -   pre/post balances: USDC down, aToken up

2.  **Withdraw USDC and verify underlying returned**

3.  **Interest accrual sanity**

    -   warp time forward; assert aToken balance non-decreasing (may be slow on testnets; treat as "≥" not ">")

4.  **Failure mode: pool paused/frozen**

    -   if you can't pause on fork, simulate via mocking pool for this case; fork for happy path, mocks for failure path

5.  **Cap / limits enforcement**

    -   attempt to exceed caps; assert revert or "soft-fail" behavior matches spec

6.  **Re-entrancy/Callback surface**

    -   use a malicious receiver contract on settlement paths to ensure external calls can't re-enter escrow logic

* * * * *

6) Past attack vectors & integration pitfalls to explicitly test
================================================================

### A. "Poisoned aToken" / unexpected token balances

A known Aave V3 class of issue: users receiving "dust" aTokens with weird collateral settings can cause unexpected behavior in some contexts (poisoning patterns).\
**Your integration tests should ensure:**

-   Receiving unexpected aToken dust cannot break withdrawal/settlement

-   Your accounting does not assume "aToken balance == principal"

### B. Approvals / allowance abuse & race conditions

ERC20 allowance patterns are a long-standing source of issues; use safe patterns and test:

-   allowance reset-to-zero then set (or use safeIncrease/Decrease patterns)

-   no lingering approvals to strategy/pool beyond what is necessary

### C. Oracle / price manipulation via flash liquidity (if you ever price anything)

If your protocol uses any spot price (even indirectly), assume flash-loan manipulation exists.\
For your escrow-yield use-case, you *usually* shouldn't depend on price at all.\
**Test to confirm you don't:**

-   no price-based branches

-   no "value in USD" logic for solvency based on manipulable sources

### D. Read-only reentrancy / inconsistent-view attacks

Even protocols that avoid state-changing reentrancy can be exploited via read-only reentrancy when they trust external "views" mid-flow.\
**Test:**

-   any view-based checks aren't used to authorize or finalize state in a way an attacker can influence via callbacks

### E. Peripheral contract mistakes

Aave had incidents in periphery adapters (not core) due to integration assumptions.\
**Takeaway for you:** your module is "periphery-like" relative to Aave; test it like you're the periphery that can be exploited.

* * * * *

7) Specific tests that should be included (copy/paste into Cursor task list)
============================================================================

Unit tests (mock pool)
----------------------

-   `test_registerAToken_rejects_wrongUnderlying()`

-   `test_registerAToken_rejects_nonContract()`

-   `test_supply_emitsExpectedEvents_andUpdatesPrincipal()`

-   `test_supply_handlesApproveToZeroPattern()`

-   `test_withdraw_partial_then_full_conservesAssets()`

-   `test_withdraw_revertsOrSoftFails_onPoolFailure()` (depending on your design)

-   `test_pause_blocksEnterYield_allowsExitYield()`

-   `test_caps_enforced_global_and_perEscrow()`

-   `test_interest_distribution_matchesSpec()` (user/protocol split)

-   `test_noCrossEscrowLeakage_multipleEscrows()`

Fuzz tests
----------

-   `testFuzz_supplyWithdraw_roundTrips(amount, steps)`

-   `testFuzz_capsNeverExceeded(amounts[])`

-   `testFuzz_settle_neverOverpays(escrowId, amount)`

-   `testFuzz_noLingeringAllowance(amount)` (if using transferFrom)

Stateful invariant suite
------------------------

-   `invariant_totalEntitlement_le_totalAssetsHeld()`

-   `invariant_principalAccounting_consistent()`

-   `invariant_noUnauthorizedModuleCalls()`

-   `invariant_capsRespected()`

-   `invariant_pauseSemantics()`

Fork tests (Base Sepolia Aave)
------------------------------

-   `testFork_supplyUSDC_mintsAToken()`

-   `testFork_withdrawUSDC_returnsUnderlying()`

-   `testFork_addressDerivation_fromPoolReserveData()` (regression against "wrong UI address")

-   `testFork_interestNonDecreasing_overTimeWarp()` (non-strict)

* * * * *

8) "Anything else" (high leverage)
==================================

### A. Differential tests: mock vs fork

Run the same scenario against:

-   Mock Pool (controlled failures)

-   Fork Pool (real integrations)\
    ...and assert matching outcomes where applicable.

### B. Event-driven assertions

Given you care about telemetry codes, write tests that assert:

-   correct failure reason emitted for each soft-failure path

-   no "defined but never emitted" codes remain unless intentionally unused

### C. Gas and DoS checks

-   Ensure loops are bounded (per-escrow lists, module registries)

-   Ensure settlement doesn't become uncallable as positions grow

---

## Verification (2026-01-23)

-   **Gap analysis:** [AAVE_INTEGRATION_CHECKLIST_GAP_ANALYSIS.md](./AAVE_INTEGRATION_CHECKLIST_GAP_ANALYSIS.md) — checklist vs. current tests; most items complete, remaining gaps low priority.
-   **Status and accounting:** [AAVE_INTEGRATION_CHECKLIST_STATUS.md](./AAVE_INTEGRATION_CHECKLIST_STATUS.md) — test inventory, accounting verification (principal, fees, yield, PUSH model, `remainingAllowance`).