# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [Unreleased]

### Added
- **BondLedger custody primitive** (`contracts/shared/BondLedger.sol` + `IBondLedger.sol`) — narrow reusable custody and exact-settlement component extracted from Sew's appeal-bond lifecycle. Handles principal custody (ETH/ERC20), deterministic bond positions, one-time exact settlement via bounded allocation lists (`REFUND` / `RESOLVER_PAYOUT` / `FORFEIT`), pull-based claims, recipient claimables, `forfeitedBondReserve`, `AccessControl` authority, reentrancy guard, and balance-before/after ERC20 validation. Runtime size 5,194 B.
- **`ResolverIncentiveModuleV2BondLedger`** — Sew-facing incentive-module facade that retains Sew-specific allocation computation, resolver tracking, metrics, and legacy events while delegating custody and settlement to `BondLedger`. Runtime size 24,300 B (276 B EIP-170 headroom; frozen).
- **Appeal-bond behavioural correction suite** — `BondBehaviourCorrection.t.sol` (15 tests) covering refund-through-production-path, failed-appeal resolver payout, forfeiture reserve, atomic settlement, round/cohort ownership, idempotency, and `setResolutionModule` authority.
- **BondLedger differential suite** — `BondLedgerDifferential.t.sol` (10 cases) proving semantic equivalence between the corrected embedded implementation and the BondLedger-backed implementation across refund, resolver allocations, rounding/remainder, forfeiture reserve, finalization cleanup, ETH/ERC20 bonds, net-principal-after-fee, double-resolution idempotency, and invalid-authority rejection.
- **BondLedger unit tests** — `BondLedger.t.sol` (17 tests) covering posting, exact settlement, claims, reserve accounting, reentrancy, and authority.
- **PRF appeal-bond scenarios** — `DR-C-003` refund-on-reversal, `DR-C-004` resolver-payout, `DR-C-005` forfeit-reserve, `DR-C-006` distribution-atomicity.
- **PRF review handoff + topology** — `docs/review/bond-ledger-prf-review-handoff.md` and content-addressed `docs/review/bond-ledger-review-topology.json` (sha256 `dbb6087b...`).
- **Contract size gate** — `scripts/check-bondledger-size.sh` and updated `scripts/print-contract-sizes.ts` freezing BondLedger and the review facade at committed sizes with explicit-approval policy.

- Dispute liveness timeout (`ACTION_DISPUTE_TIMEOUT`, type 5) — auto-cancels escrows stuck in `DISPUTED` state when `maxDisputeDuration` elapses since `disputeRaisedTimestamp`. On trigger, finalizes the dispute and refunds the sender.
- Slashing module integration (DR v3): `slashingModule` address in `DRMStorageBase`, wired into `recordResolution` (vindication credit via `restoreReversalSlashOnVindication`) and `recordReversal` (automated slash via `slashForReversal`).
- `restoreReversalSlashOnVindication` in `ResolverSlashingModuleV1` — iterates prior rounds and credits resolver stake when a higher-level resolution vindicates a prior decision.
- `creditStakeForVindication` in `ResolverStakingModuleV1` and `IStakingModule` for protocol-backed liability restoration.
- `REVERSED_WITH_CREDIT` status and `SlashRestoredOnVindication` event in `ISlashingModule`.
- Explicit CodeQL workflow (`.github/workflows/codeql.yml`) with pnpm pre-installed — fixes CI runner "pnpm not found" error on javascript-typescript analysis.
- V2 Strategic Preparation: Defined semantic identity architecture (bytes32 derived IDs) to achieve cryptographic provenance and eliminate potential identity-confusion risks identified in simulation audits.
- Operational Safety Roadmap: Specified delegated "create-blocked" guards for yield module health and resolver capacity to protect user funds from known operational stress states.

- Security documentation (`SECURITY.md`) with responsible disclosure policy
- Comprehensive security model (`docs/SECURITY_MODEL.md`)
- Operational runbooks (`governance/runbooks/`) for emergency, recovery, and governance procedures
- Audit documentation (`docs/AUDIT.md`) with scope and status
- Drill and rehearsal documentation (`docs/DRILLS_AND_REHEARSALS.md`)
- Repository hygiene improvements (`.nvmrc`, `.env.example`, `LICENSE`)
- CI/CD pipeline (`.github/workflows/ci.yml`)
- Governance documentation (`docs/governance.md`, `docs/GOVERNANCE_SURFACE_MAP.md`)
- Module extraction: DecentralizedResolutionModule moved to separate package (`contracts/decentralized-resolution-module/`)

