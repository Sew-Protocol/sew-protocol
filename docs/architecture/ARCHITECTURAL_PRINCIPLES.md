# Architectural Principles

Design principles that guide protocol and contract development. This document is intentionally short and is meant to be a stable reference; detailed rationale lives in the surrounding architecture docs.

**Last Updated**: 2026-09

---

## Core Principles

### 1) Snapshot semantics (immutability per-escrow)
- Once an escrow is created, its **modules and settings are snapshotted** for that escrow.
- Governance can change defaults for **future escrows**, but should not mutate rules for in-flight escrows.

### 2) Governance is the only upgrade path
- Core contracts are treated as **immutable**.
- Protocol evolution should happen through **module swaps** and **parameter changes** via Timelock.
- Emergency actions should be **down-only** and constrained to a Guardian policy.

### 3) Safe-by-default user flows
- Prefer explicit state machines and typed errors over ambiguous behaviors.
- Avoid silent partial failure in user-critical paths; where non-blocking behavior exists (e.g. yield), it must be observable (events + reason codes).

### 4) Clear separation of concerns
- Core escrow state machine lives in `BaseEscrow`.
- Deterministic creation, dispute, and settlement derivation are compiled in as internal libraries (`EscrowCreationLogic`, `EscrowDisputeLogic`, `EscrowSettlementLogic`); escrow custody and state transitions remain in escrow contracts. The remaining external “ops” contracts (`YieldOps`, `BondCollector`, `GuardianOps`) carry state/custody, not computation.
- Global configuration determines what may be **instantiated**; per-workflow snapshots determine what is **authoritative afterward**.
- Complex logic should be extracted into libraries/modules rather than growing core bytecode.

### 5) Observability is a first-class requirement
- Emit high-signal events for state transitions and automation outcomes.
- Use stable reason codes/enums instead of strings where possible.

### 6) Size-aware engineering
- Treat EIP-170 limits as a design constraint.
- Prefer techniques like via-IR, library extraction, and avoiding duplicated logic to keep deployable bytecode under limits.

---

## Retained Policy Decisions

Stable decisions that should not be re-litigated by cleanup refactors.

### `resolverMustBeContract=false` is intentionally retained
- `resolverMustBeContract` lives in `EscrowCreationPolicy` (default `true`; production posture is `true`).
- `false` permits a non-zero **EOA** `customResolver`. It affects **resolver admissibility at creation only**; established workflow authority and custody/settlement mechanics are unchanged.
- Consequences of `false`, specified: the EOA becomes the workflow's resolver authority; resolver callbacks are unavailable; appeals are unsupported for that custom-resolver workflow; settlement/custody execution is identical.
- The capability is supported and tested end-to-end (creation → dispute → resolution), and there is a contract-resolver route for richer behavior.
- **Removal is a product-hardening decision, not cleanup.** Do not collapse the flag during refactors. PRF/assurance should bind the **frozen per-workflow resolver authority**, not the subsequently mutable global setting.

---

## Related Docs
- `docs/architecture/ARCHITECTURE_OVERVIEW.md`
- `docs/architecture/TECHNICAL_OVERVIEW.md`
- `docs/architecture/CONTRACTS_SUMMARY.md`
- `docs/governance/GOVERNANCE_SURFACE_MAP.md`
- `docs/policies/EMERGENCY_POLICY.md`
- `docs/policies/UPGRADE_POLICY.md`

