# Migration Inventory

This task establishes the deployable-artifact boundary only. **Nothing is moved
in this pass.** The inventory below records, for a future incremental
migration, which current deployment/governance tooling is likely to move into
the shared deployment-composition repository versus remain SEW-local.

Read with the exporter context: `sew-protocol` stays authoritative for SEW
source/compile/tests/bytecode. The shared repo will own composition,
shared-config, classification, chain/env selection, governance topology,
parameter config, execution, validation, and the deployment ledger. Repository
placement does not determine architectural ownership.

## Likely candidates to move later (deployment-composition / global-governance)

These are concerned with cross-system addresses, the deployment ledger,
environment/network validation, proposal construction across shared governance,
or generic deployment verification:

- **Deploy scripts**
  - `deploy/10_safe.ts` — guardian multisig infra
  - `deploy/16_escrow_admin_contract.ts` — shared escrow admin timelock
  - `deploy/20_gov_token.ts`, `deploy/30_timelock.ts`, `deploy/40_governor.ts`,
    `deploy/32_release_strategy.ts`, `deploy/80_cancellation_strategy.ts` —
    shared governance contracts
  - `deploy/50_timelock_wiring.ts`, `deploy/60_protocol_governance.ts`,
    `deploy/95_finalize_governance.ts` — governance role wiring/finalize
  - `deploy/90_guardian_ops.ts` — guardian + emergency recovery ops
  - `deploy/76_l2_address_registry.ts` — cross-chain address coordination
- **Config**
  - `config/governance.config.ts` — governance topology/parameters
  - `config/chains.config.ts` — chain/network configuration + validation
  - `config/deployments.registry.ts` — deployment ledger registry
- **Scripts**
  - `scripts/gov/*` — proposal construction across shared governance
  - `scripts/_lib/ledger.ts` — ledger persistence
  - `scripts/_lib/network-validation.ts` — environment/network validation
  - `scripts/export-ledger.ts`, `scripts/export-deployments.ts`,
    `scripts/query-deployments.ts` — ledger tooling
  - `scripts/validate-deployment-v1.ts` — generic deployment verification
  - `deploy-registry/` — historical deployment facts (preserved; shared repo may
    consume or reference, never reinterpret)
  - `config/deployable-allowlist.json` + `scripts/export-deployables.ts` +
    `scripts/validate-deployables.ts` + `scripts/pack-deployables.ts` +
    `scripts/_lib/deployables/*` + `deployables/` — the artifact-export boundary
    (this task); the *consumer* of this boundary lives in the shared repo.

## Likely SEW-local tooling (remains)

- **SEW contract deployment** (core escrow + yield + resolution modules)
  - `deploy/05_create2_factory.ts`, `deploy/14_module_management.ts`,
    `deploy/15_yield_dispute_ops.ts`, `deploy/70_core_escrow.ts`,
    `deploy/75_aave_yield_module.ts`, `deploy/85_dr3_modules.ts`,
    `deploy/86_decentralized_resolution_module.ts`
  - Note: `deploy/15_yield_dispute_ops.ts` still references `YieldOps`, which is
    **not** in the current source and is excluded from the export allow-list.
    This is a SEW-local cleanup/debt item, not an export blocker.
- **SEW-specific test journeys / scenarios / diagnostics**
  - `test/foundry/**`, `scripts/run-core-tests.sh`, `scripts/test-core-modules.sh`,
    `scripts/coverage-summary.sh`, `scripts/filter-coverage.js`,
    `scripts/monitoring/**`, `config/differential-setup.json`,
    contract-specific operational diagnostics and escrow/yield/resolution
    scenario tests.

## Boundaries that must not move

- `contracts/**` (SEW source), `out/`, `out-halmos/`, foundry/hardhat build
  config, and the forge/halmos test suites stay here — `sew-protocol` remains
  authoritative for SEW bytecode.
- Historical deployment records in `deploy-registry/` are historical facts and
  must not be reinterpreted or overwritten.

## Decision rule

Move tooling only when it is deployment-composition/global-governance oriented
and generic enough to serve PRF + SEW + shared. Keep anything that is
SEW-contract-specific, SEW-test-journey-specific, or that could change SEW
bytecode. When in doubt, keep it SEW-local and expose only the deployable
artifact bundle (this task) as the boundary.
