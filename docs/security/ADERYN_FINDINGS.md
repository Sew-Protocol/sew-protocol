# Aderyn Findings Baseline

Known-and-reviewed static-analysis findings for the Sew protocol Solidity tree.

The purpose of this baseline is to distinguish **known + reviewed** findings from
**new + unexplained** ones across Aderyn runs. It is **not** a catalogue of scary
findings, and it is **not** indexed by Aderyn's H-x / L-x numbering (which changes
between Aderyn versions). Findings are identified by:

```
detector identity
+ contract / function
+ semantic reason
```

---

## Current baseline snapshot

| Metric | Value |
| --- | --- |
| Accepted High | 7 |
| Accepted Low | 19 |
| nSLOC | 14,417 |
| Accepted intentional (L-12) | 3 |
| L-13 address-validation repaired | 1 of 12 |

Generated with:
- Aderyn `0.6.8`
- Config: `aderyn.toml` (root, production scope)
- Revision: working copy `yqrpxzvv` (parent `sqmmqxks`), 2026-09-23

Reading this snapshot: if the Aderyn version, config/scope, or source tree changes,
re-assess before treating a total delta as "a new finding" — a version/config/scope
shift can move totals without any code change.

---

## Run metadata

- Aderyn version: `0.6.8`
- Config: `aderyn.toml` (root)
- Production scope: `src` auto-detected (Foundry); excludes `contracts/mocks/`,
  `contracts/arbitration/mocks/`, `contracts/test/`, `contracts/generated/`,
  `contracts/vendor/`. Core libraries and interfaces are intentionally **in scope**.
- Baseline commit: working copy `yqrpxzvv` (parent `sqmmqxks`) — shared jj repo,
  multi-workspace.
- Last regenerated: 2026-09-23

---

## Disposition classes

| Class | Meaning | Automation |
| --- | --- | --- |
| A — Mechanical | dead code, unused imports, visibility/style hygiene | Auto-fix acceptable + tests |
| B — Local structural | duplicate declarations, unnecessary inheritance, isolated interface cleanup | Agent can fix, human reviews diff |
| C — Semantic / security | reentrancy, authorization, value flow, state transition, external-call ordering | No unattended auto-repair |
| D — Intentional / detector mismatch | mocks, deliberate non-standard tokens, nonce flagged as randomness | Suppress/exclude/document; don't mutate code |

For Sew specifically, anything involving BaseEscrow, settlement, dispute
transitions, DRM, BondLedger, governance, yield custody, or authorization should
default to **C** even when Aderyn calls it Low.

---

## Accepted current findings (High)

### H — `abi.encodePacked()` hash collision
| Location | Class | Disposition | Rationale |
| --- | --- | --- | --- |
| `CREATE2EscrowFactory.sol` :: `_buildSalt`-style | C | INTENTIONAL-SAFE | Fixed-length, injective packed args; no variable-length concatenation — no collision surface. |
| `L2AddressRegistry.sol` :: salt derivation | C | INTENTIONAL-SAFE | Same: fixed-length packed args under domain context. |

### H — ETH transferred without address checks
| Location | Class | Disposition | Rationale |
| --- | --- | --- | --- |
| `EscrowAccounting.sol` :: ETH payout path | C | INTENTIONAL-SAFE | CEI pull-payment to `_msgSender()`; recipient is the authenticated caller, not attacker-supplied. |

### H — Reentrancy (state change after external call, ~60 instances)
| Locations | Class | Disposition | Rationale |
| --- | --- | --- | --- |
| KlerosArbitrableProxy, BaseEscrow, EscrowAccounting, EscrowVault, EmergencyRecoveryProposal, AaveYieldModule, DecentralizedResolutionModule, ResolverIncentiveModule(V2BondLedger), ResolverSlashingModule, ResolverStakingModule, GuardianOps, ModuleRegistry, BondLedger | C | FALSE-POSITIVE / REVIEWED | Vast majority are guarded by `nonReentrant` or are view/read paths or follow pull-payment CEI. Do **not** mass-apply `nonReentrant`. Review each per the 3-question policy (external control transfer → state/liability committed before it → what a re-entrant call can do). |

