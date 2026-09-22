# Dispute Resolution Staging Plan (IEO → DR v1 → DR v2 → DR v3)

## Core approach

**Decentralise decisions first.  
Decentralise incentives second.  
Decentralise capital last.**

This staging minimises time-to-IEO, minimises risk of catastrophic loss, and accelerates confidence by observing adversarial behaviour on mainnet _before_ introducing resolver-stake economics.

---

## Why we stage: where the real risk lives

The dangerous part of dispute resolution is **not** who makes the decision.

It is:

> **What happens financially when someone is wrong.**

A resolver making a bad decision is annoying.  
A resolver **losing money** is adversarial.

So we explicitly separate:

- **A. Decision decentralisation** (who decides and how)
- **B. Economic adversarial pressure** (who can profit by attacking the system)

We introduce B only after A is proven stable under real usage patterns.

---

## Release phases

| Phase                  | What is decentralised | What is still soft             |
| ---------------------- | --------------------- | ------------------------------ |
| IEO + Central resolver | governance, upgrades  | dispute resolution, incentives |
| DR v1                  | decision-making       | incentives + capital           |
| DR v2                  | incentives            | capital                        |
| DR v3                  | capital               | nothing                        |

### IEO + Central Resolver (pre-DR)

- **Single defined resolver** can resolve in favour of: buyer / seller / partial split
- Governance: standard + slow lanes for module swaps and parameter changes
- Purpose: ship fast, reduce protocol surface area, fund simulations and testing for DR

---

## DR v1 — decentralise decisions (no resolver money at risk)

### Keep / gain

- Multiple independent actors (curated set)
- Random allocation from a suitable resolver set
- Escalations
- Kleros backstop (optional lane / integration)
- Governance-controlled module swaps and parameters

### Explicitly avoid (remove)

- Bribery incentives (no slashing / no resolver stake exposure)
- Griefing economics (appeals do not directly harm resolver capital)
- Appeal attacks targeting resolver stake
- Stake-draining / “attack the bond” games

### Incentives in v1 (non-capital, performance-based)

- **Workload routing** is the primary lever:
  - Higher performance ⇒ more assigned cases
  - Lower performance ⇒ fewer cases (down to zero)
- Optional: modest fee share still allowed, but **no capital at risk** for resolvers

### Performance signals (v1)

Positive:

- Resolves disputes within SLA windows
- Resolutions not escalated, or escalated but upheld
  Negative:
- Slow response beyond limit
- Unresponsive
- Escalated and reversed (repeatedly)

> Note: in v1, “punishment” is _workload reduction_, not slashing.

### Phase gate (exit criteria for moving to DR v2)

- Stable escalation rate observed over N weeks (define N)
- No evidence of systematic griefing / appeal spam causing UX collapse
- Resolver response-time distribution is predictable
- Kleros backstop is operationally tested (if enabled)
- Incident runbooks tested (timeouts, unresponsive resolvers, module rollback)

---

## DR v2 — decentralise incentives (money at risk for users, not resolvers)

Goal: introduce **economic friction** that prevents griefing and strategic escalation, without yet creating resolver stake attack surfaces.

### Add

- **Escalation / appeal bonds**
- **Appeal fee curves** (increasing cost per escalation step)
- **Rules for bond redistribution** (who earns the bond if appeal fails)

### Still avoid

- Resolver staking
- Slashing

### Incentive detail (v2)

- Parties (buyer/seller) post bonds to escalate
- If escalation fails (decision upheld), the bond is paid out to:
  - previous resolver(s) and/or
  - protocol treasury and/or
  - a shared pool (depending on design)
- If escalation succeeds (decision reversed), bond is returned (or partially returned) to the escalator, and the system may:
  - discount the next appeal, or
  - pay the next resolver set

### Phase gate (exit criteria for moving to DR v3)

- Appeal spam is economically suppressed (cost > benefit)
- No viable “cheap griefing” strategy
- Clear evidence bonds reduce low-quality escalations
- Kleros lane economics behave as intended (if enabled)

---

## DR v3 — decentralise capital (money at risk for resolvers)

Only after v1/v2 behaviour is known do we introduce resolver-stake economics.

### Add

- Resolver bonds (capital at risk)
- Slashing (objective triggers only)
- Senior backing (delegation / underwriting)
- Fraud lane (investigation + execution path)

### Why v3 is survivable

By this stage:

- We know how people behave
- We know typical appeal rates
- We know griefing patterns
- We know worst-case loads

This is when game theory becomes survivable.

---

## Why this reaches “100% confidence” faster

The bottleneck is not contract development.  
It is learning where adversaries will attack.

Fastest path:

1. Put the mechanism on mainnet
2. Fund it
3. Let real humans try to break it
4. Observe without catastrophic loss

Staging achieves adversarial learning without exposing resolver capital too early.

---

## Escalation cost curves (choose one)

We need escalation costs that make:

- “I’m angry” appeals expensive
- “I found a real error” appeals possible

### Option A: Linear (simplest)

`cost(k) = base + k * step`

Pros: simple UX  
Cons: may be too cheap to grief at high volume

### Option B: Quadratic (discourages repeated escalation hard)

`cost(k) = base + step * k^2`

Pros: strong anti-spam, still OK for 1–2 appeals  
Cons: can become very expensive quickly

### Option C: Geometric / exponential (most aggressive)

`cost(k) = base * r^k` (r > 1)

Pros: makes deep escalation rare  
Cons: can “lock out” legitimate appeals late

### Recommended default for v2

- Quadratic with conservative parameters:
  - base: covers operational cost
  - step: tuned so k=1 is affordable, k>=3 is painful
- Add a ceiling for UX if needed (optional), but prefer no ceiling if safety dominates.

---

## Design guardrails (non-negotiables)

- Slashing (v3) must be **objective and contract-executed** (timeouts, provable non-response, etc.)
- DAO governs rules/modules, not individual case outcomes
- “Soft removal” (workload to 0) is the primary safety lever until v3
