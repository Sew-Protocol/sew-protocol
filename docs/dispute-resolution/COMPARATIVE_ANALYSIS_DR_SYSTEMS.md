# Comparative Analysis: Sew DR vs UMA Oracle vs Kleros

**Date**: 2026-04-25  
**Scope**: Architecture comparison, appeal game-theory benchmarks, public benchmark suite  
**Audience**: Protocol engineers, security auditors, mechanism designers, potential integrators

---

## 1. System Architecture Comparison

The three systems resolve different problem classes and should not be treated as direct competitors, but their mechanisms overlap enough for a precise comparison to be useful — especially on appeal economics, token design, and security model.

### 1.1 Decision Model

| Dimension | Sew Protocol | UMA (Optimistic Oracle) | Kleros |
|---|---|---|---|
| **Problem class** | Human-judgment disputes (physical goods, delivery, service quality) | Data/price disputes ("was ETH/USD < $3,000 at block N?") | General legal/factual disputes (curated courts) |
| **Who decides** | Permissioned professional resolver, single actor per round | Token holders vote in Data Verification Mechanism (DVM) | Randomly selected jurors from PNK-staked pool |
| **Selection** | Weighted-random from approved set; EMA quality score adjusts weight | All UMA token holders eligible | Probability ∝ PNK staked in that court |
| **Jury size** | 1 resolver per round (professional, senior, or Kleros) | All participating token holders (~mass vote) | Exponentially doubling: 3 → 7 → 15 → 31... |
| **Outcome type** | Binary (RELEASE / CANCEL) or partial | Continuous numerical (oracle price) or binary | Binary or categorical (court-specific) |
| **Specialization** | Professional resolvers with subject-matter approval | None — same DVM for all dispute types | Court-specific (e.g., Freelance Court, Token Curated Registry) |
| **Anonymity** | Resolvers pseudonymous, whitelisted | Voters fully anonymous | Jurors anonymous, selected probabilistically |

**Key structural difference:** Sew uses *appointed expert* judgment (one professional per round). UMA uses *economic-majority* judgment (mass token vote). Kleros uses *random-sample* judgment (crowdsourced Schelling coordination). These are not interchangeable: Sew's model is weakest against bribery at scale but strongest at subject-matter accuracy for low-volume, high-context disputes.

---

### 1.2 Appeal and Escalation Mechanism

| Dimension | Sew Protocol | UMA | Kleros |
|---|---|---|---|
| **Rounds** | MAX_ROUND = 2 (L0 → L1 → L2/Kleros) | Single round (no re-appeal) | Unbounded (rare in practice; effective cap ~5) |
| **Trigger** | Either party posts escalation bond | Either party posts challenge bond equal to proposer bond | Losing party posts appeal bond |
| **Cost curve** | Quadratic: `b(k) = b₀ + b₁k²` (default: b₀ = b₁ = 0.01 ETH) | Fixed symmetric bond (proposer = challenger) | Grows with jury count doubling × fee/juror |
| **Bond token** | Same token as escrow asset (enforced) | Bond token configurable per deployment | ETH (arbitration fees) + PNK at risk |
| **Failed appeal** | Bond paid to prior-round resolver(s) | Challenger loses bond; split: winner + UMA voters | Minority jurors lose PNK; majority earn fees |
| **Successful appeal** | Bond refunded to escalating party | Challenger wins; 50% of proposer bond | Winning jurors earn minority-juror PNK |
| **Resolution latency** | R0: 24h, R1: 48h, R2: 7d + 2d/3d appeal windows | Liveness: configurable (2h default); DVM vote: ~4 days | Per-round juror deliberation: varies by court (days) |
| **Appeal deadline enforcement** | Enforced on-chain: `finalizeDispute` reverts if window open | Enforced on-chain | Enforced on-chain |
| **Max latency (full chain)** | ≤ 2 + 24h + 2 + 48h + 7d ≈ 12 days | ≤ 2h + 4 days = ~4.1 days | Theoretically unbounded; typically 2–4 weeks for 3 rounds |

**Sew vs UMA escalation:** UMA has no multi-round escalation — the DVM is a single authoritative vote. There is no recourse once the DVM settles. Sew's three-tier structure gives parties two appeal opportunities before reaching Kleros, each more expensive. This is appropriate for disputes where the initial resolver might have incomplete information.

