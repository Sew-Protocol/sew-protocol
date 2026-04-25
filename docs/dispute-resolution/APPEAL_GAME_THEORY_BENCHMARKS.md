# Appeal Game Theory: Formal Benchmarks for Sew Protocol DR

**Date**: 2026-04-25  
**Scope**: Formal equilibrium analysis of the appeal bond mechanism with executable verification methods  
**Purpose**: Falsifiable claims about protocol properties, each with a runnable measurement method

---

## Notation

| Symbol | Meaning | Source |
|---|---|---|
| `V` | Escrow value (in USD) | per-escrow |
| `B(k)` | Bond required to escalate to round `k` | `EscalationCostLibrary` |
| `b₀` | Base bond cost | `escalationCostConfig.baseCost` = 0.01 ETH (default) |
| `b₁` | Step size | `escalationCostConfig.stepSize` = 0.01 ETH (default) |
| `p(k)` | Probability that escalation to round `k` results in reversal | empirical |
| `K` | MAX_ROUND | `DRMStorageBase.MAX_ROUND` = 2 |
| `α` | EMA alpha | `emaAlphaBps / 10000` = 0.10 |
| `R(r)` | Resolver `r` reversal rate | empirical |
| `S(r)` | Resolver `r` staked bond (effective USD) | `ResolverStakingModuleV1.getEffectiveBond()` |
| `T_r(k)` | Resolve deadline for round `k` | `resolveDeadlines[k]` = [24h, 48h, 7d] |
| `T_a(k)` | Appeal window for round `k` | `appealWindows[k]` = [2d, 3d, 0] |

**Bond formula (quadratic, default):**

```
B(k) = b₀ + b₁ × k²       k ∈ {1, 2}
B(1) = 0.01 + 0.01 = 0.02 ETH
B(2) = 0.01 + 0.04 = 0.05 ETH
```

---

## Theorem 1: Rational Non-Escalation

**Statement:** A risk-neutral party escalates to round `k` iff their expected value from escalating is positive.

**Proof sketch:**

