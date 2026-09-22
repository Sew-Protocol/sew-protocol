# Contract Cleanup Safety Envelope

**Status:** baseline recorded before structural cleanup  
**Date:** 2026-09-21  
**Purpose:** define the accepted implementation and validation evidence that must remain behaviorally equivalent during library/module cleanup.

## 1. Evidence classification

- **Fresh:** command was run in this checkout and output was observed.
- **Documented:** recorded in repository documentation but not independently reproduced here.
- **Unavailable:** required source, manifest, tool, or deployment evidence is absent.
- **Blocked:** command exists but currently fails, times out, or is incompatible with the installed toolchain.

This checkout has no `.git` metadata. Historical commit IDs in the review documents cannot be independently verified here.

## 2. Accepted active implementation

### Deployment topology from source

The active deployment path is defined by:

- `deploy/85_dr3_modules.ts`
- `deploy/86_decentralized_resolution_module.ts`
- `deploy/70_core_escrow.ts`
- `deploy/30_timelock.ts`
- `deploy/50_timelock_wiring.ts`
- `deploy/60_protocol_governance.ts`

`deploy/85_dr3_modules.ts` deploys and wires:

- `ResolverStakingModuleV1`
- `ResolverSlashingModuleV1`
- `BondTokenRegistry`
- `DRMAdminFacet`
- `PaymentCalculationLibraryV1`
- `ResolverIncentiveModuleV2`

`deploy/86_decentralized_resolution_module.ts` then:

- deploys `DecentralizedResolutionModule`;
- sets `BondTokenRegistry`;
- sets the incentive module to `ResolverIncentiveModuleV2`;
- registers `EscrowVault`;
- grants governance roles.

**Accepted topology:**

```text
EscrowVault
  -> DecentralizedResolutionModule
      -> ResolverIncentiveModuleV2
          -> PaymentCalculationLibraryV1
      -> BondTokenRegistry
      -> ResolverStakingModuleV1
      -> ResolverSlashingModuleV1
```

`ResolverIncentiveModuleV2BondLedger` is not selected by the deployment scripts.

The BondLedger review topology is retained as a separate review artifact:

- `docs/review/bond-ledger-review-topology.json`
- `docs/review/bond-ledger-prf-review-handoff.md`

It must not be treated as proof of active production deployment without a network-specific deployment manifest or on-chain verification.

### Active resolution and incentive implementations

- Active resolution module: `contracts/modules/decentralized-resolution-module/DecentralizedResolutionModule.sol`
- Active incentive implementation: `contracts/modules/decentralized-resolution-module/incentive/ResolverIncentiveModuleV2.sol`
- V2 base implementation: `ResolverIncentiveModuleV1.sol`
- BondLedger alternative/review facade: `ResolverIncentiveModuleV2BondLedger.sol`
- BondLedger primitive: `contracts/shared/BondLedger.sol`

## 3. Fresh bytecode-size baseline

Measured with `forge inspect ... deployedBytecode` after compiling with Solidity `0.8.37`:

| Contract | Runtime bytes | EIP-170 24,576-byte limit |
|---|---:|---:|
| `BaseEscrow` | abstract/no runtime bytecode | n/a |
| `EscrowVault` | 38,217 | over by 13,641 |
| `EscrowableERC20` | 41,597 | over by 17,021 |
| `DecentralizedResolutionModule` | 32,275 | over by 7,699 |
| `ResolverIncentiveModuleV1` | 15,141 | under |
| `ResolverIncentiveModuleV2` | 20,393 | under |
| `ResolverIncentiveModuleV2BondLedger` | 25,526 | over by 950 |
| `BondLedger` | 7,555 | under |

The existing `pnpm size:check` gate is currently **blocked** by an unrelated TypeScript error in `scripts/print-contract-sizes.ts`:

```text
TS1117: An object literal cannot have multiple properties with the same name.
```

The duplicate property is `overLimit` at line 108. Hardhat compilation itself completed and independently reported:

