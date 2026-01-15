# Testing Documentation

**Last Updated:** 2026-01-06  
**Purpose:** Comprehensive testing guide for the escrow protocol

---

## Overview

This repository uses a **hybrid testing approach** with both Hardhat (TypeScript) and Foundry (Solidity) test frameworks. Each framework is used for its strengths:

- **Foundry (Forge)**: Contract correctness, invariants, fuzzing, edge cases
- **Hardhat**: System behavior, multi-contract integrations, deployment/upgrade flows

---

## Test Structure

```
test/
├── hardhat/          # TypeScript integration tests
│   ├── governance/   # Governance and timelock tests
│   ├── integration/  # Multi-contract integration tests
│   └── ...
└── foundry/          # Solidity unit and invariant tests
    ├── core/         # Core contract comprehensive tests
    ├── invariants/   # Invariant tests
    ├── priorities/   # Top 10 priority test suites
    └── ...
```

---

## What is Tested in Forge vs Hardhat

### Forge Tests (Contract Correctness)

**Purpose:** Test pure contract logic, invariants, and edge cases

**Coverage:**

- ✅ State machine correctness (`priority2_state_machine.t.sol`)
- ✅ Snapshot immutability (`priority1_snapshot_immutability.t.sol`)
- ✅ Reentrancy protection (`priority3_reentrancy.t.sol`)
- ✅ Caps enforcement (`priority4_caps_enforcement.t.sol`)
- ✅ Guardian down-only powers (`priority5_guardian_downonly.t.sol`)
- ✅ Governance time delays (`priority6_governance_delays.t.sol`)
- ✅ Dispute resolution correctness (`priority7_dispute_resolution.t.sol`)
- ✅ Fee accounting accuracy (`priority8_fee_accounting.t.sol`)
- ✅ Yield generation safety (`priority9_yield_generation.t.sol`)
- ✅ Emergency procedures (`priority10_emergency_procedures.t.sol`)
- ✅ Invariants (`EscrowInvariants.t.sol`)
- ✅ Fuzz tests (multiple test files with `testFuzz`)

**When to Write in Forge:**

- Testing pure contract logic (math, state machines, accounting)
- Fuzzing / property tests
- Fast iteration on tricky corner cases
- Testing revert reasons / custom errors precisely
- Gas assertions and deterministic EVM-level behavior

### Hardhat Tests (System Behavior)

**Purpose:** Test end-to-end flows, integrations, and operational procedures

**Coverage:**

- ✅ Multi-contract integrations (`AaveIntegration.test.ts`)
- ✅ Deployment flows (`MainnetReleaseSequence.test.ts`)
- ✅ Governance/timelock flows (`governance/` tests)
- ✅ Module swaps (`05_ModuleSnapshotting.test.ts`)
- ✅ Access control (`01_AccessControl.test.ts`)
- ✅ Event validation (multiple tests)
- ✅ JS/TS tooling integration (all Hardhat tests)

**When to Write in Hardhat:**

- End-to-end flows that mirror user/ops interactions
- Deployment + initialization ordering
- Governance lane changes / timelock flows
- Module swaps / upgrades
- Validating event correctness for off-chain indexers/UI
- Testing JS/TS tooling integration
- Cross-tool parity checks

---

## How to Run Tests

### Run All Tests

```bash
pnpm test
# Runs: pnpm test:hardhat && pnpm test:foundry
```

### Run Hardhat Tests Only

```bash
pnpm test:hardhat
# or
hardhat test
```

### Run Foundry Tests Only

```bash
pnpm test:foundry
# or
forge test
```

### Run Specific Test Files

**Hardhat:**

```bash
hardhat test test/hardhat/EscrowVault.test.ts
```

**Foundry:**

```bash
forge test --match-path test/foundry/priorities/priority1_snapshot_immutability.t.sol
```

### Run Invariant Tests

```bash
forge test --match-contract EscrowInvariants
```

### Run Fuzz Tests

```bash
forge test --match-test testFuzz
```

---

## Coverage Reporting

### Known Limitations

**Issue 1: Hardhat Coverage Under-Report**

- `solidity-coverage` only measures Hardhat test coverage
- Foundry tests are not included in Hardhat coverage reports
- **Result:** Contracts tested primarily in Foundry show 0% coverage in Hardhat reports

