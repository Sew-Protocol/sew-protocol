# Dispute Economics

> **Scope:** This document describes the economic and incentive design of the Sew Protocol
> decentralized dispute resolution system: escalation cost curves, appeal bond mechanics,
> bond distribution to resolvers, EMA reputation scoring, resolver assignment, bond
> composition and valuation, delegated bond coverage, slashing, insurance pool, and payment
> calculation.
>
> **Sources:**
> `contracts/modules/decentralized-resolution-module/DecentralizedResolutionModule.sol`,
> `contracts/modules/decentralized-resolution-module/EscalationCostLibrary.sol`,
> `contracts/modules/decentralized-resolution-module/BondValuationLibrary.sol`,
> `contracts/modules/decentralized-resolution-module/PaymentCalculationLibraryV1.sol`,
> `contracts/modules/decentralized-resolution-module/InsurancePoolVault.sol`,
> `contracts/modules/decentralized-resolution-module/ResolutionAnalytics.sol`,
> `contracts/modules/decentralized-resolution-module/ResolverIncentiveModuleV2.sol`,
> `contracts/modules/decentralized-resolution-module/ResolverSlashingModuleV1.sol`,
> `contracts/modules/decentralized-resolution-module/ResolverStakingModuleV1.sol`,
> `contracts/modules/decentralized-resolution-module/DecentralizedResolverStructs.sol`.

---

## 1. Overview

The Decentralized Resolution Module (DRM) is designed around three principles:

1. **Costly escalation deters frivolous appeals.** A dispute that reaches a higher round
   only because one party is annoyed is a cost they bear, not the protocol.

2. **Correct resolvers are rewarded by the loser.** Appeal bonds flow to resolvers whose
   decisions were upheld — creating a direct payment from the party that triggered an
   unnecessary escalation to the resolver whose decision it validated.

3. **Resolver accountability is enforced by reputation, then by bond.** DR v1 uses EMA
   reputation to route work and exclude poor performers. DR v2 adds user-posted appeal
   bonds. DR v3 adds resolver-held bonds, delegated senior coverage, slashing, and an
   insurance pool.

The DRM is versioned. Resolvers, fees, escalation curves, and the payment library are all
replaceable via governance. The core state machine is stable across versions.

---

## 2. Three-round escalation pipeline

Every dispute goes through a maximum of three rounds, each with a distinct resolver class:

```
Round 0 — Initial resolver pool
           Weighted round-robin assignment from registered resolvers.
           Decision subject to appeal within the appeal window.
                │
                │  escalation bond required (cost curve)
                ▼
Round 1 — Senior resolver
           Senior resolvers are DAO-appointed, higher accountability tier.
           Decision subject to appeal within the appeal window.
                │
                │  escalation bond required (cost curve)
                ▼
Round 2 — Kleros (external resolution)
           Final round. KlerosArbitrableProxy routes to Kleros court.
           canEscalate() returns (false, _, _): structurally terminal.
           No further appeal path exists within the protocol.
```

The DRM tracks per-dispute state in `DisputeMetadata`:

- `currentRound` (0–2)
- `resolverAtRound[3]` — assigned resolver per round
- `decisionAtRound[3]` — outcome per round
- `appealDeadline[3]` — appeal window closes at this timestamp per round
- `bondDepositorAtRound[3]` / `bondAmountAtRound[3]` — who posted bond and how much
- `bondRefundedAtRound[3]` — whether the bond was refunded (upheld) or forfeited (overturned)

---

## 3. Escalation cost curves

**Contract:** `EscalationCostLibrary`

Escalation is not free. The appealing party must post an appeal bond equal to the escalation
cost for the target round. Three curve types are supported:

| Curve type | Formula | Recommended use |
|-----------|---------|----------------|
| Linear | `cost(k) = baseCost + stepSize × k` | Mild deterrence |
| **Quadratic** | `cost(k) = baseCost + stepSize × k²` | **Default — strong anti-spam, still manageable for 1–2 appeals** |
| Geometric | `cost(k) = baseCost × multiplier^k` | High-value escrows; very aggressive deterrence |

Where `k` is the escalation count (0-indexed: `k = level - 1`).

**Example escalation costs with quadratic curve:**