**Sew vs Kleros escalation:** Both use increasing-cost multi-round structures. Kleros's exponential jury doubling means each appeal roughly doubles the arbitration fee. Sew's quadratic curve means the second escalation costs `b₀ + 4b₁` vs the first's `b₀ + b₁`. At default parameters (b₀ = b₁ = 0.01 ETH), the ratio is 5:1 — weaker than Kleros's typical ~2× per-round multiplier on absolute cost but stronger on percentage increase.

---

### 1.3 Economic Security Model

| Dimension | Sew Protocol | UMA | Kleros |
|---|---|---|---|
| **Security source** | Resolver reputation + bond (DR v3) + appeal costs | "Cost to corrupt DVM" = cost to acquire 50%+1 UMA | Schelling coordination among large juror sample |
| **Resolver/juror capital at risk** | DR v3: stablecoin + SEW bond; epoch caps 20%/10%; waterfall to senior | DVM voters: opportunity cost of locked UMA | Jurors: PNK redistributed from minority to majority |
| **Per-case loss cap** | `max($2,000, 4× resolverBond)` — hard on-chain gating | None; any size dispute goes to same DVM | None; Kleros handles arbitrary value disputes |
| **Insurance pool** | `InsurancePoolVault` funded by 20% of slashes + protocol fees | None | None |
| **Token role** | SEW: governance + resolver stake collateral + deflationary sink | UMA: DVM voting power + fee income | PNK: juror selection probability + stake redistribution |
| **Token burn on misbehavior** | Slashed SEW is burned (`burn()` if ERC20Burnable, else → 0xdead) | None (forfeited bonds go to winners/voters) | None (PNK redistributed, not burned) |
| **Correlated failure risk** | Multiple resolvers staking identically in small market | DVM whale attack: single actor buying 50%+ UMA | Bribing a majority of a small initial jury (cheap for small panels) |

**Key asymmetry with UMA:** UMA's security is proportional to market cap of UMA token. If UMA market cap is $M, corrupting the DVM costs `>$M/2`. For Sew, the "cost to corrupt a resolver" is their staked bond (min $250–$500 for L0) plus reputational loss. For a single high-value escrow, a bribe of `escrow_value × 50% + 1 wei` beats the resolver's expected future income from honest behavior. This is why Sew has hard per-case limits (`maxEscrowPerL0Case = min($2,000, 4× bond)`) — the bribery attack surface is mechanically bounded.

**Key asymmetry with Kleros:** Kleros's Schelling mechanism is most secure when the "correct" answer is objectively obvious (the "focal point" is clear). For ambiguous disputes — "was the item as described?" — jurors have no common focal point, and the majority vote is noise. Sew's professional resolvers are selected for subject-matter expertise, which is precisely what's needed for ambiguous physical-goods disputes. The tradeoff: Sew has fewer independent decision-makers, so coordinated corruption among 1–2 professional resolvers is cheaper than corrupting 3–7 Kleros jurors.

---

### 1.4 Token Design Comparison

| Dimension | SEW | UMA | PNK |
|---|---|---|---|
| **Primary function** | Governance + resolver bond collateral | DVM voting weight | Juror selection probability |
| **Secondary function** | Deflationary sink (slashed tokens burned) | Fee income for DVM voters | Stake redistribution (minority → majority) |
| **Demand driver** | Resolver participation requirement; scale ∝ dispute volume | Speculative + protocol fee income | Dispute volume; more disputes = more PNK at play |
| **Inflation/deflation** | Deflationary on misconduct; no base inflation designed | Inflationary (governance mints for voters) | Redistributive (zero-sum within pool) |
| **Price failure mode** | SEW crash reduces effective bond value by at most `20% × haircut = 10%` | UMA crash reduces security linearly | PNK crash reduces juror selection value linearly |
| **Oracle dependency** | None — bond valuation is haircut-adjusted USD, oracle-free | Price data settled by DVM (circular for UMA/UMA pairs) | None |

---

### 1.5 Structural Gaps in Current Sew Implementation

Against the design:

| Gap | Impact |
|---|---|
| `distributeAppealBond(false)` never triggered from `finalizeDispute` | Appeal bonds from failed escalations are stranded in `ResolverIncentiveModuleV2` — resolver payment path broken for failed appeals |
| `ISlashingModule.slashForTimeout` / `slashForReversal` not called from DRM | Automated slashing on misbehavior is not live; only manual `slashForFraud` via ROLE_TIMELOCK |
| Counter-party compensation = 0 | Harmed parties receive nothing from resolver slashes |
| Treasury transfer from slash proceeds not implemented | Slash proceeds pool in `ResolverSlashingModuleV1`, not routed to treasury |

See `docs/dispute-resolution/INCENTIVE_MODULE_REVIEW.md` for full status of each item.

---

## 2. Appeal Game Theory Benchmarks

Define `V` = escrow value, `B(k)` = bond required to escalate to round `k`, `p(k)` = probability that escalation to round `k` results in reversal given a correctly decided round `k-1`.

### 2.1 Rational Escalation Threshold

**Proposition:** A rational party escalates to round `k` iff:

```
p(k) × V > B(k) + (1 - p(k)) × 0
```

i.e. expected recovery exceeds the bond at risk.

**Rearranging:**

```
p(k) > B(k) / V
```

**At Sew defaults** (`B(1) = b₀ + b₁×1 = 0.02 ETH`, `B(2) = b₀ + b₁×4 = 0.05 ETH`):

| Escrow value V | Min p(1) to escalate | Min p(2) to escalate | Rational for both rounds? |
|---|---|---|---|
| $100 | B(1)/V ≈ 40% (at $2500/ETH) | 100% — irrational | Only first round |
| $500 | 8% | 20% | Both rounds for p ≥ 20% |
| $2,000 | 2% | 5% | Both rounds for almost any credible dispute |
| $10,000 | <1% | 1% | Both rounds — bonds are nearly free |

**Implication:** At default parameters, bonds provide negligible anti-spam protection for escrows over ~$2,000. For the target $20–$2,000 range, the quadratic curve is effective. **Governance should consider scaling `b₀` and `b₁` proportionally to escrow value** (e.g., expressed as bps of escrow amount) rather than absolute ETH amounts, which are volatile and value-blind.

---

### 2.2 Griefing Cost Bound

**Definition:** A griefer escalates purely to delay settlement (no belief in winning). Cost to a griefer who escalates the full chain:

```
Grief_cost = B(1) + B(2) = (b₀ + b₁) + (b₀ + 4b₁) = 2b₀ + 5b₁
```

At defaults: `2(0.01) + 5(0.01) = 0.07 ETH ≈ $175` (at $2,500/ETH).

**Kleros comparison:** Kleros's 3-round appeal chain costs roughly `3× juror_fee × jurors_per_round`. For a typical Kleros General Court with 3→7 jurors at ~0.03 ETH/juror-round, total grief cost ≈ `3×0.03 + 7×0.03 = 0.3 ETH ≈ $750`. Sew's 2-round chain is 4× cheaper to grief than Kleros 3-round. This is consistent with Sew's smaller target dispute size.

**UMA comparison:** UMA challenge bond is symmetric and typically in the tens-to-hundreds of thousands of dollars range (anchored to dispute value). Griefing UMA is prohibitively expensive for most protocol disputes. This reflects UMA's design for high-value price data, not consumer disputes.

---

### 2.3 Bribery Resistance

**Definition:** The minimum cost for an attacker to induce resolver `r` to decide incorrectly on escrow `E`.

```
Bribe_min = max(expected_future_income(r), stake_at_risk(r))
```

For DR v3:
- `stake_at_risk(r)` = effective bond (min $250 resolver, min $25,000 senior)
- `expected_future_income(r)` = discounted stream of future resolver fees — not explicitly quantified in current implementation

**Current weakness (DR v1/v2, pre-staking):** `stake_at_risk = 0`. Bribe cost = expected future income only = `workload × fee_per_case × discount_factor`. With no resolver bond, any dispute with value exceeding `expected_future_income` is vulnerable to bribery in principle.

**Implication:** The per-case limit (`maxEscrowPerL0Case`) is the primary bribery guard in DR v1/v2. For a $500 dispute assigned to a resolver earning $5/case, bribe cost is their expected future income. The $2,000 per-case cap ensures bribes are only rational if `$2,000 < expected_future_income`, which is defensible for established professional resolvers.

