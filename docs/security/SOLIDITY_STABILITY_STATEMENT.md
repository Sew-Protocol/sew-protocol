# Sew Solidity Stability Statement

## Scope and meaning of stability

This statement describes source evolution and available assurance evidence; it is not an audit opinion and does not claim that Sew Solidity is unchanged, fully audited, or proven secure.

Here, stability is reported along separate dimensions:

- **Architectural:** whether the escrow, module, DRM, resolver, arbitration, and custody architecture remains recognisably continuous.
- **Interface:** whether externally callable contracts, selectors, events, and interfaces remain compatible; this is not asserted where a complete ABI comparison is unavailable.
- **Storage:** whether storage compatibility is preserved; this requires deployment-specific layout evidence and is not established for the February deployment.
- **Behavioral:** whether lifecycle, accounting, authority, appeal, and custody semantics are unchanged. The evidence shows material changes in these areas.
- **Deployment:** whether a source revision and runtime bytecode are proven to be deployed. The February source reference is bound, but runtime codehash/build equivalence remains unknown.
- **Assurance continuity:** whether changes are accompanied by tests, static-analysis disposition, or differential evidence.

## Historical baseline: saved Aderyn report

The archived artifact is [`docs/archived/report-before25jan.md`](../archived/report-before25jan.md), SHA-256:

```text
2f91229ef4fd64d494019740cef0cc85a7323c1c2bd050109986541eee13cd84
```

It reports 97 Solidity files and 11,680 nSLOC, with 7 high and 28 low findings. The high findings were: arbitrary `from` in `transferFrom`; duplicate contract names; ETH transfers without address checks; weak randomness; locked Ether; an incorrect ERC20 interface; and reentrancy. The low findings are preserved in the report itself, including centralization, unsafe ERC20 operations, unspecified pragma, missing events, unchecked returns, and code-quality findings.

The artifact contains no report date, Aderyn version, source commit/tree root, compiler version, optimizer configuration, deployment address, or runtime hash. Its filename is not sufficient evidence that it describes January 25 source. Therefore:

```text
SOURCE REVISION: UNKNOWN / APPROXIMATE HISTORICAL SNAPSHOT
```

The report is historical security-analysis evidence, not proof of the February 19 deployment source.

## Source evolution

The repository history demonstrates that the Solidity implementation was not unchanged. The core escrow/module/DRM architecture remained recognisably continuous, but targeted security, accounting, lifecycle, authority, cancellation, and appeal changes accumulated from May onward.

| Period / change | Solidity scope | Classification | Canonical/deployed impact | Evidence |
| --- | --- | --- | --- | --- |
| Historical Aderyn snapshot | 97 files, 11,680 nSLOC; exact source unknown | Baseline | Not bound to deployment | `report-before25jan.md` and hash above |
| `6006e723` (18 May) | Safe casts in `EscrowViewContract`; deletion/renaming of unused duplicate/default interfaces | Security hardening plus refactor/cleanup | Affected source tree; deployment impact not established | Commit message and diff |
| `1654fb15` (20 May) | Per-escrow timeout snapshots, timeout invariant, keeper authorization | Security repair / lifecycle hardening | Material timed-action semantics | Commit message and `BaseEscrow.sol` diff |
| `057ff6e9` (14 May) | Mutual split proposal/accept/cancel and pull-only settlement | Additive feature with settlement semantics | Adds an alternative settlement path | Commit message, `MutualSplit.t.sol` |
| `6f0d2146`, `48fa3e56` | Resolver-capacity correction; snapshot module address for cancellation/yield | Accounting/security repairs | Material safety behavior | Commit history |
| `54819e27` (1 Jun) | Cancellation vault/library refactor and strategy changes | Refactor with lifecycle implications | Canonical cancellation implementation changed; equivalence must be tested, not assumed | Commit diff |
| `867186d3`, `a870d4b8` | Partial release, finalization, resolver capacity/bond/liveness fixes | Security/accounting/lifecycle repairs | Material lifecycle behavior | Commit history and tests |
| `5f84818d` (31 Jul) | Atomic appeal-bond distribution from higher-round resolution; refund, payout, forfeiture accounting, authority | **Material behavioral correction** | Frozen reference behavior for later differential work | `BondBehaviourCorrection.t.sol`: 15/15; full suite reported 1459/0 |
| `49593286` (31 Jul) | `BondLedger`, V2 facade, interfaces, differential suite | Alternative/review implementation | Explicitly PRF review; not proven deployed or canonical | Commit says `PRF_REVIEW`; 10 differential cases |
| `d8cf9889`, `33cb902e` (Sep) | Versioned immutable resolution configuration, per-workflow binding, direct selection/frozen Appeal V1 surfaces | Material configuration/authority semantics and additive candidate surface | September candidate; deployment status separate/unknown | Commit diffs and regression/integration tests |
| `2533d0b0` (22 Sep) | BondLedger/facade updates and tests | Candidate/review implementation change | Does not by itself establish deployment wiring | Commit diff |
| `96600050` (23 Sep) | Address checks, events, safety fixes, and Aderyn dispositions across 17 files | Security repair/hardening | Current source candidate; not historical deployment evidence | Commit diff and current Aderyn baseline |

