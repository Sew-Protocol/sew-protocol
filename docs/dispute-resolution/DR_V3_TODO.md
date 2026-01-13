# DR v3 Implementation TODO

**Target:** Decentralize Capital (Resolver Staking + Slashing)  
**Status:** Planning Phase  
**Approach:** Interface-first, no-op stubs, then real implementations with invariants

---

## Overview

DR v3 introduces **capital at risk** for resolvers through staking and slashing mechanisms. This is the final phase of the staged rollout: "Decentralise decisions first, decentralise incentives second, **decentralise capital last**."

**Key Principle:** Capital at risk creates adversarial pressure. We only introduce this after decisions (v1) and incentives (v2) are proven stable.

---

## Phase 1: Interface Boundaries (No-Op Implementations)

### Goal
Define clean interfaces for staking and slashing modules, integrate them into `DecentralizedResolutionModule` with no-op stubs, ensuring the architecture supports hot-swapping without breaking existing functionality.

### Tasks

#### 1.1 Create `IStakingModule.sol` Interface
- [ ] Define stake/unstake functions
- [ ] Define stake queries (getStake, getAvailableStake, isStakeSufficient)
- [ ] Define delegation functions (for senior backing)
- [ ] Define lifecycle hooks (onStakeChanged, onResolverAssigned)
- [ ] Define emergency functions (pause, emergencyWithdraw)
- [ ] Add events (StakeDeposited, StakeWithdrawn, StakeDelegated, etc.)

#### 1.2 Create `ISlashingModule.sol` Interface
- [ ] Define slash functions (slashForTimeout, slashForReversal, slashForFraud)
- [ ] Define slash calculation functions (getSlashAmount, getSlashableStake)
- [ ] Define appeal functions (appealSlash, resolveSlashAppeal)
- [ ] Define lifecycle hooks (onSlashingEvent, onResolverRemoved)
- [ ] Add events (ResolverSlashed, SlashAppealed, SlashReversed, etc.)

#### 1.3 Create `StakingModuleNoOp.sol`
- [ ] Implement IStakingModule with no-op functions
- [ ] All functions return success but do nothing
- [ ] Emit events for observability
- [ ] Document "This is a placeholder for testing"

#### 1.4 Create `SlashingModuleNoOp.sol`
- [ ] Implement ISlashingModule with no-op functions
- [ ] All functions return success but do nothing
- [ ] Emit events for observability
- [ ] Document "This is a placeholder for testing"

#### 1.5 Integrate into `DecentralizedResolutionModule`
- [ ] Add `IStakingModule public stakingModule` storage variable
- [ ] Add `ISlashingModule public slashingModule` storage variable
- [ ] Add governance functions to set modules (slow lane)
- [ ] Wire lifecycle hooks:
  - Call `stakingModule.onResolverAssigned()` when resolver assigned
  - Call `slashingModule.onSlashingEvent()` on timeout/reversal
- [ ] Add view functions to check if modules are active
- [ ] Ensure backward compatibility (modules can be address(0))

#### 1.6 Write Integration Tests
- [ ] Test module swapping (no-op → real)
- [ ] Test lifecycle hooks called correctly
- [ ] Test backward compatibility (v1/v2 work without v3 modules)
- [ ] Test governance controls (only timelock can set modules)

---

## Phase 2: Staking Module Implementation

### Goal
Implement real staking logic with ERC20 tokens, time-locks, and delegation support.

### Tasks

#### 2.1 Create `ResolverStakingModuleV1.sol`
- [ ] ERC20 stake token support
- [ ] Minimum stake requirements per resolver tier
- [ ] Stake time-lock periods (prevent instant withdrawal after bad decision)
- [ ] Delegation support (senior resolvers back standard resolvers)
- [ ] Stake utilization tracking (how much is "at risk" vs "available")
- [ ] Emergency pause mechanism

#### 2.2 Staking Features
- [ ] `stake(uint256 amount)` - Deposit stake tokens
- [ ] `unstake(uint256 amount)` - Withdraw (after time-lock)
- [ ] `delegateStake(address resolver, uint256 amount)` - Senior backs resolver
- [ ] `undelegateStake(address resolver, uint256 amount)` - Remove backing
- [ ] View functions for stake status

#### 2.3 Stake Requirements
- [ ] Standard resolver: minimum stake (e.g., 1000 tokens)
- [ ] Senior resolver: higher minimum (e.g., 10000 tokens)
- [ ] Stake multiplier for workload capacity
- [ ] Grace period for falling below minimum