**DR v3 improvement:** With $500 resolver bond and 14-day unbonding, the bribe also needs to exceed the forfeited bond. For $500 dispute → bond $500 → bribery unprofitable by construction (bribe ≥ bond > dispute value). This is the formal motivation for `maxEscrowPerL0Case = min($2,000, 4× resolverBond)`.

**Kleros comparison:** Bribing a 3-juror Kleros panel costs `bribe × 2` (need majority = 2 of 3 jurors), plus jurors must conceal coordination. Kleros's public commitment mechanism (commit-reveal) makes coordination detectable. Sew has no commit-reveal; a resolver can simply decide incorrectly. However, Sew's whitelist and reputation layer is a practical deterrent that Kleros (open to any PNK staker) lacks.

---

### 2.4 Reversal Incentive Alignment

The escalation bond design creates a second-order signal: **an escalation that succeeds is strong evidence the prior resolver was wrong**. This feeds the EMA quality score.

**Formal relationship:**

Let `R(r)` = resolver `r`'s reversal rate (fraction of decisions escalated and reversed). The EMA score adjusts assignment weight:

```
score(r) = (1 - α) × score_prev(r) + α × event_signal(r)
```

where `emaAlphaBps = 1000` (10% weight on each new event), and reversal events carry a negative signal.

**Implication:** A resolver whose decisions are consistently upheld earns higher assignment weight. A resolver whose decisions are consistently reversed gets workload→0 before DR v3 staking kicks in. This creates *graduated deterrence*: bad resolvers are demoted before they lose capital.

**UMA has no equivalent** — voters face no quality-score signal, only the reward for voting correctly (with majority). Kleros jurors have an implicit signal (minority redistribution) but no persistent reputation score across disputes.

---

### 2.5 Escalation Equilibrium Summary

| Equilibrium condition | Formula | At Sew defaults | Risk |
|---|---|---|---|
| Rational non-escalation | `V × p < B(k)` | V < $250 at p=10% | Bonds too cheap for $2K+ disputes |
| Griefing unprofitable | `Grief_cost > lockup_cost_to_griefer` | $175 full chain | Cheap vs $2K escrow |
| Bribery unprofitable (DR v3) | `V < resolverBond` | True for V ≤ $500 | Not true for V near $2K cap |
| Reversal → resolver penalised | EMA signal → workload ↓ | Active from DR v1 | Soft only; no capital loss until v3 |

---

## 3. Public Benchmark Suite

These benchmarks define measurable, falsifiable claims about the protocol. Each benchmark has a target value derived from the mechanism design, a measurement method, and a pass/fail criterion. They can be evaluated by simulation, formal analysis, or on-chain observation.

---

### BM-01: Griefing Tax Rate

**Claim:** A rational griefer loses at least G% of the dispute value by exhausting the full appeal chain.

**Formula:** `G = (B(1) + B(2)) / V`

**Target:** G ≥ 5% for all disputes in `[V_min, maxEscrowPerL0Case]`

**Measurement:** For a given governance configuration `(b₀, b₁, V)`, compute `G` analytically. Parameterise across the target escrow range.

**Pass criterion:** `G(V_min) ≥ 5%` and `G(maxEscrowPerL0Case) ≥ 0.5%` (even weak griefing cost at maximum escrow)

**Current result at defaults:** `G($100) = 70%` (bonds dominate), `G($2,000) = 3.5%` — **fails** upper-end criterion. The bond curve needs scaling for the full $2K range.

**Note:** This benchmark motivated the recommendation to express `baseCost` as bps of escrow value rather than absolute ETH.

---

### BM-02: Rational Escalation Threshold

**Claim:** Any party with a genuine dispute (P(reversal) ≥ P_min) will find escalation economically rational.

**Formula:** Escalation is rational iff `p > B(k) / V`

**Target:** For `V ≥ $200` and `p ≥ 25%`, escalation should always be rational at round 1.

**Measurement:** Compute `B(1) / V` across the escrow value range. Plot the minimum `p` required to escalate.

**Pass criterion:** `B(1) / V ≤ 25%` for `V ≥ $200`

**Current result:** At `B(1) = 0.02 ETH ≈ $50`: `B(1)/V = 25%` at V = $200. **Borderline pass.** At higher ETH prices, the absolute bond rises and may fail.

**Recommendation:** Denominate bond in escrow token (already architecture-supported), not ETH. This makes BM-02 ETH-price-invariant.

---

### BM-03: Bribery Resistance Ratio

