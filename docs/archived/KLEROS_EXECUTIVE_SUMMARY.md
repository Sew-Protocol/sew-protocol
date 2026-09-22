# Sew Protocol × Kleros — Executive Summary

**For:** Kleros integrations / protocol team  
**Context:** First technical meeting  
**Depth:** This document is a 10-minute read. All claims link to deeper references.

---

## 1. What Sew Protocol is

Sew is a **non-custodial escrow and dispute resolution protocol** built on Base (Ethereum L2),
designed for physical and digital commerce where delivery cannot be confirmed on-chain.

The core mechanic is simple: a buyer locks funds in an escrow contract at the moment of
payment. The seller sees the locked commitment but cannot access the funds until the buyer
confirms delivery — or a configurable auto-release timer expires. If delivery fails, the
buyer raises a dispute, and a resolution process determines where the funds go.

Three properties define the trust model:

- **Immutable per-escrow rules.** Module configuration (including which resolution module
  handles disputes, and therefore which arbitration path applies) is snapshotted at escrow
  creation. No subsequent governance action can alter terms for an active escrow.
- **Pull-only settlement.** No contract function pushes tokens to an address. Resolved
  parties claim from a ledger. This eliminates push-payment attack surfaces.
- **Resolver capital at risk.** In the live decentralized tier (DR v3), professional resolvers
  post bonds. Incorrect decisions can result in slashing. This aligns resolver incentives with
  correct outcomes.

**Scale context:** Sew is designed for commerce-grade volume — potentially thousands of active
escrows concurrently, each with a discrete dispute lifecycle.

---

## 2. Why Kleros matters to Sew

Sew's dispute pipeline has three rounds:

```
Round 0  Standard resolver  (appointed; 24h deadline)
    │
    │  losing party escalates
    ▼
Round 1  Senior resolver    (DAO-appointed; 48h deadline)
    │
    │  losing party escalates
    ▼
Round 2  ──► Kleros          (decentralised; final; no further escalation)
```

Kleros is not the default path. It is the **final backstop** — the layer that handles
disputes where two rounds of appointed resolver decisions have failed to produce an
accepted outcome.

This role is structurally important for two reasons:

**Credible commitment.** Without a credible, neutral final layer, the round-1 outcome is
effectively final. A party that lost at round 1 but has a strong case has no recourse. Kleros
provides that recourse — and because Kleros is permissionless and censorship-resistant, it
cannot be captured by the protocol team or the resolver pool.

**Resolver accountability.** Resolvers know that decisions can be escalated to Kleros. A
resolver whose decisions are systematically overturned at the Kleros round incurs direct costs
(their appeal bond is forfeited when Kleros reverses them). This creates an ongoing feedback
signal that the resolver pool's internal quality is being externally audited.

---

## 3. Why Kleros is a good fit

Several properties make Kleros a strong fit specifically for Sew's backstop role:

**ERC-792 compliance.** Kleros implements the `IArbitrator` interface. Sew's
`KlerosArbitrableProxy` implements `IArbitrable`. The integration is a standard adapter,
not a custom fork.

**Finality semantics match.** Kleros issues a terminal ruling after its internal appeal
rounds complete. Sew needs exactly this — a single authoritative outcome that it can map to
a final escrow state. The ruling mapping is unambiguous:

| `_ruling` | Escrow outcome | Effect |
|---|---|---|
| `1` | Release to recipient (seller) | `releaseAsDisputeResolver` — funds go to `et.to` |
| `2` | Cancel to sender (buyer) | `cancelAsDisputeResolver` — funds returned to `et.from` |
| `0` | Refused to rule | No automatic settlement; liveness fallback via `resolveDisputeByTimeout` |

These map directly to `ResolutionOutcome.RELEASE` and `ResolutionOutcome.CANCEL` in the DRM,
the same outcome enum used at rounds 0 and 1. Kleros is slot-compatible with the internal
resolver interface.

**Sybil resistance.** Kleros court juries are drawn from staked PNK pools. Bribing a Kleros
jury to overturn a well-founded resolver decision is significantly more expensive than bribing
an individual resolver — especially for the dispute values Sew targets. This is the correct
cost asymmetry for a backstop layer.

