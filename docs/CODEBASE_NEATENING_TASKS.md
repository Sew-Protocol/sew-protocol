# Codebase Neatening Tasks

This is a cleanup backlog for the post-feature-freeze pass. It deliberately does
not treat currently changing or temporarily broken contracts as defects. Re-run
the review after the active contract work has settled.

## P0: Compiler and release baseline

- [ ] Upgrade the Solidity baseline from `0.8.33` to `0.8.38` once the compiler is available and compatible with the dependency/toolchain versions.
- [ ] Update every project compiler setting together: `foundry.toml`, Hardhat configuration, CI, compiler-settings tests, deployment metadata, and release documentation.
- [ ] Decide and document the pragma policy: exact pin, compatible range, or exact pin for production contracts with a separate range for tests/mocks.
- [ ] Remove the remaining mixed pragmas (`0.8.20`, `0.8.28`, `0.8.33`) where there is no deliberate compatibility reason, including examples, mocks, interfaces, and helper contracts.
- [ ] Rebuild all artifacts and regenerate TypeChain output after the compiler upgrade; do not use checked-in artifacts from the previous compiler.
- [ ] Re-run unit, integration, invariant, fork, Halmos, formal, coverage, deployment, verification, and contract-size checks under the new compiler.
- [ ] Record bytecode and storage-layout changes and obtain an explicit release decision for every upgradeable or already-deployed contract.
- [ ] Update the deployment registry and compiler metadata so source verification matches the actual release build.

## P0: Remove obsolete 24 KB workarounds

The current code contains a large architecture built around EIP-170 contract
size pressure: extracted `*Library` and `*Ops` contracts, delegatecall paths,
facades, assembly getters, pause stubs, frozen-size gates, and comments such as
“extracted to reduce contract size”. After the relevant Ethereum upgrade and
target-chain support are confirmed, review these as one coordinated migration,
not as isolated cleanup.

- [ ] Confirm the actual network activation, client support, and deployment policy for the increased contract-size limit before removing any workaround.
- [ ] Produce a before/after size and gas report for `BaseEscrow`, `EscrowVault`, `EscrowableERC20`, `DecentralizedResolutionModule`, `ResolverIncentiveModuleV2`, and `ResolverIncentiveModuleV2BondLedger`.
- [ ] Identify which libraries and `*Ops` contracts exist only because of size pressure; candidates include `StateManagementLibrary`, `ModuleSnapshotLibrary`, `FeeRecordingLibrary`, `ModuleManagementLibrary`, `AaveYieldHandlingLibrary`, `YieldDistributionLibrary`, `RecoveryLibrary`, `YieldHandlingLibrary`, `ResolverLogicLibrary`, `EscrowEncodingLibrary`, `DisputeRaiseLibrary`, `DisputeEscalationLibrary`, `ResolverActionLibrary`, `ModuleProposalLibrary`, `BalanceUpdateLibrary`, `TokenRecoveryLibrary`, `FeeWithdrawalLibrary`, `CreateOps`, `SettlementOps`, `DisputeOps`, and `BondCollector`.
- [ ] Inline or regroup size-only logic into the owning contracts where this improves readability, auditability, and call-path transparency.
- [ ] Replace size-only `delegatecall` and library-address wiring with direct internal calls where safe; retain delegatecall only where it is a deliberate, documented upgrade or isolation boundary.
- [ ] Remove size-only assembly/storage-slot helpers after proving equivalent storage access with ordinary Solidity; retain assembly only with a measured safety or gas benefit.
- [ ] Revisit the pause-function removal and compatibility stubs in `BaseEscrow`; either restore a real production control or remove the dead surface and update interfaces/tests/docs.
- [ ] Remove the BondLedger “frozen size” policy, historical commit reference, and special-case gate once the size constraint is no longer a release constraint.
- [ ] Simplify `scripts/print-contract-sizes.ts` and CI so it reports useful deployment telemetry rather than enforcing obsolete EIP-170/frozen-size rules.
- [ ] Remove size-optimization language from source comments, changelog entries, and phase documents, replacing it with the current architectural rationale where one remains.
- [ ] Re-audit storage layout, reentrancy, authorization, error bubbling, event ordering, gas usage, and upgrade/deployment behavior after each library-to-internal-code migration.

## P1: Comment and documentation cleanup

- [ ] Remove comments that merely restate the following line, parameter name, type, or obvious control flow.
- [ ] Remove stale implementation-history comments such as `Phase 1`, `Phase 2`, `Phase 3`, `Priority 2`, and task-number references from production Solidity.
- [ ] Remove obsolete “temporary”, “future”, “will be handled”, and “before deployment” notes; convert any still-valid item into a tracked issue or explicit invariant.
- [ ] Remove comments describing removed pause behavior, removed auto-transfer behavior, compatibility shims, and old size limits after the corresponding code is settled.
- [ ] Preserve and improve only comments that explain externally observable behavior, security assumptions, storage invariants, delegatecall context, rounding, lifecycle constraints, or non-obvious protocol economics.
- [ ] Normalize NatSpec on all public/external contracts and interfaces: consistent `@title`, `@notice`, `@dev`, `@param`, `@return`, and event documentation.
- [ ] Remove stale “production ready”, “complete”, and phase-delivery claims from docs unless they are backed by the current release checklist and test evidence.
- [ ] Resolve the outstanding TODO in `test/foundry/token/ERC20EdgeCases.t.sol` or turn it into a tracked test task with an owner and acceptance criteria.
- [ ] Review changelog and phase-delivery documents for duplicated, contradictory, or historical material that should be archived rather than presented as current guidance.

