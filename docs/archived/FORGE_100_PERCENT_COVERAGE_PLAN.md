# Forge 100% Test Coverage Plan

## Executive Summary

Goal: Achieve 100% test coverage in Foundry (Forge) for all core contracts, with Hardhat serving as an integration test layer.

**Current Status:**
- ✅ 236 Foundry tests passing
- ✅ 483 Hardhat core tests passing  
- ❌ Forge coverage compilation fails (stack too deep without viaIR)
- ⚠️ Coverage tool incompatible with viaIR optimization

## Coverage Strategy

### Phase 1: Fix Coverage Tooling (IMMEDIATE)
**Problem:** `forge coverage` fails with "Stack too deep" errors because coverage mode disables optimizer and viaIR.

**Solutions:**
1. **Option A (Recommended):** Use `--ir-minimum` flag with coverage
   - Command: `forge coverage --ir-minimum`
   - Enables viaIR with minimum optimization
   - May have slightly inaccurate source mappings but functional
   
2. **Option B:** Simplify contracts temporarily for coverage runs
   - Not recommended (defeats purpose)

3. **Option C:** Use manual coverage via trace analysis
   - Run tests with `-vvvv` and analyze traces
   - Labor intensive but accurate

**Action Items:**
- [ ] Test `forge coverage --ir-minimum` with current contracts
- [ ] If still fails, create simplified mock contracts for coverage measurement
- [ ] Document coverage baseline once tooling works

---

## Phase 2: Map Hardhat Tests → Forge Tests

### Current Test Distribution

#### Foundry Tests (18 files, 236 tests)
```
test/foundry/
├── core/                          # 3 files - Core contract comprehensive tests
│   ├── BaseEscrowComprehensive.t.sol
│   ├── EscrowableERC20Comprehensive.t.sol
│   └── EscrowVaultComprehensive.t.sol
├── priorities/                    # 10 files - Security priority tests
│   ├── priority1_snapshot_immutability.t.sol
│   ├── priority2_state_machine.t.sol
│   ├── priority3_reentrancy.t.sol
│   ├── priority4_caps_enforcement.t.sol
│   ├── priority5_guardian_downonly.t.sol
│   ├── priority6_governance_delays.t.sol
│   ├── priority7_dispute_resolution.t.sol
│   ├── priority8_fee_accounting.t.sol
│   ├── priority9_yield_generation.t.sol
│   └── priority10_emergency_procedures.t.sol
├── security/                      # 1 file - DoS & attack vectors
│   └── DoSVectors.t.sol
├── token/                         # 1 file - ERC20 edge cases
│   └── ERC20EdgeCases.t.sol
├── libraries/                     # 1 file - Library validation
│   └── YieldDistributionValidation.t.sol
├── invariants/                    # 2 files - Property-based testing
│   ├── EscrowInvariants.t.sol
│   └── EscrowHandler.sol
└── governance/                    # 1 file - Governance simulation
    └── GovForkSim.t.sol
```

#### Hardhat Tests (13 files, 483 passing + 52 failing)
```
test/hardhat/
├── BaseEscrow.test.ts                              # ✅ Core escrow logic
├── BaseEscrow.moduleValidation.test.ts             # ✅ Module validation
├── BaseEscrow.security.test.ts                     # ❌ 22 FAILING (missing resolution module setup)
├── EscrowVault.test.ts                             # ✅ Vault-specific tests
├── EscrowableERC20.test.ts                         # ✅ Token escrow tests
├── AaveIntegration.test.ts                         # ✅ Aave yield integration
├── EscalationFee.test.ts                           # ✅ Fee escalation logic
├── CoreContractsCoverage.test.ts                   # ✅ Coverage baseline
├── ModuleMetadata.test.ts                          # ✅ Module metadata/versioning
├── MainnetReleaseSequence.test.ts                  # ✅ Deployment sequences
├── upgradeableBox.test.ts                          # ✅ Upgrade patterns
├── KlerosIntegration.test.ts                       # ❌ 0 FAILING (new feature)
├── DecentralizedResolutionModule.advanced.test.ts  # ❌ 0 FAILING (new feature)
└── ResolverIncentiveModule.comprehensive.test.ts   # ❌ 30 FAILING (new feature)
```

