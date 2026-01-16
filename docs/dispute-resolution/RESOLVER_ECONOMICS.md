## Detailed overview: Resolver staking, escalation deposits, incentives, and slashing (Ethereum-native 2026)

**Launch-safe v3 defaults (single source):** `docs/dispute-resolution/DR_V3_LAUNCH_SAFE_DEFAULTS.md`

### Executive design rule

**Decentralise decisions first.\
Decentralise incentives second.\
Decentralise capital last.**

The system becomes adversarial when _capital is at risk_. A resolver making a wrong call is annoying; a resolver losing money creates a profit motive to attack the mechanism. So we intentionally introduce **economic adversarial pressure** only after **decision-making and escalation flows** are stable under real usage.

---

1. # Escalation deposits: bonds, delays, increasing fees

## 1.1 Core mechanism: escalation-bonded appeals

**Every escalation requires the losing party to post an appeal bond.**

- If escalation succeeds (the outcome is reversed): the escalator gets the bond back **in full when the protocol appeal fee is inactive**, and receives the refundable portion when the protocol appeal fee is active.

- If escalation fails (outcome upheld): the bond is paid to the prior resolver set **in full when the protocol appeal fee is inactive**, and pays the resolvers from the post-fee bond amount when the protocol appeal fee is active.

**Result:** "Appeal because I'm angry" becomes financially irrational.

### Minimal on-chain state

For each dispute `D`:

- `round`: current escalation step `k` (0 = initial resolver)

- `decision[k]`: outcome at round `k`

- `appealBond[k]`: bond amount posted to reach round `k`

- `appealDeadline[k]`: latest time to appeal to next round

- `resolverSet[k]`: the resolver(s) who decided round `k`

- `status`: Open / Resolved / Escalated / Expired

### Core transitions

1.  **Initial ruling** (`k=0`)

2.  **Appeal window opens** (time boxed)

3.  If appealed:
    - escalator posts bond for round `k+1`

    - system assigns next resolver(s)

4.  **New ruling** (`k+1`)

5.  Compare outcomes:
    - If outcome flips → appeal bond returns to escalator (minus fee if any)

    - If outcome same → bond paid to resolver(s) from previous round

> Important: "success" should be defined precisely. Commonly: _the next round decision differs from the prior round_. You can later refine to "final outcome differs from initial outcome," but that adds complexity and delays incentives. Start simple.

## 1.2 Bond sizing: increasing fees via cost curves

If appeals don't get more expensive, a griefer can keep escalating cheaply. So bond cost must grow with depth.

### Curve options

Let `k` be the appeal number (1 for first appeal, 2 for second, ...)

**Linear:**\
`bond(k) = base + step * k`

- Good UX, weaker anti-spam.

**Quadratic (recommended default):**\
`bond(k) = base + step * k^2`

- Strongly discourages repeated escalation while keeping the first appeal affordable.

**Geometric / exponential:**\
`bond(k) = base * r^k` where `r > 1`

- Very strong anti-spam; can price out legitimate late appeals.

### Recommended 2026 default

- **Quadratic** with conservative parameters.

- Tune such that:
  - `bond(1)` is "painful but possible"

  - `bond(3)` is "almost never rational"

You can also impose `maxRounds` to cap worst-case UX and duration.

## 1.3 Delays (time as a spam throttle)

Delays are a second throttle: they raise the cost of griefing by increasing lockup time and slowing throughput.

### Mechanism: bounded windows

For each round:

- Resolver must respond within `t_resolve[k]`

- Parties may appeal within `t_appeal[k]`

Increase delays with depth:

- `t_resolve[k] = baseResolve + k * resolveStep` (or mild geometric)

- `t_appeal[k] = baseAppeal + k * appealStep`

This reduces:

- rapid-fire appeal spam

- manipulative "race" strategies

- latency games intended to block funds

## 1.4 What this prevents (and why)

**Harassment / appeal spam:** escalating costs and lockup time make it irrational.\
**Bribe-farming:** you can't profit by forcing repeated appeals unless you can flip outcomes---harder with random assignment and multi-resolver rounds.\
**Governance capture:** if appeals are cheap, attackers can generate massive dispute volume and pressure governance; expensive appeals reduce attack throughput.

---

2. # Delegation must be capital-weighted

Your model (senior resolvers appoint resolvers) is good. The missing piece is ensuring **appointments scale exposure**.

## 2.1 Defined delegation bond + liability ceiling

Each Senior Resolver `S` has:

- `seniorBond`: staked collateral

- `delegationExposure`: computed risk for all appointed resolvers

- `liabilityCeiling`: maximum loss per epoch / per resolver / per dispute class

### Delegation bond rule (simple)

Senior can only appoint more resolvers if:

`availableCoverage = seniorBond - reservedCoverage`\
and\
`reservedCoverage >= requiredCoverageForAppointments`

Where:\
`requiredCoverageForAppointments = Σ (resolverBond[r] * coverageMultiplier)`\
across all resolvers `r` appointed by `S`.

This prevents:

> "I appoint 100 sockpuppets."

Because each appointment consumes coverage capacity.

## 2.2 Quantified exposure scaling (concrete)

