# PRF Review Handoff — Appeal-Bond Behaviour Correction + BondLedger Custody Extraction

Status: **READY FOR REVIEW**
Date: 2026-07-31
Scope: appeal-bond lifecycle in Sew's decentralized-resolution incentive module

## 1. Why the appeal-bond behaviour changed

PRF-based review and targeted testing of Sew's appeal-bond lifecycle identified
three material defects in the existing implementation:

| Defect | Observation |
|--------|-------------|
| D1 | `DecentralizedResolutionModule.recordReversal` called `incentiveModule.distributeAppealBond(..., true)` inside a `try/catch`; the resolution module was not an authorised caller, so the refund path was a **silent no-op**. |
| D2 | `distributeAppealBond(..., false)` (failed-appeal resolver payout) existed but was **unreachable** from any production path. |
| D3 | `forfeitAppealBond` and `onDisputeFinalized` marked principal forfeited **without any liability destination**; the tokens stayed in the module with no accounting or withdrawal path. |

A fourth issue surfaced during the fix:

| D5 | `ResolverIncentiveModuleV1.onResolverAssigned` was `onlyEscrowContract`; the resolution module could not record resolver cohorts through the production path, so a reachable failed-appeal payout could operate against an empty/incomplete resolver set. |

## 2. Corrected normative behaviour

Frozen in commit `5f84818` (`REFERENCE_BEHAVIOUR`):

- `recordResolution` distributes the appeal bond **atomically** for every
  higher-round decision:
  - decision flips prior round  → `distributeAppealBond(priorRound, true)`  → refund to escalator;
  - decision matches prior round → `distributeAppealBond(priorRound, false)` → equal payout to prior-round resolvers.
  - A distribution failure **reverts the entire resolution** (no `try/catch` swallow).
- `recordReversal` is reduced to reversal analytics + automated slashing; bond
  distribution is owned by `recordResolution`.
- `onResolverAssigned` (and `distributeAppealBond` / `onDisputeFinalized`) accept
  a registered escrow **or** the configured `resolutionModule` (set via
  `setResolutionModule`, `ROLE_TIMELOCK`).
- Forfeited principal is tracked in `forfeitedBondReserve`; the reserve is
  accounted but has **no withdrawal authority in this phase** (distribution is a
  separate post-review economic decision).

## 3. Why BondLedger was extracted

Custody and settlement were separated from Sew's appeal logic into a narrow,
reusable primitive so that:

- custody is a separately testable/auditable component;
- the frozen corrected Sew semantics remain the semantic reference;
- the primitive is reusable by other applications without adopting Sew.

**Sew-specific (kept out of the primitive):** appeal eligibility, escalation
economics / cost curves, outcome determination, resolver selection, protocol
fees, excess ETH refunds, metrics, legacy events.

**Reusable (in the primitive):** principal custody (ETH/ERC20), exact one-time
settlement via bounded allocation lists, pull-based claims, recipient
claimables, forfeited reserve, authority separation, conservation.

## 4. What remained behaviourally invariant

A 10-case differential suite compares the corrected embedded implementation
(`REFERENCE_BEHAVIOUR`) against the BondLedger-backed implementation
(`PRF_REVIEW`) and asserts the semantic projection is identical:

| Case | Compared |
|------|----------|
| Successful appeal | refund amount, claimant, metrics |
| Failed appeal | resolver set, exact allocations, claims |
| Odd resolver split | same remainder recipient, conservation |
| Explicit forfeiture | reserve amount |
| Finalisation cleanup | reserve amount |
| ETH bond | custody + refund + ETH claim |
| ERC-20 bond | custody + outcome |
| Fee-bearing bond | net principal after fee |
| Double resolution | same rejection / idempotency |
| Invalid authority | same intended rejection |

Architectural differences (which contract holds funds, emitter addresses,
internal call topology) are deliberately ignored.

## 5. Reference commits

```
4959328  feat: extract appeal-bond custody into BondLedger primitive (PRF_REVIEW)
5f84818  fix: correct appeal-bond lifecycle before BondLedger custody extraction (REFERENCE_BEHAVIOUR)
```

`REFERENCE_BEHAVIOUR_COMMIT` = corrected pre-BondLedger semantics.
`PRF_REVIEW_COMMIT` = BondLedger-backed implementation submitted for review.

## 6. New PRF scenarios (all executed, all PASS)

| Scenario | Purpose | Result |
|----------|---------|--------|
| DR-C-003 appeal-bond-refund-on-reversal | reversal → refund | PASS (6 steps, 0 reverts) |
| DR-C-004 appeal-bond-resolver-payout | failed appeal → resolver allocation | PASS (6 steps, 0 reverts) |
| DR-C-005 appeal-bond-forfeit-reserve | forfeiture → reserve accounting | PASS (4 steps, 0 reverts) |
| DR-C-006 appeal-bond-distribution-failure-atomic | settlement atomicity | PASS (5 steps, 0 reverts) |
| DR-C-001 sybil scaling (existing) | escalation economics | PASS (10 steps, 0 reverts) |
| DR-C-002 slash-appeal-bond-lifecycle (existing) | slash appeal bond | PASS (7 steps, 4 reverts) |
| DR-N-002 escalation-bond-return (existing) | bond return | PASS (8 steps, 0 reverts) |

