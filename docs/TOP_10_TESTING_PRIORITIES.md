# Top 10 Testing Priorities

**Last Updated:** 2026-01-06  
**Status:** Pre-Mainnet  
**Purpose:** Identify the most critical testing areas before mainnet deployment

---

## Executive Summary

This document identifies the top 10 testing priorities based on:
- **Security Impact**: Critical invariants and attack vectors
- **Financial Risk**: Areas that could lead to fund loss
- **Operational Readiness**: Procedures that must work in production
- **Complexity**: Areas with complex logic requiring thorough testing

**Current Test Status:** ✅ 277 passing, 22 pending (Hardhat + Foundry)

---

## Priority Ranking

| Priority | Area | Type | Risk Level | Status |
|----------|------|------|------------|--------|
| #1 | Snapshot Immutability | Invariant | 🔴 Critical | ⚠️ Partial |
| #2 | State Machine Correctness | Invariant | 🔴 Critical | ✅ Good |
| #3 | Reentrancy Protection | Security | 🔴 Critical | ⚠️ Review Needed |
| #4 | Caps Enforcement | Security | 🔴 Critical | ⚠️ TBD |
| #5 | Guardian Down-Only Powers | Security | 🔴 Critical | ✅ Good |
| #6 | Governance Time Delays | Security | 🟠 High | ✅ Good |
| #7 | Dispute Resolution Correctness | Functional | 🟠 High | ⚠️ Partial |
| #8 | Fee Accounting Accuracy | Financial | 🟠 High | ⚠️ Partial |
| #9 | Yield Generation Safety | Integration | 🟠 High | ⚠️ TBD |
| #10 | Emergency Procedures | Operational | 🟠 High | ⚠️ Documentation Ready |

---

## 1. 🔴 Snapshot Immutability ("New Escrows Only")

**Priority:** #1 - **CRITICAL**  
**Risk Level:** 🔴 **CRITICAL** - Governance cannot change existing escrow rules  
**Status:** ⚠️ **PARTIAL** - Tests exist but need comprehensive coverage

### Why Critical

Snapshot immutability is a **core security guarantee** of the protocol. If violated, governance could retroactively change escrow rules, breaking user trust and potentially causing fund loss.

### What to Test

1. **Module Snapshots Never Change**
   - ✅ Verify snapshot fields are set at creation
   - ⚠️ Verify snapshot fields are NEVER modified after creation
   - ⚠️ Fuzz test: Attempt to modify snapshots via all possible functions
   - ⚠️ Verify no per-escrow setters exist

2. **Module Getters Read from Snapshots**
   - ✅ Test existing escrows use old modules after swap
   - ⚠️ Fuzz test: Create escrow, swap module, verify old escrow still uses old module
   - ⚠️ Test all module getters (`getResolutionModule()`, `getReleaseStrategy()`, etc.)

3. **Governance Changes Affect New Escrows Only**
   - ✅ Test module swap affects only new escrows
   - ⚠️ Fuzz test: Multiple swaps, verify each escrow uses correct module
   - ⚠️ Test edge cases: Swap during active escrow, verify no impact

### Test Coverage Needed

- [ ] Foundry invariant: Snapshot fields immutable after creation
- [ ] Fuzz test: Attempt all possible state changes on existing escrows
- [ ] Integration test: Module swap with active escrows
- [ ] Edge case: Escrow created during module swap
- [ ] Verify: No functions exist that modify snapshot fields

### Related Documentation

- `docs/SECURITY_MODEL.md` - Invariants #4, #5
- `docs/governance.md` - Snapshot semantics

---

## 2. 🔴 State Machine Correctness

**Priority:** #2 - **CRITICAL**  
**Risk Level:** 🔴 **CRITICAL** - Prevents double-spending and invalid transitions  
**Status:** ✅ **GOOD** - Tests exist but need expansion

### Why Critical

State machine violations can lead to:
- **Double-spending**: Funds released multiple times
- **Invalid transitions**: Escrows in impossible states
- **Fund loss**: Escrows stuck in invalid states

### What to Test

1. **Valid State Transitions Only**
   - ✅ Test valid transitions: NONE → PENDING → {RELEASED, REFUNDED, DISPUTED} → RESOLVED
   - ⚠️ Test ALL invalid transitions revert
   - ⚠️ Fuzz test: Random state transitions, verify only valid ones succeed
   - ⚠️ Test edge cases: Multiple rapid transitions