- `partialRelease(workflowId, amount)` on `EscrowVault` — buyers can release a portion of escrowed funds to the seller while the escrow stays `PENDING` for the remainder; auto-finalizes to `RELEASED` when cumulatively released in full
- `amountReleased` mapping on `BaseEscrow` tracking cumulative partial release amounts per escrow
- `EscrowPartiallyReleased` event for indexing partial release activity
- `canPartialRelease()` view on `EscrowViewContract` for wallet-accuracy checks
- Release (bit 0) and partialRelease (bit 5) action bits in `getActionStatus()`

- `initializeDisputeWithCategory()` in `DecentralizedResolutionModule` — staking-gated dispute initialization that verifies per-resolver maximum case capacity before assignment, ensuring liveness when resolvers are near capacity
- `IStakingModule` interface and `StakingModuleNoOp` default implementation for resolver staking queries
- `setStakingModule()` admin function on `DecentralizedResolutionModule` for configuring per-resolver staking limits
- `InsufficientResolverStake` error raised when escrow value exceeds a resolver's staked capacity
- `StakingModuleUpdated` event emitted on staking module changes

### Changed

- **Appeal-bond distribution is now atomic in `recordResolution`** — for higher-round decisions the bond is settled as part of the resolution transition: a flipped decision refunds the bond to the escalator, a matching decision pays the prior-round resolvers. A settlement failure reverts the entire resolution (no silent `try/catch` swallow). `recordReversal` is reduced to reversal analytics + automated slashing; distribution is owned by `recordResolution`.
- **Resolution-module authority** — `ResolverIncentiveModuleV1` gains `resolutionModule` + `setResolutionModule()` (`ROLE_TIMELOCK`). `distributeAppealBond`, `onDisputeFinalized`, and `onResolverAssigned` accept a registered escrow or the configured resolution module (`onlyEscrowOrResolutionModule`), fixing resolver-cohort population through the DRM production path.
- **Forfeited principal is accounted** — explicit forfeiture, no-resolver payout paths, and finalization cleanup now credit `forfeitedBondReserve` instead of leaving tokens stranded with no liability destination. The reserve has no withdrawal authority in this phase.

- Updated CI node-version from 20 to 22 (Node 20 deprecated on GitHub Actions runners). Swapped `setup-node`/`setup-pnpm` order so pnpm is on PATH before store-cache resolution.
- Removed stale `.eslintrc.cjs` — ESLint v9 uses flat config (`eslint.config.cjs`) exclusively.
- Removed `pnpm-workspace.yaml` — single-package project, was causing `packages field missing` errors in CI.
- Consolidated `docs/archive/` → `docs/archived/` and `docs/deployments/` → `docs/deployment/` to eliminate duplicate directories.
- Added `pnpm-lock.yaml` and `pnpm-workspace.yaml` back to tracking (removed from `.gitignore`).
- Added `.certora_internal/` and `.claude/` to `.gitignore` for local run artifacts and IDE config.
- Moved `differential-setup.json` to `config/` and removed stray root-level `project.json` and `report.md`.

- Removed `ROLE_MODULE_DEVELOPER` for governance consistency (all upgrades now via `ROLE_TIMELOCK`)
- Simplified upgrade authorization in DecentralizedResolutionModule and ResolverIncentiveModule
- Updated `BaseEscrow` configuration management: consolidated individual setter functions into atomic `ProtocolConfig` updates to optimize contract size
- Unified all access control patterns to use `ROLE_TIMELOCK` (removed redundant `Ownable` ownership for proxy and aggregator contracts)
- Updated contract structure: core contracts in `contracts/core/`, shared interfaces in `contracts/shared/`
- Updated import paths across all contracts and tests
- Updated documentation to reflect module extraction and role removal
- Updated repeat-attacker integration tests to align with current escalation behavior: cooldown is tracking/scaling-oriented and no longer a hard within-window escalation block.

- `_releaseEscrowTransfer` and `_cancelAndRefund` now subtract `amountReleased[workflowId]` from the settlement amount, so only the unreleased remainder is released or refunded
- `withdrawEscrow` now accepts `PENDING` state in addition to `RELEASED`, `REFUNDED`, and `RESOLVED` — allows sellers to pull partial release funds while the escrow is still active