Let `W(k)` = value recovered if escalation succeeds (the opponent's position, approximately `V`).  
Let `L(k) = B(k)` = value lost if escalation fails.  
Expected value of escalating: `EV(k) = p(k) × V - (1 - p(k)) × B(k)`

Escalation is rational iff `EV(k) > 0`:

```
p(k) × V > (1 - p(k)) × B(k)
p(k) × (V + B(k)) > B(k)
p(k) > B(k) / (V + B(k))
```

Since `B(k) << V` for most commercial escrows, the approximation `p(k) > B(k) / V` is tight.

**Benchmark BM-T1:** The minimum probability of success `p*` that makes escalation rational is `p* ≈ B(k) / V`. This is the *griefing threshold*: parties with `p < p*` should not escalate. The protocol relies on this being above the baseline noise probability.

**Table — p\* for round 1 at default parameters (B(1) ≈ $50 at ETH=$2,500):**

| V | p* (round 1) | p* (round 2) | Interpretation |
|---|---|---|---|
| $50 | 50% | 100%+ | Only escalate if very confident |
| $100 | 33% | 100%+ | Round 2 effectively blocked |
| $200 | 20% | 50% | Reasonable thresholds |
| $500 | 9% | 22% | Both rounds accessible to credible disputes |
| $1,000 | 5% | 11% | Very accessible |
| $2,000 | 2% | 6% | Near-zero friction |

**Warning:** At ETH = $5,000 (2× scenario), B(1) = $100, halving effective accessibility. At ETH = $10,000, B(1) = $200. Bond denomination in escrow token eliminates this volatility.

---

## Theorem 2: Griefing Equilibrium

**Statement:** A griefer (party with no genuine belief in winning, `p = 0`) faces a pure cost of exhausting the appeal chain. Griefing is irrational iff `Grief_cost > griefer_benefit`.

**Grief cost (full chain):**

```
Grief_cost = B(1) + B(2) = (b₀ + b₁) + (b₀ + 4b₁) = 2b₀ + 5b₁
```

At defaults: `2(0.01) + 5(0.01) = 0.07 ETH ≈ $175`

**Griefer's benefit** from exhausting the chain is delay: `delay_benefit = lockup_of_opponent × opportunity_cost`

For the opponent, funds are locked during dispute resolution. If opponent's opportunity cost is `r` and dispute takes additional `D` days after original deadline:

```
delay_benefit_to_griefer = V × r × D / 365
```

**Full chain delay:** `D = T_r(0) + T_a(0) + T_r(1) + T_a(1) + T_r(2) = 24h + 2d + 48h + 3d + 7d ≈ 14d`

For `D = 14d`, `r = 5%` annual, `V = $1,000`: `delay_benefit = $1,000 × 0.05 × 14/365 ≈ $1.92`

**Griefing is almost never economically rational.** The benefit from delay is negligible for the annual interest rates on locked funds. The bond ($175) vastly exceeds the delay value ($1.92) even at $1,000 escrows.

**Exception:** If the griefer profits from delay by some mechanism external to the escrow (e.g., short-selling related assets, regulatory arbitrage), the delay_benefit is not bounded by V × r. This is an out-of-scope attack vector.

**BM-T2 formula:** `Grief_cost / delay_benefit > 1` for all disputes in target range. At current defaults, this holds with a ratio of ~90:1 for $1,000 escrows.

---

## Theorem 3: Bribery Resistance (DR v3)

**Statement:** For a resolver `r` with effective bond `S(r)` and expected future income stream `F(r)`, bribery is rational for an attacker iff:

```
V_gained > S(r) + F(r)
```

where `V_gained = V × 50%` (partial benefit from flipping decision, as opponent retains something regardless).

**Since `maxEscrowPerL0Case = min($2,000, 4 × S(r))`:**

```
V_gained ≤ 2,000 / 2 = $1,000
S(r) ≥ 250 (minimum bond)
```

So bribery is irrational at V ≤ $2,000 iff `F(r) ≥ $1,000 - $250 = $750`

**BM-T3 target:** Professional resolvers maintain `F(r) ≥ $750` as a minimum viable professional income stream. This is easily satisfied for any resolver handling >10 cases/month at $5+/case.

**Waterfall implication:** In DR v3, a briber must overcome both `S(r)` (resolver bond) and `F(r)` (income at risk). Even if the resolver's bond is minimal, a senior resolver's delegation (`S_senior ≥ $25,000`) adds a second layer: corrupting the senior undermines the entire delegation network.

---

## Theorem 4: Convergence of EMA Quality Signal

**Statement:** With `α = 0.10`, the EMA quality score of resolver `r` converges to within `ε` of their true steady-state score after `N(ε) ≈ -ln(ε) / α` disputes.

```
|EMA(n) - EMA(∞)| ≤ ε  after  n ≥ -ln(ε) / 0.10 disputes
```

| ε | N required |
|---|---|
| 10% | 23 disputes |
| 5% | 30 disputes |
| 1% | 46 disputes |

**Interpretation:** A resolver needs ~30 cases before their quality score is a reliable signal. This has two implications:

1. **Cold-start problem:** New resolvers with 0 cases have undefined EMA. The current `minEmaScoreThreshold = 500000` means they are excluded from assignments entirely. A probationary score (e.g., 600,000 = "neutral") would allow new resolvers to receive low-weight assignments while building history.

2. **Workload-routing latency:** If a resolver degrades in quality, governance (or automated weight adjustment) needs ~30 disputes to act on reliable signal. Epoch caps on slashing (7-day windows) are consistent with this convergence time.

---

## Theorem 5: Schelling Stability vs Kleros

**Statement:** Sew's single-expert model is more accurate than a random Schelling jury when the dispute involves domain knowledge, and less accurate when the dispute involves an objectively verifiable binary fact.

Let `p_expert` = probability a professional resolver decides correctly.  
Let `p_juror` = probability a Kleros juror decides correctly on a Schelling coordination problem.

For a Kleros panel of N jurors, the probability of a correct majority vote is:

```
P_Kleros(N) = Σ_{k=⌈N/2⌉}^{N} C(N,k) × p_juror^k × (1 - p_juror)^(N-k)
```

For `p_juror = 0.6, N = 3`: `P_Kleros(3) ≈ 0.648`  
For `p_juror = 0.6, N = 7`: `P_Kleros(7) ≈ 0.710`

For `p_expert = 0.85` (assumed for curated professional resolver): Sew single-expert wins for all N up to ~50 at these parameters.

**The crossover point:** Sew's model is inferior to Kleros only when `p_expert < p_juror^* ≈ 0.55` for N=7. A resolver with majority accuracy below 55% would be outperformed by 7 random jurors. The whitelist and EMA quality system should ensure `p_expert >> 0.55` in practice.

**This formally justifies the round-2 Kleros backstop:** If round-0 and round-1 resolvers have reached conflicting decisions, their individual accuracy is in doubt. Sending to Kleros (N=7+) is a rational escalation even if individual juror accuracy is modest.

---

## Public Benchmark Suite: Runnable Specification

The following benchmarks are designed to be reproducible by any external party with access to on-chain data or the open-source simulation toolkit.

---

### BM-01: Griefing Tax Rate

**Input:** `(b₀, b₁, V, ETH_price_USD)`  
**Computation:** `G = (B(1) + B(2)) / V × 100%`  
**Pass criterion:** `G(V_min) ≥ 5%` and `G(V_max) ≥ 0.5%`  
**Verification:** Purely analytical. No on-chain dependency.  

```python
def griefing_tax(b0_eth, b1_eth, V_usd, eth_price):
    b0 = b0_eth * eth_price
    b1 = b1_eth * eth_price
    B1 = b0 + b1 * 1**2
    B2 = b0 + b1 * 2**2
    return (B1 + B2) / V_usd

# At defaults: b0=0.01, b1=0.01, eth_price=2500
assert griefing_tax(0.01, 0.01, 100, 2500) >= 0.05     # BM-01 lower bound
assert griefing_tax(0.01, 0.01, 2000, 2500) >= 0.005   # BM-01 upper bound
```

**Current values:** `G($100) = 175%`, `G($2,000) = 8.75%` — **PASS** at $2,500/ETH. Benchmark fails if ETH > ~$5,000 at fixed absolute bonds.

---

### BM-02: Rational Access

**Input:** `(b₀, b₁, V, p_threshold)`  
**Claim:** Parties with p ≥ p_threshold find escalation rational for V ≥ V_min  
**Computation:** `required_p = B(1) / (V + B(1))`  
**Pass criterion:** `required_p(V_min) ≤ p_threshold`

```python
def required_p_to_escalate(b0_eth, b1_eth, V_usd, eth_price, round_k):
    b = (b0_eth + b1_eth * round_k**2) * eth_price
    return b / (V_usd + b)

# Target: p >= 25% is rational for V >= $200 at round 1
assert required_p_to_escalate(0.01, 0.01, 200, 2500, 1) <= 0.25
```

---

### BM-03: Bond Distribution Completeness

**Inputs:** Smart contract state on any network where `ResolverIncentiveModuleV2` is deployed.  
**Computation:** Query all disputes where `dm.status == Final`, check `hasAppealBond(id, escrow, round)` for each `round ∈ {1, 2}`. Count undistributed bonds.  
**Pass criterion:** Zero disputes with `hasAppealBond == true` and `bond.distributed == false` and `dm.status == Final`.

```solidity
// Foundry invariant
function invariant_noStrandedBondsAfterFinality() public {
    for (uint256 id = 1; id <= lastDisputeId; id++) {
        DisputeMetadata memory dm = drm.getDisputeMetadata(workflowId, escrow);
        if (dm.status == DisputeStatus.Final) {
            for (uint8 r = 1; r <= MAX_ROUND; r++) {
                AppealBondRecord memory bond = incentiveV2.getAppealBond(id, escrow, r);
                assertFalse(bond.amount > 0 && !bond.distributed,
                    "Stranded bond after finality");
            }
        }
    }
}
```

**Current status: FAIL** — known bug. Fix: add `distributeAppealBond(r-1, false)` loop in `finalizeDispute`.

---

### BM-04: Slashing Epoch Solvency

**Inputs:** `resolverCount`, `avgBond`, `insurancePoolBalance`, `EPOCH_LENGTH = 7d`, `RESOLVER_SLASH_CAP_BPS = 2000`  
**Computation:** Maximum insurance pool drawdown in a single epoch assuming all resolvers are slashed to their epoch cap simultaneously.

```python
def max_epoch_drawdown(resolver_count, avg_bond_usd, insurance_pct=0.20):
    max_per_resolver = avg_bond_usd * 0.20  # 20% epoch cap
    max_drawdown = resolver_count * max_per_resolver
    # Only 20% of each slash goes to insurance
    insurance_drawdown = max_drawdown * insurance_pct
    return insurance_drawdown

# For 10 resolvers at $500 avg bond:
# max_drawdown = 10 * 100 = $1,000
# insurance_drawdown = $200

def solvency_ratio(resolver_count, avg_bond_usd, pool_balance):
    drawdown = max_epoch_drawdown(resolver_count, avg_bond_usd)
    return pool_balance / drawdown if drawdown > 0 else float('inf')
```

**Pass criterion:** `solvency_ratio ≥ 1.0`

---

### BM-05: EMA Convergence Rate

**Inputs:** Resolver history (sequence of outcomes: resolved, escalated, reversed)  
**Computation:** Simulate EMA score convergence given known true accuracy `p_correct`

```python
def simulate_ema_convergence(p_correct, alpha=0.10, n_cases=50, n_sims=1000):
    """Returns mean absolute error of EMA vs steady-state score after n_cases."""
    steady_state = p_correct  # simplified; actual formula is more complex
    errors = []
    for _ in range(n_sims):
        ema = 0.5  # initial score (neutral)
        for _ in range(n_cases):
            outcome = 1 if random.random() < p_correct else 0
            ema = (1 - alpha) * ema + alpha * outcome
        errors.append(abs(ema - steady_state))
    return sum(errors) / len(errors)

# Pass: mean error < 0.05 after 30 cases
assert simulate_ema_convergence(0.85, n_cases=30) < 0.05
```

---

### BM-06: Finality Latency

**Inputs:** On-chain event logs for `DisputeRaised` and `finalizeDispute` calls  
**Computation:** `latency = finalizeTimestamp - disputeOpenTimestamp`  
**Pass criteria:**
- Non-appealed: P90 ≤ 72h (24h resolve + 2d appeal window)
- Single appeal: P90 ≤ 168h (72h + 48h resolve + 3d appeal window)
- Full chain: P90 ≤ 336h (168h + 7d resolve)

---

### BM-07: Resolver Accuracy Distribution

**Inputs:** All resolved disputes with known appeal outcomes  
**Computation:** `resolver_accuracy = upheld_decisions / total_escalated_decisions`  
**Pass criterion:** P25 of active resolver accuracy ≥ 70% (better than random by substantial margin)

---

### Benchmark Registry

| ID | Name | Type | Status | Frequency |
|---|---|---|---|---|
| BM-01 | Griefing tax rate | Analytical | ACTIVE | On every param change |
| BM-02 | Rational access | Analytical | ACTIVE | On every param change |
| BM-03 | Bond distribution completeness | On-chain invariant | **FAIL** | Continuous |
| BM-04 | Slashing epoch solvency | Simulation | OPEN | Quarterly |
| BM-05 | EMA convergence | Simulation | OPEN | On alpha change |
| BM-06 | Finality latency | On-chain | OPEN (no mainnet data) | Weekly |
| BM-07 | Resolver accuracy | On-chain | OPEN (no mainnet data) | Monthly |

---

## Parameter Sensitivity Summary

The following parameters most directly affect the benchmark outcomes. Governance proposals touching these should rerun BM-01 through BM-05 as standard checks.

| Parameter | Current default | BM-01 sensitivity | BM-02 sensitivity | Note |
|---|---|---|---|---|
| `baseCost` | 0.01 ETH | High | High | Denominating in escrow token removes ETH price sensitivity |
| `stepSize` | 0.01 ETH | High | High | Same issue |
| `emaAlphaBps` | 1000 (10%) | — | — | Affects BM-05 convergence |
| `RESOLVER_SLASH_CAP_BPS` | 2000 (20%) | — | — | Affects BM-04 solvency |
| `MIN_STABLE_BPS` | 8000 (80%) | — | — | Affects bribery resistance |
| `SEW_HAIRCUT_BPS` | 5000 (50%) | — | — | Affects effective bond calculation |
| `COVERAGE_MULTIPLIER` | 3 | — | — | Affects senior capacity |
