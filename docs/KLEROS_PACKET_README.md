# Sew Protocol — Technical Documentation Packet for Kleros

**Prepared for:** Kleros integrations / protocol team  
**Prepared by:** Sew Protocol  
**Contracts:** `sew-protocol` @ `8785826`  
**Simulation:** `sew-simulation` @ `9fbb4ba`  
**Date:** 2026-05-21  

---

## Purpose

This packet is a self-contained technical reference for the Kleros team.

It covers the Sew Protocol escrow and dispute resolution system in enough
depth to evaluate:

- How Kleros fits into the Sew dispute escalation model.
- What the Sew contracts guarantee by construction, and where Kleros is
  relied upon as a final backstop.
- What Sew's governance model can and cannot do to active escrows or
  Kleros-bound disputes.
- What the economic incentive design looks like for each escalation round,
  including Kleros-round costs and bond outcomes.
- How the protocol has been validated: deterministic scenario replay,
  adversarial simulation, and invariant checking.

These documents are derived directly from contract source code. Where
claims are verified by simulation, the simulation repository is cited.
Where open items remain, they are marked explicitly.

---

## Document Index

### 01 — Protocol Overview

**File:** `01_PROTOCOL_OVERVIEW.md`  
**Source:** `docs/PROTOCOL_OVERVIEW.md`  
**Length:** ~406 lines

The primary entry point. Explains what Sew Protocol is, the full protected-transfer
lifecycle (create → release / cancel / dispute → resolve), the escrow guarantee model,
the role of each subsystem, and the DR v3 implementation status.

**Read this first.**

---

### 02 — Protocol Modularity and Snapshot Isolation

**File:** `02_PROTOCOL_MODULARITY.md`  
**Source:** `docs/architecture/PROTOCOL_MODULARITY.md`  
**Length:** ~577 lines

Covers the six module types (resolution, release, cancellation, yield generation,
yield distribution, incentive), how module snapshots work, and — critically for
Kleros — **why governance changes after escrow creation cannot affect a Kleros-bound
dispute**. The module snapshot is frozen at `createEscrow()` and is immutable for
the life of that escrow.

**Relevant to Kleros:** §Module Snapshot Isolation, §Resolution Module.

---

### 03 — Dispute Resolution Architecture

**File:** `03_DISPUTE_RESOLUTION_ARCHITECTURE.md`  
**Source:** `docs/dispute-resolution/DISPUTE_RESOLUTION_ARCHITECTURE.md`  
**Length:** ~459 lines

The technical reference for the full dispute resolution pipeline. Covers:

- The three-round escalation model (Round 0: standard resolver, Round 1: senior
  resolver, Round 2: Kleros).
- How disputes are opened, assigned, resolved, and escalated.
- The `canEscalate()` / `isFinalRound` contract interface that gates Kleros entry.
- The `KlerosArbitrableProxy` adapter contract (`IArbitrable` / `IArbitrator`).
- Dispute timeout, liveness, and mutual split paths.
- Governance immutability invariants during active disputes.

**Relevant to Kleros:** §4.4 (Escalation model), §4.5 (Round 2 / Kleros), §4.10
(Governance controls and immutability), §4.11 (Contract map).

---

### 04 — Dispute Economics

**File:** `04_DISPUTE_ECONOMICS.md`  
**Source:** `docs/dispute-resolution/DISPUTE_ECONOMICS.md`  
**Length:** ~539 lines

Covers bond composition, appeal cost curves, slashing schedule, insurance pool,
capacity gate, and the economic flywheel. For Kleros specifically, covers:

- How appeal bonds are structured for round-2 (Kleros) escalation.
- What happens to bonds on a Kleros ruling (winning party bond return, losing
  party bond slashed to insurance pool).
- The quadratic cost curve that makes spurious Kleros escalations expensive.
- Arbitration fee handling (`msg.value` forwarded to `KlerosArbitrableProxy`).
- Simulation coverage: Phases F, H, J, AI.

**Relevant to Kleros:** §Appeal bond mechanics (round 2), §Arbitration fee,
§DR version roadmap, §Adversarial simulation coverage.

---

### 05 — Governance Constraints

**File:** `05_GOVERNANCE_CONSTRAINTS.md`  
**Source:** `docs/governance/GOVERNANCE_CONSTRAINTS.md`  
**Length:** ~171 lines

The "what governance **cannot** do" reference. Enumerates:

- The 13 per-escrow immutabilities frozen at `createEscrow()` (including
  `resolutionModule`, `appealBondProtocolFeeBps`, `maxDisputeDuration`,
  `appealWindowDuration`).