2. **No Double-Spending**
   - ✅ Test `remainingBalance` never exceeds `totalDeposited`
   - ⚠️ Fuzz test: Multiple release/cancel attempts
   - ⚠️ Test: Partial releases don't allow double-spending
   - ⚠️ Test: Completed escrows have `remainingBalance == 0`

3. **Workflow ID Consistency**
   - ✅ Test `nextWorkflowId == escrowTransfers.length`
   - ⚠️ Fuzz test: Concurrent escrow creation
   - ⚠️ Test: Workflow ID matches array index

### Test Coverage Needed

- [ ] Foundry invariant: State machine correctness
- [ ] Fuzz test: All possible state transitions
- [ ] Edge case: Rapid state transitions
- [ ] Double-spend prevention: Multiple release attempts
- [ ] Workflow ID consistency: Concurrent creation

### Related Documentation

- `docs/SECURITY_MODEL.md` - Invariants #1, #2, #3

---

## 3. 🔴 Reentrancy Protection

**Priority:** #3 - **CRITICAL**  
**Risk Level:** 🔴 **CRITICAL** - Prevents reentrancy attacks  
**Status:** ⚠️ **REVIEW NEEDED** - Slither flagged 3 functions

### Why Critical

Reentrancy attacks can lead to:
- **Fund drainage**: Multiple withdrawals in single transaction
- **State corruption**: Invalid state during reentrant calls
- **Double-spending**: Funds released multiple times

### What to Test

1. **Functions with External Calls**
   - ⚠️ `BaseEscrow.escalateDispute()` - External module call + ETH transfers
   - ⚠️ `BaseEscrow.partialReleaseAsDisputeResolver()` - External library call
   - ⚠️ `BaseEscrow.partialCancelAsDisputeResolver()` - External library call
   - ✅ All have `nonReentrant` modifier (verified)

2. **Reentrancy Attack Scenarios**
   - ⚠️ Test: Malicious contract reenters during external calls
   - ⚠️ Test: Cross-function reentrancy via `escrowTransfers` mapping
   - ⚠️ Test: Reentrancy during ETH transfers
   - ⚠️ Test: Reentrancy during token transfers

3. **Checks-Effects-Interactions Pattern**
   - ⚠️ Verify: State changes before external calls where possible
   - ⚠️ Test: CEI pattern compliance (even with `nonReentrant`)

### Test Coverage Needed

- [ ] Reentrancy test: Malicious contract attempts reentrancy
- [ ] Cross-function reentrancy: Via shared state
- [ ] ETH transfer reentrancy: During escalation fee transfers
- [ ] Token transfer reentrancy: During payout execution
- [ ] CEI pattern verification: State before external calls

### Related Documentation

- `docs/SLITHER_STATUS.md` - Reentrancy findings #3.1, #3.2, #3.3
- `docs/SECURITY_MODEL.md` - Security Goal #9

---

## 4. 🔴 Caps Enforcement

**Priority:** #4 - **CRITICAL**  
**Risk Level:** 🔴 **CRITICAL** - Prevents excessive exposure to external protocols  
**Status:** ⚠️ **TBD** - Tests need verification

### Why Critical

Cap bypass can lead to:
- **Excessive exposure**: Funds beyond risk tolerance in Aave
- **Protocol insolvency**: If Aave fails, protocol loses more than intended
- **Governance bypass**: Caps are a key risk control

### What to Test

1. **Caps Enforced at Deposit Time**
   - ⚠️ Test: Token cap enforcement (`tokenCap[token]`)
   - ⚠️ Test: Global cap enforcement (`globalCap`)
   - ⚠️ Test: Cap exceeded reverts transaction
   - ⚠️ Test: Zero cap (unlimited) handling

2. **Exposure Tracking Accuracy**
   - ⚠️ Test: `currentExposure` incremented on deposit
   - ⚠️ Test: `currentExposure` decremented on withdrawal
   - ⚠️ Test: Multiple deposits/withdrawals maintain accuracy
   - ⚠️ Test: Edge case: Deposit at cap, then withdraw, then deposit again

3. **Cap Update Scenarios**
   - ⚠️ Test: Lowering cap below current exposure reverts
   - ⚠️ Test: Raising cap allows more deposits
   - ⚠️ Test: Guardian can only lower caps (down-only)

### Test Coverage Needed

- [ ] Cap enforcement: Token cap exceeded reverts
- [ ] Cap enforcement: Global cap exceeded reverts
- [ ] Exposure tracking: Increment/decrement accuracy
- [ ] Edge case: Deposit at cap boundary
- [ ] Guardian down-only: Cannot raise caps

