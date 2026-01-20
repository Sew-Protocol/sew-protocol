# DR v3 Launch‑Safe Defaults (Resolver Capital, Slashing, Mixed Bonds)

## TL;DR (for partners / exchanges)
- **Security is anchored in stable USD collateral**: resolver/senior bonds are primarily stablecoin-backed (oracle-free).
- **SEW adds alignment without becoming a point of failure**: SEW can be used in bonds but is haircut and capped.
- **Oracle-free mixed bond rule**: `EffectiveBondUSD = stable + (SEW × 0.5 haircut)` with **≥80% stable / ≤20% SEW** enforced.
- **Launch-safe operational guardrails**: long unbonding (14d/21d), objective deadlines, mechanical slashing, and epoch caps prevent insolvency cascades.
- **Deflationary sink on misconduct**: **slashed SEW is treated as burned**.

**Purpose:** Capture the **launch-safe** DR v3 economic/security parameters and the rationale in one place, so the whitepaper, tokenomics, and implementation status docs can reference a single source of truth.

---

## 1) Denomination & bond token design (oracle‑free)

### 1.1 Mixed bond token design (SEW + USD stablecoin)

**Effective bond (risk‑adjusted USD):**

\[
EffectiveBondUSD =
\; stablecoinBond
\;+\; (sewBond \times haircut)
\]

Where `haircut ∈ (0,1]` converts SEW to risk‑adjusted USD **without oracles**.

**Launch defaults (locked):**
- `haircut = 0.5`
- **Minimum composition (enforced):**
  - **≥ 80%** of effective security from **stablecoin**
  - **≤ 20%** from **SEW** (after haircut)

This is a **protocol-level shock absorber**:
- A 50% SEW crash only reduces total security by ~5% (given the 20% cap and 0.5 haircut).
- A 90% SEW crash only reduces total security by ~9%.

But it also creates **structural SEW demand**:
- Serious resolvers must buy and hold SEW.
- Seniors must hold even more SEW to underwrite more resolvers.
- As dispute volume grows, SEW demand grows structurally (without letting SEW price become a single point of failure).

**Why this is Ethereum‑native (2026‑grade):**
- **Stable asset** anchors solvency and liveness.
- **Volatile native token (SEW)** aligns incentives, upside, and governance weight.
- This mirrors the ecosystem lesson from EigenLayer/UMA/Kleros: don’t let the governance token be the only thing holding the system up.

---

## 2) Withdrawal / unbonding delays (slashability window)

**Defaults (launch-safe):**
- **Resolvers:** 14 days
- **Seniors:** 21 days

Rationale:
- Long exit delays are standard for slashable systems (restaking-style safety).
- Seniors (insurance layer) should be slashable for longer than resolvers.

---

## 3) Minimum bonds & capacity limits (calibrated to £20–£2,000 escrows)

### 3.1 Resolver bond (L0)
- **Min resolver bond:** **$250**
- **Suggested operating bond:** **$500**

**Capacity gating (key safety lever):**

\[
MaxEscrowPerL0Case =
min(2000,\; 4 \times resolverBond)
\]

Implications:
- $500 bond → up to $2,000
- $250 bond → up to $1,000

### 3.2 Senior bond (L1)
- **Min senior bond:** **$25,000**
- **Recommended senior bond:** **$50,000–$100,000**

Rationale:
- Seniors are the insurance layer; cheap seniors make delegation toothless and concentrate bribery pressure.

---

## 4) Capital‑weighted delegation (coverage multiplier + buffer)

Coverage requirement per appointed resolver:

\[
coverageRequired(resolver) = resolverBond(resolver) \times M
\]

Utilization buffer:

\[
reservedCoverage(senior) \le seniorBond(senior) \times U
\]

**Launch defaults (locked):**
- `M = 3`
- `U = 0.50` (50%)

Effect:
- Prevents “I appoint 100 sockpuppets”.
- Leaves headroom for correlated failures and tail risks.

---

## 5) Epoch caps & freeze durations (prevent insolvency cascades)

**Epoch length:** 7 days

**Per-resolver slash cap per epoch:**
- **20% of resolver bond**, then **freeze + workload=0** until next epoch + top-up

**Per-senior slash cap per epoch:**
- **10% of senior bond**, then **freeze senior + pause new appointments** until next epoch + top-up

**Freeze durations:**
- Severe event (missed resolve deadline): **72 hours**
- Repeated severe event within epoch: **7 days**
- “Insufficient bond” condition: freeze until topped up (minimum 72h)

---

## 6) Objective slashing schedule (no committees, no subjective votes)

Deadlines:
- `t_accept`: 30 minutes
- `t_resolve_L0`: 24 hours
- `t_resolve_L1`: 48 hours

Penalties (basis points of bond):
- Missed accept: **25 bps (0.25%)**
- Missed resolve: **200 bps (2%) + 72h freeze**
- Repeat missed resolve in same epoch: **500 bps (5%) + 7d freeze**
- Reversal on escalation: **0 bps initially** (use reputation/workload only)

Waterfall rule:
1) Slash resolver bond up to penalty  
2) If penalty remains → slash senior bond (after resolver bond exhausted), bounded by epoch cap  
3) If still insufficient → freeze + workload=0 until top-up

---

## 7) SEW handling on slashing

When SEW is slashed from resolver/senior bonds, it is treated as **burned** (deflationary sink), rather than being retained as protocol revenue.

---

## 8) What this lets you say (2026 credibility)

You can honestly claim:

> “Dispute resolution is secured primarily by stable capital,  
> but aligned economically through SEW staking and rewards.”

That reads as:
- neutral
- credible
- not reflexively speculative

---

## 9) Implementation pointers (where these are enforced)
- Mixed bond valuation + composition: `contracts/decentralized-resolution-module/ResolverStakingModuleV1.sol`
- Bond valuation math: `contracts/decentralized-resolution-module/BondValuationLibrary.sol`
- Slashing schedule, epoch caps, freezes, SEW burn handling: `contracts/decentralized-resolution-module/ResolverSlashingModuleV1.sol`
- Resolver deadlines / appeal windows: `contracts/decentralized-resolution-module/DecentralizedResolutionModule.sol`