- `EscrowableERC20Factory`: 43,631 bytes
- `DecentralizedResolutionModule`: 32,024 bytes
- `ResolverIncentiveModuleV2BondLedger`: 25,283 bytes

Those Hardhat and Forge sizes differ because they are produced by different artifact/build paths; the Forge values above are the cleanup baseline.

**Do not change size-related structure until the size tool is repaired or replaced with a reproducible measurement command.**

## 4. Gas baseline

A fresh complete gas report was **not obtained**:

```bash
forge test --gas-report
```

was still compiling/running when the 10-minute bound was reached.

Trace-equivalence tests did emit per-test gas values. These are behavioral replay gas observations, not a complete gas baseline. Examples:

- inline create/release: `590617`–`756688`
- inline dispute paths: approximately `635995`–`882373`
- v2 replay cases: approximately `1149427`–`16399567`

A complete gas report is a required pre/post-cleanup artifact. Run it separately after the cleanup baseline is stabilized and save the output, rather than relying on terminal output.

## 5. Solidity validation baseline

### Full Foundry suite

Command:

```bash
forge test -vvv
```

**Status:** blocked by the 10-minute execution bound in this session. Compilation completed in earlier attempts, but the complete suite result was not observed. Historical documentation reports passing suites, but that is not fresh evidence.

### Invariant suites

Command:

```bash
forge test --match-path 'test/foundry/invariants/*.t.sol' -vvv
```

**Fresh partial result:**

- `StateInvariants.invariant_fees_monotone`: PASS, 256 runs, 128,000 calls, 0 reverts.
- `ResolverInvariants.invariant_resolver_exclusivity`: PASS, 256 runs, 128,000 calls, 0 reverts.

The command reached the 10-minute bound before the complete invariant directory result was observed. Do not label the entire invariant suite as passing from this partial output.

### Trace equivalence

Command:

```bash
forge test --match-path test/foundry/TraceEquivalence.t.sol -vvv
```

**Fresh result:** 38 passed, 0 failed, 0 skipped.

This included:

- legacy create/release/dispute traces;
- Phase Z liveness trace;
- v2 lifecycle and settlement traces;
- negative/adversarial semantic fixtures;
- version and invariant-profile fail-closed checks.

This is the strongest fresh behavior-preservation evidence currently available.

### Trace regression

Command:

```bash
forge test --match-path test/foundry/TraceRegression.t.sol -vvv
```

**Fresh result:** 1 passed, 0 failed, 0 skipped, but the test logged:

```text
TraceRegressionTest: no regression fixtures yet - skipping
```

`test/foundry/traces/regression/manifest.json` currently contains an empty fixture list. This is a passing harness, not a meaningful regression-corpus result.

## 6. Halmos/formal baseline

Configured commands from `package.json`:

```bash
pnpm test:halmos:smoke
pnpm test:formal:smoke
```

Fresh Halmos status:

```text
BLOCKED: installed Halmos CLI rejects the configured `--profile halmos` usage.
The command reports: unrecognized arguments: halmos
```

The source configuration is in `foundry.toml` under `[profile.halmos]`. Existing `out-halmos/` artifacts are generated outputs and should not be treated as current proof evidence; repository inspection found metadata generated with Solidity `0.8.33`, while current source configuration is `0.8.37`.

Applicable formal source:

- `test/foundry/halmos/HalmosEscrowProperties.t.sol`
- `test/foundry/invariants/*.t.sol`
- `certora/` configuration and rules, where applicable

Historical documentation claims five Halmos checks pass, but no fresh Halmos result is accepted until the CLI invocation is repaired and outputs are regenerated.

## 7. PRF and adversarial evidence

### PRF DR scenario set

The documented set is in `docs/review/bond-ledger-prf-review-handoff.md`:

