# PRF Adjudication Outcome / Closure — SEW-Side Design Seam

**Status:** Design only. **No closure-root system is implemented.** This document
defines what the Solidity architecture should eventually *expose* or *consume* so it
can bind to `prf/adjudication-outcome.v1` and `prf/adjudication-closure.v1` without
redesigning custody.

**Companion artifacts (external):** `prf/adjudication-outcome.v1`,
`prf/adjudication-closure.v1`.

---

## 1. Semantic model

Keep five distinct stages; never let one boolean or loosely coupled variables stand
in for all of them:

```
decision  →  normalized SEW outcome  →  finality / adjudication closure
          →  settlement instruction  →  actual escrow state transition
```

And three distinct **facts** that must not be conflated:

1. **A decision exists** (something was recorded).
2. **Adjudication process state / finality** (appealable? final? refused? escalated?).
3. **Economic settlement outcome** (release / refund) and its **realization**.

Process states (`REFUSED`, `APPEALED`, `EXPIRED`, `TIMED_OUT`, `ESCALATED`, `FINAL`)
are **not** economic outcomes. In particular, refusal is process state, not an outcome.

---

## 2. Current Solidity seams (what already exists)

| Semantic role | Current representation | Notes |
|---|---|---|
| Decision recorded | module `decisionAtRound`; escrow `EscrowResolved` event | resolver-asserted, echoed into module |
| Normalized outcome | `bool isRelease` (escrow) / `ResolutionOutcome {NONE,RELEASE,CANCEL}` (module) | minimal vocabulary; no `SPLIT` (split is mutual agreement, not adjudicated) |
| Reserved commitment slot | `PendingSettlement.resolutionHash` | **non-binding**; reserved for `finalOutcomeRoot` |
| Appealable / final (escrow) | `PendingSettlement.appealDeadline` | the authoritative settlement predicate today |
| Final (module) | `DisputeStatus.Final` via `finalizeDispute` | best-effort; failure swallowed |
| Authority gate | `et.disputeResolver` (`_isAuthorizedDisputeResolver`) | frozen per workflow; must never be a bridge |
| Refusal (process) | `KlerosArbitrableProxy.refusalTimestamp` / `RulingRefused` / `isRefused` | observational only; no settlement authority |
| Realization | `_releaseEscrowTransfer` / `_cancelAndRefund` → `claimableBalances` | pull-only; custody local |
| Appeal-domain commitments | `appealedDecisionRoot`, `resolutionQuoteRoot`, `handoffRoot`, `klerosConfigRoot` | stable; compositional base |

---

## 3. Authority model (instantiate vs authoritative-afterward)

```
Creation assurance
    binds creation policy / resolver admissibility
                 ↓
Workflow authority snapshot
    binds the actual selected resolver (frozen per workflow)
                 ↓
Resolution assurance
    proves the acting resolver matches that frozen authority
```

- Global configuration (`EscrowCreationPolicy`) determines what **may be
  instantiated**.
- The per-workflow snapshot (`escrowSettings.customResolver` /
  `escrowTransfers.disputeResolver`) determines what is **authoritative afterward**.
- Settlement assurance must rely on the **frozen per-workflow authority**, never on
  the subsequently mutable global `resolverMustBeContract` setting.
- If a creation/policy root is introduced later, `resolverMustBeContract` can be
  committed **there**; it should not gate later transitions.

---

## 4. Future closure seam (design)

The smallest boundary that does not touch custody:

- **Capture** at the decision→pending transition (`BaseEscrow._executeResolution`):
  a terminal `finalOutcomeRoot` / `adjudicationClosureRoot` computed by the
  snapshotted resolution module, compositionally over the existing stable
  commitments.
- **Store** it in `PendingSettlement` (the reserved slot currently held by
  `resolutionHash`).
- **Verify/re-read** at realization (`EscrowSettlement.executePendingSettlement`)
  against the snapshotted module.
- **Capability detection must be explicit**, not inferred from whether a call
  happened to succeed. A swallowed revert must not be read as "module does not
  support finality."

Security property (non-negotiable):

```
remote decision message  ≠  settlement authority
```

A local escrow acts only on a pre-authorized, authenticated, final settlement
instruction bound to its own dispute. No bridge/receiver, no arbitrary-call
settlement, no new privileged execution path.

---

## 5. Explicit non-goals

- No cross-chain machinery, no remote settlement authority.
- No closure-root implementation before the PRF artifact shapes are fixed.
- No `SPLIT` in the adjudication outcome vocabulary.
- No unification that makes process states into economic outcomes.
- Custody/enforcement stays local.

---

## 6. Open questions for the PRF artifact design

1. Exact schema of `finalOutcomeRoot` / `adjudicationClosureRoot` and how it composes
   from `appealedDecisionRoot` + `resolutionQuoteRoot` + `handoffRoot` + round +
   outcome + refusal flag.
2. Single finality predicate: how to express "module supports authenticated finality"
   in a way the escrow can verify (ERC-165 capability vs explicit interface).
3. Whether refusal needs a distinct on-chain terminal path or forever maps to
   timeout→refund (current behavior).
4. Whether `resolutionHash` is renamed to the closure slot or kept and extended.

---

## 7. Already-enforced invariants (evidence)

- `resolutionHash` cannot alter authorization/finality/pending-settlement/custody —
  `test/foundry/core/ResolutionHashNonBinding.t.sol`.
- Refusal is observational: no settlement propagation —
  `test/foundry/arbitration/KlerosIntegration.t.sol` (refusal tests).
- Timeout→refund is unaffected by refusal representation —
  `test/foundry/core/DisputeTimeoutRefund.t.sol`.
- Creation derivation equivalence — `test/foundry/ops/CreationLogicEquivalence.t.sol`.

---

## 8. Related docs

- `docs/FINALITY.md`, `docs/SETTLEMENT.md`, `docs/SECURITY_MODEL.md`
- `docs/dispute-resolution/FINALITY_DISCIPLINE_DEV_PLAN.md`
- `docs/architecture/ARCHITECTURAL_PRINCIPLES.md` (snapshot / instantiate-vs-authoritative)