### Build

- **Minimal uberjar runner:** `prf-runner-sew-0.1.0-uber.jar` (18 MB) — self-contained scenario replay jar with no Clojure CLI, no source tree required. Source-only build (no AOT). Uses `java -jar ... -m resolver-sim.minimal-runner --scenario <file>` from any directory. Added `build.clj` + `bb build:sew`.

### Fixed

- **Successful-appeal refund path was a silent no-op** — `DecentralizedResolutionModule.recordReversal` called `distributeAppealBond(..., true)` inside a `try/catch`, but the resolution module was not an authorised caller, so refunds never settled. Bond distribution now runs atomically from `recordResolution` with resolution-module authority.
- **Failed-appeal resolver payout was unreachable** — `distributeAppealBond(..., false)` existed but was never invoked from any production path. `recordResolution` now calls it when a higher-round decision matches the prior round.
- **Forfeited principal was stranded** — `forfeitAppealBond` and `onDisputeFinalized` marked principal distributed with no liability destination and no withdrawal path. Principal is now tracked in `forfeitedBondReserve`.
- **Resolver cohorts not populated through the production path** — `onResolverAssigned` was `onlyEscrowContract`, so the DRM could not record round resolvers, leaving failed-appeal payouts to run against empty/incomplete sets. Now uses `onlyEscrowOrResolutionModule`.

- **Resolver rotation capacity leak in `forceProgress()`:** When a resolver times out and `forceProgress` rotates to a new resolver, the old resolver's `resolverActiveDisputes`, `resolverCapacity.currentDisputes`, and `resolverStats.casesAssigned` are now decremented (they were never cleaned up, causing capacity drift). The old resolver's stake is unlocked via `stakingModule.onDisputeEscalated()` and the new resolver's stake is locked via `stakingModule.onResolverAssigned()`.
- **Escalation/challenge bond leak on `finalize`:** `ResolverIncentiveModuleV2.onDisputeFinalized` was inherited as a no-op from V1, so undistributed appeal/challenge bonds for finalized rounds accumulated indefinitely. The override now iterates rounds 0 to `finalRound` and forfeits any undistributed bonds via `AppealBondForfeited`.
- **`onDisputeFinalized` made virtual in V1:** Allows V2 to override it for bond cleanup.

- **StateManagementLibrary guards:** `transitionToReleased`, `transitionToRefunded`, `transitionToResolved`, and `transitionToDisputed` now revert `AlreadyTerminal` if called on a terminal escrow — prevents silent state corruption.
- **`disputeRaisedTimestamp` cleanup:** All terminal paths (`_cancelAndRefund`, `_releaseEscrowTransfer`, `acceptSplit`) now delete `disputeRaisedTimestamp[workflowId]` — fixes stale state leak.
- **`_finalizeDisputeInModule` coverage:** Added calls from `_executeResolution` immediate path, `resolveDisputeByTimeout`, `autoCancelDisputedEscrow` via `ACTION_AUTO_CANCEL_DISPUTED`, and `_closeDisputeByMutualAgreement` — resolver capacity previously leaked on these paths.
- **`SEL_FINALIZE_DISPUTE` selector fix:** Signature changed from `"finalizeDispute(uint256)"` (single param) to `"finalizeDispute(uint256,address)"` with `address(this)` passed — the wrong selector made all module finalization calls silent no-ops. Same fix in `EscrowManagementLibrary.sol`.
- **Yield unwind double-failure:** Returns `amount` (remaining balance) instead of `yieldPrincipal` (full deposited amount) when both unwind paths fail — prevents claimable inflation when partial release occurred before yield failure.
- **Yield module state cleanup:** `v25YieldModules` and `v25YieldPrincipals` deleted after successful unwind and on double-failure — prevents double-call double-counting.
- **`_applyEscrowSettings` mutual exclusion:** Added independent `BothAutoTimesSet` guard — prevents both auto times being set simultaneously even if `setTimeoutConfig` is bypassed.
- **`_executeResolution` pending settlement guard:** Added `PendingDecisionAlreadyExists` revert — prevents resolver from overwriting an existing pending settlement with a different decision.
- **`acceptSplit` partial release guard:** Reject split if `amountReleased[workflowId] > 0` — prevents `BalanceUnderflow` when partial release occurred before split.
- **`DisputeRaiseLibrary` denominator guard:** Added `if (escrowFee >= escrowFeeDenominator) return false` — prevents division by zero if escrow fee is misconfigured.
- **`EscrowableERC20.withdrawFees` CEI fix:** `totalFees = 0` moved before `_transfer` — closes Checks-Effects-Interactions violation.
- **`DisputeOps` escrowData encoding:** Switched from 4-element `abi.encode(token,from,to,amountAfterFee)` to 5-element `EscrowEncodingLibrary.encodeEscrowTransferData(...)` — matches CreateOps encoding so modules receive consistent data.
- **`_finalizeDisputeInModule` event emission:** `OperationFailure` event emitted when `finalizeDispute` or `decrementResolverActiveDisputes` low-level calls fail — provides governance observability for module desync.