### Related Documentation

- `docs/SECURITY_MODEL.md` - Invariants #8, #9
- `docs/governance.md` - Guardian down-only powers

---

## 5. 🔴 Guardian Down-Only Powers

**Priority:** #5 - **CRITICAL**  
**Risk Level:** 🔴 **CRITICAL** - Guardian cannot increase risk  
**Status:** ✅ **GOOD** - Tests exist

### Why Critical

Guardian powers are intentionally limited to prevent:
- **Risk escalation**: Guardian cannot increase protocol risk
- **Fund theft**: Guardian cannot access funds
- **Governance bypass**: Guardian cannot override governance

### What to Test

1. **Guardian Cannot Raise Caps**
   - ✅ Test: `guardianLowerTokenCap()` requires `newCap <= currentCap`
   - ⚠️ Fuzz test: Attempt to raise cap, verify revert
   - ⚠️ Test: Edge case: `newCap == currentCap` (should succeed)

2. **Guardian Cannot Unpause**
   - ✅ Test: `unpause()` requires `ROLE_TIMELOCK`
   - ⚠️ Test: Guardian cannot call `unpause()` directly
   - ⚠️ Test: Unpause requires timelock (48h delay)

3. **Guardian Cannot Enable Aave**
   - ✅ Test: `setAaveEnabled(true)` requires `ROLE_TIMELOCK`
   - ⚠️ Test: Guardian can only call `guardianDisableAave()`
   - ⚠️ Test: Guardian cannot enable Aave

### Test Coverage Needed

- [ ] Guardian down-only: Cannot raise caps
- [ ] Guardian down-only: Cannot unpause
- [ ] Guardian down-only: Cannot enable Aave
- [ ] Fuzz test: All guardian functions are down-only
- [ ] Access control: Guardian doesn't have `ROLE_TIMELOCK`

### Related Documentation

- `docs/SECURITY_MODEL.md` - Invariants #10, #11, #12
- `docs/EMERGENCY_POLICY.md` - Guardian powers and limits

---

## 6. 🟠 Governance Time Delays

**Priority:** #6 - **HIGH**  
**Risk Level:** 🟠 **HIGH** - Time delays prevent rapid malicious changes  
**Status:** ✅ **GOOD** - Tests exist

### Why Critical

Time delays are a key security mechanism:
- **Review period**: Community can review and veto proposals
- **Attack prevention**: Prevents rapid malicious changes
- **Transparency**: All changes are publicly visible before execution

### What to Test

1. **Slow Lane Queue/Activate Pattern**
   - ✅ Test: Queue requires 48h delay
   - ✅ Test: Activate requires 7-day wait after queue
   - ⚠️ Test: ETA stored onchain and enforced
   - ⚠️ Test: Activate before ETA reverts
   - ⚠️ Test: Total delay ~9 days

2. **Standard Lane Timelock Delay**
   - ✅ Test: Standard lane requires `ROLE_TIMELOCK`
   - ✅ Test: TimelockController enforces 48h delay
   - ⚠️ Test: Execute before delay reverts
   - ⚠️ Test: Delay is exactly 48 hours

3. **Emergency Lane Immediate Execution**
   - ✅ Test: Emergency functions use `onlyRole(ROLE_GUARDIAN)`
   - ✅ Test: No timelock delay for emergency functions
   - ⚠️ Test: Guardian functions execute immediately

### Test Coverage Needed

- [ ] Slow lane: Queue → wait → activate pattern
- [ ] Slow lane: ETA enforcement
- [ ] Standard lane: 48h delay enforcement
- [ ] Emergency lane: Immediate execution
- [ ] Integration: Full governance proposal flow

### Related Documentation

- `docs/SECURITY_MODEL.md` - Invariants #13, #14, #15
- `docs/governance.md` - Governance lanes

---

## 7. 🟠 Dispute Resolution Correctness

**Priority:** #7 - **HIGH**  
**Risk Level:** 🟠 **HIGH** - Core functionality, must work correctly  
**Status:** ⚠️ **PARTIAL** - Basic tests exist, need comprehensive coverage

### Why Critical

Dispute resolution is core functionality:
- **User trust**: Users must trust dispute resolution works
- **Fund safety**: Incorrect resolutions can cause fund loss
- **Fairness**: Resolutions must be fair and transparent

### What to Test

1. **Dispute Lifecycle**
   - ✅ Test: Raise dispute transitions to DISPUTED
   - ⚠️ Test: Only participants can raise dispute
   - ⚠️ Test: Dispute can only be raised in PENDING state
   - ⚠️ Test: Resolver assignment works correctly