- `DR-C-001` — sybil scaling / escalation economics
- `DR-C-002` — slash appeal-bond lifecycle
- `DR-C-003` — appeal-bond refund on reversal
- `DR-C-004` — appeal-bond resolver payout
- `DR-C-005` — appeal-bond forfeiture reserve
- `DR-C-006` — distribution-failure atomicity
- `DR-N-002` — escalation-bond return

The handoff records all as PASS, and reports:

- DR-C-001: 10 steps, 0 reverts
- DR-C-002: 7 steps, 4 expected reverts
- DR-C-003: 6 steps, 0 reverts
- DR-C-004: 6 steps, 0 reverts
- DR-C-005: 4 steps, 0 reverts
- DR-C-006: 5 steps, 0 reverts
- DR-N-002: 8 steps, 0 reverts

**Status:** documented only. The Clojure simulation tree, EDN scenario fixtures, and PRF evidence bundle are absent from this checkout. These results cannot be freshly reproduced here.

### Adversarial Solidity scenarios

Fresh trace-equivalence evidence covers:

- wrong outcome;
- unauthorized resolver;
- unexecuted settlement;
- wrong escalation level;
- wrong dispute initiator;
- invalid auto-cancel timing;
- wrong resolution actor;
- same-block resolution ordering;
- appeal failure cascade;
- terminal-state escalation attempts;
- pending-settlement expiry and illegal release attempts.

All 38 replay tests passed.

## 8. Clojure ↔ Solidity correspondence

The correspondence machinery is present in:

- `test/foundry/TraceEquivalence.t.sol`
- `test/foundry/TraceRegression.t.sol`
- `test/foundry/TraceEquivalenceDemo.t.sol`
- `test/foundry/traces/README.md`
- `test/foundry/traces/schema/trace-fixture.v1.schema.json`
- `test/foundry/traces/v2/*.json`

The Clojure exporter and model are referenced as:

- `sew-simulation/src/resolver_sim/io/trace_export.clj`
- `sew-simulation/test/resolver_sim/contract_model/properties_test.clj`

They are not present locally. Therefore the fresh claim is limited to **Solidity replay against checked-in canonical fixtures**, not a newly executed Clojure-to-Solidity export/equivalence run.

The trace machinery does enforce correspondence-style properties including:

- escrow state;
- amount after fee;
- held and fee totals;
- pending-settlement existence;
- dispute level;
- state transitions;
- resolution actor/outcome;
- schema/CDRS negotiation;
- invariant-profile resolution and application.

## 9. Canonical/reference vectors

Accepted checked-in reference material includes:

- `test/foundry/traces/v2/*.json`
- `test/foundry/traces/schema/trace-fixture.v1.schema.json`
- `test/foundry/traces/regression/manifest.json`
- `test/foundry/halmos/seeds.json`
- `config/differential-setup.json`
- `broadcast/DifferentialSetup.s.sol/31337/run-latest.json`
- `docs/review/bond-ledger-review-topology.json`

The v2 invariant profile recorded by the fixtures is:

```text
id:      solidity-equivalence-core-v1
version: 1
root:    31d07038dcde86ac6f34b229fded0fce98b679c2bd83130b607f0b9a2a27e19f
```

Known fixture limitations are documented in `TraceEquivalence.t.sol`; some fixtures require regeneration or modules not deployed in the basic harness.

## 10. Dependency/reference inventory

Before structural edits, inventory references across these categories:

### Production contracts

- `contracts/core/`
- `contracts/modules/`
- `contracts/libraries/`
- `contracts/shared/`
- `contracts/interfaces/`
- `contracts/types/`
- `contracts/ops/`
- `contracts/governance/`

### Tests

- `test/foundry/core/`
- `test/foundry/decentralized-resolution-module/`
- `test/foundry/modules/`
- `test/foundry/invariants/`
- `test/foundry/halmos/`
- `test/foundry/traces/`

### Deployment and manifests

- `deploy/*.ts`
- `config/deployments.registry.ts`
- `config/differential-setup.json`
- `broadcast/`
- `deployments/` if generated for a target network
- `deploy-registry/`