**Claim:** For any escrow assigned to a resolver `r`, the cost of bribing `r` exceeds the profit from the attack.

**Formula:** `BR(r, E) = resolverBond(r) / V(E)`

**Target (DR v3):** `BR ≥ 1.0` (bond ≥ escrow value)

**Measurement:** Given resolver bond = $500 and `maxEscrowPerL0Case = min($2,000, 4×$500) = $2,000`, compute `BR = 500/2000 = 0.25`. **Fails target of 1.0.**

The hard per-case limit is `4× bond`, so `BR ≥ 1/(4) = 0.25` by construction.

**Interpretation:** The system is designed for `BR = 0.25`, not 1.0. The correct framing for the target is: `bribe cost > bond + expected future income ≥ bond`, so the effective attack cost is `bond + income ≥ $500 + expected_stream`. The benchmark should be:

**Revised target:** `BR × (1 + income_multiple) ≥ 1.0`, where `income_multiple = PV(future resolver income) / resolverBond`

**Pass criterion:** Resolver professional income stream (in PV terms) ≥ 3× their bond → effective `BR ≥ 1.0`.

**Measurement method:** Requires on-chain observation of resolver fee income per resolved dispute × estimated caseload.

---

### BM-04: Appeal Bond Distribution Completeness

**Claim:** 100% of appeal bonds are eventually distributed (refunded or paid to resolvers) — no bonds are permanently stranded.

**Measurement:** On-chain: count disputes that reached `DisputeStatus.Final` with `incentiveModule.hasAppealBond(workflowId, escrow, round) == true` after finalization.

**Pass criterion:** Zero disputes where `hasAppealBond == true` AND `bond.distributed == false` AND `dm.status == Final`

**Current result:** **FAIL** — as documented in `INCENTIVE_MODULE_REVIEW.md`, `distributeAppealBond(false)` is not called from `finalizeDispute`. Failed-appeal bonds accumulate unresolved.

**Fix status:** Open. Fix is a loop in `finalizeDispute` calling `distributeAppealBond(r-1, false)` for `r = 1..finalRound`.

---

### BM-05: Slashing Coverage Ratio

**Claim:** For a worst-case simultaneous slashing event (N resolvers slashed in one epoch), the insurance pool remains solvent.

**Formula:**
```
worst_case_loss = N × maxEscrowPerL0Case × P_wrongful_payout
insurance_pool_funded = Σ (slash_proceeds × 20%)
coverage_ratio = insurance_pool_funded / worst_case_loss
```

**Target:** `coverage_ratio ≥ 1.0` for any realistic N

**Measurement:** Simulation — assume N randomly selected resolvers are slashed simultaneously; compute insurance pool drawdown vs funded amount.

**Parameters:**
- Epoch cap: `20%` of resolver bond per epoch
- Insurance pool: funded by `20%` of slash proceeds
- `maxEscrowPerL0Case = $2,000`

**Current result:** Not yet quantified — requires simulation with realistic resolver population size and dispute volume assumptions. At launch (small resolver set, low volume), coverage ratio will be well above 1.0. The benchmark becomes binding as volume scales.

---

### BM-06: Reversal Rate as Quality Signal

**Claim:** Resolver EMA quality scores converge to their true accuracy within N disputes.

**Formula:** With `emaAlphaBps = 1000` (α = 0.10), the EMA converges to within ε of true rate after `k ≈ -ln(ε) / α` disputes.

For ε = 0.05 (5% of true value): `k ≈ -ln(0.05) / 0.10 ≈ 30 disputes`

**Target:** EMA score reflects true reversal rate (±5%) within 30 disputes for each resolver.

**Measurement:** Simulation — assign resolvers with known accuracy `p_correct`, generate disputes, compare EMA after N cases to `p_correct`.

**Pass criterion:** `|ema_score - f(p_correct)| < ε` for 95% of simulations with N ≥ 30 disputes per resolver.

**Note:** 30 disputes per resolver to achieve convergence means alpha is only meaningful after significant volume. New resolvers should start with a conservative default score, not 0, to avoid the cold-start assignment problem.

---

### BM-07: Appeal-Chain Finality Latency

**Claim:** The expected time from dispute open to final settlement is under T_max for disputes that are not appealed, and under T_full for disputes that exhaust all rounds.