**Issue 2: Forge Coverage Fails**

- `forge coverage` fails due to "stack too deep" errors with large contracts
- This is a tooling limitation, not a testing gap
- **Workaround:** Use behavior coverage (checklists + mapping + invariants) instead of line coverage

### Current Coverage Approach

We use **behavior coverage** rather than chasing a single coverage percentage:

1. **Coverage Map:** See `docs/COVERAGE_MAP.md` (to be created)
2. **Critical Path Coverage:** Documented in test files
3. **Invariant Tests:** More valuable than line coverage for correctness

### Running Coverage

**Hardhat Coverage:**

```bash
pnpm coverage
# Generates: coverage/ directory with HTML report
```

**Foundry Coverage (Currently Disabled):**

```bash
forge coverage  # Fails due to stack too deep
```

---

## Test Coverage Map

See `docs/COVERAGE_MAP.md` for detailed mapping of:

- Contract → key behaviors → test files
- Critical paths covered
- Branch/edge-case matrix

---

## Audit-Ready Testing Checklist

### ✅ Core Correctness (Complete)

- ✅ State machine completeness
- ✅ Access control (all privileged functions tested)
- ✅ Accounting invariants
- ✅ Timeout / stuck-funds prevention

### ✅ Adversarial Behavior (Complete)

- ✅ Fuzz tests for core flows
- ✅ Invariants (Forge) run in CI
- ✅ Reentrancy & callback scenarios

### ⚠️ Adversarial Behavior (In Progress)

- ⚠️ DoS vectors (large arrays, iteration limits, griefing) - **TODO**
- ⚠️ Revert-on-transfer patterns - **TODO**

### ✅ Integration & Ops Readiness (Complete)

- ✅ Deployment tests
- ✅ Upgrade/module swap tests
- ⚠️ Event correctness (partial - needs comprehensive validation)

### ❌ Token/Asset Interaction Safety (Missing)

- ❌ ERC20 edge cases (fee-on-transfer, rebasing, non-standard) - **TODO**

### ✅ CI Discipline (Complete)

- ✅ CI runs all checks on every PR
- ✅ Deterministic test runs

**See `docs/TESTING_GUIDELINES_ASSESSMENT.md` for detailed gap analysis and plan.**

---

## Test Statistics

**Current Test Count:**

- Hardhat: 344 passing tests
- Foundry: 76 passing tests (including invariants)
- **Total: 420 passing tests**

**Test Categories:**

- Unit tests: Core contract functionality
- Integration tests: Multi-contract interactions
- Invariant tests: Property-based testing
- Fuzz tests: Randomized input testing
- Governance tests: Access control and timelock flows
- Deployment tests: Mainnet release sequence

---

## Best Practices

### When to Write in Forge vs Hardhat

**Quick Decision Rule:**

> "If this fails in production, would I debug Solidity first or ops/scripts first?"
>
> - Solidity first → Forge
> - Ops/scripts first → Hardhat

### Avoid Duplication

**One Canonical Home Rule:**

- Invariant/accounting rule → canonical in Forge; Hardhat may do smoke integration
- Operational flow (deploy/upgrade/governance) → canonical in Hardhat; Forge may test underlying invariants

### Test Quality Standards

1. **Clear test names** that describe what is being tested
2. **Comprehensive assertions** that verify expected behavior
3. **Edge case coverage** including boundary conditions
4. **Error case testing** for all revert conditions
5. **Gas considerations** where relevant (especially in Forge)

---

## Related Documentation

- [`docs/Testing_guidelines.md`](./Testing_guidelines.md) - Testing best practices
- [`docs/TESTING_GUIDELINES_ASSESSMENT.md`](./TESTING_GUIDELINES_ASSESSMENT.md) - Current state assessment and plan
- [`docs/COVERAGE_MAP.md`](./COVERAGE_MAP.md) - Detailed coverage mapping (to be created)
- [`docs/TOP_10_TESTING_PRIORITIES.md`](./TOP_10_TESTING_PRIORITIES.md) - Priority test areas

---

**Note:** This document is a living document and will be updated as testing practices evolve.
