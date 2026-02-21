# Aave Yield Module Deployment & Validation Plan

## Objective
Validate the Base Sepolia v1 deployment against both default and Aave yield configurations through structured testing phases before committing to mainnet.

## Current State
- ✅ 13/15 contracts deployed on Base Sepolia
- ✅ Default configuration verified and operational
- ⏳ AaveYieldModule: Code exists but NOT YET DEPLOYED
- ✅ All source code verified (Sourcify + BaseScan)

## Testing Strategy

### Phase 1: Default Deployment Validation (Current)
**Goal**: Verify core deployment works without Aave module

**Tests to Run**:
1. **Infrastructure Tests** (Foundry)
   ```
   forge test test/foundry/testnet/Phase0BaseSepoliaFork.t.sol -vv
   ```
   - Contract deployments
   - Address registry
   - Access control
   - Basic functionality

2. **Core Journey Tests** (Foundry)
   ```
   forge test test/foundry/testnet/Phase1CoreJourneysBaseSepoliaFork.t.sol -vv
   ```
   - Release workflows
   - Settlement flows
   - Module registration
   - Default strategies

3. **Module Validation Tests** (Hardhat)
   ```
   pnpm test -- test/hardhat/BaseEscrow.moduleValidation.test.ts
   ```
   - Module registry
   - Strategy activation
   - Module snapshot
   - Permission checks

4. **Security Tests** (Foundry)
   ```
   forge test test/foundry/testnet/SecurityAttackSimBaseSepoliaFork.t.sol -vv
   ```
   - Access control attacks
   - Reentrancy
   - State manipulation
   - Privilege escalation

**Success Criteria**:
- ✅ All Phase0 tests pass
- ✅ All Phase1 tests pass
- ✅ All module validation tests pass
- ✅ No security findings
- ✅ Gas usage acceptable

---

### Phase 2: AaveYieldModule Deployment
**Goal**: Deploy and verify AaveYieldModule integration

**Prerequisites**:
- Phase 1 validation passed
- AaveYieldModule checksum verified (✅ already fixed)
- Aave Pool address confirmed on Base Sepolia

**Deployment Steps**:
1. Verify config is correct
   ```
   cat deploy/75_aave_yield_module.ts | grep -A 5 "Base Sepolia"
   ```

2. Deploy contract
   ```
   pnpm hardhat deploy --network baseSepolia --tags aave
   ```

3. Register in module registry
   ```
   # Via governance proposal or direct if owner
   ```

4. Verify deployment
   ```
   pnpm hardhat verify --network baseSepolia <AAVE_MODULE_ADDRESS> <args>
   ```

---

### Phase 3: Aave Module Integration Validation
**Goal**: Verify Aave module doesn't break existing functionality

**Tests to Run**:
1. **Re-run Core Tests with Aave Module**
   ```
   forge test test/foundry/testnet/Phase1CoreJourneysBaseSepoliaFork.t.sol -vv
   ```

2. **Aave-specific Tests**
   ```
   forge test test/foundry/modules/AaveYieldModuleForkTest.sol -vv
   ```

3. **Integration Tests**
   ```
   pnpm test -- test/hardhat/AaveIntegration.test.ts
   ```

4. **Module Validation**
   ```
   pnpm test -- test/hardhat/BaseEscrow.moduleValidation.test.ts
   ```

**Success Criteria**:
- ✅ All Phase1 tests still pass (no regressions)
- ✅ All Aave-specific tests pass
- ✅ Integration tests pass
- ✅ No new security issues
- ✅ Module properly registered

---

### Phase 4: Yield Generation Testing (Time-based)
**Goal**: Verify yield generation over sufficient time period

**Duration**: 7-30 days (configurable)

**Tests to Run**:
1. **Yield Accumulation Tests**
   ```
   forge test test/foundry/modules/AaveYieldModule.t.sol -vv
   ```

2. **Time-variant Testing**
   - Deploy escrow with Aave module
   - Wait for yield to accrue
   - Verify yield balance increases
   - Test withdrawal of original + yield

3. **Stress Testing**
   - Multiple concurrent escrows
   - Rapid deposit/withdraw cycles
   - Large amounts
   - Edge cases

4. **Comparative Testing**
   - Default vs Aave module comparison
   - Yield generation rates
   - Gas efficiency

**Success Criteria**:
- ✅ Yield visible after N days
- ✅ Yield distribution correct
- ✅ All funds accounted for
- ✅ No losses during cycles
- ✅ Performance acceptable

---

## Branch Selection: Feature Branch (Recommended)

```
Branch: feature/aave-module-validation
Based on: main
Pattern: Main → validation feature branch → test results → merge back
```

**Setup**:
```bash
git checkout main
git pull origin main
git checkout -b feature/aave-module-validation
```

**Rationale**:
- Isolates validation work from main
- Easy to update if issues found
- Keeps release branch clean
- Simple PR workflow
- Rollback friendly

---

## Test Execution Commands

### Phase 1 - Default Deployment
```bash
# Foundry tests (parallel)
forge test test/foundry/testnet/Phase0BaseSepoliaFork.t.sol -vv
forge test test/foundry/testnet/Phase1CoreJourneysBaseSepoliaFork.t.sol -vv
forge test test/foundry/testnet/SecurityAttackSimBaseSepoliaFork.t.sol -vv

# Hardhat tests
pnpm test -- test/hardhat/BaseEscrow.moduleValidation.test.ts
pnpm test -- test/hardhat/BaseEscrow.security.test.ts
```

### Phase 2 - AaveYieldModule Deployment
```bash
export BASESCAN_API_KEY=your_key
pnpm hardhat deploy --network baseSepolia --tags aave
```

### Phase 3 - Aave Module Validation
```bash
# Re-run Phase 1 tests
forge test test/foundry/testnet/Phase1CoreJourneysBaseSepoliaFork.t.sol -vv

# Aave-specific tests
forge test test/foundry/modules/AaveYieldModuleForkTest.sol -vv

# Hardhat integration
pnpm test -- test/hardhat/AaveIntegration.test.ts
```

### Phase 4 - Yield Generation
```bash
# Yield tests
forge test test/foundry/modules/AaveYieldModule.t.sol -vv

# Live testnet monitoring
pnpm test -- test/hardhat/testnet/BaseSepoliaLiveFeeFlows.test.ts
```

---

## Timeline

| Phase | Duration | Notes |
|-------|----------|-------|
| Phase 1 | 1-2 hours | Local tests only |
| Phase 2 | 30 min | Deployment + verification |
| Phase 3 | 2-3 hours | Regression + integration |
| Phase 4 | 7-30 days | Time-dependent yield validation |

**Total**: 2-4 hours initial, 7-30 days yield validation

---

## Deliverables

After completion:
- ✅ Test results document
- ✅ Coverage report
- ✅ Gas analysis
- ✅ Yield accumulation data
- ✅ Security assessment
- ✅ Recommendation for mainnet deployment
- ✅ Release tag: `testnet/base-sepolia-v1-aave-validated`

---

## Rollback Plan

| Scenario | Action |
|----------|--------|
| Phase 1 Failure | Fix deploy scripts, re-run tests |
| Phase 2 Failure | Check constructor args, fix checksum, redeploy |
| Phase 3 Failure | Identify regression, fix config, re-test |
| Phase 4 Failure | Investigate yield logic, file bug, iterate |