### Scripts and gates

- `scripts/print-contract-sizes.ts`
- `scripts/check-bondledger-size.sh`
- `scripts/check-foundry-deps.sh`
- `scripts/test-core-modules.sh`
- `scripts/print-contract-sizes.ts`
- `package.json`
- `Makefile`
- `foundry.toml`
- `hardhat.config.ts`

### Documentation and external-model references

- `docs/review/bond-ledger-prf-review-handoff.md`
- `docs/review/bond-ledger-review-topology.json`
- `docs/CODEBASE_NEATENING_TASKS.md`
- `docs/CHANGELOG.md`
- `docs/architecture/`
- `docs/dispute-resolution/`
- `docs/optimization/`
- `docs/security/`
- `test/foundry/traces/README.md`

### Generated outputs

- `artifacts/`
- `out/`
- `out-halmos/`
- `cache/`
- `cache-foundry/`
- `typechain-types/`
- `broadcast/`

Generated outputs are not authoritative source. After structural cleanup they must be regenerated from source; do not manually path-edit or hand-maintain them.

## 11. BondLedger canonicalization gate

The BondLedger primitive surface is frozen pending the final PRF comparison. No further primitive design changes are authorized unless the comparison exposes a concrete semantic mismatch.

### Frozen custody contract

```text
open position
  -> exact custody
  -> operator-bound authority
  -> one terminal settlement
       -> complete principal allocation
       -> typed disposition
       -> nonzero authoritative cause root
       -> canonical realized distribution
  -> one-time claims
```

The supported ERC20 domain requires exact receipt of the declared principal. Fee-on-transfer and transfer-time rebasing assets are unsupported; BondLedger's exact-receipt check is intentional.

### Frozen semantic projection

The final PRF comparison must run identical canonical scenario inputs against the corrected embedded V2 reference and the BondLedger-backed candidate, then normalize both results to:

- scenario identity;
- admitted/rejected transition and resulting DRM state/round;
- authority;
- bond obligation, asset, principal, payer, and funder semantics;
- refund, resolver-payout, or forfeiture disposition;
- realized `recipient -> total amount` distribution;
- claimable and claimed amounts by recipient;
- disposition cause class and authoritative cause identity/root;
- principal/refund/payout/forfeiture accounting and conservation;
- terminal status.

The comparison must require equality of both admitted and rejected transitions. It must ignore contract addresses, storage layout, event emitters, internal call topology, physical custody location, and pre-normalization allocation ordering.

The preserved evidence artifact must record reference and candidate identities, corpus/projection roots and versions, scenario counts, admitted/rejected counts, result roots, and semantic mismatch count. The gate closes only with zero mismatches.

### Bounded DRM allocation invariant

A valid DRM resolver payout cannot exceed `BondLedger.MAX_ALLOCATIONS`:

```text
eligible payout rows <= unique recorded resolvers
                     <= MAX_RESOLVERS_PER_DISPUTE
                     = 50
                     = BondLedger.MAX_ALLOCATIONS
```

The facade sorts allocations before settlement; resolver identity uniqueness prevents duplicate payout rows.

### PRF model-enrichment gate before projection

The PRF appeal-bond projection must remain blocked until the authoritative Sew model can reconstruct one complete scenario bond-by-bond without inference from aggregate totals.

Authoritative bond records must distinguish:

```text
bond/posted-amount   = gross amount
bond/posting-fee     = posting fee
bond/custodied-amount = gross amount - posting fee
```

The accounting layers are separate:

```text
posted amount = posting fee + custodied amount
custodied amount = terminal allocations + remaining bond custody
```

Failed operations must remain outside protocol world-state mutation. Transition evidence may record:

- operation identity;
- applied/reverted status;
- pre domain-state root;
- post domain-state root;
- pre/post appeal-bond-state roots.

A reverted operation is valid only when its canonical appeal-bond substate root is unchanged. A failure receipt must not be appended to the reverted protocol world merely to make the failure observable.