---

## Phase 3: Coverage Gaps Analysis

### Contracts Requiring Additional Forge Tests

#### 1. **BaseEscrow.sol** - Core escrow logic
**Existing Forge Coverage:**
- ✅ Comprehensive tests (BaseEscrowComprehensive.t.sol)
- ✅ State machine tests (priority2_state_machine.t.sol)
- ✅ Reentrancy tests (priority3_reentrancy.t.sol)
- ✅ Dispute resolution (priority7_dispute_resolution.t.sol)
- ✅ Invariant tests (EscrowInvariants.t.sol)

**Missing from Forge (needs replication):**
- [ ] Module validation edge cases (from BaseEscrow.moduleValidation.test.ts)
  - Module interface validation
  - Metadata detection
  - Version compatibility checking
  - Backward compatibility
- [ ] Advanced security scenarios (from BaseEscrow.security.test.ts - ONCE FIXED)
  - Reentrancy attack vectors
  - Integer overflow/underflow edge cases
  - Access control bypass attempts
  - State machine violations with complex workflows
  - Invalid workflow ID handling
  - Time-based operation edge cases

**Estimated New Tests:** 40-50 tests

---

#### 2. **EscrowableERC20.sol** - Token-based escrow
**Existing Forge Coverage:**
- ✅ Comprehensive tests (EscrowableERC20Comprehensive.t.sol)
- ✅ ERC20 edge cases (ERC20EdgeCases.t.sol)
- ✅ Fee accounting (priority8_fee_accounting.t.sol)

**Missing from Forge:**
- [ ] Complex token transfer scenarios
- [ ] Fee calculation edge cases (zero fee, max fee, rounding)
- [ ] Token balance edge cases with escrow

**Estimated New Tests:** 15-20 tests

---

#### 3. **EscrowVault.sol** - Vault-based escrow
**Existing Forge Coverage:**
- ✅ Comprehensive tests (EscrowVaultComprehensive.t.sol)
- ✅ Caps enforcement (priority4_caps_enforcement.t.sol)

**Missing from Forge:**
- [ ] Multi-token deposit scenarios (from EscrowVault.test.ts)
- [ ] Vault-specific edge cases
- [ ] Exposure tracking with multiple tokens

**Estimated New Tests:** 20-25 tests

---

#### 4. **AaveYieldGenerationModule.sol** + **AaveYieldModule.sol**
**Existing Forge Coverage:**
- ✅ Yield generation tests (priority9_yield_generation.t.sol)
- ✅ Yield distribution validation (YieldDistributionValidation.t.sol)

**Missing from Forge:**
- [ ] Full Aave integration scenarios (from AaveIntegration.test.ts)
  - Aave configuration and setup
  - Deposit/withdrawal flows
  - Yield calculation accuracy
  - Yield distribution on release/cancel
  - Proportional withdrawals
  - Failure scenarios
  - Total deposited tracking

**Estimated New Tests:** 30-35 tests

---

#### 5. **DefaultResolutionModule.sol** + Resolution System
**Existing Forge Coverage:**
- ✅ Basic dispute resolution (priority7_dispute_resolution.t.sol)

**Missing from Forge:**
- [ ] Resolution module lifecycle
- [ ] Resolver selection logic
- [ ] Module upgrade scenarios
- [ ] Metadata and versioning

**Estimated New Tests:** 15-20 tests

---

#### 6. **Fee & Escalation System**
**Existing Forge Coverage:**
- ✅ Fee accounting (priority8_fee_accounting.t.sol)

**Missing from Forge:**
- [ ] Escalation fee complex scenarios (from EscalationFee.test.ts)
- [ ] Multi-level escalation
- [ ] Fee distribution accuracy

**Estimated New Tests:** 10-15 tests

---

#### 7. **Governance & Timelock**
**Existing Forge Coverage:**
- ✅ Governance delays (priority6_governance_delays.t.sol)
- ✅ Guardian downonly (priority5_guardian_downonly.t.sol)
- ✅ Emergency procedures (priority10_emergency_procedures.t.sol)
- ✅ Fork simulation (GovForkSim.t.sol)

