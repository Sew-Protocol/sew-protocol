# Historical Aderyn Repair-Lineage Dataset

An evidence-backed map from the **archived pre-25-January Aderyn report** to each
finding's present disposition, repair depth, and architectural impact. This is an
**analysis and documentation** artifact. It does not implement a generic PRF
repairability framework, scoring system, incentive mechanism, or new runtime
contract.

The question this dataset answers, finding by finding:

> What happened to each issue in `docs/archived/report-before25jan.md`, how deeply
> did its remediation affect the implementation, and did fixing it require changing
> Sew's underlying architecture?

The underlying hypothesis under test is:

> Sew has remained architecturally continuous while accepting meaningful security
> and lifecycle corrections.

This document is the human-readable companion to the machine-readable mapping in
[`HISTORICAL_ADERYN_REPAIR_LINEAGE.edn`](./HISTORICAL_ADERYN_REPAIR_LINEAGE.edn).

---

## 1. Source and provenance

| Item | Value |
| --- | --- |
| Report | `docs/archived/report-before25jan.md` |
| SHA-256 | `2f91229ef4fd64d494019740cef0cc85a7323c1c2bd050109986541eee13cd84` |
| Verified | Recalculated with `sha256sum` on 2026-09-28 — **matches** the previously recorded value. |
| File count (reported) | 97 Solidity files |
| nSLOC (reported) | 11,680 |
| High findings (reported) | 7 |
| Low findings (reported) | 28 |
| Findings extracted | **35** (7 high, 28 low) |
| Total occurrences | **774** |
| Aderyn version | **UNKNOWN** (not present in report) |
| Compiler / optimizer | **UNKNOWN** (not present in report) |
| Source commit / tree root | **UNKNOWN** |
| Deployment binding | **UNKNOWN** |

### Provenance limitation (retained, per task)

The archived report carries **no** source commit/tree root, Aderyn version,
compiler version, optimizer configuration, deployment address, or runtime hash.
The filename must **not** be treated as evidence that the report describes the
exact January-25 source. Consequently:

```text
historical source revision: UNKNOWN
historical deployment binding: UNKNOWN
```

The report describes the **old pre-refactor layout**:

- `contracts/decentralized-resolution-module/*.sol` (incl. `*V1.sol`)
- `contracts/ops/{CreateOps,DisputeOps,SettlementOps,YieldOps}.sol`
- monolithic `core/BaseEscrow.sol`
- legacy module contracts (`ResolverIncentiveModuleV1/V2`, `ResolverStakingModuleV1`,
  `ResolverSlashingModuleV1`, `AaveYieldGenerationModule`)

That layout no longer exists. The current tree (124 `.sol`, 111 production-scoped,
14,417 nSLOC, 7H+19L under Aderyn 0.6.8) has been reorganized:

| Old | Current |
| --- | --- |
| `contracts/decentralized-resolution-module/*.sol` | `contracts/modules/decentralized-resolution-module/**` |
| `ResolverIncentiveModuleV1.sol` + `V2` | `.../incentive/ResolverIncentiveModule.sol` |
| `ResolverStakingModuleV1` | `.../staking/ResolverStakingModule.sol` |
| `ResolverSlashingModuleV1` | `.../slashing/ResolverSlashingModule.sol` |
| `contracts/ops/{CreateOps,DisputeOps,SettlementOps,YieldOps}.sol` | consolidated into `core/Escrow*` files |
| monolithic `core/BaseEscrow.sol` | decomposed into `core/Escrow{Lifecycle,Settlement,Disputes,Creation,Accounting,Configuration,Storage,Yield,...}.sol` |
| `AaveYieldGenerationModule.sol` | `modules/AaveYieldModule.sol` |
| `EscrowAdminContract.sol` | `admin/EscrowGovernanceTimelock.sol` |

This path map is central to judging whether an old finding's remediation happened
"inside" a preserved architecture or across a fundamentally changed one.

