# Architectural Principles

Design principles that guide protocol and contract development. This document is intentionally short and is meant to be a stable reference; detailed rationale lives in the surrounding architecture docs.

**Last Updated**: 2026-01

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
- External “ops” contracts compute/validate and orchestrate, but escrow custody and state transitions remain in escrow contracts.
- Complex logic should be extracted into libraries/modules rather than growing core bytecode.

### 5) Observability is a first-class requirement
- Emit high-signal events for state transitions and automation outcomes.
- Use stable reason codes/enums instead of strings where possible.

### 6) Size-aware engineering
- Treat EIP-170 limits as a design constraint.
- Prefer techniques like via-IR, library extraction, and avoiding duplicated logic to keep deployable bytecode under limits.

---

## Related Docs
- `docs/architecture/ARCHITECTURE_OVERVIEW.md`
- `docs/architecture/TECHNICAL_OVERVIEW.md`
- `docs/architecture/CONTRACTS_SUMMARY.md`
- `docs/governance/GOVERNANCE_SURFACE_MAP.md`
- `docs/policies/EMERGENCY_POLICY.md`
- `docs/policies/UPGRADE_POLICY.md`