### H — Storage array edited with memory
| Location | Class | Disposition | Rationale |
| --- | --- | --- | --- |
| `L2AddressRegistry.sol` :: `supportedChains` update | C | INTENTIONAL-SAFE | Explicit storage write-back of the updated array; not the "storage pointer to memory" bug. |

### H — Unprotected initializer
| Location | Class | Disposition | Rationale |
| --- | --- | --- | --- |
| `KlerosArbitrableProxy.sol` :: init, `DefaultResolutionModule.sol` :: init | C | FALSE-POSITIVE | `initializeDispute`-style entry points are no-ops in this context — no state to protect from a second call. |

### H — Weak randomness
| Location | Class | Disposition | Rationale |
| --- | --- | --- | --- |
| `KlerosArbitrableProxy.sol`, `L2AddressRegistry.sol`, `MultiL2ModuleCoordinator.sol` :: nonce derivation | C | INTENTIONAL | `block.timestamp`/nonce used as a **unique nonce/id**, not as a randomness source. Do not "improve randomness" where randomness is not required. |

### H — Yul block contains `return`
| Location | Class | Disposition | Rationale |
| --- | --- | --- | --- |
| `DecentralizedResolutionModule.sol` :: delegatecall result path | C | INTENTIONAL | Deliberate Yul `return` to bubble the delegatecall return data verbatim. |

---

## Accepted current findings (Low) — address-validation review (L-13)

Detector: **address state variable set without checks** (Aderyn L-13 in 0.6.8; previously L-14).

Semantic review outcome: **1 of 12 repaired** (DRM `setAdminFacet`); the rest are
intentional sentinel/disabled-zero addresses or non-production-reachable setters, and were
left unchanged. No instance was changed merely to silence the detector.

| Instance | Class | Disposition | Rationale |
| --- | --- | --- | --- |
| `EvidenceModuleV1.sol` :: init `escrowContract` (98) | C | UNCHANGED — design decision | Upgradeable config binding; no downstream zero-guard either way. Zero would break the `onlyEscrowContract` modifier callbacks, but whether zero is a valid "unset-then-set" state is a configuration design decision, not a clear defect. |
| `EvidenceModuleV1.sol` :: init `resolutionModule` (99) | C/D | UNCHANGED — sentinel | Zero is a valid disabled sentinel: both `_canSubmitEvidenceInternal` and `canSubmitEvidence` guard `if (resolutionModule != address(0))`. |
| `EvidenceModuleV1.sol` :: `setEscrowContract` (351) | C | UNCHANGED — design decision | Same as init `escrowContract`; upgradeable reconfiguration path. |
| `EvidenceModuleV1.sol` :: `setResolutionModule` (357) | C/D | UNCHANGED — sentinel | Same as init `resolutionModule`; zero = disabled. |
| `DRMAdminFacet.sol` :: `setAdminFacet` (86) | D | UNCHANGED — not production-reachable | DRM defines its own `setAdminFacet` directly, so the DRM fallback never routes this selector to the facet. Rejecting zero here would be redundant defensive code on an unreachable setter. |
| `DRMAdminFacet.sol` :: `setBondTokenRegistry` (449) | D | UNCHANGED — sentinel | Zero = disabled: guarded at use `if (address(bondTokenRegistry) != address(0))` (with `defaultBondToken()` fallback). |
| `DRMAdminFacet.sol` :: `setIncentiveModule` (481) | D | UNCHANGED — sentinel | Zero = disabled: guarded `if (address(incentiveModule) != address(0))` at every use. |
| `DRMAdminFacet.sol` :: `setStakingModule` (487) | D | UNCHANGED — sentinel | Zero = disabled: guarded `stakingModule != address(0)`. |
| `DecentralizedResolutionModule.sol` :: `setAdminFacet` (138) | C | REPAIRED | Zero is never legitimate: `_delegateAdmin` reverts `AdminFacetNotSet()` on zero, so zero is only ever an error state. Added set-time `revert ZeroAddress('adminFacet')` on both bootstrap and TIMELOCK-rotation paths. Tests: `AdminFacetZeroAddress.t.sol` (2). |
| `BondTokenRegistry.sol` :: constructor `initialDefaultToken` (61) | D | UNCHANGED — valid sentinel (ETH) | **Zero is the ETH token sentinel and the default** (see `BondTokenWhitelist.t.sol`: `isAccepted(address(0))` true, `defaultBondToken() == address(0)` = ETH). Rejecting zero here would break ETH-as-default-bond-token. |
| `ResolverSlashingModule.sol` :: `setInsurancePoolVault` (1313) | D | UNCHANGED — sentinel | Zero = disabled: guarded at use (`_distributeSlashedFunds`, `getInsurancePoolBalance`, `fundInsurancePool` all check `address(insurancePoolVault) != address(0)`). Constructor rejects zero; the setter permits intentional service-disable. |
| `ResolverStakingModule.sol` :: `slashingModule` setter (1254) | D | UNCHANGED — sentinel | Zero = disabled: guarded `slashingModule != address(0)` at use in DRM `recordResolution`/`_recordReversalAnalytics`. |

