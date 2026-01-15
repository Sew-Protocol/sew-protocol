# Testing Documentation

This directory contains all testing-related documentation for the protocol.

## Overview

The protocol uses a **hybrid testing approach** with both Hardhat (TypeScript) and Foundry (Solidity) test frameworks:

- **Foundry (Forge)**: Contract correctness, invariants, fuzzing, edge cases
- **Hardhat**: System behavior, multi-contract integrations, deployment/upgrade flows

## Key Documents

### Getting Started

- **[TESTING.md](./TESTING.md)** - Comprehensive testing guide and guidelines
- **[Testing_guidelines.md](./Testing_guidelines.md)** - Testing guidelines and best practices
- **[TESTING_GUIDELINES_ASSESSMENT.md](./TESTING_GUIDELINES_ASSESSMENT.md)** - Assessment of testing guidelines adherence

### Test Plans & Strategies

- **[TESTING_ADHERENCE_PLAN.md](./TESTING_ADHERENCE_PLAN.md)** - Plan for achieving testing adherence
- **[TOP_10_TESTING_PRIORITIES.md](./TOP_10_TESTING_PRIORITIES.md)** - Top 10 testing priorities
- **[FORGE_TEST_EXPANSION_SUMMARY.md](./FORGE_TEST_EXPANSION_SUMMARY.md)** - Summary of Foundry test expansion

### Test Execution & Status

- **[TEST_STATUS_REPORT.md](./TEST_STATUS_REPORT.md)** - Current test status report
- **[TESTING_ADHERENCE_COMPLETE.md](./TESTING_ADHERENCE_COMPLETE.md)** - Completion status of testing adherence
- **[TESTING_ADHERENCE_INDEX.md](./TESTING_ADHERENCE_INDEX.md)** - Index of testing adherence coverage
- **[TEST_UPDATE_SUMMARY_2026-01-09.md](./TEST_UPDATE_SUMMARY_2026-01-09.md)** - Test update summary

### Migration & Maintenance

- **[TEST_MIGRATION_NOTE.md](./TEST_MIGRATION_NOTE.md)** - Notes on test migration
- **[TEST_UPDATE_PROMPT.md](./TEST_UPDATE_PROMPT.md)** - Prompt for test updates
- **[DISABLED_TESTS_FIX_GUIDE.md](./DISABLED_TESTS_FIX_GUIDE.md)** - Guide for fixing disabled tests

### Module-Specific Tests

- **[FIX_INCENTIVE_MODULE_TESTS_PROMPT.md](./FIX_INCENTIVE_MODULE_TESTS_PROMPT.md)** - Prompt for fixing incentive module tests
- **[INCENTIVE_MODULE_TEST_PLAN.md](./INCENTIVE_MODULE_TEST_PLAN.md)** - Test plan for incentive module

### Production Testing

- **[MAINNET_RELEASE_SEQUENCE_TESTS.md](./MAINNET_RELEASE_SEQUENCE_TESTS.md)** - Tests for mainnet release sequence

## Test Structure

```
test/
├── hardhat/          # TypeScript integration tests
│   ├── governance/   # Governance and timelock tests
│   ├── integration/  # Multi-contract integration tests
│   └── ...
└── foundry/          # Solidity unit and invariant tests
    ├── core/         # Core contract comprehensive tests
    ├── decentralized-resolution-module/  # DRM tests
    └── ...
```

## Running Tests

```bash
# Run all tests
pnpm test

# Run only Hardhat tests
pnpm test:hardhat

# Run only Foundry tests
pnpm test:foundry

# Generate coverage report
pnpm coverage
```

## See Also

- [Coverage Documentation](../coverage/README.md)
- [Main Documentation](../README.md)