#### 2.4 Stake Time-Locks
- [ ] Post-decision lock (e.g., 7 days after resolution)
- [ ] Appeal window lock (stake frozen during appeals)
- [ ] Escalation lock (stake frozen if escalated)
- [ ] Configurable lock durations per scenario

---

## Phase 3: Slashing Module Implementation

### Goal
Implement slashing logic with graduated penalties, appeals, and fraud proofs.

### Tasks

#### 3.1 Create `ResolverSlashingModuleV1.sol`
- [ ] Slashing calculation logic (percentage-based)
- [ ] Graduated penalties (timeout < reversal < fraud)
- [ ] Slashing appeals process
- [ ] Slash distribution (protocol, counter-party, insurance pool)
- [ ] Fraud proof verification

#### 3.2 Slashing Rules
- [ ] **Timeout Slash:** 1-5% of stake (configurable)
- [ ] **Reversal Slash:** 5-20% of stake (based on severity)
- [ ] **Fraud Slash:** 50-100% of stake (provable malicious behavior)
- [ ] Max slash per period (prevent cascading losses)
- [ ] Accumulated slash tracking

#### 3.3 Slashing Appeals
- [ ] Resolver can appeal slash within window (e.g., 3 days)
- [ ] Appeal requires bond (to prevent spam)
- [ ] Senior resolver or DAO reviews appeal
- [ ] Slash reversed or upheld
- [ ] Appeal bond returned or forfeited

#### 3.4 Slash Distribution
- [ ] 50% to protocol treasury
- [ ] 30% to counter-party (user harmed by bad decision)
- [ ] 20% to insurance pool (covers catastrophic failures)
- [ ] Configurable percentages via governance

---

## Phase 4: Fraud Lane Implementation

### Goal
Implement off-chain fraud proof system for detecting collusion and malicious behavior.

### Tasks

#### 4.1 Create `FraudProofModule.sol`
- [ ] Fraud proof submission (anyone can submit)
- [ ] Proof types: collusion, bribery, outcome manipulation
- [ ] Evidence format (merkle proofs, signatures, etc.)
- [ ] Verification logic
- [ ] Reward for valid fraud proofs

#### 4.2 Fraud Detection
- [ ] Collusion detection (multiple resolvers same address)
- [ ] Bribery detection (suspicious on-chain payments)
- [ ] Outcome manipulation (statistically unlikely patterns)
- [ ] Off-chain coordination detection (requires external evidence)

#### 4.3 Fraud Proof Verification
- [ ] Cryptographic proof validation
- [ ] Dispute period (resolver can counter-prove)
- [ ] DAO escalation for complex cases
- [ ] Automatic slashing on verified fraud

---

## Phase 5: Economic Safety Features

### Goal
Implement safety mechanisms to prevent catastrophic failures and black swan events.

### Tasks

#### 5.1 Stake Insurance Pool
- [ ] Pool funded by protocol fees + slash distributions
- [ ] Covers user losses when resolver stake insufficient
- [ ] Caps on insurance payouts per incident
- [ ] Pool rebalancing mechanism

#### 5.2 Circuit Breakers
- [ ] Max slash per resolver per period (e.g., 50% per month)
- [ ] Total slash cap across system (prevent bank run)
- [ ] Emergency pause if anomalies detected
- [ ] Gradual resume mechanism

