# Sew Protocol — Repository Map

> A navigational reference for the full repository. Start here when locating contracts,
> tests, documentation, or tooling. Internal links are relative to the repository root.
>
> **Companion documents:**
> [`docs/PROTOCOL_OVERVIEW.md`](PROTOCOL_OVERVIEW.md) — what the protocol does  
> [`docs/SECURITY_MODEL.md`](SECURITY_MODEL.md) — threat model and security posture  
> [`docs/architecture/ARCHITECTURE_OVERVIEW.md`](architecture/ARCHITECTURE_OVERVIEW.md) — architectural decisions  
> [`docs/INDEX.md`](INDEX.md) — documentation index (doc-only)

---

## Root layout

```
sew-protocol/
├── contracts/          ← Solidity source (all production code lives here)
├── test/               ← Foundry + Hardhat tests
│   ├── foundry/        ← Primary test suite (Foundry / Forge)
│   └── mocks/          ← Shared mock helpers for Hardhat tests
├── docs/               ← All documentation
├── lib/                ← Foundry dependencies (git submodules)
├── script/             ← Forge deployment and differential scripts
├── deploy/             ← Hardhat deploy scripts
├── certora/            ← Certora formal verification harnesses
├── examples/           ← Standalone usage examples (Vault, UpgradeableBox)
├── governance/         ← Off-chain governance simulation helpers
├── artifacts/          ← Hardhat compilation artifacts (generated)
├── out/                ← Forge build output (generated)
├── typechain-types/    ← Generated TypeScript typings (generated)
├── foundry.toml        ← Forge configuration (solc 0.8.33, via_ir, optimizer 200)
├── hardhat.config.ts   ← Hardhat configuration
├── package.json        ← npm scripts (test, compile, deploy, lint, gov:*, size)
├── slither.config.json ← Slither static analysis configuration
├── remappings.txt      ← Forge import remappings
└── Makefile            ← Common dev tasks
```

---

## Contracts

### Core (`contracts/core/`)

The kernel of the protocol. All escrow lifecycle logic is rooted here.

| File | Role |
|---|---|
| `BaseEscrow.sol` | Abstract base for all escrow vaults. State machine, dispute lifecycle, module dispatch, CEI-safe settlement and release flows. All public functions are `nonReentrant`. |
| `EscrowVault.sol` | Concrete vault for native ERC-20 tokens. Extends `BaseEscrow`; adds per-token balance tracking, fee withdrawal, and accounting reconciliation. |
| `EscrowableERC20.sol` | Placeholder ERC-20 vault variant; constructor reverts — not deployable in current release. |
| `BondCollector.sol` | Collects and holds appeal bonds posted during dispute escalation. |
| `ModuleSnapshotRegistry.sol` | Stores per-escrow module snapshots (`ModuleSnapshot`); written once at `createEscrow()`, never mutated. |
| `CREATE2EscrowFactory.sol` | Deterministic deployment of escrow contracts via CREATE2. |
| `EscrowViewContract.sol` | Read-only view aggregator for off-chain tooling and frontends. |
| `EscrowVaultHelper.sol` | Helper view functions for `EscrowVault`. |
| `EscrowVaultAnalytics.sol` | Analytics and reporting views over vault state. |
| `BalanceAggregator.sol` | Aggregates balances across multiple vaults. |
| `MultiL2EscrowAggregator.sol` | Cross-L2 escrow state aggregation. |
| `MultiL2ViewAggregator.sol` | Cross-L2 view queries. |
| `MultiL2ModuleCoordinator.sol` | Module coordination across L2 deployments. |
| `L2AddressRegistry.sol` | Registry of canonical contract addresses per L2 network. |
| `RPCEndpointManager.sol` | On-chain registry of RPC endpoints for keeper automation. |
| `MulticallFallbackHandler.sol` | EIP-1271-compatible multicall fallback for Safe wallets. |
| `modules/DefaultResolutionModule.sol` | Simple resolution module for non-DR escrows (no incentives). |

