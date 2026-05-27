# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [Unreleased]

### Added

- Security documentation (`SECURITY.md`) with responsible disclosure policy
- Comprehensive security model (`docs/SECURITY_MODEL.md`)
- Operational runbooks (`governance/runbooks/`) for emergency, recovery, and governance procedures
- Audit documentation (`docs/AUDIT.md`) with scope and status
- Drill and rehearsal documentation (`docs/DRILLS_AND_REHEARSALS.md`)
- Repository hygiene improvements (`.nvmrc`, `.env.example`, `LICENSE`)
- CI/CD pipeline (`.github/workflows/ci.yml`)
- Governance documentation (`docs/governance.md`, `docs/GOVERNANCE_SURFACE_MAP.md`)
- Module extraction: DecentralizedResolutionModule moved to separate package (`contracts/decentralized-resolution-module/`)

### Changed

- Removed `ROLE_MODULE_DEVELOPER` for governance consistency (all upgrades now via `ROLE_TIMELOCK`)
- Simplified upgrade authorization in DecentralizedResolutionModule and ResolverIncentiveModule
- Updated `BaseEscrow` configuration management: consolidated individual setter functions into atomic `ProtocolConfig` updates to optimize contract size
- Unified all access control patterns to use `ROLE_TIMELOCK` (removed redundant `Ownable` ownership for proxy and aggregator contracts)
- Updated contract structure: core contracts in `contracts/core/`, shared interfaces in `contracts/shared/`
- Updated import paths across all contracts and tests
- Updated documentation to reflect module extraction and role removal
- Updated repeat-attacker integration tests to align with current escalation behavior: cooldown is tracking/scaling-oriented and no longer a hard within-window escalation block.

### Fixed

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