Bond disposition and claiming are distinct lifecycle stages:

```text
bond/status: open -> disposed

one terminal disposition
    -> allocations / entitlement
    -> claimable balances
    -> claimed balances
```

A disposed bond remains claimable until its allocations are fully claimed. Reconciliation must compare allocated entitlement with `claimable + claimed`, not allocation directly with current claimable balances.

For every bond, local conservation must hold before any aggregate reconciliation:

```text
custodied amount
  = terminal allocation total
  + remaining bond custody
```

Lifecycle constraints are explicit:

```text
open bond:
  terminal allocation total = 0
  remaining bond custody = custodied amount
  terminal disposition count = 0

disposed ordinary appeal bond:
  terminal disposition count = 1
  terminal allocation total = custodied amount
  remaining bond custody = 0

disposed bond with an explicit retained-remainder policy:
  terminal allocation total + remaining bond custody = custodied amount
```

For every recipient and asset:

```text
allocated entitlement = currently claimable + already claimed
```

Claims consume entitlement only; they do not alter the historical terminal disposition or its allocation/cause record. A failed operation changes none of the obligation, custody, disposition, or entitlement state.

Appeal identity must preserve the appealed ordinal and both escalation levels. The exact semantics must be explicit, for example:

```text
appeal/ordinal
escalation/from-level
escalation/to-level
```

A bond identity must be derived from stable lineage such as workflow, dispute, appeal ordinal, and posting-operation identity. Payer, asset, and amount are committed content, not identity substitutes.

Before `appeal_bond_projection.clj` is implemented, the enrichment must demonstrate:

- every posted bond has one unique identity;
- posted amount, fee, and custodied amount reconcile;
- every successful terminal action identifies its exact bond;
- every terminal allocation is preserved by recipient;
- every disposition has mandatory cause type and nonzero cause root;
- reverted operations leave the appeal-bond-state root unchanged;
- aggregate accounting fields reconcile independently against the authoritative records.

The aggregate fields remain reconciliation surfaces, not reconstruction sources:

```text
Σ posted amounts       ↔ total-bonds-posted
Σ posting fees         ↔ bond-fees
Σ open custody         ↔ bond-balances / held accounting
Σ refund entitlement   ↔ claimable + claimed bond refunds
Σ distributions        ↔ appeal-bond-distributions-by-token
Σ forfeitures          ↔ appeal-bonds-forfeited-insurance
```

### Deployment gate after PRF

Only after the semantic gate passes may the source architecture become:

```text
DecentralizedResolutionModule
  -> ResolverIncentiveModule
      -> BondLedger
```

The already-deployed embedded V2 remains historical on-chain code for existing snapshotted escrows and is not a future source-tree alternative.

## 12. Cleanup acceptance criteria

A structural cleanup is accepted only if all applicable conditions hold:

1. Deployment scripts still resolve the same active resolution and incentive implementations, unless the migration is explicit.
2. Runtime bytecode sizes are measured with the same compiler/profile and recorded before and after.
3. A complete gas report is captured before and after.
4. Full Foundry tests pass.
5. All relevant invariant/fuzz suites pass, with run/call/revert counts recorded.
6. Trace-equivalence tests pass against the same canonical fixture set.
7. The adversarial negative fixtures produce the same expected rejection/outcome.
8. PRF DR scenarios are rerun, or their absence is explicitly recorded as a release blocker.
9. Clojure↔Solidity trace export/equivalence is rerun when the Clojure tree is available.
10. Halmos/formal checks are rerun with regenerated outputs under the current compiler.
11. Canonical/reference vectors and invariant-profile roots are unchanged unless a deliberate protocol change is approved.
12. All production, test, script, deployment, documentation, PRF, fixture, and generated-artifact references are updated consistently.

The key invariant is therefore:

> same modeled protocol behavior, same adversarial outcomes, and same Solidity/model correspondence — not merely “tests still pass.”