### Ops contracts (`contracts/ops/`)

Stateless facet contracts. `BaseEscrow` delegates specific operations to these via
`ROLE_ADMIN_CONTRACT`. All ops require `ROLE_ESCROW_CONTRACT` to call back into the vault.

| File | Role |
|---|---|
| `CreateOps.sol` | Escrow creation, yield deposit on creation, yield-deposit resume/pause. |
| `SettlementOps.sol` | Mutual split proposals, split execution, settlement flow. |
| `DisputeOps.sol` | Dispute initiation, resolver decision submission, finalization. |
| `YieldOps.sol` | Yield withdrawal and distribution. |
| `GuardianOps.sol` | Guardian-only emergency operations (forced Aave unwind). |

### Modules (`contracts/modules/`)

Swappable implementation modules. Each module is pointed to by a `ModuleSnapshot` field
for a given escrow. Changes require Slow lane governance (~9 days).

| File | Role |
|---|---|
| `AaveYieldModule.sol` | Yield generation via Aave v3. Deposits principal, accrues aTokens, enforces per-token and global exposure caps, slippage-checked withdrawals. |
| `DefaultYieldGenerationModule.sol` | No-op yield generation (hold only). |
| `DefaultYieldDistributionModule.sol` | Default yield distribution to configured recipients. |
| `DefaultReleaseStrategy.sol` | Default release authorization (recipient acceptance required). |
| `DefaultCancellationStrategy.sol` | Default cancellation rules. |
| `BuyerOnlyCancellationStrategy.sol` | Restricts cancellation to the buyer (sender) only. |

#### Decentralized Resolution Module (`contracts/modules/decentralized-resolution-module/`)

The DR v3 subsystem. Implements the full three-round escalation pipeline.

| File | Role |
|---|---|
| `DecentralizedResolutionModule.sol` | Main DRM contract. Manages dispute lifecycle: assignment, accept, decide, escalate, finalize. |
| `DRMStorageBase.sol` | Storage layout for the DRM (diamond-style separation). |
| `DRMAdminFacet.sol` | Governance-accessible configuration for the DRM. |
| `DRMAnalytics.sol` | Read-only analytics and metrics views. |
| `DecentralizedResolverStructs.sol` | Shared struct definitions (`DisputeMetadata`, `ResolverMetadata`, etc.). |
| `ResolverIncentiveModuleV1.sol` | Incentive accounting v1 (fee tracking per resolver). |
| `ResolverIncentiveModuleV2.sol` | Incentive accounting v2 (appeal bond recording). |
| `ResolverStakingModuleV1.sol` | DR v3 resolver staking: bond posting, unbonding delays, capacity gating. |
| `ResolverSlashingModuleV1.sol` | DR v3 slashing: timeout/fraud slashes, epoch caps, slash appeal. |
| `SlashingModuleNoOp.sol` | No-op slashing implementation (used in v1/v2 rollout phases). |
| `StakingModuleNoOp.sol` | No-op staking implementation (used in v1/v2 rollout phases). |
| `BondTokenRegistry.sol` | Whitelist of tokens accepted for appeal bonds. |
| `IBondTokenRegistry.sol` | Interface for bond token registry. |
| `InsurancePoolVault.sol` | Insurance pool seeded by slashed funds; payer-of-last-resort for resolver insolvency. |
| `BondValuationLibrary.sol` | Bond valuation with haircut and composition rules (80% stable / 20% SEW). |
| `EscalationCostLibrary.sol` | Escalation cost curves (linear, quadratic, geometric). |
| `PaymentCalculationLibraryV1.sol` | Resolver fee distribution weighted by escalation level. |
| `ResolutionAnalytics.sol` | EMA reputation scoring, workload routing, attention signals. |
| `IPaymentCalculationLibrary.sol` | Interface for payment calculation library. |
| `ISlashingModule.sol` | Slashing module interface. |
| `IStakingModule.sol` | Staking module interface. |

### Admin (`contracts/admin/`)