**Court specialization.** The Kleros court hierarchy allows Sew to route disputes to a
commerce-specific subcourt where jurors have relevant domain knowledge. The `extraData`
parameter on `createDispute` encodes the court ID. Sew does not hard-code a court; this is
operator-configurable.

**Decentralization without custody.** Kleros never holds escrow funds. The `KlerosArbitrableProxy`
receives only the arbitration fee (`msg.value`). The escrow funds remain in Sew contracts
throughout. Kleros adjudicates; Sew escrows; neither controls both.

**Governance independence.** Because the escalation configuration is snapshotted per escrow
at creation, and active disputes cannot have their arbitration path altered by any subsequent
governance action, Kleros does not need to trust the Sew team or governance process for the
integrity of in-flight disputes. Once a round-2 escalation has been triggered, its resolution
path is fully determined by the `KlerosArbitrableProxy` address frozen in that escrow's
module snapshot. Governance cannot intervene.

---

## 4. What is already implemented

### Contract integration (on Base)

- **`KlerosArbitrableProxy`** — deployed adapter implementing `IArbitrable` and `IArbitrator`
  interfaces. Handles `createDispute()`, receives the `rule()` callback from Kleros, and
  propagates the ruling to `BaseEscrow` via `_propagateRuling`.

- **Round-2 escalation gate** — `DRMDisputeFacet.escalateDispute()` checks `canEscalate()`
  and `isFinalRound`. If `isFinalRound == true`, the call is routed to the external resolver
  (Kleros). If `isFinalRound == false`, it routes internally. The escalation path is determined
  by the module snapshot frozen at escrow creation.

- **`setExternalResolver`** — governance function (48h Timelock) that sets the
  `KlerosArbitrableProxy` address in the DRM. The address frozen in `et.disputeResolver` at
  round-2 escalation time is the one used for that dispute — a future governance change to the
  external resolver address does not affect in-flight disputes.

- **Arbitration fee forwarding** — `msg.value` passed to `escalateDispute` is forwarded to
  `KlerosArbitrableProxy.createDispute()`. No Sew protocol revenue is extracted from the
  arbitration fee.

- **Evidence submission** — `submitEvidence(escrowId, evidenceURI)` in `DRMDisputeFacet`.
  Evidence is submitted to Kleros's `EvidenceModuleV1` and emits the standard `Evidence`
  event that Kleros court UIs consume.

- **Liveness fallback** — if Kleros stalls (network issue, ruling never received),
  `resolveDisputeByTimeout()` is available after `maxDisputeDuration` elapses from dispute
  open time. This is an auto-refund path; it does not require any Kleros action.

### Simulation validation

The simulation suite contains **8 named deterministic scenarios** covering the Kleros
integration path specifically (S18–S23 plus flash-loan and reentrancy variants):

| Scenario | What is validated |
|---|---|
| `s18` — Kleros L0 resolves | Basic happy path: round-2 Kleros ruling accepted and propagated |
| `s19` — Escalation rejected post-resolve | Once a round resolves, escalation is blocked |
| `s20` — Max escalation guard | Escalation beyond `MAX_ROUND` is rejected |
| `s21` — Pending settlement cleared on escalation | Pending split is cleared when round-2 begins |
| `s22` — Agree-cancel blocked during dispute | Parties cannot agree-cancel while Kleros is live |
| `s23` — Preemptive escalation blocked | Cannot jump to Kleros before appeal window opens |
| `s45` — Flash-loan stake inflation | Bond inflation attack does not affect Kleros routing |
| `s67` — Reentrancy via callback | Reentrancy through the `rule()` callback is blocked |

Beyond deterministic scenarios, **`data/params/phase-e1-kleros.edn`** is a purpose-built
parameter configuration for Monte Carlo simulation of Kleros-round economics under
adversarial escalation pressure.

---

## 5. What remains open

These are documented open items, not unknown risks:

| Item | Nature | Detail |
|---|---|---|
| **`ruling == 0` (refused to rule) liveness** | Protocol gap | If Kleros declines to rule, the escrow stays in `DISPUTED` until the global `maxDisputeDuration` timeout triggers an auto-refund. No automated re-routing exists. |
| **`extraData` court ID not enforced on-chain** | Caller trust assumption | The court ID in `extraData` is set by whoever triggers round-2 escalation. Sew contracts do not validate it. Production deployments need an audited court configuration and caller guidance. |
| **`setExternalResolver` is 48h-laned (not 7-day slow lane)** | Governance window | Module swaps require the 7-day slow lane. Resolver-address changes require only 48h. A governance compromise within that window could redirect new round-2 escalations, but not in-flight ones. |
| **Kleros internal appeal rounds are opaque to Sew** | By design | Sew receives only the terminal Kleros ruling. Intermediate Kleros appeal dynamics (jury doublings, timing, costs) are not visible to Sew contracts. This is correct but means Kleros appeal duration adds to total escrow resolution time. |
| **Kleros-round liveness not simulation-backed** | Evidence gap | Deterministic scenarios cover the Kleros integration path. Monte Carlo simulation of Kleros-specific liveness under network congestion has not been run. |

---

## 6. Why the simulation work may interest Kleros

The Sew simulation suite is not just a Sew-specific test harness. It models dispute
economics, escalation dynamics, and adversarial resolver behavior in ways that may be useful
to Kleros for independent reasons:

**Escalation trap model.** `phase-ai-escalation-trap.edn` models an adversary that
deliberately forces escalation to drain appeal bonds — a class of attack that affects any
multi-round dispute system. The simulation finds that quadratic appeal cost curves (the
default in Sew's DR v3 bond model) reduce this attack's profitability significantly.

**Ring attacker model.** The `RingAttacker` adversary models a coordinated ring of *N*
resolvers that rotate disputes to suppress per-member fraud detection below the threshold.
The key finding: ring evasion becomes less viable when a second detection layer (such as an
external oracle or Kleros-level reversal signal) is present. This is relevant to Kleros
court-juries-as-detectors for resolver misbehavior.

**Correlated failure modeling.** `stochastic/correlated_failures.clj` models shared-bias
and herding dynamics in resolver panels — directly applicable to jury-pool design questions
(how much diversity is needed to avoid correlated errors?).

**Bond sizing under adversarial pressure.** Phase H simulations produce 2D sweeps over
`(resolver-bond-bps × slash-multiplier)` showing where the honest/malicious EV ratio flips.
This kind of adversarial calibration is applicable to Kleros PNK stake sizing analysis.

**Framework portability.** The replay engine and adversary protocol are protocol-agnostic.
The `SimulationAdapter` interface could be implemented for a Kleros court model, which would
allow the same deterministic replay and Monte Carlo infrastructure to generate evidence for
Kleros-specific hypotheses.

---

## Document map

| Document | What it covers | Priority for Kleros review |
|---|---|---|
| `07_KLEROS_INTEGRATION.md` | Full end-to-end Kleros integration: `rule()`, `createDispute()`, bond handling, liveness, known limits | **Primary** |
| `03_DISPUTE_RESOLUTION_ARCHITECTURE.md` | Three-round escalation model, round gating, module snapshot isolation | High |
| `04_DISPUTE_ECONOMICS.md` | Bond composition, appeal cost curves, round-2 fee handling | High |
| `05_GOVERNANCE_CONSTRAINTS.md` | What governance cannot do to an active Kleros-bound dispute | High |
| `01_PROTOCOL_OVERVIEW.md` | Full protocol overview including escrow lifecycle | Context |
| `02_PROTOCOL_MODULARITY.md` | Module snapshot isolation — why governance cannot redirect a live Kleros dispute | Context |
| `06_FORWARD_ONLY_UPGRADES.md` | Upgrade safety model for the `KlerosArbitrableProxy` address | Context |
| `08_WITHDRAWALS.md` | How a Kleros ruling maps to the final withdrawal path | Background |

**30-minute focused read:** `07_KLEROS_INTEGRATION.md` → §4.4–4.8 of
`03_DISPUTE_RESOLUTION_ARCHITECTURE.md` → `05_GOVERNANCE_CONSTRAINTS.md`.

---

## Evidence

| | |
|---|---|
| **Contracts** | `sew-protocol` @ `3af2646` |
| **Simulation** | `sew-simulation` @ `9fbb4ba` |
| **Generated/reviewed** | 2026-05-21 |
| **Verification status** | All technical claims in this document are directly sourced from the referenced contract code and simulation configuration files. Open items in §5 are reproduced verbatim from the evidence footers of the deeper documents. |
