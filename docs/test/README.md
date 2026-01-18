# Testing Documentation

This directory contains essential testing guidelines and documentation for the protocol.

## Overview

The protocol uses a **hybrid testing approach** with both Hardhat (TypeScript) and Foundry (Solidity) test frameworks:

- **Foundry (Forge)**: Contract correctness, invariants, fuzzing, edge cases
- **Hardhat**: System behavior, multi-contract integrations, deployment/upgrade flows

## Key Documents

### Testing Guidelines

- **[TESTING.md](./TESTING.md)** - Comprehensive testing guide and framework overview
- **[Testing_guidelines.md](./Testing_guidelines.md)** - Testing best practices and guidelines

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

## Historical Test Documentation

Historical test plans, status reports, and implementation tasks have been moved to `docs/more/test/` for reference.

## Quick Reference

### When to Use Forge vs Hardhat

**Use Forge when:**
- Testing pure contract logic (math, state machines, accounting)
- You want fuzzing / property tests
- You need fast iteration on tricky corner cases
- You're testing revert reasons / custom errors precisely
- You want gas assertions and deterministic EVM-level behavior

**Use Hardhat when:**
- You need end-to-end flows that mirror how users/ops interact
- Testing deployment + initialization ordering
- Testing governance lane changes / timelock flows
- Testing role assignments and access control
- Testing integration with external contracts
- Testing upgrade flows and storage layout

## See Also

- [Contributing Guide](../guides/CONTRIBUTING.md) - General contributing guidelines
- [Coding Standards](../guides/CODING_STANDARDS.md) - Code style and standards