### Critical numbering caveat

**Aderyn `H-x` / `L-x` numbers are NOT stable identifiers across runs.** They vary
with the detector set, Aderyn version, and file order. In particular:

- Commit `6006e723` ("address Aderyn high-priority issues H-4 and H-6") comes from a
  **different run's** numbering:
  - its **H-4 = Unsafe Casting** (SafeCast), not the archived **H-4 (Weak Randomness)**;
  - its **H-6 = Contract Name Reused** (= archived H-2), not the archived **H-6 (Incorrect ERC20)**.

Therefore every finding below is keyed by **detector identity and affected surface**,
never by the H/L number alone. Where a commit message references a number, the
number is cross-checked against the detector semantics before any causal claim.

---

## 2. Methodology

### 2.1 Extraction

All 35 findings and their 774 individual occurrences were extracted from
`report-before25jan.md`. Structure of the report:

```text
## H-x: Title
  details
   summary
  <contract/function>   [one per occurrence]
```

Each finding records:

- a **stable local historical key** (`pre25jan-H-01`, `pre25jan-L-01`, …);
- the original **Aderyn title / detector**;
- severity;
- **occurrence count** and individual affected locations;
- the report's own ordering (the local keys are assigned in report order; no
  additional ordering is invented).

### 2.2 Lineage classification

Each finding was investigated independently through jj history, diffs, renames,
commit messages, the current implementation, the current `ADERYN_FINDINGS.md`, and
tests. The disposition vocabulary (with strong—not speculative—criteria):

- **DIRECTLY_REPAIRED** — good causal evidence (commit message, issue ref, contemporaneous doc, or an unusually clear direct diff).
- **LIKELY_REPAIRED** — code history supports the relationship but causal attribution cannot be established.
- **SUPERSEDED** — obsolete through architectural replacement; the mechanism no longer exists.
- **CODE_REMOVED** — the offending code was deleted.
- **STILL_PRESENT_REVIEWED_SAFE** — still present, reviewed, and accepted (no defect).
- **STILL_PRESENT_OPEN** — still present and represents a genuinely open concern.
- **FALSE_POSITIVE_OR_DETECTOR_MISMATCH** — detector error or mismatch with current toolchain/target.
- **NOT_APPLICABLE_AFTER_REFACTOR** — the finding's subject no longer exists for reasons orthogonal to the Defect.
- **UNRESOLVED_LINEAGE** — reserved for cases where no defensible mapping exists.

Correlation is never silently upgraded to causation.

### 2.3 Repair depth

For every finding that was repaired, superseded, or removed:

| Depth | Meaning | Examples |
| --- | --- | --- |
| 0 | **Disposition only** — no production semantic change. | false positive, intentional reviewed behaviour |
| 1 | **Surface / local hardening** — small bounded change, no meaningful lifecycle change. | zero-address validation, event emission, safe-transfer helper, explicit return check, safe cast, visibility cleanup |
| 2 | **Local semantic correction** — behaviour change inside an existing component, without changing trust/custody/state-machine boundaries. | SafeERC20 adoption, forceApprove |
| 3 | **Cross-component / lifecycle correction** — material behavioural refactor spanning components or lifecycle semantics, preserving the architectural model. | (none here) |
| 4 | **Architectural replacement** — foundational commitment changed (custody model, settlement authority, upgrade model, escrow state machine). | V1/V2 merge + BondLedger extraction (H-5) |

A meaningful behavioural correction is **never** classified as depth-1 solely
because its diff is small.

### 2.4 Architectural-impact booleans

Recorded independently and explicitly (each `true`/`false`, or `unknown`):

```text
custody-boundary-changed?
settlement-authority-changed?
privilege-or-governance-boundary-changed?
escrow-state-machine-changed?
module-selection-model-changed?
active-escrow-snapshot-model-changed?
storage-migration-required?
external-interface-breaking-change?
cross-contract-behaviour-change?
```