Pick one:

**A) Per-resolver coverage**

- Each appointed resolver requires `coverage = resolverBond * m`

- `m` starts high in early network, decreases as system matures.

**B) Per-case coverage**

- Appointments don't cost much, but each case assigned to an appointed resolver consumes "coverage units" and caps throughput if senior bond is low.

**C) Hybrid (recommended)**

- Baseline per-resolver coverage + per-case cap to prevent burst risk.

## 2.3 Liability ceiling implementation

Define:

- `maxLossPerEpoch`

- `maxLossPerResolver`

- `maxLossPerDispute`

If slashing would exceed a limit:

- excess becomes **workload throttling** / suspension, not additional slash

- remaining penalties apply next epoch only after re-bond

This prevents senior-resolver insolvency from cascading into protocol-wide instability.

3. # Reputation must be slow, not reactive

Fast reputation systems are gameable and unfair.

## 3.1 EMA-style scoring (slow half-life)

Maintain per resolver:

- `score` in [0..1] (or [0..10000])

- Update after each case using an EMA:

`score_new = score_old * (1 - α) + outcomePoints * α`

Where:

- `α` is small (e.g., 0.01--0.05) → slow change

- `outcomePoints` is derived from performance metrics

### Multi-signal outcomePoints

Weight objective signals more than subjective ones:

- Timeliness (SLA met)

- Responsiveness (no missed commits)

- Escalation alignment (upheld vs reversed)

- Later: user feedback (low weight)

- Later: DAO feedback (low weight)

## 3.2 Multi-epoch aggregates

Instead of updating score per-case only, also track per epoch (week/month):

- `casesHandled`

- `upheldRate`

- `timeoutRate`

- `avgResponseTime`

Then compute:

- `eligibility` and `workloadWeight` from both EMA and epoch stats

This prevents:

- one bad case destroying a resolver

- angry users brigading feedback

- short-term noise

4. # DAO should govern the machine, not the cases

This is essential for legitimacy and for reducing regulatory perception risk.

## 4.1 DAO controls (allowed)

- Who can be senior resolver (membership / eligibility)

- Bond sizes and curve parameters

- Escalation rules and max rounds

- Slashing percentages, thresholds, timeouts

- Module upgrades (standard/slow lanes)

- Appoint investigation committee roles (fraud lane)

## 4.2 DAO must NOT control (prohibited)

- Who won a specific dispute

- Reversing a specific ruling

- Slashing a specific resolver ad hoc

### Concrete enforcement

- Ensure no governance method can call `slash(address)` directly.

- Governance can only:
  - update parameters

  - upgrade modules

  - appoint committee keys

- Slashing must be triggered by **contract state transitions** (timeouts, missed commitments, on-chain contradictions, escalation outcome checks)

5. # DAO-driven fraud adjudication must be separated from slashing

Fraud is inherently subjective and evidence-heavy. But slashing must be mechanical.

## 5.1 Fraud lane architecture

**Fraud lane is a separate module** with:

- Committee selection (DAO appoints committee membership)

- Evidence submission and time windows

- On-chain quorum verification

- Deterministic execution: if quorum threshold met, apply ban and slash per rules

DAO's role:

- appoint/replace committee

- set thresholds and procedures

- upgrade fraud module

DAO does not:

- take funds directly

- decide per case outcome

6. # Objective slashing (Ethereum-native 2026)

## 6.1 Slashing triggers must be objective

Allowed triggers:

- Missed deadlines (no action within `t_resolve`)

- No response / unresponsive proof

- On-chain contradictions (e.g. signed commitment then violated)

- Escalation outcome alignment (decision reversed at next round)

Not allowed:

- forum votes

- "community feels"

- ad hoc governance calls

## 6.2 Deterministic slashing table

| Event                                          | Penalty                               | Mechanism                            |
| ---------------------------------------------- | ------------------------------------- | ------------------------------------ |
| Missed deadline                                | small % slash                         | auto once `deadline` passes          |
| No response (after grace)                      | medium % slash + temporary suspension | auto                                 |
| Decision reversed on escalation (repeat-based) | % slash scaled by EMA + severity      | computed on transition to next round |
| Fraud proven (committee quorum)                | 100% slash + ban                      | fraud module                         |

Important nuance:

- For "reversed on escalation," don't slash harshly per single reversal. Use:
  - a small penalty

  - scaled by repeated reversals

  - bounded by epoch ceilings

This avoids punishing honest disagreement and preserves decentralisation.

7. # Two-tier staking (v3): resolver deductible + senior insurance

## 7.1 Structure

**Resolver bond (deductible):**

- smaller stake

- first-loss for their own behaviour (timeouts, negligence)

**Senior bond (insurance):**

- large stake (100--1000× resolver bond)

- covers systemic risk from appointed resolvers

- also covers senior's own decisions

## 7.2 Payout ordering

When a slashable event occurs:

1.  slash resolver bond up to cap

2.  if needed and within defined exposure: slash senior bond

3.  if beyond ceiling: suspend & reduce workload; require re-bond

This prevents:

- small resolvers becoming attack targets

- seniors from appointing recklessly

- cascading insolvency