| File | Role |
|---|---|
| `EscrowGovernanceTimelock.sol` | TimelockController extension that grants `ROLE_TIMELOCK` on the escrow contracts. |

### Governance (`contracts/governance/`)

| File | Role |
|---|---|
| `GovGovernor.sol` | `GovernorTimelockControl` DAO governor. Enforces proposal threshold (10M SEW) and quorum (4M SEW). |
| `SlowLaneQueueActivate.sol` | Two-step queue/activate pattern for high-impact changes (7-day delay). |
| `EmergencyRecoveryProposal.sol` | Governance-controlled emergency recovery proposal contract. |

### Arbitration (`contracts/arbitration/`)

| File | Role |
|---|---|
| `KlerosArbitrableProxy.sol` | Adapter connecting DRM round 2 to Kleros arbitration. Implements `IArbitrable`. |
| `IArbitrable.sol` | Kleros `IArbitrable` interface. |
| `IArbitrator.sol` | Kleros `IArbitrator` interface. |
| `mocks/MockKlerosArbitrator.sol` | Mock Kleros arbitrator for testing. |

### Evidence module (`contracts/evidence-module/`)

| File | Role |
|---|---|
| `EvidenceModuleV1.sol` | On-chain evidence submission and retrieval for disputes. |

### Bridges (`contracts/bridges/`)

| File | Role |
|---|---|
| `DeferredFundingBridge.sol` | Bridge that allows deferred / conditional funding of escrows. |
| `SpendingLimitProxy.sol` | Proxy enforcing spending limits on escrow creation. |

### Guards (`contracts/guards/`)

Invariant-guard libraries for yield operations.

| File | Role |
|---|---|
| `InvariantGuardedAaveYieldLibrary.sol` | Aave-specific invariant checks wrapping yield operations. |
| `InvariantGuardHelper.sol` | Shared guard helpers. |
| `InvariantGuardInternal.sol` | Internal guard implementation. |

### Libraries (`contracts/libraries/`)

Extracted logic libraries (`using L for ...` or direct call pattern). Key libraries:

| File | Role |
|---|---|
| `EscrowCreationLibrary.sol` | Escrow creation validation and setup. |
| `EscrowAccountingLibrary.sol` | Balance tracking and accounting deltas. |
| `DisputeRaiseLibrary.sol` | Dispute initiation validation. |
| `DisputeManagementLibrary.sol` | Dispute state transitions. |
| `DisputeEscalationLibrary.sol` | Escalation round management. |
| `DisputeInitializationLibrary.sol` | Dispute metadata initialization. |
| `StateManagementLibrary.sol` | Escrow state machine transitions. |
| `ModuleSnapshotLibrary.sol` | Snapshot capture and lookup. |
| `ModuleManagementLibrary.sol` | Default module getters/setters. |
| `ModuleProposalLibrary.sol` | Slow-lane queue/activate for module changes. |
| `SettingsValidationLibrary.sol` | Parameter bounds enforcement (bounds on all config). |
| `AaveYieldHandlingLibrary.sol` | Aave deposit/withdraw CEI patterns. |
| `AaveYieldLibrary.sol` | Aave-specific math and balance queries. |
| `YieldHandlingLibrary.sol` | Generic yield delegation. |
| `YieldDistributionLibrary.sol` | Yield distribution to recipients. |
| `BondHandlingLibrary.sol` | Appeal bond posting and release. |
| `FeeRecordingLibrary.sol` | Protocol fee accrual. |
| `FeeWithdrawalLibrary.sol` | Fee withdrawal CEI pattern. |
| `RecoveryLibrary.sol` | Token recovery (excess balance extraction). |
| `ResolverLogicLibrary.sol` | Resolver assignment and round management. |
| `ResolverActionLibrary.sol` | Resolver accept/decide/timeout actions. |
| `ResolutionModuleLibrary.sol` | Resolution module dispatch. |
| `ResolutionTableLibrary.sol` | Resolution outcome lookup. |
| `ProtocolMathLibrary.sol` | Shared fixed-point math. |
| `EscrowManagementLibrary.sol` | Escrow lifecycle helpers. |
| `EscrowEncodingLibrary.sol` | ABI encoding helpers for escrow data. |
| `BalanceUpdateLibrary.sol` | Balance update coordination. |
| `TokenRecoveryLibrary.sol` | Token recovery with safety checks. |
| `YieldPresetLibrary.sol` | Yield preset selection and configuration. |
| `ModuleGetterLibrary.sol` / `ModuleGetterConsolidationLibrary.sol` | Module address resolution. |
| `EscrowVaultAccountingLibrary.sol` / `EscrowVaultModuleLibrary.sol` | Vault-specific helpers. |