Run: `bb run:scenario scenarios/edn/<ID>.edn --report-format summary`

## 7. Unrestricted Solidity test results

Command: `forge test -vvv` (fuzz + invariants included)

**147 test suites, 1459 passed, 0 failed, 14 skipped.**

Breakdown (approximate, from captured per-suite lines):
unit/integration ~1285, fuzz ~19 (256 runs each), invariant ~119, remainder in
uncaptured suite lines. Aggregate is authoritative.

Bond-specific suites pass in isolation (e.g. `BondRounding` 5/5,
`AppealBondRecording` 10/10, `BondLedger` unit 17/17, differential 10/10).

## 8. Known skips (14)

All skips are environmental (fork / deployment-artifact / network dependent),
not logic failures, and none exercise the changed appeal-bond/BondLedger
behaviour:

| Skip | Suite | Reason |
|------|-------|--------|
| setUp ×1 | migrated/03_BoundsEnforcement | environment |
| setUp ×1 | AaveYieldModuleFailureModeTest | environment |
| setUp ×2 | EscrowStateMachineTest | environment |
| setUp ×1 | AaveYieldModuleIntegrationTest | environment |
| setUp ×1 | AaveYieldModuleLifecycleTest | environment |
| setUp ×2 | BondRounding.unit | environment (passes 5/5 in isolation) |
| setUp ×1 | GovGovernorTest | environment |
| setUp ×1 | PartialReleaseTest | environment |
| setUp ×1 | AppealBondRecording.unit | missing base-sepolia deployment artifacts (passes 10/10 in isolation) |
| test_recovery_accounting | EscrowVaultAccountingTest | network/artifact |
| test_PauseUnpause_AccessControl | EscrowLifecycleTest | network/artifact |

## 9. PRF reporting serialization quirk (FIXED)

Previously some scenarios semantically passed and emitted evidence while the
outer wrapper reported `Command status: failed / Scenario outcome: unknown`
due to `Cannot encode unsupported type` (a `LazySeq` in claim results reaching
`canonical-bytes`).

**Fixed** in `protocol-robustness-framework`
`src/resolver_sim/commands/scenario_orchestration.clj`: `persisted-value` now
normalises sequence types (`clojure.lang.ISeq`) to vectors before hashing.
Verified: all DR-C-001..006 and DR-N-002 now report `Command status: completed
/ Scenario outcome: pass`. The fix only affects previously-failing
serialization; no valid evidence depended on the old behaviour. PRF test
results are unchanged by the fix (15 failures + 1 error pre-existing both
before and after, unrelated to this change).

## 10. Evidence and verification commands

Topology manifest (content-addressed):
`docs/review/bond-ledger-review-topology.json`
sha256 `dbb6087b5e43c6c2073051e4ffaa5ca7d904a7bb614b679922e7520ba3414502`

```bash
# Solidity release gate (unrestricted)
forge test -vvv

# Differential semantic equivalence
forge test --match-contract BondLedgerDifferential -vvv

# BondLedger primitive unit tests
forge test --match-contract BondLedgerTest -vvv

# Behavioural regression suite
forge test --match-contract BondBehaviourCorrection -vvv

# Source commitments
sha256sum contracts/shared/BondLedger.sol \
  contracts/shared/interfaces/IBondLedger.sol \
  contracts/modules/decentralized-resolution-module/ResolverIncentiveModuleV2BondLedger.sol \
  contracts/modules/decentralized-resolution-module/ResolverIncentiveModuleV2.sol \
  contracts/modules/decentralized-resolution-module/DecentralizedResolutionModule.sol \
  contracts/modules/decentralized-resolution-module/ResolverIncentiveModuleV1.sol

# Bytecode commitments
forge inspect contracts/shared/BondLedger.sol:BondLedger bytecode | sha256sum
forge inspect contracts/modules/decentralized-resolution-module/ResolverIncentiveModuleV2BondLedger.sol:ResolverIncentiveModuleV2BondLedger bytecode | sha256sum

# Contract size gate (frozen sizes, explicit-approval policy)
scripts/check-bondledger-size.sh
pnpm size:check

# PRF scenario execution
bb run:scenario scenarios/edn/DR-C-003-appeal-bond-refund-on-reversal.edn --report-format summary
# ... DR-C-004, DR-C-005, DR-C-006, plus existing DR-C-001/002, DR-N-002

# PRF evidence bundle
bb benchmark:export <evidence-path> <output.tar.gz>
bb benchmark:verify <evidence-path>
```

## 11. Scope limitation

BondLedger is **reusable but validated here against Sew only**. It is not
claimed as a universally audited primitive. Its interface and conservation
properties (posted = pending + settled claimant liabilities + forfeited
reserve) are generic, but a second non-Sew application is required before
promoting it to a general developer primitive.

## 12. Review narrative

> During PRF-based review of Sew's appeal-bond lifecycle, testing identified
> broken refund routing, an unreachable failed-appeal payout path, and
> unaccounted forfeited principal. Those behaviours were corrected and made
> explicit. The corrected implementation was then used as the semantic
> reference for extracting custody and settlement into BondLedger, a narrowly
> reusable primitive. A 10-case differential suite confirms the extraction
> leaves the corrected Sew semantics unchanged.