```
baseCost = 100 USDC, stepSize = 50 USDC

Round 1 (k=0): 100 + 50×0 = 100 USDC
Round 2 (k=1): 100 + 50×1 = 150 USDC
Round 3 (k=2): 100 + 50×4 = 300 USDC
```

The escalation cost configuration (`EscalationCostConfig`) is itself governance-controlled
with a queue/activate pattern in the DRM — changes require a pending period before taking
effect. A separate `bondToken` field in the config allows the bond to be denominated in any
ERC-20 token or ETH.

**Anti-spam property:** A dispute that has already reached round 2 (Kleros) has required the
appealing party to post round-1 and round-2 bonds in sequence. Under the quadratic curve,
each successive escalation is more expensive than the last. A party repeatedly appealing
correct decisions will exhaust their bond balance faster than they can win.

---

## 4. Appeal bond mechanics

When a party escalates a dispute to round `n`, they post an appeal bond equal to
`getRequiredAppealBond(workflowId, escrow, currentLevel)`. This bond is held by the DRM
until the dispute finalises.

**On finalisation (`finalizeDispute`):**

- The DRM calls `incentiveModule.distributeAppealBond(workflowId, escrowContract, priorRound, upheld)`
- If the round-`n` decision was **upheld** (i.e., the escalation was unsuccessful): the
  bond is forfeited and transferred to the resolver(s) who decided at round `n-1`.
- If the round-`n` decision was **overturned** (i.e., the escalation was correct): the bond
  is refunded to the depositor.

This creates a direct incentive structure:

> **Posting an appeal bond is a bet on the prior resolver being wrong.** If you are right,
> you get your bond back. If you are wrong, the resolver who was right gets your bond.

The bond depositor and amount are stored per round in `bondDepositorAtRound` and
`bondAmountAtRound`. The `bondRefundedAtRound` flag records the outcome for auditability.

---

## 5. Resolver payment distribution (`PaymentCalculationLibraryV1`)

**Contract:** `PaymentCalculationLibraryV1` (implements `IPaymentCalculationLibrary`)

When a dispute is finalised, fees accumulated across the escrow fee and escalation fees are
distributed to the resolvers who participated in the dispute, weighted by their escalation
level.

**Level weights (V1 defaults):**

| Round | Weight |
|-------|--------|
| 0 (initial resolver) | 1.0× (level0 = 10,000 bps) |
| 1 (senior resolver) | 1.5× (level1 = 15,000 bps) |
| 2 (Kleros/external) | 2.0× (level2 = 20,000 bps) |

Higher-round resolvers are compensated more per case because their work is more complex and
their time more scarce.

**Payment formula:**

```
totalFees     = escrowFee + escalationFees
resolverShare = totalFees × resolverSharePercentage / 10,000
payment[i]    = resolverShare × weight[i] / totalWeight
```

Rounding remainders are distributed proportionally across resolvers with non-zero payments,
rather than all going to the first resolver. This prevents systematic over-payment to any
single position.

The payment library is a separately deployed contract (`IPaymentCalculationLibrary`) so it
can be upgraded by governance without touching the DRM itself. Upgrading the library changes
how future disputes are settled but does not retroactively affect in-flight disputes.

---

## 6. EMA reputation scoring

**Contract:** `ResolutionAnalytics`

Every resolver has an EMA (exponential moving average) quality score tracked in
`ResolverStats.emaScore` (0–1,000,000 fixed-point, where 1,000,000 = perfect performance).

**EMA update formula:**

```
score_new = score_old × (1 - α) + outcome × α
```

Where `α` is governed by `emaAlphaBps` (default 10% = 1,000 bps) and outcome values are:

| Event | Outcome signal |
|-------|---------------|
| Decision submitted on time | 1,000,000 (perfect, `OUTCOME_UPHELD`) |
| Decision reversed on appeal | 500,000 (neutral, `OUTCOME_REVERSED`) |
| Timeout (missed accept or resolve deadline) | 0 (worst, `OUTCOME_TIMEOUT`) |

New resolvers start with a perfect score of 1,000,000 — they receive the benefit of the doubt
until they have a track record.

**Score to routing weight:**

```
workloadWeight = emaScore / 100       (produces 0–10,000 bps)
```