### Token (`contracts/token/`)

| File | Role |
|---|---|
| `SewToken.sol` | SEW ERC-20 governance token. Used for DAO voting, resolver bonds, and slashed SEW burn. |

### Interfaces (`contracts/interfaces/`, `contracts/shared/interfaces/`)

| File | Role |
|---|---|
| `IEscrowCore.sol` | Core escrow interface. |
| `IReleaseStrategy.sol` | Release strategy module interface. |
| `ICancellationStrategy.sol` | Cancellation strategy interface. |
| `IYieldGenerationModule.sol` / `V2` | Yield generation module interface. |
| `IYieldDistributionModule.sol` | Yield distribution module interface. |
| `IYieldModule.sol` | Combined yield module interface. |
| `IResolver.sol` | Resolver interface. |
| `IModuleRegistry.sol` | Module registry interface. |
| `IEvidenceModule.sol` | Evidence module interface. |
| `IResolutionModule.sol` | Resolution module interface (shared). |
| `IIncentiveModule.sol` | Incentive module interface (shared). |
| `ISlashingModuleV3.sol` / `IStakingModuleV3.sol` | DR v3 staking/slashing interfaces. |
| `IFraudProofModule.sol` | Fraud proof module interface. |
| `aave/AaveV3Interfaces.sol` | Aave v3 pool and aToken interfaces. |

### Registry (`contracts/registry/`)

| File | Role |
|---|---|
| `ModuleRegistry.sol` | On-chain registry mapping module names to implementation addresses. |

### Types (`contracts/types/`)

| File | Role |
|---|---|
| `EscrowTypes.sol` | Solidity struct definitions (`EscrowTransfer`, `EscrowSettings`, `TimeoutConfig`, etc.). |
| `YieldPresets.sol` | Yield configuration preset enum and mappings. |

### Mocks (`contracts/mocks/`)

Testing-only mock contracts (ERC-20 variants, mock Aave pool, mock resolution module, etc.).

---

## Tests (`test/foundry/`)

The primary test suite runs on Forge. Hardhat tests in `test/` cover legacy scenarios and
are executed separately.

### npm test commands

| Command | What it runs |
|---|---|
| `npm test` | All tests (Foundry + Hardhat) |
| `npm run test:foundry` | Full Forge suite |
| `npm run test:foundry:core` | Core escrow tests only |
| `npm run test:foundry:modules` | Module tests only |
| `npm run test:foundry:invariants` | Invariant (stateful fuzz) tests |
| `npm run test:foundry:release-resolution` | Release and resolution flow tests |
| `npm run test:halmos:smoke` | Halmos symbolic execution smoke run |
| `npm run test:formal:smoke` | Formal verification smoke check |
| `npm run coverage` | Coverage report |

### Test suite structure

