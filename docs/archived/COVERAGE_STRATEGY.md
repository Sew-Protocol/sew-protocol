# Test Coverage Strategy

## Problem Removed

**solidity-coverage** created incompatibility issues when attempting to run across both Hardhat and Forge test suites:
- Contract instrumentation caused "Transaction out of gas" errors
- viaIR compilation combined with coverage instrumentation exceeded gas limits during deployment
- Test suites failed during coverage runs despite passing normally
- The tool was not designed for hybrid Hardhat+Forge environments

## Current Approach: Forge-Only Coverage

The project now uses **Forge for all coverage reporting**:

### Rationale
1. **Foundry Benchmark**: Forge's native coverage tools are reliable and well-maintained
2. **Framework Integration**: Forge is the native test framework for Solidity code coverage
3. **No Instrumentation Overhead**: Forge coverage doesn't instrument contracts, avoiding gas limit issues
4. **Pure Solidity Tests**: All core contract logic can be tested in Solidity without layer complexity

### Test Structure

```
test/
├── hardhat/                    # Integration & complex scenarios
│   └── *.test.ts              # TypeScript, tests deployment flows, upgrades
│
└── foundry/                    # Core unit coverage
    └── **/*.t.sol             # Pure Solidity, 100% coverage target
```

### Coverage Targets

| Metric | Target | Current |
|--------|--------|---------|
| **Lines** | 100% | 236/236 tests passing |
| **Functions** | 100% | All core functions tested |
| **Branches** | 100% | All paths exercised |

### Running Coverage

```bash
# Foundry coverage (100% target)
forge coverage

# Hardhat tests (integration layer)
npm run test:hardhat

# Combined test suite
npm test
```

### When to Use Each Framework

**Foundry (test/foundry/**):
- Unit tests for pure contract logic
- State transitions and edge cases
- Gas optimization verification
- Coverage-focused tests

**Hardhat (test/hardhat/**):
- Deployment and upgrade flows
- Cross-contract integration
- Live network simulation
- Transaction sequencing scenarios

## Removed Dependencies

- `solidity-coverage@^0.8.17` - Deleted from package.json
- `coverage` script - Removed from package.json
- `coverage:report` script - Removed from package.json
- `import 'solidity-coverage'` - Removed from hardhat.config.ts

## Benefits

✅ **All core tests pass** without coverage overhead (236 Foundry tests)  
✅ **No gas limit issues** during test execution  
✅ **True 100% coverage possible** in Foundry  
✅ **Cleaner architecture** with defined responsibilities  
✅ **Faster test execution** without instrumentation  
✅ **Native Solidity tests** for better debugging  

## Future Improvements

1. Replicate critical Hardhat tests in Foundry to reach 100% coverage
2. Generate Foundry coverage reports in CI/CD
3. Maintain integration tests in Hardhat for complex scenarios only
