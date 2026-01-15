## v3 parameters (conservative defaults, tunable via slow lane)

These are "start-safe" numbers intended to minimize tail risk while you observe real behaviour.

### A) Time constants (Ethereum-native norms)

**Epoch length (for caps + accounting):**

- **7 days** (weekly accounting is common for operational monitoring and reduces tuning noise)

**Withdrawal / unbonding delay (resolver + senior):**

- **21 days** default\
  Rationale: long delays are standard in restaking/staking designs to keep stake slashable during the window and give time to detect issues; EigenLayer discusses withdrawal delays and slashability windows in this range.

**Freeze duration (on insufficient bond / repeated objective failures):**

- **72 hours** for first severe event (e.g., timeout-resolve)

- **7 days** for repeat severe events within an epoch\
  Freeze means: workload weight forced to 0, cannot accept new disputes, cannot withdraw.

**Liveness / deadlines (objective triggers):**

- `t_accept`: **15 minutes** (or 30m if you expect mobile-only operators)

- `t_resolve_L0`: **24 hours**

- `t_resolve_L1 (senior)`: **48 hours**\
  These are forgiving enough to avoid accidental slashes, but tight enough to prevent hostage-taking via latency games.

---

### B) Minimum bonds (resolver + senior)

You need two things simultaneously:

1.  enough at stake that objective failures are costly

2.  not so high that you centralize to a few operators

Because you didn't provide expected escrow sizes yet, use a **hybrid: absolute floor + capacity-based scaling**.

#### Resolver bond (L0)

- **Minimum resolver bond:** **$500** (or equivalent in bond token)

- **Target resolver bond:** **max($500, 1% of "max escrow amount per dispute" you allow L0 to handle)**

- **Hard cap coverage rule:** a resolver cannot be assigned disputes above a configured `maxEscrowPerResolver` unless they top up bond.

#### Senior bond (L1)

- **Senior bond multiple:** **200× resolver min** to start (within your earlier 100--1000× concept)

- So if resolver min is $500 → senior min is **$100,000**.

Why so high? Seniors are your "insurance layer." If the senior layer is weak, capital-weighted delegation has no bite.

> If that feels too high for launch, keep the multiple, but reduce the resolver floor only if dispute sizes are tiny.

---

### C) Coverage multiplier + delegation limits (prevents "100 sockpuppets")

You want "capital-weighted delegation" to be enforced mechanically.

A simple, safe rule:

**Coverage requirement per appointed resolver:**

- `coverageRequired = resolverBond(resolver) * M`

- Start with **M = 3** (very conservative)

**Appointment constraint:**

- `reservedCoverage(senior) = Σ coverageRequired(resolversAppointedBySenior)`

- Must satisfy: `reservedCoverage(senior) <= seniorBond(senior) * utilizationFactor`

**utilizationFactor (buffer):**

- Start with **0.5** (i.e., only allow half the senior bond to be "reserved")

- This leaves headroom for correlated penalties and prevents cliff insolvency.

This pattern mirrors how serious operator systems treat "insufficient bond" as a first-class condition (stop earning / forced replenishment behaviour is explicitly used by Lido's staking modules).

**Practical effect (with M=3, utilizationFactor=0.5):**\
A senior with $100k bond can reserve up to $50k coverage; if each resolver has $500 bond, each appointment costs $1,500 coverage ⇒ about **33 resolvers** max at the floor. More resolvers require higher senior bond, higher resolver bond, or both.

---

### D) Epoch caps (stops senior-resolver insolvency cascades)

Caps prevent a single bad day from wiping a senior and destabilizing the network.

**Per-resolver cap (per epoch):**

- Maximum slashable amount = **20% of resolver bond per epoch**\
  Beyond that: freeze + workload=0 + forced top-up to re-enable.

**Per-senior cap (per epoch):**

- Maximum slashable amount = **10% of senior bond per epoch**\
  Beyond that: freeze senior + freeze all new appointments + workload throttling for their appointed resolvers until senior tops up.

These caps trade "punish hard" for "preserve stability." You still get strong incentives because the operator loses income and gets sidelined, but you reduce cascade failure risk.

---

### E) Objective penalty schedule (no committees, no subjective votes)

Since you're doing **"senior only after resolver bond exhausted,"** implement slashing waterfall:

1.  slash resolver bond up to penalty

2.  if penalty remains → slash senior bond (subject to caps)

3.  if still remains → freeze + workload=0 + require top-up

**Penalty defaults (basis points of bond):**

- Missed accept deadline: **25 bps** (0.25%)

- Missed resolve deadline: **200 bps** (2%) + 72h freeze

- Repeated missed resolve in same epoch: **500 bps** (5%) + 7d freeze

- Reversal on escalation: **0 bps initially** (recommended)
  - If you later want it: use **soft penalty only** via workload reduction/score, not slashing, to avoid punishing honest disagreement.

Fraud lane slashing can remain v4 if you want; if you do add it in v3: it must be quorum-triggered and contract-executed (DAO configures committee only).