## P1: Naming and repository consistency

- [ ] Rename the package from `hardhat-deploy-hybrid` if that is no longer the product/repository name, or document why the historical name is retained.
- [ ] Correct and standardize environment/RPC names, including the apparent `RPC_BASE_SEPROLIA` typo versus `base_sepolia`.
- [ ] Choose one convention for version suffixes and apply it consistently: `V1`/`V2` versus `v1`/`v2`, including contracts, interfaces, folders, deployment names, and docs.
- [ ] Choose one naming convention for module roles (`Module`, `Library`, `Ops`, `Helper`, `Facade`, `Proxy`, `Aggregator`) and rename misleading names, especially contracts that are no longer merely size-extraction helpers.
- [ ] Resolve terminology drift among `EscrowVault`, `BaseEscrow`, `EscrowableERC20`, `BasicEscrowVault`, and `BasicEscrowableERC20`; document the intended hierarchy and use it consistently.
- [ ] Standardize test naming and suffixes (`.t.sol`, `.test.t.sol`, `invariants`, `unit`, `integration`, `fork`) and align directory names with the test commands that select them.
- [ ] Standardize `MockERC20`, `ERC20Mock`, `MockNonStandardERC20`, and other mock names so the name describes behavior rather than origin.
- [ ] Standardize singular/plural and role names in interfaces and structs, including resolver, dispute, bond, module, escrow, and evidence terminology.
- [ ] Normalize import quote style, path casing, declaration ordering, visibility ordering, and whitespace through the configured formatter, then keep formatting checks deterministic in CI.

## P1: Production-readiness pass

- [ ] Replace string-based `require` messages in production contracts with custom errors where ABI/API compatibility permits.
- [ ] Review every `try/catch` and deployment-script warning that currently labels failures “non-critical”; ensure failures that can leave an unsafe or unverifiable deployment are fatal.
- [ ] Remove emojis and ad-hoc status formatting from release-critical scripts, or centralize structured deployment logging suitable for CI and incident records.
- [ ] Make deployment scripts idempotent and fail-closed: validate chain ID, addresses, roles, timelock ownership, initializer state, and post-deployment invariants before reporting success.
- [ ] Remove testnet-only forwarding, mocks, example contracts, and experimental paths from production build/deployment surfaces, or isolate them behind clearly named test-only directories and configuration.
- [ ] Review all `legacy`, `deprecated`, `compatibility`, and `reserved` fields/functions; delete them where no external consumer or storage-layout requirement remains, otherwise document an explicit removal plan.
- [ ] Review every external call and `delegatecall` for target validation, return-data handling, reentrancy assumptions, storage compatibility, and event/accounting effects.
- [ ] Replace magic numbers and duplicated protocol constants with one canonical source, especially limits, fee bounds, decimals, delays, appeal windows, and evidence defaults.
- [ ] Make access-control role names, admin transfers, emergency controls, and timelock assumptions explicit in interfaces, deployment checks, and runbooks.
- [ ] Add a release gate that verifies no deployer/admin retains unintended privileges and that all configured addresses are nonzero and on the expected chain.
- [ ] Remove generated outputs, local deployment broadcasts, reports, caches, and environment-specific files from source control unless each is intentionally a release fixture.
- [ ] Ensure `.env` and other local secrets are not tracked and add a CI secret-scanning check.

## P2: Test and tooling cleanup

- [ ] Make `pnpm test` fail on coverage-command failures instead of masking them with `|| true`; apply the same review to report and validation scripts.
- [ ] Remove duplicate Hardhat/Foundry test coverage where one canonical test gives the same assurance, while retaining cross-tool tests for compiler/deployment compatibility.
- [ ] Replace broad test selections and shell scripts with named, reproducible profiles for unit, core, module, invariant, fork, formal, and release tests.
- [ ] Remove unused imports, dead test helpers, stale traces, obsolete deployment fixtures, and generated artifacts that are not required to reproduce a test.
- [ ] Add CI checks for formatting, naming/pragma consistency, stale TODOs, compiler drift, deployment-surface changes, and production contract size telemetry.
- [ ] Keep the size report as informational telemetry after the limit migration; retain a conservative alert threshold rather than a historical hard-coded gate.
- [ ] Update README, docs index, setup guides, governance runbooks, and CI instructions to describe one current path from build through deployment and verification.

## Completion criteria

- [ ] A clean release build uses the approved `0.8.38` compiler configuration with no unintended mixed pragmas.
- [ ] No production code relies on a size workaround solely to satisfy the obsolete 24 KB limit.
- [ ] Remaining libraries, delegatecalls, assembly, compatibility surfaces, and comments each have a current, documented reason to exist.
- [ ] Naming, deployment checks, tests, docs, and release metadata describe the same architecture and release procedure.
- [ ] Full release validation passes from a clean checkout, with no masked failures or unreviewed generated changes.
