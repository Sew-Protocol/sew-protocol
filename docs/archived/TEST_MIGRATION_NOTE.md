# Test Migration to Foundry/Forge

**Date:** 2026-01-09  
**Status:** In Progress

## Overview

This project is in the process of migrating test suites from Hardhat to Foundry/Forge for improved testing capabilities and performance.

## Current Test Status

### Hardhat Tests (Legacy)

- **Total Tests:** 445 passing, 112 pending
- **Test Framework:** Hardhat + Ethers.js + Chai
- **Location:** `test/hardhat/`

### Test Coverage Breakdown

#### ✅ Fully Functional Test Suites (400 tests)

- Core escrow functionality
- Dispute resolution workflows
- Kleros integration (41 tests)
- ERC20 token escrows
- Governance and access control
- Escalation mechanisms
- DecentralizedResolutionModule advanced tests (45 tests)

#### ✅ Migrated to Forge

- **ResolverIncentiveModule.comprehensive.test.ts** -> `test/foundry/core/ResolverIncentiveModuleComprehensive.t.sol`
  - Status: ✅ Complete
  - Notes:
    - Fixed critical bug in `ResolverIncentiveModule.sol` (uninitialized proxy storage).
    - Removed test for non-existent `moduleName` metadata.
    - Verified 15/15 tests passing in Forge.
    - Deleted legacy skipped Hardhat test.

#### ⏭️ Skipped Tests - Pending Forge Migration

**BaseEscrow.security.test.ts** (SKIPPED)

- Reason: Requires resolution module configuration incompatible with current fixtures
- Status: Setup issues causing consistent failures
- Migration needed: Reimplement in Forge with proper fixture structure

## Known Issues

1. **EscrowableERC20 Tests Broken**: Existing Hardhat tests relying on `EscrowableERC20` (e.g., `EscalationFee.test.ts`) are failing because `EscrowableERC20` is a stubbed "placeholder" contract to avoid size limits. It grants no roles and has empty method bodies for governance functions.
2. **EscrowVault Compilation**: `EscrowVault.sol` causes "Stack too deep" errors in Foundry. It has been temporarily disabled (renamed) or excluded to allow other tests to run.

## Forge Test Development

### Existing Forge Tests

Located in `test/foundry/`

### Migration Plan

1. ✅ Keep existing 400+ working Hardhat tests operational
2. ✅ Skip incompatible tests with clear documentation
3. ⏳ Gradually migrate test suites to Forge
4. ⏳ Implement new security tests in Forge
5. ⏳ Eventually deprecate Hardhat tests once Forge coverage is complete

## Running Tests

### Hardhat Tests (Current)

```bash
# Run all tests (includes 112 skipped)
npx hardhat test

# Run specific test file
npx hardhat test test/hardhat/KlerosIntegration.test.ts

# Run with coverage
npx hardhat coverage
```

### Forge Tests (Future)

```bash
# Run all Forge tests
forge test

# Run with gas reporting
forge test --gas-report

# Run with coverage
forge coverage
```

## Test Files Status

### Active Test Files

- ✅ `test/hardhat/BaseEscrow.test.ts` - Core functionality
- ✅ `test/hardhat/ERC20Escrow.test.ts` - ERC20 integration
- ✅ `test/hardhat/KlerosIntegration.test.ts` - Kleros arbitration (41 tests)
- ✅ `test/hardhat/EscalationFee.test.ts` - Fee mechanics
- ✅ `test/hardhat/DecentralizedResolutionModule.test.ts` - Resolution workflows
- ✅ `test/hardhat/DecentralizedResolutionModule.advanced.test.ts` - Advanced unit tests (45 tests)
- ✅ All other existing test files in `test/hardhat/`

### Skipped Test Files (Pending Migration)

- ⏭️ `test/hardhat/ResolverIncentiveModule.comprehensive.test.ts` - Interface mismatch
- ⏭️ `test/hardhat/BaseEscrow.security.test.ts` - Fixture incompatibility

## Notes for Developers

### When Writing New Tests

- **Prefer Forge** for new security and unit tests
- **Use Hardhat** only for integration tests requiring complex JavaScript logic
- **Follow patterns** from existing passing tests

### Before Removing Skipped Tests

Ensure equivalent or better coverage exists in Forge test suite before deleting skipped Hardhat tests.

### Known Issues

1. Some tests call functions that are internal-only (ResolverIncentiveModule)
2. Security test fixtures need refactoring for proper module initialization
3. Timestamp-based tests may need adjustment in Forge (different EVM behavior)

## Related Documentation

- [KLEROS_INTEGRATION_GUIDE.md](./KLEROS_INTEGRATION_GUIDE.md) - Kleros test patterns
- [IMPLEMENTATION_STATUS_REPORT_2026-01-09.md](./IMPLEMENTATION_STATUS_REPORT_2026-01-09.md) - Overall project status
- [CRITICAL_UNIMPLEMENTED_TASKS.md](./CRITICAL_UNIMPLEMENTED_TASKS.md) - Outstanding work items

---

**Last Updated:** 2026-01-09  
**Maintained By:** Development Team