8. # Workload as the primary safety lever (v1 onward)

Workload routing is your most underrated weapon:

- It's reversible

- It's low-risk

- It changes incentives without enabling stake attacks

## 8.1 WorkloadWeight function

Define:\
`WorkloadWeight = f(score, availability, recentTimeoutRate, stakeTier)`

- In v1: no stake input; mostly `score` + `availability`

- In v3: incorporate stake tiers or senior backing

Bad actors:

- don't get nuked instantly

- get starved of income → exit naturally

This is extremely resilient.

9. # Attack vectors and specific mechanisms that stop them

Below are the main failure modes you listed, with concrete countermeasures.

---

## 9.1 Griefing (blocking funds / wasting time)

**Attack:** party escalates repeatedly, stalls resolution, harms counterparty.

**Stops:**

1.  **Increasing appeal bond curve** (quadratic/geometric)

2.  **Appeal deadlines** (no appeal after window)

3.  **Max escalation depth**

4.  **Delay scaling** (deep escalation takes longer and costs more)

5.  Optional: **bond forfeiture on no-show** (if escalator fails to participate at next round)

**Implementation:**

- `appealBond(k)` increases

- `appealDeadline[k]` enforced

- `maxRounds` enforced

- If escalator doesn't submit required payload/signature by `t_submit`, bond is forfeited

---

## 9.2 Appeal spam (cheap harassment of resolvers)

**Attack:** attacker files lots of appeals to drain resolver time or manipulate workload.

**Stops:**

1.  **Escalator bond paid to resolver if appeal fails**

2.  **Per-address rate limits** (optional, careful: can be sybil'd)

3.  **Stake/fee gating** (minimum escrow size to unlock multi-appeals)

4.  **Reputation-weighted routing** (spam goes to hardened resolvers or pooled committees)

**Implementation:**

- Pay failed-appeal bonds directly to previous resolver set (and/or shared pool)

- Require `escrowAmount >= threshold` for deeper than `k=1`

## 9.3 Bribery (decision buying)

**Attack:** party bribes resolver to rule incorrectly.

**Stops:**

1.  **Random assignment** + sufficiently large resolver pool

2.  **Multi-resolver rounds** at higher tiers (committee of 3/5)

3.  **Escalation bonds** (bribed ruling likely escalated; if flipped, prior resolver loses bond reward and reputation; in v3, stake risk)

4.  **Slow reputation + workload** (suspicious patterns reduce assignments)

5.  **Fraud lane** for strong evidence (off-chain + on-chain proof)

**Implementation:**

- For `k>=2`, assign a committee and take majority outcome

- Track correlation metrics (later): same parties + same resolver outcomes

- Fraud committee can ban/slash if proven

---

## 9.4 Latency games (timeouts, strategic unresponsiveness)

**Attack:** resolvers intentionally delay; parties time appeals to maximize harm.

**Stops:**

1.  **Commit-reveal / signed commitments** (optional, heavier)

2.  **Strict SLAs with automatic penalties**

3.  **Availability beacons** (resolvers must "heartbeat" to accept new cases)

4.  **Automatic reassignment** on missed deadlines (with penalty)

**Implementation:**

- Resolver must accept assignment within `t_accept` or auto-reassign

- Must submit ruling within `t_resolve` or auto-reassign + penalty

- Repeated timeouts reduce workload to zero (v1), slash bond (v3)

---

## 9.5 Senior-resolver insolvency (delegation risk)

**Attack/failure:** senior backs too many resolvers; a cluster of penalties wipes senior bond; protocol becomes unstable.

**Stops:**

1.  **Defined delegation bond requirement**

2.  **Liability ceilings per epoch**

3.  **Exposure accounting** (reserved coverage)

4.  **Appointment caps based on coverage**

5.  **Emergency suspension without extra slashing** beyond caps

**Implementation:**

- `requiredCoverageForAppointments` enforced on appointment

- `maxLossPerEpoch` enforced on slashing

- If ceiling reached: freeze further assignments, require top-up

10. # "Open marketplace" timing (do not start open)

2026 best practice:

- Start **curated, bonded, DAO-appointed** resolvers.

- Only later add:
  - optional user-choice lanes

  - premium speed lanes

  - high-bond arbitrators

Open too early leads to:

- bribe-based undercutting

- cartel formation

- reputation gaming

- pay-to-win arbitration

So: **never start open**.

11. # Putting it together: staged implementation map

### DR v1 (decisions decentralised; no resolver capital)

- curated resolver set

- random assignment

- escalation logic

- optional Kleros backstop

- performance → workload (to zero)

- EMA reputation (slow)

- no staking, no slashing

- objective timeouts (penalty = workload reduction)

### DR v2 (incentives decentralised; capital still soft for resolvers)

- escalation bonds (appeal deposits)

- increasing bond curve (quadratic default)

- bounded appeal windows and delays

- bond payout rules (fail → resolver, success → refund)

- still no resolver staking/slashing

### DR v3 (capital decentralised)

- resolver bonds

- objective slashing

- senior backing with capital-weighted delegation

- liability ceilings + exposure accounting

- fraud lane with committee quorum and mechanical execution
