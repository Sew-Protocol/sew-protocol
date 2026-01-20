# Missing Items from RESOLVER_ECONOMICS.md

**Date**: 2025-01-XX  
**Comparison**: Implementation status vs. `RESOLVER_ECONOMICS.md` requirements

---

## Critical Missing Items

### 1. Appeal Window Enforcement ✅ **COMPLETE**

**From**: `RESOLVER_ECONOMICS.md` Section 1.1, `DR_V3_TODO.md` Phase 5.4  
**Status**: ✅ **IMPLEMENTED**  
**Requirement**:

> "Tokens must only be transferred to seller AFTER appeal window expires"

**Implementation Complete**:

- ✅ Modified `BaseEscrow._executeResolution()` to query appeal deadline from resolution module
- ✅ Only executes transfer if final round, otherwise stores pending settlement
- ✅ Added `executePendingSettlement()` function to execute after appeal window expires
- ✅ Updated `automateTimedActions()` to automatically execute pending settlements
- ✅ Escalation already cancels pending settlements (was already implemented)
- ✅ Added `getAppealDeadlineAndRound()` to DecentralizedResolutionModule
- ✅ Added `getPendingSettlement()` view function
- ⚠️ Tests pending (TODO item #5)

**Status**: ✅ **COMPLETE** - All code changes implemented

**See**: `APPEAL_WINDOW_ENFORCEMENT_IMPLEMENTATION.md` for full details

---

## High Priority Missing Items

### 2. Increasing Delays (Calculated, Not Fixed)

**From**: `RESOLVER_ECONOMICS.md` Section 1.3, `RESOLVER_ECONOMICS_TODOS.md` line 191  
**Status**: ⚠️ **NOT IMPLEMENTED**  
**Requirement**:

> "Increase delays with depth: `t_resolve[k] = baseResolve + k * resolveStep` and `t_appeal[k] = baseAppeal + k * appealStep`"

**Current State**:

- Fixed arrays: `resolveDeadlines[3] = [3 days, 5 days, 7 days]`
- Fixed arrays: `appealWindows[3] = [2 days, 3 days, 0]`
- Not calculated dynamically

**Impact**: Medium - Less flexible, but functional. Current delays work but don't scale.

**Required Implementation**:

1. Add config: `baseResolve`, `resolveStep`, `baseAppeal`, `appealStep`
2. Calculate: `resolveDeadlines[k] = baseResolve + k * resolveStep`
3. Calculate: `appealWindows[k] = baseAppeal + k * appealStep`
4. Add governance functions to update parameters
5. Maintain backward compatibility

**Priority**: **HIGH** - Improves system flexibility and anti-spam effectiveness

---

## Medium Priority Missing Items

### 3. Missing Events

**From**: `RESOLVER_ECONOMICS_TODOS.md` lines 45-51  
**Status**: ⚠️ **PARTIALLY MISSING**  
**Missing Events**:

- ❌ `AppealOpened` - Not emitted (but `DisputeEscalatedToRound` exists)
- ⚠️ `AppealBondPosted` - Not emitted (but `AppealBondRecorded` exists - similar purpose)
- ❌ `AppealResolved` - Not emitted
- ⚠️ `DisputeFinalised` - Status exists, but event not emitted (hook `onDisputeFinalized` exists)

**Impact**: Low - Observability reduced, but functionality works. Events help with indexing and monitoring.

**Required Implementation**:

1. Add `AppealOpened` event in `DecentralizedResolutionModule.executeEscalation()`
2. Add `AppealResolved` event when appeal outcome determined
3. Add `DisputeFinalised` event in `finalizeDispute()`
4. Update event documentation

**Priority**: **MEDIUM** - Improves observability and integration with external systems

---

### 4. Bond Forfeiture Integration

**From**: `RESOLVER_ECONOMICS.md` Section 1.4, `RESOLVER_ECONOMICS_TODOS.md` line 203  
**Status**: ⚠️ **NOT INTEGRATED**  
**Requirement**:

> "Optional: bond forfeiture on no-show (if escalator fails to participate at next round)"

**Current State**:

- `forfeitAppealBond()` exists in `ResolverIncentiveModuleV2`
- Not automatically called from escalation timeout flow
- Manual forfeiture possible, but not automatic

**Impact**: Medium - Reduces anti-griefing effectiveness. Escalators who don't participate keep bonds.

**Required Implementation**:

1. Integrate `forfeitAppealBond()` into escalation timeout handling
2. Call when escalator fails to participate at next round
3. Add tests for forfeiture scenarios

**Priority**: **MEDIUM** - Improves anti-griefing mechanisms

---

### 5. Counter-Party Compensation in Slashing

**From**: `RESOLVER_ECONOMICS.md` Section 6.2, `DR_V3_TODO.md` Phase 3.4  
**Status**: ❌ **NOT IMPLEMENTED**  
**Requirement**:

> "30% to counter-party (user harmed by bad decision)"

**Current State**:

- Slash distribution sets `toCounterParty = 0`
- No logic to identify counter-party
- No payout mechanism for counter-party

**Impact**: Medium - Users harmed by bad decisions don't receive compensation from slashes.

**Required Implementation**:

1. Identify counter-party from dispute metadata
2. Implement counter-party payout logic
3. Add tests for counter-party compensation

**Priority**: **MEDIUM** - Improves user protection and fairness

---

## Low Priority Missing Items

### 6. Treasury Contract Integration

**From**: `DR_V3_TODO.md` Phase 3.4, `DR_V3_PHASE5_SUMMARY.md` line 23  
**Status**: ❌ **NOT IMPLEMENTED**  
**Requirement**: Transfer protocol portion of slashes to treasury

**Current State**:

- Protocol portion (30%) remains in slashing module contract
- TODO comment exists: "Transfer protocol portion to treasury (when treasury contract exists)"

**Impact**: Low - Funds not lost, just not routed. Can be transferred manually.

**Priority**: **LOW** - Wait for treasury contract deployment

---

### 7. Slash Proposer Rewards

**From**: `DR_V3_TODO.md` Phase 3.4  
**Status**: ❌ **NOT IMPLEMENTED**  
**Requirement**: Reward users who propose valid slashes

**Current State**:

- `toSlashProposer = 0` in distribution
- No tracking of slash proposers
- No reward mechanism

**Impact**: Low - Reduces incentive for reporting, but not critical.

**Priority**: **LOW** - Future enhancement

---

### 8. Configurable Slash Percentages

**From**: `DR_V3_TODO.md` Phase 3.4  
**Status**: ⚠️ **PARTIALLY IMPLEMENTED**  
**Requirement**: Configurable percentages via governance

**Current State**:

- Percentages are hardcoded (50% protocol, 30% counter-party, 20% insurance)
- No governance functions to update percentages

**Impact**: Low - Current percentages work, but less flexible.

**Priority**: **LOW** - Future enhancement

---

## Summary

### Critical (Fix Immediately): 1

1. Appeal Window Enforcement

### High Priority (Next Sprint): 1

2. Increasing Delays Calculation

### Medium Priority (Future Enhancement): 3

3. Missing Events
4. Bond Forfeiture Integration
5. Counter-Party Compensation

### Low Priority (v3 Features): 3

6. Treasury Integration
7. Slash Proposer Rewards
8. Configurable Slash Percentages

---

**End of Analysis**