| Directory / file | Focus |
|---|---|
| `core/` | Full escrow lifecycle: creation, release, cancellation, disputes, settlement, split, yield, reentrancy, pause, accounting, per-escrow settings isolation |
| `decentralized-resolution-module/` | DR v1/v2/v3 invariants, appeal bond distribution, bond valuation, slashing, staking, escalation depth histogram, capacity exhaustion, incentive module exploit scenarios |
| `governance/` | Governor, TimelockController, SlowLaneQueueActivate, emergency recovery proposal, quorum calculation, fork simulation |
| `invariants/` | Stateful invariant handlers: escrow accounting invariants, resolver invariants, state machine invariants |
| `modules/` | Aave yield module (lifecycle, failure modes, fork tests, mainnet fork, accounting, invariants), cancellation strategy, evidence module, yield generation module |
| `arbitration/` | Kleros arbitrable proxy integration |
| `bridges/` | DeferredFundingBridge, SpendingLimitProxy |
| `admin/` | EscrowAdminContract governance tests |
| `halmos/` | Halmos symbolic execution property tests |
| `libraries/` | Library coverage, yield distribution validation |
| `migrated/` | Tests migrated from Hardhat: access control, slow lane, bounds enforcement, guardian controls, module snapshotting, Timelock integration, mainnet release sequence |
| `registry/` | ModuleRegistry tests |
| `token/` | SewToken tests |
| `testnet/` | Base Sepolia fork tests: phase 0 setup, phase 1 core journeys, security attack simulation |
| `ops/` | OpsCoverage |
| `TraceEquivalence*.t.sol` | Trace equivalence and regression tests (deterministic replay validation) |
| `BondWithdrawalGuard.t.sol` | Bond withdrawal safety guards |

---

## Documentation (`docs/`)

### Canonical reference documents (start here)

| File | Content |
|---|---|
| [`PROTOCOL_OVERVIEW.md`](PROTOCOL_OVERVIEW.md) | Top-level protocol overview: state machine, DR pipeline, module system, governance, security summary, deployment architecture, document index |
| [`SECURITY_MODEL.md`](SECURITY_MODEL.md) | Threat model, trust assumptions, access control, defensive patterns, economic security, emergency controls, resolved issues, known risks |
| [`WHITEPAPER.md`](WHITEPAPER.md) | Protocol whitepaper |
| [`CHANGELOG.md`](CHANGELOG.md) | Protocol version history |
| [`INDEX.md`](INDEX.md) | Documentation index |
| [`README.md`](README.md) | Repository readme |

### Architecture (`docs/architecture/`)

| File | Content |
|---|---|
| [`ARCHITECTURE_OVERVIEW.md`](architecture/ARCHITECTURE_OVERVIEW.md) | High-level architecture, component relationships, upgrade strategy |
| [`TECHNICAL_OVERVIEW.md`](architecture/TECHNICAL_OVERVIEW.md) | Contract-level technical detail, DR v3 status, staging rollout |
| [`CONTRACTS_SUMMARY.md`](architecture/CONTRACTS_SUMMARY.md) | One-line summary of every deployed contract |
| [`ARCHITECTURAL_PRINCIPLES.md`](architecture/ARCHITECTURAL_PRINCIPLES.md) | Core design principles (containment, isolation, forward-only) |
| [`PROTOCOL_MODULARITY.md`](architecture/PROTOCOL_MODULARITY.md) | Module system: snapshot isolation, swap mechanics, interface contracts |
| [`PROTOCOL_FEES.md`](architecture/PROTOCOL_FEES.md) | Fee model: escrow fee, yield fee, appeal bond fee |
| [`YIELD_MODULE_ARCHITECTURE.md`](architecture/YIELD_MODULE_ARCHITECTURE.md) | Yield module design and Aave integration architecture |
| [`CONTRACT_DEPENDENCY_MAP.md`](architecture/CONTRACT_DEPENDENCY_MAP.md) | Contract-to-contract dependency graph |
| [`ESCROW_CREATION_AND_SETTINGS.md`](architecture/ESCROW_CREATION_AND_SETTINGS.md) | Escrow creation flow and per-escrow settings |
| [`CANCEL_SEMANTICS_DESIGN.md`](architecture/CANCEL_SEMANTICS_DESIGN.md) | Cancellation semantics and strategy module design |
| [`CONTRACT_QUICK_REFERENCE.md`](architecture/CONTRACT_QUICK_REFERENCE.md) | Quick-reference table of all contracts |

### Governance (`docs/governance/`)