2. **Resolution Correctness**
   - ✅ Test: Resolver can resolve dispute
   - ⚠️ Test: Payout validation (sum equals remaining balance)
   - ⚠️ Test: Multiple payouts work correctly
   - ⚠️ Test: Partial resolution (if supported)
   - ⚠️ Test: Invalid payouts revert

3. **Escalation**
   - ⚠️ Test: Escalation to higher level works
   - ⚠️ Test: Escalation fee collection
   - ⚠️ Test: Escalation updates resolver
   - ⚠️ Test: Escalation fee refund on failure

4. **Edge Cases**
   - ⚠️ Test: Dispute timeout handling
   - ⚠️ Test: Resolver removal during active dispute
   - ⚠️ Test: Module swap during active dispute

### Test Coverage Needed

- [ ] Dispute lifecycle: Raise → resolve → complete
- [ ] Payout validation: Sum equals remaining balance
- [ ] Escalation: Multi-level escalation works
- [ ] Escalation fees: Collection and refund
- [ ] Edge cases: Timeout, resolver removal, module swap

### Related Documentation

- `docs/CRITICAL_UNIMPLEMENTED_TASKS.md` - Escalation fee verification
- `docs/SECURITY_MODEL.md` - Security Goal #4

---

## 8. 🟠 Fee Accounting Accuracy

**Priority:** #8 - **HIGH**  
**Risk Level:** 🟠 **HIGH** - Financial correctness  
**Status:** ⚠️ **PARTIAL** - Basic tests exist

### Why Critical

Fee accounting errors can lead to:
- **Protocol insolvency**: Incorrect fee collection
- **User fund loss**: Fees deducted incorrectly
- **Resolver payment errors**: Incorrect incentive distribution

### What to Test

1. **Fee Calculation**
   - ✅ Test: Fee calculation uses correct denominator
   - ⚠️ Test: Fee calculation with different fee rates
   - ⚠️ Test: Fee calculation edge cases (zero, max, rounding)
   - ⚠️ Test: Fee calculation for different token amounts

2. **Fee Collection**
   - ✅ Test: Fees collected on escrow creation
   - ⚠️ Test: Fees tracked per token
   - ⚠️ Test: Fee withdrawal works correctly
   - ⚠️ Test: Fee recipient can withdraw accumulated fees

3. **Escalation Fees**
   - ⚠️ Test: Escalation fee collection
   - ⚠️ Test: Escalation fee refund on failure
   - ⚠️ Test: Excess escalation fee refund
   - ⚠️ Test: Zero escalation fee handling

4. **Resolver Incentives**
   - ⚠️ Test: Resolver payment calculation
   - ⚠️ Test: Payment distribution
   - ⚠️ Test: Payment library upgrades (if applicable)

### Test Coverage Needed

- [ ] Fee calculation: All edge cases
- [ ] Fee collection: Per-token tracking
- [ ] Escalation fees: Collection and refund
- [ ] Resolver incentives: Payment calculation and distribution
- [ ] Fee withdrawal: Accumulated fee withdrawal

### Related Documentation

- `docs/SECURITY_MODEL.md` - Threat: Fee accounting errors
- `docs/CRITICAL_UNIMPLEMENTED_TASKS.md` - Escalation fee verification

---

## 9. 🟠 Yield Generation Safety

**Priority:** #9 - **HIGH**  
**Risk Level:** 🟠 **HIGH** - External integration risk  
**Status:** ⚠️ **TBD** - Tests need expansion

### Why Critical

Yield generation involves external protocol (Aave):
- **External risk**: Inherits Aave protocol risks
- **Accounting accuracy**: Must track deposits/withdrawals correctly
- **Cap enforcement**: Must respect exposure caps

### What to Test

1. **Aave Integration**
   - ⚠️ Test: Deposit to Aave works correctly
   - ⚠️ Test: Withdrawal from Aave works correctly
   - ⚠️ Test: Yield calculation accuracy
   - ⚠️ Test: aToken balance tracking

2. **Cap Enforcement**
   - ⚠️ Test: Caps enforced before Aave deposit
   - ⚠️ Test: Deposit at cap boundary
   - ⚠️ Test: Withdrawal updates exposure correctly

3. **Pause Mechanism**
   - ⚠️ Test: Guardian can disable Aave
   - ⚠️ Test: Disabled Aave prevents new deposits
   - ⚠️ Test: Existing deposits remain in Aave
   - ⚠️ Test: Re-enable requires timelock

