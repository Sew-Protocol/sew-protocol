# Testing Migration Strategy: Foundry vs Hardhat

## Executive Summary

**Recommendation**: **Hybrid Approach** - Use Foundry for core contract testing (invariants, fuzzing, gas optimization) and Hardhat for integration tests and deployment scripts.

---

## Current State

### Existing Test Infrastructure
- **Framework**: Hardhat with TypeScript
- **Test Files**: 
  - `BaseEscrow.test.ts` (Chai + Ethers.js)
  - `EscrowVault.test.ts`
  - `EscrowableERC20.ts`
  - `AaveIntegration.test.ts`
- **Coverage**: ~40-50% (estimated)
- **Testing Style**: Unit tests with exact value assertions

### New Directory Setup
- **Package Manager**: pnpm (vs yarn)
- **Hardhat**: Classic (not Ignition), new version
- **Foundry**: Available and configured
- **Both frameworks**: Can run simultaneously

---

## Foundry Advantages

### 1. **Invariant Testing** ✅
- **Property-based testing**: Tests invariants rather than exact values
- **Example**: "Total escrow balance always equals sum of individual escrows"
- **Better for**: Complex state machines, financial invariants

### 2. **Fuzzing** ✅
- **Automated input generation**: Tests with random valid inputs
- **Finds edge cases**: Boundary conditions, overflow scenarios
- **Better for**: Input validation, arithmetic operations

### 3. **Gas Optimization** ✅
- **Built-in gas reporting**: `forge test --gas-report`
- **Gas snapshots**: Track gas changes over time
- **Better for**: Optimization efforts, contract size reduction

### 4. **Performance** ✅
- **Faster execution**: Native Solidity, no TypeScript overhead
- **Parallel execution**: Tests run concurrently
- **Better for**: Large test suites, CI/CD pipelines

### 5. **Cheatcodes** ✅
- **Rich testing utilities**: `vm.prank`, `vm.expectRevert`, `vm.warp`
- **State manipulation**: Time, block number, balances
- **Better for**: Complex scenarios, edge cases

### 6. **Formal Verification** ✅
- **Integration with tools**: Certora, Halmos
- **Symbolic execution**: Prove properties mathematically
- **Better for**: Critical security properties

---

## Hardhat Advantages

### 1. **TypeScript Integration** ✅
- **Type safety**: Full TypeScript support
- **IDE support**: Better autocomplete, refactoring
- **Better for**: Complex test logic, integration with frontend

### 2. **Deployment Scripts** ✅
- **Deployment infrastructure**: Already set up
- **Network management**: Multi-network support
- **Better for**: Deployment workflows, migration scripts

### 3. **Frontend Integration** ✅
- **Type generation**: TypeChain for frontend
- **Contract artifacts**: Standard format
- **Better for**: Full-stack development

### 4. **Ecosystem** ✅
- **Plugin ecosystem**: Many plugins available
- **Tooling**: Verification, coverage, gas reporting
- **Better for**: Comprehensive development workflow

### 5. **Existing Tests** ✅
- **Migration cost**: Lower if keeping Hardhat
- **Team familiarity**: If team knows Hardhat
- **Better for**: Quick iteration, maintaining existing tests

---

## Recommended Strategy: Hybrid Approach

### Phase 1: Core Contract Tests → Foundry

**Migrate to Foundry**:
1. **BaseEscrow invariants**
   - Total balance = sum of escrows
   - State transitions are valid
   - Fees are correctly calculated
   - Yield distribution is correct

2. **Fuzzing tests**
   - Input validation (amounts, addresses, workflow IDs)
   - Arithmetic operations (fees, yield calculations)
   - State machine transitions

3. **Gas optimization tests**
   - Gas benchmarks for key operations
   - Gas snapshots for regression testing

**Location**: `packages/hardhat/test/foundry/`

**Example Structure**:
```
test/foundry/
├── BaseEscrow.invariants.t.sol
├── BaseEscrow.fuzz.t.sol
├── EscrowVault.invariants.t.sol
├── EscrowableERC20.fuzz.t.sol
└── GasBenchmarks.t.sol
```

### Phase 2: Integration Tests → Hardhat (Keep)

**Keep in Hardhat**:
1. **End-to-end flows**
   - Full escrow lifecycle
   - Multi-contract interactions
   - Event emission verification

2. **Deployment tests**
   - Contract deployment
   - Module registration
   - Configuration setup

3. **Frontend integration**
   - Contract interaction patterns
   - Hook testing (if needed)

**Location**: `packages/hardhat/test/integration/` (or keep existing structure)

---

## Migration Plan

### Step 1: Set Up Foundry Tests (Week 1)

1. **Create Foundry test structure**
   ```bash
   mkdir -p packages/hardhat/test/foundry
   ```

2. **Create `foundry.toml`** (if not exists)
   ```toml
   [profile.default]
   src = "contracts"
   out = "out"
   libs = ["node_modules"]
   test = "test/foundry"
   
   [profile.default.optimizer]
   enabled = true
   runs = 10000
   via_ir = true
   ```

3. **Write first invariant test**
   - Start with simple invariants
   - Example: Balance consistency

### Step 2: Migrate Core Tests (Week 2-3)

1. **Priority order**:
   - BaseEscrow invariants (highest priority)
   - Fuzzing for input validation
   - Gas benchmarks
   - EscrowVault invariants
   - EscrowableERC20 invariants