plus

```text
production-contracts-touched
architectural-domains-touched
```

The operative question is **not** "how many lines changed?" but:

> Could the defect be corrected inside the architecture that already existed?

Note the deliberate separation of **architecture preservation** from **behavioural
preservation**: a finding may have *behavior changed: yes* while *architecture
preserved: yes*.

### 2.5 Confidence

Evidence preference order: (1) exact source diff; (2) commit message / issue /
historical doc showing causal intent; (3) regression test added with the repair;
(4) current implementation; (5) current Aderyn disposition; (6) later documentation.

Confidence levels: `HIGH`, `MEDIUM-HIGH`, `MEDIUM`, `LOW-MEDIUM`, `LOW`.

---

## 3. Complete disposition table

Columns: Historical ID, Severity, Finding (detector), Affected surface, Disposition,
Confidence, Repair commit(s), Repair depth, Behaviour changed?, Architecture
preserved?, Contracts/domains touched, Regression evidence, Release/deployment/
chain binding, Notes.

| ID | Sev | Finding | Affected surface | Disposition | Conf | Repair commit(s) | Depth | Beh? | Arch? | Contracts/domains | Regression | Release/Deploy/Chain | Notes |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| H-1 | High | Arbitrary `from` passed to `transferFrom` | mock token usage | STILL_PRESENT_REVIEWED_SAFE | HIGH | — | 0 | no | yes | mocks (non-prod) | — | UNKNOWN | Mock-only; arbitrary-from is intentional test convenience. |
| H-2 | High | Contract name reused in different files | `ISlashingModule` / `IStakingModule` dup | DIRECTLY_REPAIRED | HIGH | `6006e723` (its "H-6"), `ce786459` | 1 | yes | yes | interface dedup | added tests | UNKNOWN | Cleanest causal case; commit names the issue. |
| H-3 | High | ETH transferred without address checks | `SafeMock` | STILL_PRESENT_REVIEWED_SAFE | HIGH | — | 0 | no | yes | mocks | — | UNKNOWN | Mock-only, non-prod. |
| H-4 | High | Weak randomness | DRM resolver-selection seed | STILL_PRESENT_OPEN | MEDIUM | — | 0 | no | yes | DRM resolver selection | none | UNKNOWN | **Open**: remaining `keccak256(abi.encodePacked(blockHash, category, curIdx))`; `block.timestamp`→`curIdx` was resolver-rotation refactor, not a fix; not covered by current INTENTIONAL disposition. |
| H-5 | High | Contract locks Ether without a withdraw function | `MockKlerosArbitrator` language | SUPERSEDED | HIGH | `82c7160f`, `49593286` | 4 | yes | n/a (replaced) | V1/V2 merge; BondLedger extraction | — | UNKNOWN | Superseded via architectural change; candidate-lineage, not Feb deployed ref. |
| H-6 | High | Incorrect ERC20 interface | mock ERC20 | STILL_PRESENT_REVIEWED_SAFE | HIGH | — | 0 | no | yes | mocks | — | UNKNOWN | Mock-only. |
| H-7 | High | Reentrancy: state change after external call | BaseEscrow / modules / ops | STILL_PRESENT_REVIEWED_SAFE (prod); some SUPERSEDED | HIGH | rewrites (Aave pull-model, incentive merge) | 0–1 | mixed | yes | BaseEscrow, DRM, modules, ops | existing reentrancy tests | UNKNOWN | Prod guarded `nonReentrant`/CEI; mocks non-prod; some superseded by rewrite. |
| L-1 | Low | Centralization risk | setters/admin (many) | STILL_PRESENT_REVIEWED_SAFE | HIGH | role refactor (single ROLE_TIMELOCK) | 1 | no | yes | governance/roles | — | UNKNOWN | By-design DAO; ROLE_MODULE_DEVELOPER removed; single ROLE_TIMELOCK now. |
| L-2 | Low | Unsafe ERC20 operation | token transfers tree-wide | DIRECTLY_REPAIRED | HIGH | (SafeERC20 sweep) | 2 | yes | yes | all token paths | added tests | UNKNOWN | SafeERC20 tree-wide; `forceApprove` in BondCollector; raw `.transfer`/`.approve` gone in prod. |
| L-3 | Low | Unspecific pragma | all files | STILL_PRESENT_REVIEWED_SAFE | HIGH | — | 0 | no | yes | all | — | UNKNOWN | Still caret `^0.8.37`, never pinned; accepted. |
| L-4 | Low | Address set without checks | sentinels/setters | STILL_PRESENT_REVIEWED_SAFE | MEDIUM-HIGH | DRM `setAdminFacet` ZeroAddress | 1 | partial | yes | DRM, modules, staking/slashing | `AdminFacetZeroAddress.t.sol` (2) | UNKNOWN | Most sentinel/design, accepted (ADERYN_FINDINGS L-13: 1-of-12 repaired); `StakingModuleNoOp` CODE_REMOVED. |
| L-5 | Low | Public function not used internally | various public fns | LIKELY_REPAIRED | MEDIUM | — | 1 | no | yes | various | — | UNKNOWN | public→external conversions (AGENTS-documented cleanup). |
| L-6 | Low | Literal instead of constant | inline literals | STILL_PRESENT_REVIEWED_SAFE | MEDIUM | — | 1 | no | yes | various | — | UNKNOWN | Partial: some constants added, inline literals remain; accepted. |
| L-7 | Low | `nonReentrant` not first modifier | `withdrawFees`, `executePayout` | DIRECTLY_REPAIRED | HIGH | (modifier-order cleanup) | 1 | no | yes | Escrow/incentive | added tests | UNKNOWN | Reordered modifiers (AGENTS-documented). |
| L-8 | Low | PUSH0 opcode | all files | FALSE_POSITIVE_OR_DETECTOR_MISMATCH | HIGH | — | 0 | no | n/a | all | — | UNKNOWN | Cancun `evmVersion`; Base is post-Shanghai — PUSH0 is valid; detector mismatch. |
| L-9 | Low | Modifier invoked only once | `onlySeniorResolver` | STILL_PRESENT_REVIEWED_SAFE | MEDIUM | (moved to DRMAdminFacet) | 0 | no | yes | DRM/facet | — | UNKNOWN | Benign; modifier relocated, not a defect. |
| L-10 | Low | Empty block | no-op hooks | STILL_PRESENT_REVIEWED_SAFE | MEDIUM | (delegation refactor resolved `queueEscalationCostConfig`) | 0 | no | yes | DRM, Escrow | — | UNKNOWN | Intentional no-op hooks (`_emit*`); some resolved by delegation refactor. |
| L-11 | Low | Large numeric literal | inline big numbers | STILL_PRESENT_REVIEWED_SAFE | MEDIUM | — | 0 | no | yes | various | — | UNKNOWN | Style; accepted. |
| L-12 | Low | Internal function used only once | `createTestInput`, `getAmountTier` | STILL_PRESENT_REVIEWED_SAFE | MEDIUM | — | 0 | no | yes | various | — | UNKNOWN | Legit extraction; accepted. |
| L-13 | Low | TODO comments | `ResolverSlashingModuleV1` | DIRECTLY_REPAIRED (CODE_REMOVED via consolidation) | HIGH | (consolidation) | 0 | no | yes | slashing | — | UNKNOWN | TODO removed with old-layout consolidation. |
| L-14 | Low | Unused error | several named errors | LIKELY_REPAIRED | LOW-MEDIUM | — | 1 | no | yes | various | — | UNKNOWN | Low confidence; commit attribution unresolved. |
| L-15 | Low | Loop contains require/revert | batch loops | STILL_PRESENT_REVIEWED_SAFE | MEDIUM | — | 0 | no | yes | various | — | UNKNOWN | Intentional all-or-nothing semantics. |
| L-16 | Low | Redundant statement | unused-param silencers | STILL_PRESENT_REVIEWED_SAFE | MEDIUM | — | 0 | no | yes | various | — | UNKNOWN | Accepted. |
| L-17 | Low | Unused state variable | NoOp mocks | CODE_REMOVED | HIGH | — | 0 | no | yes | mocks | — | UNKNOWN | NoOp mocks removed. |
| L-18 | Low | Local shadows state | mocks | STILL_PRESENT_REVIEWED_SAFE / FP | MEDIUM | — | 0 | no | yes | mocks | — | UNKNOWN | Mock/non-prod. |
| L-19 | Low | Uninitialized local | mocks | STILL_PRESENT_REVIEWED_SAFE / FP | MEDIUM | — | 0 | no | yes | mocks | — | UNKNOWN | Mock/non-prod. |
| L-20 | Low | Dead code | `_freezeResolverInsufficientBond` | DIRECTLY_REPAIRED (CODE_REMOVED) | HIGH | — | 0 | no | yes | slashing | — | UNKNOWN | Dead function removed. |
| L-21 | Low | Storage array length not cached | loops | DIRECTLY_REPAIRED | HIGH | (AGENTS-documented cleanup) | 1 | no | yes | various | — | UNKNOWN | Cached array length. |
| L-22 | Low | Costly operations in loop | loops | STILL_PRESENT_REVIEWED_SAFE | MEDIUM | — | 0 | no | yes | various | — | UNKNOWN | Gas advisory; accepted. |
| L-23 | Low | Missing inheritance | MockPoolAddressesProvider, MockNonStandardERC20 | STILL_PRESENT_REVIEWED_SAFE | MEDIUM | — | 0 | no | yes | mocks | — | UNKNOWN | Mock/non-prod. |
| L-24 | Low | Unused import | various | DIRECTLY_REPAIRED | MEDIUM | — | 1 | no | yes | various | — | UNKNOWN | Removed unused imports; some inferred. |
| L-25 | Low | State var could be constant | mocks | STILL_PRESENT_REVIEWED_SAFE | MEDIUM | — | 0 | no | yes | mocks | — | UNKNOWN | Mock/non-prod. |
| L-26 | Low | State change without event | setters/transitions | LIKELY_REPAIRED | HIGH | (event sweep) | 1 | no (behaviour) / yes (interface, event ABI) | yes | EvidenceModuleV1, AaveYieldModule, DRM, DRMAdminFacet, ResolverSlashingModule | — | UNKNOWN | Many events added; remaining accepted INTENTIONAL (see ADERYN_FINDINGS). `external-interface-breaking-change? = true` — events are ABI-visible, but state-transition behaviour unchanged. |
| L-27 | Low | State var could be immutable | various | LIKELY_REPAIRED | MEDIUM | — | 1 | no | yes | KlerosArbitrableProxy, InsurancePoolVault (+ others) | — | UNKNOWN | Partial: `arbitrator` + `stableToken` converted; ResolverStakingModule `stableToken`/`sewToken` NOT converted (inconsistency remains). |
| L-28 | Low | Unchecked return | token ops | LIKELY_REPAIRED | MEDIUM-HIGH | (SafeERC20 + forceApprove) | 1 | yes (partial) | yes | bond collecting | — | UNKNOWN | False positives for `_grantRole`/high-level calls; BondCollector `forceApprove` repaired. |