| File | Content |
|---|---|
| [`governance.md`](governance/governance.md) | Full governance model: lanes, roles, snapshot point, invariants, operational runbooks |
| [`GOVERNANCE_CONSTRAINTS.md`](governance/GOVERNANCE_CONSTRAINTS.md) | What governance **cannot** do: per-escrow immutabilities, Guardian bounds, parameter hard limits |
| [`GOVERNANCE_SURFACE_MAP.md`](governance/GOVERNANCE_SURFACE_MAP.md) | Every governed function: role → lane → delay → bounds |
| [`GOVERNANCE_STRUCTURE.md`](governance/GOVERNANCE_STRUCTURE.md) | DAO structure, TimelockController posture, role assignment |
| [`GOVERNANCE_PROCESS.md`](governance/GOVERNANCE_PROCESS.md) | Proposal lifecycle, voting procedure, execution |
| [`GOVERNOR_IMPLEMENTATION_ANALYSIS.md`](governance/GOVERNOR_IMPLEMENTATION_ANALYSIS.md) | Governor implementation review |
| [`QUORUM_CIRCULATING_SUPPLY_ANALYSIS.md`](governance/QUORUM_CIRCULATING_SUPPLY_ANALYSIS.md) | Quorum and circulating supply analysis |

### Dispute resolution (`docs/dispute-resolution/`)

| File | Content |
|---|---|
| [`DISPUTE_RESOLUTION_ARCHITECTURE.md`](dispute-resolution/DISPUTE_RESOLUTION_ARCHITECTURE.md) | Three-round escalation pipeline design |
| [`DISPUTE_ECONOMICS.md`](dispute-resolution/DISPUTE_ECONOMICS.md) | Bond mechanics, escalation cost curves, resolver payment distribution, EMA scoring, slashing, insurance pool |
| [`DR_V3_IMPLEMENTATION_STATUS.md`](dispute-resolution/DR_V3_IMPLEMENTATION_STATUS.md) | DR v3 implementation status (✅ COMPLETE) |
| [`DR_V3_COMPLETE_SUMMARY.md`](dispute-resolution/DR_V3_COMPLETE_SUMMARY.md) | End-to-end DR v3 summary |
| [`DR_V3_PARAMETERS.md`](dispute-resolution/DR_V3_PARAMETERS.md) | Production parameter values for DR v3 |
| [`DR_V3_LAUNCH_SAFE_DEFAULTS.md`](dispute-resolution/DR_V3_LAUNCH_SAFE_DEFAULTS.md) | Conservative launch-safe parameter defaults |
| [`KLEROS_INTEGRATION.md`](dispute-resolution/KLEROS_INTEGRATION.md) | Kleros integration design (round 2 backstop) |
| [`ESCALATION_CONFIG_AND_RESOLVER_TABLE.md`](dispute-resolution/ESCALATION_CONFIG_AND_RESOLVER_TABLE.md) | Escalation configuration and resolver routing |
| [`APPEAL_GAME_THEORY_BENCHMARKS.md`](dispute-resolution/APPEAL_GAME_THEORY_BENCHMARKS.md) | Game-theoretic analysis of appeal incentives |
| [`BOND_VALUATION_SUMMARY.md`](dispute-resolution/BOND_VALUATION_SUMMARY.md) | Bond composition, haircut, and valuation mechanics |
| [`COMPARATIVE_ANALYSIS_DR_SYSTEMS.md`](dispute-resolution/COMPARATIVE_ANALYSIS_DR_SYSTEMS.md) | Comparison of Sew DR with other decentralized dispute systems |

### Security (`docs/security/`)