**Missing from Forge:**
- [ ] Complete governance lifecycle
- [ ] Role-based access control edge cases
- [ ] Timelock queue/execute/cancel scenarios

**Estimated New Tests:** 10-15 tests

---

## Phase 4: Test Replication Roadmap

### Priority 1: Fix Tooling (Week 1)
- [ ] Resolve `forge coverage` compilation issues
- [ ] Establish coverage baseline measurement
- [ ] Document coverage gaps by contract

### Priority 2: Core Security Tests (Week 1-2)
**Target:** BaseEscrow security and edge cases
- [ ] Create `test/foundry/security/BaseEscrowSecurity.t.sol`
- [ ] Replicate all tests from BaseEscrow.security.test.ts (22 tests)
- [ ] Add Solidity-specific attack vectors (reentrancy, overflow, etc.)
- [ ] Target: 50+ security tests

### Priority 3: Module System Coverage (Week 2)
**Target:** Module validation and metadata
- [ ] Create `test/foundry/core/ModuleSystemComprehensive.t.sol`
- [ ] Replicate module validation tests (BaseEscrow.moduleValidation.test.ts)
- [ ] Add module upgrade/downgrade scenarios
- [ ] Target: 40+ module tests

### Priority 4: Aave Integration (Week 2-3)
**Target:** Complete Aave yield coverage
- [ ] Create `test/foundry/integrations/AaveIntegrationComprehensive.t.sol`
- [ ] Use mock Aave contracts for testing
- [ ] Replicate all AaveIntegration.test.ts scenarios (18 tests)
- [ ] Add yield calculation edge cases
- [ ] Target: 40+ Aave tests

### Priority 5: Vault & Multi-Token (Week 3)
**Target:** EscrowVault comprehensive coverage
- [ ] Enhance `EscrowVaultComprehensive.t.sol` with scenarios from EscrowVault.test.ts
- [ ] Multi-token deposit/withdrawal combinations
- [ ] Exposure tracking accuracy tests
- [ ] Target: 30+ vault tests

### Priority 6: Fee & Escalation (Week 3)
**Target:** Fee system edge cases
- [ ] Create `test/foundry/core/FeeSystemComprehensive.t.sol`
- [ ] Replicate EscalationFee.test.ts scenarios
- [ ] Add fee calculation edge cases
- [ ] Target: 20+ fee tests

### Priority 7: Governance Deep Dive (Week 4)
**Target:** Complete governance coverage
- [ ] Enhance governance tests with role-based scenarios
- [ ] Timelock edge cases
- [ ] Emergency pause/unpause flows
- [ ] Target: 20+ governance tests

---

## Phase 5: Coverage Verification

### Success Criteria
- ✅ `forge coverage` runs without errors
- ✅ 100% line coverage on core contracts:
  - BaseEscrow.sol
  - EscrowableERC20.sol
  - EscrowVault.sol
  - DefaultResolutionModule.sol
  - AaveYieldModule.sol
- ✅ 95%+ branch coverage on all contracts
- ✅ 100% function coverage on critical paths
- ✅ All 400+ Forge tests passing

### Coverage Measurement Commands
```bash
# Run coverage with IR support
forge coverage --ir-minimum

# Generate detailed report
forge coverage --ir-minimum --report lcov

# Generate HTML report (if supported)
genhtml lcov.info -o coverage/

# Summary view
forge coverage --ir-minimum --report summary
```

---

## Phase 6: Documentation & CI Integration

### Deliverables
- [ ] Coverage badge in README.md
- [ ] CI/CD coverage reporting (GitHub Actions)
- [ ] Coverage threshold enforcement (95%+ required)
- [ ] Automated coverage regression detection
- [ ] Monthly coverage review process

### CI Configuration
```yaml
# .github/workflows/coverage.yml
- name: Run Forge Coverage
  run: forge coverage --ir-minimum --report summary
  
- name: Check Coverage Threshold
  run: |
    COVERAGE=$(forge coverage --ir-minimum --report summary | grep "Total" | awk '{print $2}')
    if [ $(echo "$COVERAGE < 95.0" | bc) -eq 1 ]; then
      echo "Coverage $COVERAGE% is below 95% threshold"
      exit 1
    fi
```

---

## Estimated Timeline