---

## 4. Per-finding detail (non-trivial)

Detailed reasoning for the findings that carry the most interpretive weight.

### H-2 — Contract name reused (DIRECTLY_REPAIRED · depth 1 · HIGH)

Duplicate `ISlashingModule` / `IStakingModule` interface names across files. The
cleanest causal case in the dataset: commit `6006e723` explicitly names the
address-content (under its own run's "H-6" numbering — cross-checked to this
detector), with follow-up `ce786459`. Repair was a **local interface dedup** inside
the existing module-selection architecture. **Behavior changed: yes; architecture preserved: yes.**

### H-4 — Weak randomness (STILL_PRESENT_OPEN · depth 0 · MEDIUM)

Production DRM resolver-selection seeding still uses

```solidity
keccak256(abi.encodePacked(blockHash, category, curIdx))
```

at the selection sites. The historical change from `block.timestamp` to `curIdx`
was a **resolver-rotation refactor**, not a remediation of predictability. The
current `ADERYN_FINDINGS.md` INTENTIONAL disposition covers **nonce-derivation** at
`KlerosArbitrableProxy`, `L2AddressRegistry`, and `MultiL2ModuleCoordinator` — it does
**not** cover DRM resolver selection. This is the most notable genuinely **open**
item. Confidence MEDIUM because the production-only scope and the boundary with the
documented nonce-derivation disposition required inference.