| File | Content |
|---|---|
| [`SECURITY_FIXES_COMPLETED.md`](security/SECURITY_FIXES_COMPLETED.md) | All CRIT/HIGH/MED issues resolved; archived QA review list |
| [`ISSUE_RESOLUTION_STATUS.md`](security/ISSUE_RESOLUTION_STATUS.md) | Per-issue fix evidence and contract line references |
| [`OUTSTANDING_IMPROVEMENTS.md`](security/OUTSTANDING_IMPROVEMENTS.md) | Non-security LOW items remaining (gas, naming, NatSpec) |
| [`INVARIANT_GUARD_INTEGRATION.md`](security/INVARIANT_GUARD_INTEGRATION.md) | Invariant guard library integration notes |
| [`BASE_ESCROW_QA_REVIEW.md`](security/BASE_ESCROW_QA_REVIEW.md) | Completed QA review of BaseEscrow |
| [`APPEAL_BOND_SECURITY_REVIEW.md`](security/APPEAL_BOND_SECURITY_REVIEW.md) | Appeal bond security analysis |
| [`RECOVERY_FUNCTIONALITY.md`](security/RECOVERY_FUNCTIONALITY.md) | Token recovery design and safety constraints |

### Top-level standalone documents

| File | Content |
|---|---|
| [`STATE_MACHINE.md`](STATE_MACHINE.md) | Complete escrow state machine: all states, transitions, guards, and terminal conditions |
| [`FINALITY.md`](FINALITY.md) | Finality model: hard finality, partial finality, appeal windows |
| [`WINDOWS.md`](WINDOWS.md) | All protocol time windows: appeal, dispute, auto-release, auto-cancel, unbonding |
| [`SETTLEMENT.md`](SETTLEMENT.md) | Settlement mechanics: mutual split, resolver settlement, expiry-based settlement |
| [`WITHDRAWALS.md`](WITHDRAWALS.md) | Withdrawal paths: release, cancellation, yield withdrawal, fee withdrawal |
| [`AUTO_EXPIRY_AUTHORISATION.md`](AUTO_EXPIRY_AUTHORISATION.md) | Auto-expiry authorisation: `autoReleaseTime`, `autoCancelTime`, keeper automation |
| [`PREPAYMENTS.md`](PREPAYMENTS.md) | Prepayment / pay-ahead use cases |
| [`FORWARD_ONLY_UPGRADES.md`](FORWARD_ONLY_UPGRADES.md) | Forward-only upgrade constraint: no proxy upgrade, Slow lane module swap, rollback cost |
| [`DEPLOYMENT_POST_ROLES.md`](DEPLOYMENT_POST_ROLES.md) | Post-deployment role transfer checklist |
| [`SECURITY.md`](SECURITY.md) | Responsible disclosure policy, scope, contacts |
| [`payment-flow-overview.md`](payment-flow-overview.md) | Payment flow overview for integrations |

### Guides (`docs/guides/`)

| File | Content |
|---|---|
| [`KLEROS_INTEGRATION_GUIDE.md`](guides/KLEROS_INTEGRATION_GUIDE.md) | How to integrate the Kleros backstop as a resolution partner |
| [`WALLET_INTEGRATION_GUIDE.md`](guides/WALLET_INTEGRATION_GUIDE.md) | Wallet and frontend integration |
| [`ACCOUNT_ABSTRACTION_GUIDE.md`](guides/ACCOUNT_ABSTRACTION_GUIDE.md) | Account abstraction integration |
| [`CODING_STANDARDS.md`](guides/CODING_STANDARDS.md) | Solidity coding conventions and patterns used in this codebase |
| [`CONTRIBUTING.md`](guides/CONTRIBUTING.md) | Contribution process |

### Reference (`docs/reference/`)

| File | Content |
|---|---|
| [`MODULE_MAP.md`](reference/MODULE_MAP.md) | Module system map: interface → implementation → snapshot field |
| [`MODULE_DEVELOPMENT_GUIDE.md`](reference/MODULE_DEVELOPMENT_GUIDE.md) | How to build a new module |
| [`TEST_SUITE_INDEX.md`](reference/TEST_SUITE_INDEX.md) | Index of all test files and their coverage targets |
| [`invariants_suite_vaults.md`](reference/invariants_suite_vaults.md) | Vault invariant definitions and test coverage |
| [`ERROR_STANDARDIZATION.md`](reference/ERROR_STANDARDIZATION.md) | Custom error catalogue |
| [`INTERFACE_VERSIONING.md`](reference/INTERFACE_VERSIONING.md) | Interface versioning policy |
| [`SLITHER_SUMMARY_AND_RECOMMENDATIONS.md`](reference/SLITHER_SUMMARY_AND_RECOMMENDATIONS.md) | Slither static analysis findings and dispositions |