| Phase | Duration | Deliverable |
|-------|----------|------------|
| **Phase 1: Tooling** | 3 days | Coverage baseline established |
| **Phase 2: Security** | 5 days | 50+ security tests in Forge |
| **Phase 3: Modules** | 4 days | 40+ module tests in Forge |
| **Phase 4: Aave** | 5 days | 40+ Aave integration tests |
| **Phase 5: Vault** | 3 days | 30+ vault tests |
| **Phase 6: Fees** | 3 days | 20+ fee system tests |
| **Phase 7: Governance** | 3 days | 20+ governance tests |
| **Phase 8: Verification** | 4 days | 100% coverage verified |

**Total Estimated Time:** 4 weeks (20 working days)

---

## Test File Creation Checklist

### New Forge Test Files to Create
- [ ] `test/foundry/security/BaseEscrowSecurity.t.sol`
- [ ] `test/foundry/core/ModuleSystemComprehensive.t.sol`
- [ ] `test/foundry/integrations/AaveIntegrationComprehensive.t.sol`
- [ ] `test/foundry/core/FeeSystemComprehensive.t.sol`
- [ ] `test/foundry/governance/GovernanceComprehensive.t.sol`
- [ ] `test/foundry/core/EscrowVaultExtended.t.sol` (enhance existing)
- [ ] `test/foundry/security/AccessControlAttacks.t.sol`
- [ ] `test/foundry/security/TimelockAttacks.t.sol`

**Target:** 400+ total Forge tests (currently 236, add ~170)

---

## Maintenance Strategy

### Ongoing Practices
1. **Every new feature:** Write Forge tests FIRST
2. **Every bug fix:** Add regression test in Forge
3. **Weekly coverage review:** Track coverage trends
4. **Monthly audit:** Review coverage gaps
5. **Hardhat tests:** Only for complex integration scenarios

### Coverage Quality Metrics
- **Quantity:** 400+ Forge tests
- **Quality:** All critical paths exercised
- **Speed:** Test suite < 2 minutes
- **Reliability:** Zero flaky tests
- **Maintainability:** Clear test organization

---

## Appendix: Contract Coverage Matrix

| Contract | Lines | Current Forge Coverage | Target | Gap |
|----------|-------|----------------------|--------|-----|
| BaseEscrow.sol | ~800 | 75% (est) | 100% | 25% |
| EscrowableERC20.sol | ~600 | 80% (est) | 100% | 20% |
| EscrowVault.sol | ~500 | 85% (est) | 100% | 15% |
| AaveYieldModule.sol | ~400 | 70% (est) | 100% | 30% |
| DefaultResolutionModule.sol | ~300 | 75% (est) | 100% | 25% |
| Libraries & Utils | ~200 | 90% (est) | 100% | 10% |

**Note:** Estimates based on Hardhat test coverage. Exact numbers pending `forge coverage` fix.

---

## Questions & Decisions

### Q1: Should we keep Hardhat tests after reaching 100% in Forge?
**A:** YES - Hardhat tests serve as integration layer:
- Deployment sequences
- Upgrade testing
- Network forking scenarios
- Gas optimization verification

### Q2: What about the new failing test suites (Kleros, etc.)?
**A:** Fix separately:
- KlerosIntegration.test.ts - New feature, needs proper setup
- DecentralizedResolutionModule.advanced.test.ts - New feature
- ResolverIncentiveModule.comprehensive.test.ts - New feature
- BaseEscrow.security.test.ts - Fix resolution module setup (see below)

### Q3: Priority order for test replication?
**A:** 
1. Security (reentrancy, overflow, access control)
2. Core escrow logic edge cases
3. Module system
4. Aave integration
5. Vault multi-token scenarios
6. Fee/escalation edge cases
7. Governance deep dive

---

## Next Steps

1. **IMMEDIATE:** Fix `forge coverage` compilation
2. **TODAY:** Fix failing Hardhat tests (resolution module setup)
3. **THIS WEEK:** Start Phase 2 - Security test replication
4. **THIS MONTH:** Reach 100% coverage in Forge

---

**Last Updated:** 2026-01-09  
**Status:** Plan Ready for Execution  
**Owner:** Development Team