2. **Migration approach**:
   - Write Foundry tests alongside Hardhat tests
   - Run both in CI
   - Gradually deprecate Hardhat unit tests

### Step 3: Enhance with Fuzzing (Week 4)

1. **Add fuzzing**:
   - Amount fuzzing (0 to max uint256)
   - Address fuzzing (valid addresses)
   - Workflow ID fuzzing
   - State transition fuzzing

2. **Set fuzzing bounds**:
   - Reasonable ranges for production
   - Edge cases (0, max, boundary values)

### Step 4: Keep Hardhat for Integration (Ongoing)

1. **Maintain Hardhat tests**:
   - Integration tests
   - Deployment scripts
   - Frontend integration

2. **Update CI/CD**:
   - Run Foundry tests first (faster)
   - Run Hardhat integration tests
   - Both must pass

---

## Example Test Migration

### Before (Hardhat)
```typescript
it("Should calculate fees correctly", async function () {
  const amount = ethers.parseEther("1");
  const fee = await escrow.calculateFee(amount);
  expect(fee).to.equal(ethers.parseEther("0.01")); // Exact value
});
```

### After (Foundry - Invariant)
```solidity
function testFuzz_FeeCalculationIsConsistent(uint256 amount) public {
    uint256 fee = escrow.calculateFee(amount);
    // Invariant: fee <= amount (never exceeds)
    assertLe(fee, amount);
    // Invariant: fee = amount * feeRate / denominator
    assertEq(fee, amount * escrowFee() / ESCROW_FEE_DENOMINATOR);
}
```

### After (Foundry - Fuzzing)
```solidity
function testFuzz_ReleaseAmountIsValid(
    uint256 escrowAmount,
    address recipient
) public {
    vm.assume(escrowAmount > 0);
    vm.assume(recipient != address(0));
    
    // Create escrow with fuzzed amount
    uint256 workflowId = escrow.createEscrow(recipient, escrowAmount);
    
    // Release
    escrow.release(workflowId);
    
    // Invariant: Balance decreased by exact amount
    assertEq(token.balanceOf(address(escrow)), 0);
    assertEq(token.balanceOf(recipient), escrowAmount);
}
```

---

## Benefits of Hybrid Approach

### ✅ Best of Both Worlds
- **Foundry**: Fast, fuzzing, invariants, gas optimization
- **Hardhat**: TypeScript, deployment, integration, frontend

### ✅ Gradual Migration
- No big-bang rewrite
- Can migrate incrementally
- Both frameworks run in parallel

### ✅ Team Flexibility
- Developers can use preferred framework
- Foundry for contract testing
- Hardhat for integration/deployment

### ✅ CI/CD Efficiency
- Foundry tests run first (faster feedback)
- Hardhat tests for comprehensive coverage
- Parallel execution possible

---

## When to Use Each Framework

### Use Foundry For:
- ✅ Invariant testing (state consistency)
- ✅ Fuzzing (input validation, edge cases)
- ✅ Gas optimization benchmarks
- ✅ Property-based testing
- ✅ Fast unit tests
- ✅ Security-focused tests

### Use Hardhat For:
- ✅ Integration tests (multi-contract)
- ✅ Deployment scripts
- ✅ Frontend integration tests
- ✅ Complex test logic (TypeScript)
- ✅ Network-specific tests
- ✅ Event verification

---

## Migration Checklist

### Foundry Setup
- [ ] Create `foundry.toml` configuration
- [ ] Set up test directory structure
- [ ] Configure remappings for OpenZeppelin
- [ ] Add Foundry scripts to `package.json`

### Core Tests Migration
- [ ] BaseEscrow invariants
- [ ] BaseEscrow fuzzing
- [ ] EscrowVault invariants
- [ ] EscrowableERC20 fuzzing
- [ ] Gas benchmarks

### Integration Tests (Keep Hardhat)
- [ ] End-to-end escrow flows
- [ ] Deployment tests
- [ ] Module integration tests
- [ ] Event emission tests

### CI/CD Updates
- [ ] Add Foundry to CI pipeline
- [ ] Run both test suites
- [ ] Parallel execution
- [ ] Coverage reporting

### Documentation
- [ ] Update testing guide
- [ ] Document test structure
- [ ] Add examples for both frameworks
- [ ] Migration guide for team

---

## Estimated Effort

| Task | Effort | Priority |
|------|--------|----------|
| Foundry setup | 1 day | High |
| BaseEscrow invariants | 3-5 days | High |
| Fuzzing tests | 3-5 days | High |
| Gas benchmarks | 1-2 days | Medium |
| CI/CD integration | 1 day | High |
| Documentation | 1-2 days | Medium |
| **Total** | **10-16 days** | |

---

## Conclusion

**Recommended Approach**: **Hybrid (Foundry + Hardhat)**

- **Foundry**: Core contract testing, invariants, fuzzing, gas optimization
- **Hardhat**: Integration tests, deployment, frontend integration

This approach provides:
- ✅ Best testing capabilities (fuzzing, invariants)
- ✅ Maintains existing infrastructure (deployment, integration)
- ✅ Gradual migration path
- ✅ Team flexibility
- ✅ Comprehensive coverage

**Next Steps**:
1. Set up Foundry test structure
2. Write first invariant tests
3. Migrate core tests incrementally
4. Keep Hardhat for integration

---

**Last Updated**: Current Date**