### H-5 — Locks Ether without withdraw (SUPERSEDED · depth 4 · HIGH)

Flighted on `MockKlerosArbitrator`; the language-level class was superseded by
architectural change rather than an in-place fix:

- `82c7160f` — merger of the V1/V2 split (custody/state simplification);
- `49593286` — bond custody extracted into `BondLedger`.

Both are in the **Sew-Next candidate lineage**, not the Feb-deployed reference. So
H-5 is **not** counted as an "in-place repaired" finding; it is classified
SUPERSEDED and arrives at the depth-4 *architectural-replacement* bucket.

### H-7 — Reentrancy (STILL_PRESENT_REVIEWED_SAFE / SUPERSEDED · depth 0–1 · HIGH)

Production paths are guarded with `nonReentrant` or follow pull-payment CEI (see the
3-question reentrancy policy in `ADERYN_FINDINGS.md`). Some instances were
**superseded by rewrite** — the Aave pull-model (removing an external-call ordering
surface) and the incentive-module consolidation. Mocks are non-production and were
not "repaired" on principle. No new broad `nonReentrant` mass-application was done.

### L-2 — Unsafe ERC20 (DIRECTLY_REPAIRED · depth 2 · HIGH)

The deepest **in-place** repair in the current reference lineage. `SafeERC20` adopted
across token paths; `forceApprove` introduced in `BondCollector`; raw
`.transfer`/`.approve` eliminated from production code. This is a **local semantic
correction**: behaviour of token transfer changed to safe/fail-correct semantics
*inside* each existing component, without shifting custody or settlement authority.

