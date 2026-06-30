# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [Unreleased]

### Added
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

### Fixed

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