### Deployment (`docs/deployment/`, `docs/deployments/`)

| File | Content |
|---|---|
| [`deployment/RELEASES.md`](deployment/RELEASES.md) | Release history and deployment manifest |
| [`deployment/dr3/DR3_ACTIVATION.md`](deployment/dr3/DR3_ACTIVATION.md) | DR v3 activation runbook |
| [`deployment/ieo/IEO_RELEASE_GUIDE.md`](deployment/ieo/IEO_RELEASE_GUIDE.md) | IEO release procedure |
| [`deployments/base-sepolia-v1-testnet-addresses.md`](deployments/base-sepolia-v1-testnet-addresses.md) | Base Sepolia testnet contract addresses |
| [`deployment/BRANCHING_AND_RELEASE_DISCIPLINE.md`](deployment/BRANCHING_AND_RELEASE_DISCIPLINE.md) | Branch and release naming conventions |

### Policies (`docs/policies/`)

| File | Content |
|---|---|
| [`UPGRADE_POLICY.md`](policies/UPGRADE_POLICY.md) | Protocol upgrade policy |
| [`EMERGENCY_POLICY.md`](policies/EMERGENCY_POLICY.md) | Emergency response policy |

### Token (`docs/token/`)

| File | Content |
|---|---|
| [`SEW_TOKENOMICS_RECONCILIATION_MATRIX.md`](token/SEW_TOKENOMICS_RECONCILIATION_MATRIX.md) | SEW token allocation and vesting reconciliation |

---

## Build toolchain

| Tool | Version / config | Purpose |
|---|---|---|
| Solidity compiler | `0.8.33` | All production contracts |
| Foundry (Forge) | `foundry.toml` | Primary test runner, build, coverage, fuzz |
| Hardhat | `hardhat.config.ts` | Legacy test runner, deployment scripts |
| Halmos | Profile: `halmos` (via_ir=false) | Symbolic execution property tests |
| Certora Prover | `certora/` | Formal verification harnesses |
| Slither | `slither.config.json` | Static analysis |
| Aderyn | `aderyn.toml` | Additional static analysis |
| TypeChain | `typechain-types/` | Generated TypeScript contract bindings |

### Key compiler settings

```toml
# foundry.toml (profile.default)
solc        = "0.8.33"
optimizer   = true
optimizer_runs = 200
via_ir      = true     # IR-based codegen (required for contract size)
```

`via_ir = true` is required to keep `BaseEscrow` and `EscrowVault` under the 24 KB
Spurious Dragon limit after library extraction. The Halmos profile disables `via_ir`
because Halmos 0.3.x cannot process YUL IR bytecode.

### npm scripts (selected)

| Script | What it runs |
|---|---|
| `npm run compile` | Hardhat compilation |
| `npm run size` | Contract size report |
| `npm run size:check` | Fail if any contract exceeds 24 KB |
| `npm run lint` | Solhint + ESLint |
| `npm run format` | Prettier |
| `npm run gov:build` | Build governance simulation |
| `npm run gov:sim` | Run governance simulation |
| `npm run gov:surface:check` | Validate governance surface map |
| `npm run coverage` | Forge coverage report |

---

## Formal verification (`certora/`)

| File | Purpose |
|---|---|
| `harness/EscrowVaultHarness.sol` | Certora verification harness wrapping `EscrowVault` |

Certora specs (`.spec` files) live alongside or above the harness; run via Certora Prover
cloud service.

---

## Off-chain governance tools (`governance/`)

Scripts and configuration for simulating and validating DAO proposals before submission.
Used with `npm run gov:*` commands.

---

*Last updated: May 2026*