### L-4 — Address set without checks (STILL_PRESENT_REVIEWED_SAFE · depth 1 · MEDIUM-HIGH)

Most instances are intentional sentinel/disabled-zero or design decisions and were
left unchanged (`ADERYN_FINDINGS.md` L-13: **1 of 12 repaired**). The one repaired —
`DecentralizedResolutionModule.setAdminFacet` — rejects zero with `Error. ZeroAddress`
(redundant in the facet copy because DRM routes its own selector; the DRM copy is the
authoritative repaired one), backed by `AdminFacetZeroAddress.t.sol` (2 tests).
`StakingModuleNoOp` was CODE_REMOVED.

### L-26 — State change without event (LIKELY_REPAIRED · depth 1 · HIGH)

Substantial remediation: events added across `EvidenceModuleV1`,
`AaveYieldModule` (`queue*`), `DRMAdminFacet`, `DecentralizedResolutionModule`
(`setEscrowCategory` → `EscrowCategorySet`), and `ResolverSlashingModule` setters
(declared in `ISlashingModule` where applicable). The remaining instances are accepted
INTENTIONAL per `ADERYN_FINDINGS.md`:

- `EmergencyRecoveryProposal._executeRecoveryAction` — logged by caller;
- `DecentralizedResolutionModule.prepareKlerosHandoff` — transient, consumed/deleted;
- `DecentralizedResolutionModule.decrementResolverActiveDisputes` — mirror counter;
  increment side not separately evented either.