#### 5.3 Stake Liquidity Protection
- [ ] Minimum liquidity requirements (can't withdraw below threshold)
- [ ] Staged withdrawal (e.g., 10% per week)
- [ ] Exit queue (prevents mass exodus)
- [ ] Notice period before full exit

---

## Phase 6: Testing & Invariants

### Goal
Comprehensive testing including invariants, fuzz tests, and economic simulations.

### Tasks

#### 6.1 Invariant Tests
- [ ] Stake conservation: `totalStaked = sum(allResolverStakes) + delegated`
- [ ] Slashing bounds: `totalSlashed <= totalStaked`
- [ ] Time-lock enforcement: `cannotWithdrawDuringLock`
- [ ] Delegation integrity: `delegatedStake <= delegatorStake`
- [ ] Insurance pool solvency: `insurancePool >= minRequired`

#### 6.2 Fuzz Tests
- [ ] Random stake/unstake sequences
- [ ] Random slashing events
- [ ] Random fraud proof submissions
- [ ] Concurrent resolver actions
- [ ] Edge cases (minimum stakes, maximum slashes, etc.)

#### 6.3 Economic Simulations
- [ ] Simulate resolver behavior under different slash rates
- [ ] Model insurance pool sustainability
- [ ] Test attack scenarios (coordinated slashing, stake withdrawal)
- [ ] Verify economic equilibrium

---

## Phase 7: Integration & Migration

### Goal
Integrate v3 with v1/v2, create migration path, and ensure backward compatibility.

### Tasks

#### 7.1 Module Integration
- [ ] Wire staking module into resolution flow
- [ ] Wire slashing module into timeout/reversal handling
- [ ] Ensure v1 (workload) and v2 (bonds) still work
- [ ] Test full stack: v1 EMA + v2 bonds + v3 staking

#### 7.2 Migration Path
- [ ] Phase-in period (staking optional initially)
- [ ] Stake requirement ramp-up (start low, increase over time)
- [ ] Legacy resolver support (grandfathered without stake)
- [ ] Communication plan (notify resolvers of requirements)

#### 7.3 Governance Controls
- [ ] Timelock for all v3 parameter changes
- [ ] DAO vote for major changes (slash rates, minimums)
- [ ] Emergency multisig for circuit breakers
- [ ] Monitoring dashboard for stake/slash metrics

---

## Implementation Order

### Week 1: Interfaces & No-Ops
1. Create IStakingModule interface
2. Create ISlashingModule interface
3. Create no-op implementations
4. Integrate into DecentralizedResolutionModule
5. Write integration tests

### Week 2: Staking Module
1. Implement ResolverStakingModuleV1
2. Add stake/unstake logic
3. Add delegation support
4. Write unit tests
5. Write fuzz tests

### Week 3: Slashing Module
1. Implement ResolverSlashingModuleV1
2. Add slashing calculation logic
3. Add appeals process
4. Write unit tests
5. Write fuzz tests

### Week 4: Fraud Lane & Safety
1. Implement FraudProofModule
2. Add circuit breakers
3. Add insurance pool
4. Write economic simulation tests
5. Write invariant tests

### Week 5: Integration & Testing
1. Full stack integration tests
2. Migration path testing
3. Security audit preparation
4. Documentation
5. Deployment scripts

---

## Risk Mitigation

### Critical Risks
1. **Stake Theft:** Improper access control on withdrawal
   - Mitigation: Multi-sig for emergency functions, time-locks
2. **Cascading Slashing:** One bad resolver triggers mass slashing
   - Mitigation: Slash caps, circuit breakers
3. **Insurance Pool Drain:** Insufficient funds for catastrophic event
   - Mitigation: Pool caps, reinsurance, emergency pause
4. **Collusion:** Multiple resolvers coordinate to game system
   - Mitigation: Fraud proofs, random assignment, EMA scoring

### Testing Requirements
- [ ] 100% code coverage for staking/slashing modules
- [ ] 1M+ random function calls in invariant tests
- [ ] 10K+ fuzz test runs per function
- [ ] Economic simulation with 1000+ resolver scenarios
- [ ] Formal verification of critical functions (optional but recommended)

---

## Success Criteria

### Phase 1 (Interfaces) Complete When:
- [ ] All interfaces defined and documented
- [ ] No-op implementations pass tests
- [ ] DecentralizedResolutionModule integrates cleanly
- [ ] Backward compatibility verified

### Phase 2 (Staking) Complete When:
- [ ] Stake/unstake works correctly
- [ ] Delegation logic verified
- [ ] Time-locks enforced
- [ ] All tests passing

### Phase 3 (Slashing) Complete When:
- [ ] Slashing calculations correct
- [ ] Appeals process works
- [ ] Distribution logic verified
- [ ] All tests passing

### Final (v3) Complete When:
- [ ] All modules integrated
- [ ] All invariants proven
- [ ] Economic simulations pass
- [ ] Security audit complete
- [ ] Migration path tested
- [ ] Documentation complete

---

## Next Steps

**Immediate Action:** Start Phase 1 - Create interface boundaries and no-op implementations.

**Command to begin:**
```bash
# Create interface files
touch contracts/decentralized-resolution-module/IStakingModule.sol
touch contracts/decentralized-resolution-module/ISlashingModule.sol
touch contracts/decentralized-resolution-module/StakingModuleNoOp.sol
touch contracts/decentralized-resolution-module/SlashingModuleNoOp.sol

# Create test files
touch test/foundry/decentralized-resolution-module/DRv3Integration.t.sol
```

This approach ensures we can develop and test v3 incrementally without breaking v1/v2, and allows for easy rollback if issues are discovered.