Comments, documentation, generated traces, and test-only changes are not treated as Solidity semantic changes. File moves or renames are treated as refactors unless the diff shows changed behavior. The history above includes both genuine repairs and material behavior changes; commit count is not used as a stability metric.

## Security-repair lineage and Aderyn findings

The saved report and current report cannot be compared by H-/L- numbers alone: detector numbering, source scope, and Aderyn versions changed. The current documented baseline is [`docs/security/ADERYN_FINDINGS.md`](ADERYN_FINDINGS.md), generated with Aderyn 0.6.8 at source revision `yqrpxzvv` / commit `96600050`, dated 2026-09-23. Its production-scope report states 111 Solidity files, 14,417 nSLOC, 7 high and 19 low findings. The checked-in tree currently contains 125 `.sol` files because the report excludes configured mock/test/generated/vendor paths.

The current high finding identities are different: `abi.encodePacked` collision, ETH transfer checks, reentrancy, storage-array/memory editing, unprotected initializer, weak randomness, and Yul `return`. The project baseline records many as intentional-safe, false-positive, or reviewed design cases and records targeted repairs such as DRM admin-facet zero-address validation and missing-event fixes. This supports the narrower claim that later work included targeted finding response and disposition. It does **not** prove that every historical finding maps one-to-one to a current finding, nor that all old findings were resolved.

Finding lineage that can be stated conservatively:

- Some historical findings were directly addressed by later repairs, including unsafe casting/overflow exposure, timeout snapshot use, authorization of timed actions, event observability, and selected address validation.
- Some findings became irrelevant through deletion, renaming, module extraction, or architecture changes, such as duplicate-name and unused-default surfaces.
- Some detector findings persist because they are reviewed intentional behavior or detector mismatches, including nonce use described as weak randomness and guarded/pull-payment external calls.
- A complete historical finding-by-finding mapping is **UNKNOWN / NOT YET BOUND** because the saved report has no source revision or Aderyn metadata.

## Sew V1 deployed reference, maintained lineage, and Sew Next candidate

The July reference commit `5f84818d` is not merely a file refactor: it corrected the appeal-bond lifecycle. Distribution became atomic with higher-round resolution, failed-appeal payout became reachable, forfeited principal became accounted, and reversal was reduced to analytics/slashing. Its reported Forge evidence is subsequent/reference evidence, not February deployment assurance.

`49593286` introduced BondLedger and a Sew-facing facade for PRF review. The commit explicitly calls it a review implementation and supplies a ten-case differential suite. The repository also contains later BondLedger updates (`2533d0b0`) and September appeal/configuration work. Their presence in the tree does not establish that they were deployed, wired into the February deployment, or canonical for the established v1.x path. The September appeal primitive should therefore be described as a candidate/review architecture unless an exact deployment manifest and runtime evidence proves otherwise.

The source-lineage model used by this statement is:

- **Sew V1 deployment source reference:** `74176ab9ae13efe1ce9e4669e306ea73a72d6058`; release tag `testnet/base-sepolia-v1` at `1904950a` has an identical Solidity tree. This is a source/release reference, not cryptographically proven runtime equivalence.
- **Sew V1 maintained/corrected lineage:** post-February fixes, features, and corrections, including the corrected appeal semantics at `5f84818df95d35edbd0a8c74565043fccd81ff15`. These must not be projected backward onto the deployment source reference.
- **Sew Next:** the successor/readability and candidate architecture beginning with the BondLedger extraction/review work and continuing through module consolidation, naming/readability cleanup, appeal/configuration work, and the extracted appeal primitive. Current JJ candidate ancestry is rooted in the September `main` line (`9a7e7013`) and related candidate work; it is not yet a deployment/canonicality claim.
The best-supported comparison boundary is synthetic rather than a single existing tag: treat `5f84818df95d35edbd0a8c74565043fccd81ff15` as the last maintained/corrected V1 reference, and `4959328684a26ebfdbd9a1c467a07e43dc27647c` as the first clearly successor-oriented BondLedger review change, merged at `f588fe022e325d27c877ab777558bcf63772a7f9`. The later September `main` ancestry (`9a7e7013`) continues that successor/readability programme. Confidence is medium: the July merge is an explicit feature/review boundary, but subsequent cleanup and candidate work was developed across multiple JJ lines rather than one cleanly named Sew Next branch.

The established reference path and the candidate path must remain separate in assurance claims:

```text
established/reference: ordinary Sew DRM appeal lifecycle and July corrected behavior
candidate/review: BondLedger-backed custody and extracted appeal primitive
```

## Test and analysis continuity

The July reference commit reports 1,459 unrestricted Forge tests passing with zero failures and 15/15 `BondBehaviourCorrection` tests. The BondLedger review commit reports ten differential semantic-equivalence cases. The repository also contains `TraceEquivalence.t.sol`, `TraceRegression.t.sol`, and later configuration/appeal integration tests.

These results are bound to the commits that introduced or report them. They must not be presented as tests run against the February deployment source. Current Aderyn evidence is likewise bound to the current candidate revision/configuration, not retroactively to deployment.

## Deployment status and unresolved provenance

The Sew V1 deployment source reference is bound. Commit `74176ab9ae13efe1ce9e4669e306ea73a72d6058` is dated 2026-02-19 and is explicitly `release: base-sepolia-testnet-v1 deployment`. Its release description identifies the 11/15 deployed V1 contracts and the deployment registry. The tag `testnet/base-sepolia-v1` points to commit `1904950a639a972a54ab5d9d9bf2cc0f97331479`, also dated 2026-02-19; that tagged commit adds only `TESTNET_DEPLOYMENT_SUMMARY.md`. A read-only Solidity diff between `74176ab9` and `1904950a` is empty, so `74176ab9` is the Sew V1 deployment source reference and the tag is a documentation-bearing release marker with an identical Solidity tree. Runtime bytecode-to-source/build equivalence remains unbound.

The later commit `8f7fa9734f715a4660fd7b8f0eaaaa381958c349` on 2026-03-05 updates deployment documentation for the February 19 addresses. It remains a documentation revision, not the source anchor.

The remaining February provenance limits are:

```text
February source reference: BOUND — 74176ab9ae13efe1ce9e4669e306ea73a72d6058
February release tag: BOUND — testnet/base-sepolia-v1 at 1904950a639a972a54ab5d9d9bf2cc0f97331479
Solidity tree difference release→tag: NONE
February runtime bytecode/codehashes: UNKNOWN / NOT YET BOUND
February compiler input and optimizer settings: UNKNOWN / NOT YET BOUND
February deployment report independently linked to runtime: UNKNOWN / NOT YET BOUND
February historical Forge/Aderyn result binding: UNKNOWN / NOT YET BOUND
```