If a resolver's EMA score falls below `MIN_SCORE_THRESHOLD` (50%), their workload weight
drops to zero and they stop receiving new case assignments automatically, without requiring a
governance action to remove them.

A manual `assignmentWeight` override (0–10,000 bps) can be set by governance per resolver to
exclude (`assignmentWeight = 0`) or down-weight a resolver independently of their EMA score.
An `assignmentWeight = 0` unconditionally returns weight 0, regardless of EMA score.

**Governance attention signals:**

`ResolutionAnalytics.checkResolverNeedsAttention()` returns a flag and reason code when:

- EMA score < 50% (reason code 1)
- Timeout rate > 30% (reason code 2)
- Resolver is inactive (reason code 3)
- Reversal rate > 20% (reason code 4)

These signals are informational. Acting on them (removing a resolver, adjusting their weight)
still requires a governance transaction.

---

## 7. Weighted round-robin assignment

When a dispute is opened, the DRM selects an initial resolver by weighted round-robin over
the active resolver pool. The selection process filters candidates by:

1. **Active flag** — `resolverMetadata[resolver].active` must be true.
2. **Capacity** — `currentDisputes < maxConcurrentDisputes` and `acceptsNewDisputes` true.
3. **Timeout rate gate** — candidates with a timeout rate above `maxTimeoutRateBps` are
   skipped.
4. **Assignment weight** — zero-weight resolvers are excluded; remaining weight is
   proportional to `emaScore / 100`.

The round-robin cursor advances through the eligible pool, weighted by score. Resolvers with
higher EMA scores receive proportionally more case assignments. A resolver who repeatedly
times out will see their EMA score fall, their weight fall, and eventually their assignment
rate approach zero — without any explicit exclusion action.

---

## 8. Bond composition and valuation (DR v3)

**Contract:** `ResolverStakingModuleV1` + `BondValuationLibrary`

In DR v3, resolvers must post a bond before they can accept disputes. The bond is a mixed
position of stablecoin and Sew token, subject to enforced composition rules:

| Constraint | Value |
|------------|-------|
| Minimum stable fraction | 80% of effective bond value |
| Maximum Sew fraction | 20% of effective bond value (after haircut) |
| Sew haircut | 50% (Sew token is valued at 50% of its USD price for bond purposes) |

**Effective bond calculation:**

```
effectiveBondUSD = stableAmount (normalized to 18 dec, 1:1 USD)
                 + sewAmount × sewPriceUSD × (1 − 0.50 haircut)
```

**Why a haircut?** Sew token is more volatile than a stablecoin. A sudden price drop that
wiped out 50% of Sew's value would still leave the bond's effective value unchanged, because
the Sew component is already valued at 50 cents on the dollar. The 80/20 split means even a
complete Sew crash to zero only reduces the effective bond by at most 20%.

The library also includes a `simulatePriceCrash` function that computes whether a resolver's
bond coverage would remain sufficient after a specific price decline — used during governance
review of bond parameters.

**Capacity constraint:**

```
maxEscrowPerCase = min(MAX_ESCROW_PER_L0_CASE, CAPACITY_MULTIPLIER × resolverBond)
                = min($2,000, 4 × resolverBond)
```

A resolver cannot be assigned a dispute where the escrow value exceeds their capacity limit.
This prevents a poorly-bonded resolver from being responsible for arbitrating a dispute on a
$100,000 escrow.

**Unbonding delays:**

| Role | Unbonding delay |
|------|----------------|
| Resolver | 14 days |
| Senior resolver | 21 days |

Unbonding requires a two-step request/release. A pending unbond request can be cancelled.
Stakes that are locked to an active dispute cannot be unbonded until the dispute finalises.

---

## 9. Delegated bond coverage

**Contracts:** `ResolverStakingModuleV1`, `BondValuationLibrary`

Delegated coverage is the mechanism by which a junior resolver can be backed by a senior
resolver's bond. This allows junior resolvers to participate with a smaller personal bond,
provided they have the explicit backing of a senior.

### 9.1 Coverage model

A senior's bond can back multiple junior resolvers, subject to two parameters:

| Parameter | Value | Meaning |
|-----------|-------|---------|
| Coverage multiplier (M) | 3× | A senior with bond `B` can back up to `3 × B` in total junior coverage |
| Utilization (U) | 50% | Of the senior's effective bond, at most 50% is available as coverage |

Therefore:

```
availableCoverage = seniorEffectiveBondUSD × U = seniorBond × 0.50
maxTotalJuniorCoverage = availableCoverage × M = seniorBond × 1.50
```

When a junior delegates to a senior, a `coverageAmount` is reserved from the senior's
available coverage. The senior's `reservedCoverage` increases by this amount.

### 9.2 Coverage invariants

The staking module enforces two invariants before any delegation:

1. **Coverage is sufficient:** `availableCoverage >= reservedCoverage + newCoverage`
   — a senior cannot become over-committed.
2. **Senior is active:** `stakeStatus[senior] == ACTIVE` — delegation to a suspended or
   unbonding senior is rejected.

If either invariant fails, the delegation transaction reverts. This is checked with
`BondValuationLibrary.checkCoverage(effectiveBondUSD, utilizationBps, reservedCoverage)`.

### 9.3 Coverage slashing

When a junior is slashed and their own bond is insufficient to cover the penalty, the
shortfall is taken from their delegating senior's bond:

```
senior.bond -= shortfall
emit CoverageSlashed(senior, shortfall, junior)
```

The senior's `reservedCoverage` decreases correspondingly. This creates accountability:
a senior who repeatedly backs juniors with poor judgment will see their own bond eroded
by proxy.

### 9.4 Why delegated coverage matters

Without delegated coverage, becoming a resolver requires posting the full bond personally.
This concentrates the resolver pool among well-capitalized participants and creates a
barrier for new entrants. Delegated coverage lets a reputable senior extend their capital
to back junior resolvers they trust, expanding the pool while maintaining skin-in-the-game
accountability at the senior level.

---

## 10. Slashing

**Contract:** `ResolverSlashingModuleV1`

Slashing is the DR v3 mechanism for penalising resolvers who fail their obligations. All
slashes are denominated in basis points of the resolver's bond.

### 10.1 Slash schedule

| Offense | Penalty | Notes |
|---------|---------|-------|
| Missed accept deadline (`TIMEOUT_ACCEPT`) | 0.25% (25 bps) | Immediate; no contest window |
| Missed resolve deadline (`TIMEOUT_RESOLVE`) | 2% (200 bps) | 24-hour contest window before execution |
| Repeat missed resolve in same epoch | 5% (500 bps) | Higher penalty for repeated liveness failures |
| Decision reversed (`REVERSAL`) | 0% (disabled at launch) | Reputation impact only; re-enabled in a later epoch |

Reversal slashing is intentionally disabled at launch. EMA score degradation and workload
reduction handle reversals initially; bond slashing for reversals is added once the resolver
pool has established a track record and the calibration is better understood.

### 10.2 Epoch-based slash caps

Slashing is rate-limited per resolver per epoch (30 days) to prevent runaway penalties from
a single bad period:

| Role | Cap |
|------|-----|
| Resolver | 20% per epoch (2,000 bps) |
| Senior resolver | 10% per epoch (1,000 bps) |

Once the cap is reached, further slash requests for that epoch are rejected. This bounds the
maximum loss any resolver can suffer in a single 30-day window.

### 10.3 Freeze mechanics

When a slash is pending or contested, the affected resolver's bond is frozen:

| Condition | Freeze duration |
|-----------|----------------|
| Single severe event | 3 days |
| Repeated severe event within same epoch | 7 days |

A frozen resolver cannot withdraw or unbond their stake while the freeze is active. This
prevents a resolver from withdrawing their bond immediately after a timeout to avoid the
slash.

The 24-hour contest window for `TIMEOUT_RESOLVE` slashes allows a resolver to dispute an
automated slash if they believe it was triggered in error (e.g., a network issue). Contested
slashes require governance review before execution.

### 10.4 Double-slash prevention

The mapping `workflowSlashed[escrowContract][workflowId][resolver]` ensures a resolver
can only be slashed once per dispute per escrow. Duplicate slash requests for the same
offense revert.

---

## 11. Insurance pool

**Contract:** `InsurancePoolVault`

Slashed funds do not go to any specific beneficiary. They are deposited into the
`InsurancePoolVault`, a dedicated vault with source-tagged accounting:

| Source tag | From |
|-----------|------|
| `timeout` | `TIMEOUT_ACCEPT` and `TIMEOUT_RESOLVE` slashes |
| `reversal` | `REVERSAL` slashes |
| `fraud` | `FRAUD` slashes |

Source tagging enables governance to reason about what types of resolver failure are
generating insurance capital and to target payouts appropriately (e.g., a party harmed by
a specific fraud incident can receive compensation from the fraud sub-balance).

**Payout mechanics:**

Insurance payouts require a slow-lane governance process:

1. Governance calls `proposePayout(to, amount, workflowId, reason)` — a 7-day pending
   period is applied.
2. After 7 days, governance calls `executePayout(payoutId)`.

Direct withdrawals (bypassing the propose/execute queue) are disabled by default
(`withdrawalsEnabled = false`) and can only be enabled by a governance action. The vault
holds funds indefinitely; there is no automatic disbursement.

---

## 12. Economic flywheel summary

The dispute economics form an interconnected system:

```
Dispute opened
    │
    │  Escalation cost curve discourages frivolous appeals
    │  Round-robin assignment weights resolvers by EMA score
    ▼
Resolver decision submitted
    │  EMA score updated (positive signal)
    │  Incentive module records resolver at this round
    ▼
Appealing party posts appeal bond
    │  Bond amount = escalation cost(k) — quadratic by default
    │  Bond recorded in bondDepositorAtRound[round]
    ▼
Higher-round resolver decides
    │
    ├─► If prior decision UPHELD:
    │       Appeal bond forfeited → paid to prior resolver
    │       Prior resolver EMA unchanged (already scored)
    │       Appealing party net loss = bond amount
    │
    └─► If prior decision OVERTURNED:
            Appeal bond refunded to depositor
            Prior resolver EMA score takes 0.5 outcome hit (OUTCOME_REVERSED)
            Prior resolver reversal counter increments
            If reversal rate > 20% → governance attention flag raised

Dispute finalized
    │
    ├─► Payment calculation: fees distributed weighted by round (L0=1x, L1=1.5x, L2=2x)
    │
    └─► Slashing (DR v3): timeout/fraud slash → InsurancePoolVault
        Coverage slashing: senior's bond absorbs junior's shortfall
```

---

## 13. DR version roadmap

The DRM is designed in three generations, each adding a layer of accountability:

| Version | Status | Key features |
|---------|--------|-------------|
| DR v1 | Production | EMA reputation scoring, round-robin assignment, three-round pipeline, timeout/reversal tracking |
| DR v2 | Production | User-posted appeal bonds, escalation cost curves (linear/quadratic/geometric), appeal bond distribution to resolvers, upgradeable payment library |
| DR v3 | In development | Resolver-posted bonds (mixed stable/Sew), delegated senior coverage, slashing (timeout, fraud), epoch caps, freeze mechanics, InsurancePoolVault |

DR v2 internalised the cost of frivolous escalation (paid by the escalating user). DR v3
externalises accountability to resolvers themselves: a resolver who fails their obligations
loses part of their bond, and their delegating senior absorbs any shortfall beyond the
resolver's own bond.

The framework is designed so that DR v1, v2, and v3 are each valid `IResolutionModule`
implementations. The escrow contracts do not need to know which version is active — they
call the same interface regardless.

---

## 14. Adversarial simulation coverage

The Protocol Robustness Framework includes simulation phases specifically targeting the
dispute economics:

- **Phase F** — Resolver incentive alignment: tests whether resolvers who defect (timeout,
  submit wrong decisions) are penalised faster than they can extract value.
- **Phase H** — Capacity flooding: tests whether dispute flooding attacks can overwhelm the
  resolver pool or exhaust appeal bond balances.
- **Phase J** — Multi-epoch reputation: tests whether EMA score decay correctly excludes
  poor resolvers over multiple epochs without governance intervention.
- **Phase AI** — Adversarial bond strategies: tests escalation cost curves against a
  systematic appealer trying to overturn correct decisions by repeatedly escalating.

Simulation results are recorded in `results/` and replayed via the deterministic scenario
runner. See the Protocol Robustness Framework repository for evidence reports.