This finding is the one place the dataset records
`external-interface-breaking-change? = true`: adding events extends the public ABI.
State-transition *behaviour* is unchanged, so `behaviour-changed?` remains false —
the distinction is recorded explicitly rather than collapsed.

---

## 5. Descriptive metrics

Computed **only after** the mapping was complete. These are unweighted descriptive
counts. No weighted security score is produced.

### 5.1 Findings by disposition

| Disposition | Count |
| --- | --- |
| DIRECTLY_REPAIRED | 7 |
| LIKELY_REPAIRED | 5 |
| SUPERSEDED | 1 |
| CODE_REMOVED | 1 |
| STILL_PRESENT_REVIEWED_SAFE | 19 |
| STILL_PRESENT_OPEN | 1 |
| FALSE_POSITIVE_OR_DETECTOR_MISMATCH | 1 |
| **Total** | **35** |

High-confidence mappings: `22`; medium-high: `3`; medium: `9`; low-medium: `1`;
low: `0`. Unresolved lineage: `0`.

### 5.2 Repair-depth distribution

Across **all 35 findings**:

| Depth | Count |
| --- | --- |
| 0 | 21 |
| 1 | 12 |
| 2 | 1 |
| 3 | 0 |
| 4 | 1 |

Across the **repaired subset** (DIRECTLY_REPAIRED + LIKELY_REPAIRED = 12):

| Depth | Count |
| --- | --- |
| 0 | 2 |
| 1 | 9 |
| 2 | 1 |
| 3 | 0 |
| 4 | 0 |

Median repair depth: **1**. Maximum repair depth: **2** (among in-place repairs).
The single depth-4 item is **H-5, SUPERSEDED** (architectural replacement), not an
in-place repair.

### 5.3 Architecture preservation

**All 12 repaired findings preserve the architecture**: every architectural-impact
boolean (custody boundary, settlement authority, privilege/governance boundary,
escrow state machine, module selection, active-escrow snapshot, storage migration,
cross-contract behaviour) is `false` across them. The only interface-level flag is
L-26's `external-interface-breaking-change? = true` (events added), which is ABI
surface, not architectural boundary.

**Unweighted provisional Architecture-Preserving Repair Rate (APRR)**, both
definitions stated explicitly:

```text
definition 1 (denominator = in-place repaired findings):
  12 architecture-preserving repaired / 12 repaired  =  100%

definition 2 (denominator = repaired + superseded-by-replacement):
  12 / 13  ≈  92%
```

Definition 1 is the primary figure; definition 2 includes H-5 (depth-4
architectural replacement in the candidate lineage) and is reported because the
denominator is genuinely ambiguous.

### 5.4 Other linkage metrics

Binding status recorded in the EDN (vocabulary: `KNOWN` / `UNKNOWN` / `NOT_APPLICABLE`):

| Binding | KNOWN | UNKNOWN | NOT_APPLICABLE |
| --- | --- | --- | --- |
| release-binding | 0 | 1 (`H-05`) | 34 |
| deployment-binding | 0 | 35 | 0 |
| chain-instance-binding | 0 | 0 | 35 |

No release, deployment, or chain-instance binding could be demonstrated for any
finding. The single `release-binding :unknown` is `H-05` (superseded via the
Sew-Next candidate lineage, whose release binding is not yet established). The
February-19 deployment's source/build/runtime provenance is unresolved, so no
repair is claimed present-or-absent in that deployment.

Findings with regression evidence include: H-2 (interface dedup tests), L-2
(SafeERC20), L-4 / 1-of-12 (`AdminFacetZeroAddress.t.sol`), L-7, L-21, L-26 (event
sweep), and H-7 (existing reentrancy suites).