Current `foundry.toml` uses Solidity 0.8.37, optimizer runs 200, and `via_ir = true`; the Halmos profile differs. These are current configuration facts and must not be attributed to the archived report or February deployment without build metadata.

## Conclusion

The strongest supported conclusion is:

> The core escrow/module architecture remained recognisably continuous across the period, but the Solidity implementation was not unchanged. Targeted security, accounting, lifecycle, authority, cancellation, and appeal corrections accumulated from May onward. The February V1 deployed reference is now source-bound to `74176ab9` (with the `testnet/base-sepolia-v1` tag at `1904950a` carrying an identical Solidity tree). The July appeal-bond correction is a later maintained/reference behavior change, not evidence that the February deployment already had that behavior. BondLedger and the extracted appeal primitive are separate review/candidate implementations unless deployment evidence proves they are wired into the deployed canonical path. February runtime codehash and build-input provenance remain unresolved.

Accordingly, Sew can be described as **architecturally continuous with targeted security and lifecycle evolution**, not as behaviorally unchanged or deployment-proven stable across the entire period.

## Reproducibility references

| Item | Binding |
| --- | --- |
| Historical Aderyn report | `docs/archived/report-before25jan.md`; SHA-256 `2f91229ef4fd64d494019740cef0cc85a7323c1c2bd050109986541eee13cd84`; source revision unknown |
| Current Aderyn report | `docs/archived/aderyn/report-2026-09-23-96600050.md` (retained copy of gitignored `report.md`); SHA-256 `0ccfb6715f53f3be6e2e67b55792adc0658f73890f97023a7aaa77960a639e21`; current source revision `96600050` / JJ `yqrpxzvv`; Aderyn 0.6.8; sidecar note in `docs/archived/aderyn/README.md` |
| Aderyn configuration | `aderyn.toml`; production scope excludes mocks, arbitration mocks, test, generated, and vendor paths |
| Current compiler configuration | `foundry.toml`: solc 0.8.37, optimizer runs 200, via-IR true; not historical binding |
| Sew V1 deployment source reference | Release commit `74176ab9ae13efe1ce9e4669e306ea73a72d6058`; tag `testnet/base-sepolia-v1` at `1904950a639a972a54ab5d9d9bf2cc0f97331479`; Solidity diff empty; runtime equivalence not yet bound |
| July corrected reference | `5f84818df95d35edbd0a8c74565043fccd81ff15`; `BondBehaviourCorrection` 15/15; reported full suite 1459/0 |
| July BondLedger review | `4959328684a26ebfdbd9a1c467a07e43dc27647c`; 10 differential cases; review implementation |
| September candidate examples | `d8cf9889e6ade270e95640277efc750737bd45de`, `33cb902ea269b011353fc690cff20d699f71e405`, `2533d0b02a50972e3ed2bf184b88fb224c742bb4`, `966000504ea1d6d0e0e27ea99fccaf5bdb6be999` |
| Relevant evidence | `docs/review/bond-ledger-prf-review-handoff.md`, `test/foundry/decentralized-resolution-module/BondBehaviourCorrection.t.sol`, `test/foundry/modules/BondLedgerDifferential.t.sol`, `test/foundry/TraceEquivalence.t.sol`, `test/foundry/TraceRegression.t.sol` |
| February deployment documentation | `8f7fa9734f715a4660fd7b8f0eaaaa381958c349`; later documentation of the 2026-02-19 addresses |
| Runtime codehash, compiler input, complete ABI/selector/storage comparison across eras | UNKNOWN / NOT YET BOUND |
| Recommended future refs (not created) | `v1-reference` → `74176ab9`; retain `testnet/base-sepolia-v1`; optional `v1-corrected-pre-next` → `5f84818d` if a named assurance marker is useful; Sew Next remains the successor/mainline candidate |
| Maintained-V1 → Sew Next boundary | Synthetic comparison parent: `5f84818df95d35edbd0a8c74565043fccd81ff15`; first successor/review change: `4959328684a26ebfdbd9a1c467a07e43dc27647c`, merged at `f588fe022e325d27c877ab777558bcf63772a7f9`; confidence medium |
