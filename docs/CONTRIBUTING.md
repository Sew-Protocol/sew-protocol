# Contributing Guide

Thank you for investing your time in contributing to the Escrow Protocol!

This guide provides an overview of the contribution workflow and development practices to help make the contribution process effective for everyone involved.

## About the Project

This is a **hardhat-deploy-hybrid** escrow protocol project that provides:

- **EscrowableERC20**: ERC20 token with built-in escrow functionality
- **EscrowVault**: Multi-token escrow vault for any ERC20 token
- **Modular Architecture**: Pluggable release strategies, resolution modules, and yield generation/distribution modules
- **Governance**: Onchain governance with TimelockController and OpenZeppelin Governor
- **Hybrid Testing**: Both Hardhat (TypeScript) and Foundry (Solidity) test suites

Read the [README](../README.md) to get an overview of the project.

### Vision

The goal is to provide a secure, modular, and governance-controlled escrow protocol that enables trustless peer-to-peer transactions with built-in dispute resolution, yield generation, and flexible release mechanisms.

### Project Status

The project is under active development. The protocol is currently deployed on Base Sepolia testnet.

## Getting Started

### Prerequisites

- Node.js (v20+)
- pnpm (v8+)
- Foundry (for Foundry tests)

### Setup

```bash
# Install dependencies
pnpm install

# Copy environment file
cp .env.example .env

# Compile contracts
pnpm compile

# Run tests
pnpm test
```

### Development Workflow

1. **Create a feature branch** from `main`:

   ```bash
   git checkout -b feature/your-feature-name
   ```

2. **Make your changes** following the code style guidelines below

3. **Run tests** to ensure everything works:

   ```bash
   # Run all tests
   pnpm test

   # Run only Hardhat tests
   pnpm test:hardhat

   # Run only Foundry tests
   pnpm test:foundry
   ```

4. **Check contract sizes** (important - we have 24KB limit):

   ```bash
   pnpm size:check
   ```

5. **Format and lint**:

   ```bash
   pnpm format
   pnpm lint
   ```

6. **Commit your changes** with clear commit messages

7. **Push and create a Pull Request**

## Code Style and Conventions

### Solidity

- **Solidity Version**: `^0.8.33`
- **Style**: Follow OpenZeppelin style guide
- **Formatting**: Use Prettier (configured in `.prettierrc`)
- **Naming**:
  - Functions: `camelCase`
  - Events: `PascalCase`
  - Constants: `UPPER_SNAKE_CASE`
  - Structs: `PascalCase`

### TypeScript/JavaScript

- **Formatting**: Prettier
- **Linting**: ESLint (configured in project)
- **Type Safety**: TypeScript strict mode

### Function Naming

**Important**: The protocol uses `createEscrow()` as the primary function name, not `escrowTransfer()`.

- ✅ **Use**: `createEscrow(address seller, uint256 amount)`
- ❌ **Don't use**: `escrowTransfer()` (deprecated)

For tests with multiple overloads, use `.getFunction()` to disambiguate:

```typescript
await contract
  .connect(sender)
  .getFunction('createEscrow(address,uint256)')
  .send(recipient.address, amount);
```

### Contract Size

**Critical**: Contracts must stay under the 24KB (EIP-170) limit.

- Always check contract size after changes: `pnpm size:check`
- If approaching limit, consider:
  - Extracting logic to libraries
  - Using `internal` functions instead of `public` where possible
  - Removing unused code
  - Optimizing with compiler settings

## Testing

### Test Structure

- **Hardhat Tests**: `test/hardhat/` (TypeScript)
- **Foundry Tests**: `test/foundry/` (Solidity)
- **Test Helpers**: `test/helpers/`

### Writing Tests

#### Hardhat Tests

```typescript
import { expect } from 'chai';
import { ethers } from 'hardhat';
import { EscrowableERC20 } from '../typechain-types';

describe('Feature Name', function () {
  let escrowableERC20: EscrowableERC20;

  beforeEach(async function () {
    // Setup
  });

  it('Should do something', async function () {
    // Test implementation
  });
});
```

#### Foundry Tests

```solidity
// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import 'forge-std/Test.sol';
import '../contracts/EscrowableERC20.sol';

contract FeatureTest is Test {
  EscrowableERC20 escrow;

  function setUp() public {
    // Setup
  }

  function testSomething() public {
    // Test implementation
  }
}
```

### Test Coverage

- Aim for high test coverage (>90%)
- Test both success and failure cases
- Test edge cases (zero values, max values, boundary conditions)
- Test access control (roles, permissions)
- Test state transitions

### Known Test Issues

Some tests may be failing due to:

- Function name changes (`escrowTransfer` → `createEscrow`)
- Deprecated functions (`setAuthorizedResolver` is deprecated)
- Missing module deployments in test setup

When fixing tests:

1. Update function names to `createEscrow()`
2. Use `.getFunction()` for overloaded functions
3. Ensure all required modules are deployed in test setup
4. Update deprecated function calls

## Architecture Guidelines

### Modular Design

The protocol uses a modular architecture:

- **Release Strategies**: `IReleaseStrategy` - Custom release logic
- **Resolution Modules**: `IResolutionModule` - Dispute resolution
- **Yield Generation**: `IYieldGenerationModule` - Yield generation (e.g., Aave)
- **Yield Distribution**: `IYieldDistributionModule` - Yield distribution

When adding new modules:

1. Implement the interface
2. Add to module registry
3. Update documentation
4. Add tests

### Governance

All protocol changes go through governance:

1. **Standard Lane**: Immediate execution (e.g., pause, set max attachments)
2. **Slow Lane**: 7-day delay (e.g., fee changes, module swaps)

See [Governance Documentation](governance.md) for details.

### Security Considerations

- **Reentrancy**: Use `nonReentrant` modifier where appropriate
- **Access Control**: Use role-based access control (RBAC)
- **Input Validation**: Validate all inputs
- **Checks-Effects-Interactions**: Follow CEI pattern
- **Overflow/Underflow**: Solidity 0.8+ handles automatically, but be aware

## Documentation

### Code Documentation

- **NatSpec**: All public/external functions must have NatSpec comments
- **Events**: Document all events
- **Errors**: Document all custom errors

Example:

```solidity
/**
 * @notice Create a new escrow with custom settings
 * @param seller Recipient address (seller)
 * @param amount Amount to escrow (fee will be deducted)
 * @param settings Escrow settings
 * @return workflowId The ID of the created escrow transfer
 * @dev Emits EscrowTransferCreated event
 */
function createEscrow(
  address seller,
  uint256 amount,
  EscrowSettings memory settings
) public nonReentrant whenNotPaused returns (uint256 workflowId) {
  // Implementation
}
```

### Documentation Files

- Update relevant documentation in `docs/` when making changes
- Keep `_DOCUMENT_INDEX.md` updated
- Document breaking changes in migration guides

## Pull Request Process

We follow the ["fork-and-pull" Git workflow](https://github.com/susam/gitpr)

### PR Checklist

Before submitting a PR, ensure:

- [ ] All tests pass (`pnpm test`)
- [ ] Contract sizes are within limits (`pnpm size:check`)
- [ ] Code is formatted (`pnpm format`)
- [ ] No linting errors (`pnpm lint`)
- [ ] TypeScript compiles (`pnpm typecheck`)
- [ ] Documentation is updated
- [ ] Commit messages are clear and descriptive
- [ ] PR description explains the changes and why

### PR Description Template

```markdown
## Summary

Brief description of changes

## Changes

- Change 1
- Change 2

## Testing

- [ ] Unit tests added/updated
- [ ] Integration tests pass
- [ ] Manual testing completed

## Contract Size Impact

- BaseEscrow: +X bytes / -X bytes
- EscrowVault: +X bytes / -X bytes
- EscrowableERC20: +X bytes / -X bytes

## Breaking Changes

- [ ] Yes (describe)
- [ ] No

## Related Issues

Closes #123
```

### Review Process

- PRs require at least one approval
- All CI checks must pass
- Code review feedback must be addressed
- Once approved, PRs are squashed and merged

## Issues

### Reporting Issues

When reporting issues, include:

- **Description**: Clear description of the issue
- **Steps to Reproduce**: Detailed steps
- **Expected Behavior**: What should happen
- **Actual Behavior**: What actually happens
- **Environment**: Network, contract addresses, etc.
- **Screenshots/Logs**: If applicable

### Solving Issues

1. Check existing issues to avoid duplicates
2. Assign yourself if working on an issue
3. Create a branch from `main`
4. Implement the fix
5. Add tests for the fix
6. Submit a PR with reference to the issue

## Governance Contributions

For governance-related contributions:

- See [Governance Process](GOVERNANCE_PROCESS.md)
- Follow [Upgrade Policy](UPGRADE_POLICY.md)
- Review [Emergency Policy](EMERGENCY_POLICY.md)
- Check [Governance Surface Map](GOVERNANCE_SURFACE_MAP.md)

## Code of Conduct

- Be respectful and inclusive
- Provide constructive feedback
- Help others learn and grow
- Follow security best practices

## Questions?

- Check existing documentation in `docs/`
- Review [Document Index](_DOCUMENT_INDEX.md)
- Open an issue for questions or discussions

Thank you for contributing! 🎉