4. **Edge Cases**
   - ⚠️ Test: Aave failure handling
   - ⚠️ Test: Yield distribution accuracy
   - ⚠️ Test: Multiple escrows with yield

### Test Coverage Needed

- [ ] Aave integration: Deposit/withdrawal/yield
- [ ] Cap enforcement: Before Aave deposit
- [ ] Pause mechanism: Disable/re-enable
- [ ] Edge cases: Aave failure, yield distribution
- [ ] Accounting: aToken balance tracking

### Related Documentation

- `docs/SECURITY_MODEL.md` - Threat: External yield integration risks
- `docs/governance.md` - Guardian powers

---

## 10. 🟠 Emergency Procedures

**Priority:** #10 - **HIGH**  
**Risk Level:** 🟠 **HIGH** - Operational readiness  
**Status:** ⚠️ **DOCUMENTATION READY** - Drills need to be performed

### Why Critical

Emergency procedures must work in production:
- **Incident response**: Team must be able to respond quickly
- **Fund protection**: Emergency controls protect user funds
- **Recovery**: Recovery procedures must work correctly

### What to Test

1. **Emergency Drills**
   - ⚠️ Test: Guardian can pause protocol
   - ⚠️ Test: Guardian can disable Aave
   - ⚠️ Test: Guardian can lower caps
   - ⚠️ Test: Pause prevents new escrow creation
   - ⚠️ Test: Pause prevents releases/cancellations

2. **Recovery Drills**
   - ⚠️ Test: Unpause via timelock works
   - ⚠️ Test: Re-enable Aave via timelock works
   - ⚠️ Test: Raise caps via timelock works
   - ⚠️ Test: Full recovery flow

3. **Fork Deployment Rehearsal**
   - ⚠️ Test: Full deployment on mainnet fork
   - ⚠️ Test: Role assignments correct
   - ⚠️ Test: Governance proposal simulation
   - ⚠️ Test: Emergency actions on fork

### Test Coverage Needed

- [ ] Emergency drill: Pause protocol
- [ ] Emergency drill: Disable Aave
- [ ] Emergency drill: Lower caps
- [ ] Recovery drill: Unpause via timelock
- [ ] Fork rehearsal: Full deployment and operations

### Related Documentation

- `docs/DRILLS_AND_REHEARSALS.md` - Drill templates
- `governance/runbooks/emergency.md` - Emergency procedures
- `governance/runbooks/recovery.md` - Recovery procedures

---

## Testing Implementation Plan

### Phase 1: Critical Invariants (Week 1)
1. Snapshot immutability tests
2. State machine correctness tests
3. Reentrancy protection tests
4. Caps enforcement tests

### Phase 2: Security Guarantees (Week 2)
5. Guardian down-only powers tests
6. Governance time delays tests
7. Dispute resolution correctness tests

### Phase 3: Financial & Integration (Week 3)
8. Fee accounting accuracy tests
9. Yield generation safety tests

### Phase 4: Operational Readiness (Week 4)
10. Emergency procedures drills

---

## Test Coverage Goals

### Target Coverage
- **Unit Tests**: 90%+ coverage
- **Integration Tests**: All critical paths
- **Invariant Tests**: All critical invariants
- **Fuzz Tests**: All complex functions
- **Fork Tests**: Full deployment rehearsal

### Current Status
- ✅ 277 passing tests
- ⚠️ Need expansion in priority areas
- ⚠️ Need invariant test expansion
- ⚠️ Need fuzz test expansion

---

## Related Documentation

- [`docs/SECURITY_MODEL.md`](./SECURITY_MODEL.md) - Security goals and invariants
- [`docs/SLITHER_STATUS.md`](./SLITHER_STATUS.md) - Static analysis findings
- [`docs/CRITICAL_UNIMPLEMENTED_TASKS.md`](./CRITICAL_UNIMPLEMENTED_TASKS.md) - Critical tasks
- [`docs/Mainnet_checklist.md`](./Mainnet_checklist.md) - Mainnet readiness checklist
- [`docs/OUTSTANDING_ISSUES.md`](./OUTSTANDING_ISSUES.md) - Outstanding issues

---

**Next Steps:**
1. Review each priority area
2. Expand test coverage in priority order
3. Perform emergency drills
4. Complete fork deployment rehearsal
5. Document all test results

---

**Last Updated:** 2026-01-06  
**Status:** Pre-Mainnet  
**Review Frequency:** Weekly until mainnet deployment