- What the Guardian can and cannot do (emergency pause only; cannot cancel
  Timelock proposals; cannot alter active escrow terms).
- Numerical hard bounds enforced by contract code (all bps caps, time limits,
  count limits).
- Minimum delay constraints preventing same-block governance attacks.
- The `externalResolver` change being 48h-laned (not slow-laned).

**Relevant to Kleros:** Confirms that a governance actor cannot redirect
round-2 escalations for in-flight disputes, cannot change appeal window
durations mid-dispute, and cannot alter any escrow term after creation.

---

### 06 — Forward-Only Upgrades

**File:** `06_FORWARD_ONLY_UPGRADES.md`  
**Source:** `docs/FORWARD_ONLY_UPGRADES.md`  
**Length:** ~307 lines

Covers the upgrade safety model: no upgradeable proxies, forward-only module
activation via the slow lane (7-day queue + 48h activate), and what "upgrade"
means in Sew (deploying new module addresses, not mutating existing contracts).

**Relevant to Kleros:** The `KlerosArbitrableProxy` address used in
round-2 escalations is set via `setExternalResolver` (48h Timelock). The
slow lane is required for module swaps but not for resolver address updates.
The address in force at dispute-open time is locked in `et.disputeResolver`
for that dispute. A future upgrade to a different Kleros arbitrator would
only affect new round-2 escalations.

---

### 07 — Kleros Integration

**File:** `07_KLEROS_INTEGRATION.md`  
**Source:** `docs/dispute-resolution/KLEROS_INTEGRATION.md`  
**Length:** ~450 lines

The primary Kleros-specific document. Covers in full:

- How `KlerosArbitrableProxy` implements `IArbitrable` to receive the Kleros
  `rule()` callback.
- The `createDispute()` / `rule()` flow and how the Kleros ruling maps to Sew
  escrow outcomes (RESOLVED or REFUNDED).
- Arbitration fee forwarding and the `fundedBy` / `funder` accounting pattern.
- Evidence submission (`submitEvidence` to `EvidenceModuleV1`).
- Appeal windows: Kleros-internal appeal rounds are opaque to Sew; Sew receives
  only the terminal Kleros ruling.
- The `extraData` encoding (court ID, juror count).
- Liveness: what happens if Kleros is congested or stalled.
- All known limitations and open design questions.

**This is the document Kleros reviewers should read in most depth.**

---

### 08 — Withdrawals

**File:** `08_WITHDRAWALS.md`  
**Source:** `docs/WITHDRAWALS.md`  
**Length:** ~404 lines

Covers every withdrawal path: how settlement proceeds become claimable, how
the balance-safety invariant is maintained, fee withdrawal, yield withdrawal,
and the emergency unwind paths. Included in this packet because Kleros
rulings ultimately result in one of the withdrawal paths being activated.

**Relevant to Kleros:** Confirms that a Kleros ruling (RESOLVED to buyer or
seller) maps to the standard `withdraw()` path with the same safety
invariants as any other resolution outcome.

---

## Suggested Reading Order

**For protocol/integrations review (Kleros team):**

1. `01` — Protocol Overview *(context)*
2. `07` — Kleros Integration *(primary)*
3. `03` — Dispute Resolution Architecture *(escalation model)*
4. `04` — Dispute Economics *(bond/cost mechanics)*
5. `05` — Governance Constraints *(what governance cannot do)*
6. `02` — Protocol Modularity *(snapshot isolation)*
7. `06` — Forward-Only Upgrades *(upgrade safety)*
8. `08` — Withdrawals *(settlement outcomes)*

**For a 30-minute focused read:** `07` → `03` §4.4–4.5 → `05`.

---

## Validation Status

All documents in this packet are:

- Derived from contract source code, not design-intent documents.
- Cross-referenced against the `sew-simulation` deterministic scenario suite
  (S01–S41, covering the full dispute lifecycle including Kleros escalation paths).
- Manually reviewed and evidence-footed (each document carries a verification
  status footer).

**Gaps explicitly noted in this packet:**

- Kleros liveness bounds under network congestion are not yet simulation-backed
  (see `07_KLEROS_INTEGRATION.md` §Known limitations).
- `extraData` court-ID enforcement is not yet enforced on-chain; callers must
  use a known audited court configuration.
- Formal verification of escalation state transitions is in progress.

---

## Contact

Questions on this packet: Sew Protocol engineering team.  
Questions on Kleros integration specifics: refer to `07_KLEROS_INTEGRATION.md`
§Known limitations and open design questions as a starting checklist.