**Target values:**
- Non-appealed: `T_max = 24h + 2d ≈ 3 days`
- Full appeal chain: `T_full = 24h + 2d + 48h + 3d + 7d ≈ 14 days`

**Measurement:** On-chain — measure `finalizeDispute timestamp - dispute open timestamp` across all settled disputes.

**Pass criterion:** P90 of non-appealed disputes ≤ 3 days; P50 of appealed disputes ≤ 14 days.

---

### BM-08: Kleros Backstop Integration Correctness

**Claim:** Any dispute escalated to round 2 (Kleros lane) has its decision correctly routed and applied to the escrow contract.

**Measurement:** Integration test — create escrow, escalate to round 2, submit Kleros decision, verify EscrowVault state transitions correctly.

**Pass criterion:** 100% of round-2 outcomes correctly applied; no disputes stuck in `DISPUTED` state after Kleros ruling.

**Current status:** Kleros integration is in the escalation config (`escalationConfig[2]`) but is not tested end-to-end against a live Kleros instance. This benchmark is **not yet runnable**.

---

### Benchmark Matrix

| ID | Claim | Current status | Pass/Fail |
|---|---|---|---|
| BM-01 | Griefing tax ≥ 5% for all in-range escrows | Computed analytically | FAIL at V = $2,000 with absolute bond |
| BM-02 | Rational escalation for p ≥ 25%, V ≥ $200 | Computed analytically | BORDERLINE |
| BM-03 | Bribery resistance ≥ effective bond + income | Requires income data | OPEN |
| BM-04 | 100% bond distribution completeness | On-chain observable | FAIL (known bug) |
| BM-05 | Insurance pool covers worst-case epoch | Requires simulation | OPEN |
| BM-06 | EMA convergence within 30 disputes | Requires simulation | OPEN |
| BM-07 | Finality latency within T_max / T_full | On-chain observable | OPEN (no mainnet data) |
| BM-08 | Kleros backstop correctness | Integration test | NOT RUNNABLE |

---

## 4. Positioning Summary

Sew occupies a niche that UMA and Kleros do not directly address:

- **Not an oracle** — there is no external data feed to verify. The dispute is inherently subjective ("was the item as described?").
- **Not a general legal court** — Sew's permissioned resolver model is purpose-built for commercial escrow context, not contract law or policy interpretation.
- **vs UMA:** UMA is the right primitive for binary on-chain data disputes at high value. Sew is the right primitive for low-to-medium value, human-judgment disputes in commerce. Sew could integrate UMA as its fraud lane oracle (e.g., "did the resolver vote correctly per evidence submitted?") — this is an open design option.
- **vs Kleros:** Kleros's Schelling mechanism degrades on subjective disputes without a clear focal point. Sew's curated resolvers are better calibrated for ambiguous commercial disputes. The natural integration point is the Kleros backstop (already designed into DR round 2), where Kleros provides a large independent jury as the final appeal tier rather than the primary decision-maker.

**The combined architecture — Sew expert-resolvers (L0, L1) + Kleros crowdsourced jury (L2) — is well-motivated:** it captures the accuracy of experts for the common case while preserving Kleros's anti-collusion properties as the final backstop.

---

## 5. Open Questions for Future Work

1. **Bond denomination:** Should bonds be expressed as bps of escrow value (making BM-01, BM-02 ETH-price-invariant) rather than absolute ETH? The current `EscalationCostLibrary` would need a second mode.

2. **EMA cold-start:** New resolvers have no history. The current `minEmaScoreThreshold = 500000` implies new resolvers start at zero quality — causing them to never be assigned. Should there be a probationary period with a default score?

3. **Multi-round bond sequencing:** For 3-round disputes, the round-2 bond (escalating to Kleros) is currently `B(2) = 0.01 + 4×0.01 = 0.05 ETH`. Kleros's own arbitration fee is separate. Are these additive? The interaction between the Sew escalation bond and the Kleros arbitration fee needs explicit design.

4. **Income-weighted bribery model (BM-03):** The bribery resistance benchmark cannot be completed without on-chain resolver income data. This should become a quarterly operational metric once the system has volume.

5. **Automated slashing wiring:** Gap 2 (ISlashingModule disconnected from DRM) means the reversal signal in BM-06 is purely reputational. Connecting `slashForReversal` would make the signal financial too, improving calibration convergence for BM-06.