- Fixed stale constructor revert expectation in `test/foundry/core/ModuleManagementContract.t.sol`:
  `test_constructor_zeroOwner_reverts` now expects `InvalidAddress(8, address(0))`.
- Fixed Foundry prank misuse in `test/foundry/decentralized-resolution-module/IncentiveModuleIntegration.test.t.sol` `setUp()` by removing nested `vm.prank` during an active `vm.startPrank` context.
- Fixed repeat-attacker regression expectations in `test/foundry/core/RepeatAttackerIntegration.t.sol`:
  - renamed cooldown test to `test_EscalationCooldown_NoLongerHardBlocksWithinWindow`,
  - updated assertions to validate escalation count tracking (`addressEscalationCount`) and cumulative scaling model.
- Validated all previously failing targeted tests with `forge test` reruns.

### Security

- Removed module developer role to reduce attack surface
- All upgrades now require standard governance lanes (ROLE_TIMELOCK)
- Enhanced security model documentation

---

## [0.1.0] - 2026-01-06

### Added
- V2 Strategic Preparation: Defined semantic identity architecture (bytes32 derived IDs) to achieve cryptographic provenance and eliminate potential identity-confusion risks identified in simulation audits.
- Operational Safety Roadmap: Specified delegated "create-blocked" guards for yield module health and resolver capacity to protect user funds from known operational stress states.

- Initial release preparation
- Core escrow contracts (BaseEscrow, EscrowVault, EscrowableERC20)
- Resolution modules (DefaultResolutionModule, DecentralizedResolutionModule)
- Governance infrastructure (OpenZeppelin Governor, TimelockController)
- Module architecture with swappable components
- Time-delayed governance (Standard: 48h, Slow: ~9 days)
- Emergency controls (Guardian multisig with down-only powers)
- Comprehensive test suite (Hardhat + Foundry)
- Deployment infrastructure (hardhat-deploy)

### Architecture

- Modular design with "new escrows only" semantics
- Immutable core contracts (no proxies)
- UUPS upgradeable modules (when swapped in)
- Library-based architecture for contract size optimization

### Testing

- Hardhat unit tests (277 passing)
- Foundry fuzz tests and invariants
- Integration tests for governance flows
- Test coverage reporting

---

## Versioning Strategy

This project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html):

- **MAJOR** version for incompatible API changes
- **MINOR** version for functionality added in a backwards compatible manner
- **PATCH** version for backwards compatible bug fixes

### Pre-Release Versions

- **v1.0.0-rc1**: Release candidate 1 (pre-mainnet)
- **v1.0.0-rc2**: Release candidate 2 (if needed)
- **v1.0.0**: Mainnet release

### Current Version

- **Package Version**: `0.1.0` (pre-release)
- **Target Release**: `v1.0.0` (after audits and mainnet deployment)

---

## Release Process

1. **Pre-Release**:
   - Complete all critical and high-priority items
   - Perform audits
   - Complete emergency drills
   - Tag as `v1.0.0-rc1`

2. **Release Candidate Testing**:
   - Deploy to Base Sepolia
   - Perform comprehensive testing
   - Address any issues found
   - Tag as `v1.0.0-rc2` if needed

3. **Mainnet Release**:
   - Deploy to Base mainnet
   - Verify all contracts
   - Document deployment addresses
   - Tag as `v1.0.0`

---

## Types of Changes

- **Added** for new features
- **Changed** for changes in existing functionality
- **Deprecated** for soon-to-be removed features
- **Removed** for now removed features
- **Fixed** for any bug fixes
- **Security** for vulnerability fixes

---

**Note:** This changelog will be updated as the project progresses toward mainnet deployment.