---

## Accepted current findings (Low) — remaining state-change-without-event

Detector: **state-change-without-event** (Aderyn L-12 in 0.6.8; previously L-13).

> **FROZEN — reviewed baseline findings (L-12 round complete).** The three findings
> below are accepted and should **not** be revisited merely because Aderyn keeps
> reporting them. Reopen only if: new code changes the surrounding transition; new
> evidence shows an externally meaningful transition is unlogged; or the detector
> itself improves and identifies a more precise issue. Otherwise the baseline is
> doing its job.

| Function | Class | Disposition | Rationale |
| --- | --- | --- | --- |
| `EmergencyRecoveryProposal.sol` :: `_executeRecoveryAction` | C/D | INTENTIONAL-SAFE | The proposal status transition is already logged by `RecoveryExecuted` in the caller (`executeRecovery`). An event in this internal dispatch would duplicate that observable transition and add noise. |
| `DecentralizedResolutionModule.sol` :: `prepareKlerosHandoff` | C | INTENTIONAL-SAFE | Writes ephemeral prepared-handoff state consumed and deleted by `commitKlerosHandoff`. The externally relevant transition (successor resolver assigned to round 2) is logged by `ResolverAssigned` via `_executeEscalation`. A prepare-stage event would only expose transient internal state. |
| `DecentralizedResolutionModule.sol` :: `setEscrowCategory` | C | RESOLVED | Persistent unevented write (`escrowCategory[...] = categoryKey`) that influences resolver category routing. Addressed with a minimal `EscrowCategorySet` event (see Resolved section). |
| `DecentralizedResolutionModule.sol` :: `decrementResolverActiveDisputes` | C | INTENTIONAL-SAFE | Internal escrow-driven accounting counter mirroring a resolver's active-dispute count. The lifecycle transitions that drive the decrement (dispute assignment and decision) are already logged by `ResolverAssigned` and `DecisionSubmitted`. A dedicated decrement-only event would be asymmetric noise — the increment side is not separately evented either. |

---

## Resolved while establishing baseline

- L-12 `EvidenceModuleV1.sol` :: `setEscrowContract`, `setResolutionModule` — events added.
- L-12 `AaveYieldModule.sol` :: `queueApproveEscrow`, `queueConfigureToken`, `queueConfigureTokenCap` — `*Queued` events added.
- L-12 `DRMAdminFacet.sol` :: `setDisputeTimeout` — `DisputeTimeoutUpdated` event added.
- L-12 `DecentralizedResolutionModule.sol` :: `setEscrowCategory` — `EscrowCategorySet` event added (persistent unevented write that influences resolver category routing).
- L-12 `ResolverSlashingModule.sol` :: `setMaxSlashPerPeriod`, `setAppealWindow`, `setAppealBond`, `setInsurancePoolVault`, `setUnavailabilityStats` — events added (declared in `ISlashingModule` where applicable).
- Prior rounds (documented in project AGENTS.md sessions): public→external, immutable conversions, forceApprove, cache array length, reordered modifiers, removed unused imports — previously done Low items.

---

## Policy reminder

- Do not chase "Aderyn clean". Target = 0 unexplained High, 0 unexplained new findings, 100% of findings dispositioned.
- Do not add `[detectors] exclude` globally for a detector that is systematically inappropriate; suppress narrowly at source/path level instead.
- Every security-semantic fix must run `forge test` + relevant invariants/fuzz + PRF/model correspondence — never accept "Aderyn clean" as safety evidence.
- Before releases/audits: rerun Aderyn fresh with this baseline re-reviewed, and pair with Slither + dynamic/model assurance.