---

## 6. The quality question

> What does the evidence support: A) mostly superficial repairs; B) material
> behavioural repairs but architecture overwhelmingly preserved; C) multiple
> repairs required architectural replacement; or D) insufficient evidence?

**Answer: B — Material behavioural repairs, with architecture overwhelmingly preserved.**

Reasoning:

- The repaired set (12 in-place) contains genuine **material** behavioural
  corrections: interface dedup (H-2), tree-wide `SafeERC20`/`forceApprove` (L-2,
  depth 2), broad event-observability remediation (L-26), reentrancy guards and
  pull-model rewrites (H-7). These are not merely cosmetic.
- Yet **none** of the 12 in-place repairs changed a custodial, settlement-authority,
  privilege, escrow-state-machine, module-selection, snapshot, or storage boundary.
  Task section 7 ("separate architecture preservation from behavioural
  preservation") is directly supported: timeout semantics, cancellation internals,
  resolver capacity, appeal-bond accounting, and release/finalization corrections
  are architecture-preserving despite being material.
- The only **architectural replacement** evidence (depth-4) — H-5 / BondLedger
  extraction, V1/V2 merger, incentive consolidation (H-7 partial) — lives in the
  **Sew-Next candidate lineage**, not the Feb-deployed reference, and is captured as
  SUPERSEDED rather than as an in-place repair.
- One item is genuinely **still open**: H-4 weak randomness in DRM resolver
  selection, explicitly **not** covered by the current INTENTIONAL disposition.

Distinguish the continuity axes (do not infer one from another):

| Axis | Assessment |
| --- | --- |
| Architectural continuity | **Supported** for the 12 in-place repaired findings. |
| Interface continuity | **Mostly** — L-26 added events (ABI-visible), so interface continuity is only partial. |
| Storage continuity | No storage migration flagged across repaired findings — supported. |
| Behavioural continuity | **Not** claimed — several repaired findings intentionally changed behaviour. |
| Deployment continuity | Unsupported — no deployment binding is known (all `UNKNOWN`). |

The hypothesis of architectural repairability is **supported** by the evidence,
qualified by the H-5-in-candidate-lineage caveat and the single open H-4 item.

---

## 7. Chain-instance / deployment linkage (future)

The intended eventual lineage is:

```text
historical finding / research claim
        ↓
accepted disposition
        ↓
repair commit(s)
        ↓
verification evidence
        ↓
candidate/release
        ↓
chain-instance activation, if any
```

For each finding/repair the EDN records `release-binding`, `deployment-binding`, and
`chain-instance-binding` as `KNOWN` / `UNKNOWN` / `NOT_APPLICABLE` plus the
identifier where established. In this pass no binding is invented; most are recorded
`NOT_APPLICABLE` (no chain-instance or release context applies to a historical STILL
PRESENT / disposition-only finding) and deployment binding is `UNKNOWN` for all 35.
The February-19 deployment has unresolved source/build/runtime provenance, so no
link is asserted for it.

---

## 8. Out of scope / not done

Per the task, this pass does **not**:

- add a generic `repair-lineage.v1` PRF artifact or canonical hashing;
- change researcher rewards or reputation;
- change chain-instance identity;
- put mutable changelog data into chain-instance roots;
- alter Solidity to improve the metrics;
- rewrite historical commits;
- weaken tests;
- renumber current Aderyn findings to match the old report.

---

## 9. Validation

The machine-readable EDN was parsed and validated:

```text
parse OK
findings: 35
distinct finding ids: 35
disposition counts sum to 35
depth counts sum to 35
architectural booleans internally consistent
```

Validation command (babashka EDN reader) confirmed: 35 findings, 35 distinct IDs,
disposition vocabulary in-range, depth in-range, and the single `external-interface-breaking-change? = true` on L-26 as designed. See the companion EDN for the canonical record.
