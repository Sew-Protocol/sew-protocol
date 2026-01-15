# Timeout Mechanisms Review & Recommendations

## Executive Summary

**Timeline**: 6 weeks to mainnet  
**Goal**: Organize timeout handling, ensure safety, maintain simplicity

**Recommendation**: **Minimal changes** - organize into struct for clarity, but keep current functionality. Focus on documentation and consistency.

---

## Current Timeout Mechanisms

### 1. Escrow Auto-Execution Timeouts

#### Per-Escrow Settings (in `EscrowTransfer` struct)
- `autoReleaseTime`: Absolute timestamp for auto-release (0 = disabled)
- `autoCancelTime`: Absolute timestamp for auto-cancel (0 = disabled)
- **Validation**: Cannot set both, must be in future, max 30 days from creation

#### Default Settings (in `BaseEscrow`)
- `defaultAutoReleaseTime`: Default for new escrows (0 = disabled)
- `defaultAutoCancelTime`: Default for new escrows (0 = disabled)
- **Governance**: `setDefaultAutoReleaseTime()`, `setDefaultAutoCancelTime()` (ROLE_TIMELOCK)
- **Validation**: Must be within 30 days from current time

#### Execution
- `automateTimedActions(workflowId)`: Public function, anyone can call
- Checks `block.timestamp >= autoReleaseTime` or `autoCancelTime`
- Executes release/cancel automatically

**Status**: ✅ **Working as designed**

---

### 2. Dispute Safety Timeout

#### Configuration
- `maxDisputeDuration`: 90 days (adjustable)
- **Governance**: `setMaxDisputeDuration(duration)` (ROLE_TIMELOCK, immediate)
- **No bounds checking**: Can be set to any value (potential issue)

#### Execution
- `autoCancelDisputedEscrow(workflowId)`: External function, anyone can call
- Checks: `block.timestamp >= disputeRaisedTimestamp[workflowId] + maxDisputeDuration`
- Auto-cancels disputed escrows after timeout

**Status**: ⚠️ **Needs bounds validation**

---

### 3. Appeal Window Timeout

#### Configuration
- `appealWindowDuration`: 2 days (adjustable)
- **Governance**: `_pendingAppealWindowDuration` exists but queue/activate functions **MISSING** ⚠️
- **Storage**: `PendingSettlement.appealDeadline = block.timestamp + appealWindowDuration`
- **Note**: Currently no way to update `appealWindowDuration` via governance (needs to be added)

#### Execution
- Set when resolver calls `releaseAsDisputeResolver()` or `cancelAsDisputeResolver()`
- After deadline, settlement can be finalized
- Prevents immediate finalization (allows appeals)

**Status**: ✅ **Working as designed**

---

### 4. Decentralized Resolution Module Timeouts

#### Resolve Deadlines (per round)
- `resolveDeadlines[3]`: [3 days, 5 days, 7 days] (hardcoded, adjustable via governance)
- Round 0 (resolver): 3 days
- Round 1 (senior): 5 days
- Round 2 (external/Kleros): 7 days
- **Governance**: `setResolveDeadlines()` (ROLE_TIMELOCK, immediate)
- **Bounds**: Must be > 0 and <= MAX_DISPUTE_TIMEOUT (365 days)

#### Appeal Windows (per round)
- `appealWindows[3]`: [2 days, 3 days, 0] (hardcoded, adjustable via governance)
- Round 0: 2 days to appeal
- Round 1: 3 days to appeal
- Round 2: 0 (no appeal, final)
- **Governance**: `setResolveDeadlines()` (includes appeal windows)
- **Storage**: `DisputeMetadata.appealDeadline[currentRound] = block.timestamp + appealWindows[currentRound]`

#### Dispute Timeout
- `disputeTimeout`: 7 days (DEFAULT_DISPUTE_TIMEOUT)
- **Governance**: `setDisputeTimeout()` (ROLE_TIMELOCK, immediate)
- **Bounds**: > 0 and <= MAX_DISPUTE_TIMEOUT (365 days)
- **Usage**: Used for timeout slashing logic

**Status**: ✅ **Working as designed**

---

## Current Issues

### Issue 1: Inconsistent Constants

**Problem**:
- `BaseEscrow.MAX_AUTO_TIME_DURATION = 10 * 365 * 24 * 60 * 60` (10 years)
- `SettingsValidationLibrary.MAX_AUTO_TIME_DURATION = 10 * 365 * 24 * 60 * 60` (10 years)
- `SettingsValidationLibrary.MAX_AUTO_TIME_DAYS = 30 days` (30 days)

**Analysis**:
- `MAX_AUTO_TIME_DURATION` (10 years) is used in `validateAutoTime()` for per-escrow settings
- `MAX_AUTO_TIME_DAYS` (30 days) is used in `validateAutoCancel()` and `validateAutoRelease()` for defaults
- **Inconsistency**: Per-escrow allows 10 years, defaults allow only 30 days

**Impact**: Confusing, but not breaking (different use cases)

---

### Issue 2: Unorganized State Variables

**Current**:
```solidity
uint256 public defaultAutoReleaseTime = 0;
uint256 public defaultAutoCancelTime = 0;
uint256 public constant MAX_AUTO_TIME_DURATION = 10 * 365 * 24 * 60 * 60;
uint256 public maxDisputeDuration = 90 days;
uint256 public appealWindowDuration = 2 days;
```

**Problems**:
- Scattered across contract
- No clear grouping
- Hard to see relationships
- No struct for timeout configuration

---

### Issue 3: Missing Bounds on `maxDisputeDuration`

**Current**:
```solidity
function setMaxDisputeDuration(uint256 duration) external onlyRole(ROLE_TIMELOCK) { 
    maxDisputeDuration = duration; 
    emit MaxDisputeDurationUpdated(duration); 
}
```

**Problem**: No bounds checking - could be set to 0 or very large value

**Risk**: 
- 0 = disputes never timeout (funds stuck forever)
- Very large = disputes take too long to resolve

---

### Issue 4: Duplicate Constants

**Problem**: `MAX_AUTO_TIME_DURATION` defined in both:
- `BaseEscrow.sol` (line 79)
- `SettingsValidationLibrary.sol` (line 13)

**Impact**: Code duplication, potential for divergence

---

### Issue 5: Missing Appeal Window Governance Functions

**Problem**: 
- `_pendingAppealWindowDuration` storage exists (line 112)
- But `queueAppealWindowDuration()` and `activateAppealWindowDuration()` functions are **missing**
- No way to update `appealWindowDuration` via governance

**Impact**: 
- `appealWindowDuration` is hardcoded to 2 days
- Cannot adjust based on experience
- Inconsistent with other timeout settings (which have governance)

**Fix**: Add missing functions (1 hour)

---

## Proposed Improvements

### Option 1: TimeoutConfig Struct (Recommended for Mainnet)

**Create struct to organize timeout settings**:

```solidity
struct TimeoutConfig {
    uint256 defaultAutoReleaseTime;    // Default auto-release (0 = disabled)
    uint256 defaultAutoCancelTime;     // Default auto-cancel (0 = disabled)
    uint256 maxDisputeDuration;       // Max time for disputes (safety timeout)
    uint256 appealWindowDuration;     // Time to appeal resolution
    uint256 maxAutoTimeDuration;       // Max auto time from creation (10 years)
    uint256 maxAutoTimeDays;           // Max auto time for defaults (30 days)
}
```

**Benefits**:
- ✅ Clear organization
- ✅ Easy to see all timeout settings
- ✅ Can add validation struct-wide
- ✅ Easier to document

**Implementation**:
- Replace individual state variables with `TimeoutConfig public timeoutConfig`
- Update getters/setters to use struct
- Add struct-level validation

**Gas Impact**: Minimal (struct packing)

**Timeline**: 1-2 days

---

### Option 2: Keep Current Structure (Simpler, Faster)

**Just add bounds validation and documentation**:

```solidity
function setMaxDisputeDuration(uint256 duration) external onlyRole(ROLE_TIMELOCK) { 
    require(duration >= 7 days && duration <= 365 days, "Invalid duration");
    maxDisputeDuration = duration; 
    emit MaxDisputeDurationUpdated(duration); 
}
```

**Benefits**:
- ✅ Minimal changes
- ✅ Quick to implement
- ✅ Low risk

**Timeline**: 1 hour

---

## Recommendations for 6 Weeks to Mainnet

### ✅ **DO: Quick Wins (1-2 days)** - **COMPLETED** ✅

1. ✅ **Add bounds validation to `setMaxDisputeDuration()`** - **DONE**
   ```solidity
   require(duration >= 7 days && duration <= 365 days, "Invalid duration: must be 7-365 days");
   ```
   **Status**: Implemented in `BaseEscrow.sol:283` with bounds validation (7-365 days)
   **Rationale**: Prevents accidental misconfiguration, critical safety feature

2. ✅ **Consolidate `MAX_AUTO_TIME_DURATION` constant** - **DONE**
   - ✅ Removed from `BaseEscrow.sol`
   - ✅ Using only from `SettingsValidationLibrary.sol`
   **Status**: Constant removed from BaseEscrow, single source of truth in SettingsValidationLibrary
   **Rationale**: Eliminates duplication, single source of truth

3. ✅ **Add comprehensive documentation** - **DONE**
   - ✅ `TimeoutConfig` struct documented with field comments
   - ✅ Function NatSpec comments added
   - ✅ Timeout mechanisms documented in `TIMEOUT_MECHANISMS_REVIEW.md`
   **Status**: Struct fields documented, function comments added, comprehensive review document created
   **Rationale**: Critical for audit and maintenance

4. ✅ **Add events for default timeout changes** - **DONE**
   ```solidity
   event DefaultAutoReleaseTimeUpdated(uint256 newTime);
   event DefaultAutoCancelTimeUpdated(uint256 newTime);
   ```
   **Status**: Events added in `BaseEscrow.sol:140-141`, emitted in setters
   **Rationale**: Better observability, audit trail

---

### ⚠️ **CONSIDER: Medium Priority (2-3 days)**

5. ✅ **Create `TimeoutConfig` struct** (Option 1) - **COMPLETED** ✅
   - ✅ Organized all timeout settings into struct
   - ✅ Added struct-level validation in `setTimeoutConfig()`
   - ✅ Updated getters/setters (backward compatible)
   - ✅ Added atomic update function `setTimeoutConfig()`
   - ✅ Initialized in constructors (EscrowVault, EscrowableERC20)
   **Status**: Fully implemented with bounds validation, events, and backward compatibility
   **Rationale**: Better organization, but not critical for launch
   **Risk**: Low - backward compatible, thoroughly tested
   **Decision**: ✅ **IMPLEMENTED** - Completed ahead of schedule

6. **Standardize validation bounds**
   - Decide: 30 days or 10 years for auto times?
   - Make consistent across all validations
   **Rationale**: Reduces confusion
   **Decision**: **Document the difference, fix post-launch**

---

### ❌ **DON'T: High Risk Changes**

7. **Don't change timeout logic**
   - Current logic works
   - Changing could introduce bugs
   - Test thoroughly if changing

8. **Don't add complex timeout features**
   - Keep it simple for launch
   - Can add post-launch

9. **Don't remove safety timeouts**
   - `maxDisputeDuration` is critical
   - `autoCancelDisputedEscrow()` prevents stuck funds

---

## Safety Timeout Analysis

### Current Safety Mechanisms

1. **Dispute Timeout** (`maxDisputeDuration`)
   - ✅ Prevents disputes from being stuck forever
   - ✅ Anyone can call `autoCancelDisputedEscrow()`
   - ⚠️ No bounds validation (could be set to 0)

2. **Auto-Execution Timeouts** (`autoReleaseTime`/`autoCancelTime`)
   - ✅ Prevents escrows from being stuck in PENDING
   - ✅ Anyone can call `automateTimedActions()`
   - ✅ Max 30 days (reasonable limit)

3. **Appeal Window** (`appealWindowDuration`)
   - ✅ Prevents immediate finalization
   - ✅ Allows time for appeals
   - ✅ 2 days is reasonable

### Missing Safety Mechanisms

1. **No maximum on `maxDisputeDuration`**
   - Could be set to 10 years (too long)
   - **Fix**: Add max bound (e.g., 365 days)

2. **No minimum on `maxDisputeDuration`**
   - Could be set to 0 (disables safety)
   - **Fix**: Add min bound (e.g., 7 days)

3. **No automatic execution of dispute timeout**
   - Requires manual call to `autoCancelDisputedEscrow()`
   - **Consider**: Add to `automateTimedActions()` (low priority)

---

## Time-Based Execution Review

### Current Execution Mechanisms

1. **`automateTimedActions(workflowId)`**
   - **Purpose**: Execute auto-release/auto-cancel for PENDING escrows
   - **Trigger**: Manual call (anyone can call)
   - **Checks**: `block.timestamp >= autoReleaseTime` or `autoCancelTime`
   - **State**: Only works for PENDING escrows
   - **Status**: ✅ **Working correctly**

2. **`autoCancelDisputedEscrow(workflowId)`**
   - **Purpose**: Safety timeout for DISPUTED escrows
   - **Trigger**: Manual call (anyone can call)
   - **Checks**: `block.timestamp >= disputeRaisedTimestamp + maxDisputeDuration`
   - **State**: Only works for DISPUTED escrows
   - **Status**: ✅ **Working correctly** (needs bounds validation)

3. **Appeal Window Finalization**
   - **Purpose**: Finalize settlements after appeal window
   - **Trigger**: Manual call (anyone can call)
   - **Checks**: `block.timestamp >= appealDeadline`
   - **State**: Works for RESOLVED escrows with pending settlements
   - **Status**: ✅ **Working correctly**

### Execution Patterns

**Current**: All time-based execution is **manual** (requires someone to call function)

**Alternatives Considered**:
- ❌ Automatic execution on every transaction (too expensive)
- ❌ Scheduled execution (not possible on-chain)
- ✅ Current approach: Manual execution with incentives (anyone can call, gets gas refunded)

**Status**: ✅ **Current approach is correct** - manual execution is standard pattern

---

## Proposed TimeoutConfig Struct

### Design

```solidity
struct TimeoutConfig {
    // Auto-execution defaults (0 = disabled)
    uint256 defaultAutoReleaseTime;    // Default auto-release timestamp
    uint256 defaultAutoCancelTime;     // Default auto-cancel timestamp
    
    // Safety timeouts
    uint256 maxDisputeDuration;        // Max time for disputes (7-365 days)
    uint256 appealWindowDuration;      // Time to appeal resolution (1-7 days)
    
    // Bounds (constants, but in struct for organization)
    uint256 maxAutoTimeDuration;       // Max auto time from creation (10 years)
    uint256 maxAutoTimeDays;           // Max auto time for defaults (30 days)
}
```

### Implementation

```solidity
// In BaseEscrow.sol
TimeoutConfig public timeoutConfig;

constructor(...) {
    timeoutConfig = TimeoutConfig({
        defaultAutoReleaseTime: 0,
        defaultAutoCancelTime: 0,
        maxDisputeDuration: 90 days,
        appealWindowDuration: 2 days,
        maxAutoTimeDuration: 10 * 365 * 24 * 60 * 60,
        maxAutoTimeDays: 30 days
    });
}

function setTimeoutConfig(TimeoutConfig calldata config) external onlyRole(ROLE_TIMELOCK) {
    // Validate bounds
    require(config.maxDisputeDuration >= 7 days && config.maxDisputeDuration <= 365 days, "Invalid maxDisputeDuration");
    require(config.appealWindowDuration >= 1 days && config.appealWindowDuration <= 7 days, "Invalid appealWindowDuration");
    SettingsValidationLibrary.validateAutoRelease(config.defaultAutoReleaseTime);
    SettingsValidationLibrary.validateAutoCancel(config.defaultAutoCancelTime);
    
    timeoutConfig = config;
    emit TimeoutConfigUpdated(config);
}
```

### Migration Path

1. Add struct (non-breaking)
2. Initialize in constructor
3. Update getters to read from struct
4. Update setters to write to struct
5. Keep old getters for backward compatibility (deprecated)

**Timeline**: 2-3 days (including testing)

---

## Final Recommendations

### For 6 Weeks to Mainnet

**Priority 1 (Must Do)**:
1. ✅ Add bounds validation to `setMaxDisputeDuration()` (1 hour)
2. ✅ Consolidate `MAX_AUTO_TIME_DURATION` constant (30 min)
3. ✅ Add events for default timeout changes (30 min)
4. ✅ Add missing `queueAppealWindowDuration()` and `activateAppealWindowDuration()` functions (1 hour)
5. ✅ Document all timeout mechanisms (2 hours)

**Priority 2 (Should Do)**:
5. ⚠️ Create `TimeoutConfig` struct (2-3 days) - **Only if time permits**
6. ⚠️ Standardize validation bounds (1 day) - **Document difference for now**

**Priority 3 (Nice to Have)**:
7. Add automatic dispute timeout execution to `automateTimedActions()` (1 day)
8. Add timeout configuration view function (1 hour)

---

## Code Organization Improvements

### Current State
```solidity
// Scattered across BaseEscrow.sol
uint256 public defaultAutoReleaseTime = 0;
uint256 public defaultAutoCancelTime = 0;
uint256 public constant MAX_AUTO_TIME_DURATION = 10 * 365 * 24 * 60 * 60;
uint256 public maxDisputeDuration = 90 days;
uint256 public appealWindowDuration = 2 days;
```

### Proposed Organization
```solidity
// Grouped in TimeoutConfig struct
struct TimeoutConfig {
    uint256 defaultAutoReleaseTime;
    uint256 defaultAutoCancelTime;
    uint256 maxDisputeDuration;
    uint256 appealWindowDuration;
    // Constants could be in struct or separate
}
TimeoutConfig public timeoutConfig;
```

**Alternative (Simpler)**: Just add comments grouping them:
```solidity
// ============ Timeout Configuration ============
uint256 public defaultAutoReleaseTime = 0;      // Default auto-release (0 = disabled)
uint256 public defaultAutoCancelTime = 0;        // Default auto-cancel (0 = disabled)
uint256 public maxDisputeDuration = 90 days;     // Safety timeout for disputes
uint256 public appealWindowDuration = 2 days;    // Time to appeal resolution
uint256 public constant MAX_AUTO_TIME_DURATION = 10 * 365 * 24 * 60 * 60; // Max auto time (10 years)
```

---

## Safety Recommendations

### Critical (Must Fix)
1. **Add bounds to `setMaxDisputeDuration()`**
   - Min: 7 days (reasonable minimum)
   - Max: 365 days (1 year maximum)
   - Prevents accidental misconfiguration

### Important (Should Fix)
2. **Document timeout relationships**
   - How auto times interact with dispute timeout
   - What happens if multiple timeouts trigger
   - Clear examples

3. **Add timeout configuration view**
   ```solidity
   function getTimeoutConfig() external view returns (
       uint256 defaultAutoReleaseTime,
       uint256 defaultAutoCancelTime,
       uint256 maxDisputeDuration,
       uint256 appealWindowDuration
   )
   ```
   - Helps users understand current settings
   - Useful for frontend integration

---

## Testing Considerations

### Timeout Scenarios to Test

1. **Auto-release timeout**
   - Escrow with `autoReleaseTime` set
   - Call `automateTimedActions()` after timeout
   - Verify release executes

2. **Auto-cancel timeout**
   - Escrow with `autoCancelTime` set
   - Call `automateTimedActions()` after timeout
   - Verify cancel executes

3. **Dispute safety timeout**
   - Create dispute
   - Wait `maxDisputeDuration`
   - Call `autoCancelDisputedEscrow()`
   - Verify auto-cancel executes

4. **Appeal window**
   - Resolver resolves dispute
   - Verify `appealDeadline` is set
   - Try to finalize before deadline (should fail)
   - Try to finalize after deadline (should succeed)

5. **Edge cases**
   - Timeout set to 0 (disabled)
   - Timeout set to max value
   - Multiple timeouts on same escrow
   - Timeout during dispute

---

## Summary

### Current State: ✅ **Functional but Unorganized**

**Strengths**:
- All timeout mechanisms work correctly
- Safety timeouts prevent stuck funds
- Flexible configuration

**Weaknesses**:
- Scattered state variables
- Inconsistent constants
- Missing bounds validation
- Poor documentation

### Recommended Changes (6 Weeks to Mainnet)

**Minimal Changes (1-2 days)**:
1. Add bounds validation to `setMaxDisputeDuration()`
2. Consolidate `MAX_AUTO_TIME_DURATION` constant
3. Add missing `queueAppealWindowDuration()` and `activateAppealWindowDuration()` functions
4. Add events for default timeout changes
5. Add comprehensive documentation

**Optional Improvements (2-3 days)**:
5. Create `TimeoutConfig` struct (if time permits)
6. Add timeout configuration view function

**Defer to Post-Launch**:
- Automatic dispute timeout execution
- Standardizing all validation bounds
- Complex timeout features

### Risk Assessment

**Current Risk**: **LOW** - System works, just needs organization

**With Recommended Changes**: **LOW** - Minimal changes, high safety improvement

**With Struct Refactor**: **MEDIUM** - More changes, requires thorough testing

**Recommendation**: **Do minimal changes now, struct refactor post-launch**

---

## Implementation Examples

### Missing Appeal Window Functions

**Add these functions to `BaseEscrow.sol`**:

```solidity
function queueAppealWindowDuration(uint256 duration) public onlyRole(ROLE_TIMELOCK) {
    require(duration >= 1 days && duration <= 7 days, "Invalid duration");
    _queueUint(_pendingAppealWindowDuration, duration);
    emit AppealWindowDurationQueued(duration, _pendingAppealWindowDuration.eta);
}

function activateAppealWindowDuration() public onlyRole(ROLE_TIMELOCK) {
    appealWindowDuration = _activateUint(_pendingAppealWindowDuration);
    emit AppealWindowDurationUpdated(appealWindowDuration);
}

function getPendingAppealWindowDuration() public view returns (uint256 value, uint64 eta, bool exists) {
    return getPendingUint(_pendingAppealWindowDuration);
}
```

**Add event**:
```solidity
event AppealWindowDurationQueued(uint256 newDuration, uint64 eta);
```

---

### Bounds Validation for maxDisputeDuration

**Update `setMaxDisputeDuration()`**:

```solidity
function setMaxDisputeDuration(uint256 duration) external onlyRole(ROLE_TIMELOCK) {
    require(duration >= 7 days && duration <= 365 days, "Invalid duration: must be 7-365 days");
    maxDisputeDuration = duration;
    emit MaxDisputeDurationUpdated(duration);
}
```

---

### Events for Default Timeouts

**Add events**:
```solidity
event DefaultAutoReleaseTimeUpdated(uint256 newTime);
event DefaultAutoCancelTimeUpdated(uint256 newTime);
```

**Update setters**:
```solidity
function setDefaultAutoCancelTime(uint256 time) public onlyRole(ROLE_TIMELOCK) {
    SettingsValidationLibrary.validateAutoCancel(time);
    defaultAutoCancelTime = time;
    emit DefaultAutoCancelTimeUpdated(time);
}

function setDefaultAutoReleaseTime(uint256 time) public onlyRole(ROLE_TIMELOCK) {
    SettingsValidationLibrary.validateAutoRelease(time);
    defaultAutoReleaseTime = time;
    emit DefaultAutoReleaseTimeUpdated(time);
}
```

---

## Quick Reference Table

| Timeout | Current Value | Adjustable | Governance | Bounds | Safety Critical |
|---------|--------------|------------|------------|--------|-----------------|
| `defaultAutoReleaseTime` | 0 (disabled) | ✅ Yes | Immediate (ROLE_TIMELOCK) | 0 or 30 days | ⚠️ Medium |
| `defaultAutoCancelTime` | 0 (disabled) | ✅ Yes | Immediate (ROLE_TIMELOCK) | 0 or 30 days | ⚠️ Medium |
| `maxDisputeDuration` | 90 days | ✅ Yes | Immediate (ROLE_TIMELOCK) | ❌ None | ✅ **CRITICAL** |
| `appealWindowDuration` | 2 days | ⚠️ **MISSING** | ❌ No functions | ❌ None | ⚠️ Medium |
| `autoReleaseTime` (per-escrow) | 0 (disabled) | ✅ Yes | User-set | 0 or 10 years | ⚠️ Medium |
| `autoCancelTime` (per-escrow) | 0 (disabled) | ✅ Yes | User-set | 0 or 10 years | ⚠️ Medium |
| `resolveDeadlines[3]` | [3, 5, 7] days | ✅ Yes | Immediate (ROLE_TIMELOCK) | >0, <=365 days | ⚠️ Medium |
| `appealWindows[3]` | [2, 3, 0] days | ✅ Yes | Immediate (ROLE_TIMELOCK) | >=0 | ⚠️ Medium |
| `disputeTimeout` (DR module) | 7 days | ✅ Yes | Immediate (ROLE_TIMELOCK) | >0, <=365 days | ⚠️ Medium |

**Legend**:
- ✅ = Working correctly
- ⚠️ = Needs improvement
- ❌ = Missing or broken

---

## Action Items Summary

### Must Fix Before Mainnet (4-5 hours total)

1. **Add bounds to `setMaxDisputeDuration()`** (1 hour)
   - Min: 7 days
   - Max: 365 days
   - **Risk if not fixed**: Disputes could be stuck forever or take too long

2. **Add missing appeal window governance functions** (1 hour)
   - `queueAppealWindowDuration()`
   - `activateAppealWindowDuration()`
   - `getPendingAppealWindowDuration()`
   - **Risk if not fixed**: Cannot adjust appeal window based on experience

3. **Add events for default timeout changes** (30 min)
   - `DefaultAutoReleaseTimeUpdated`
   - `DefaultAutoCancelTimeUpdated`
   - **Risk if not fixed**: Poor observability

4. **Consolidate `MAX_AUTO_TIME_DURATION` constant** (30 min)
   - Remove from `BaseEscrow.sol`
   - Use only from `SettingsValidationLibrary.sol`
   - **Risk if not fixed**: Code duplication, potential divergence

5. **Document all timeout mechanisms** (2 hours)
   - Add comprehensive comments
   - Document relationships
   - **Risk if not fixed**: Confusion, audit issues

### Should Do If Time Permits (2-3 days)

6. **Create `TimeoutConfig` struct** (2-3 days)
   - Organize all timeout settings
   - Better code organization
   - **Risk if not done**: Code remains unorganized (not critical)

### Defer to Post-Launch

7. Standardize validation bounds (30 days vs 10 years)
8. Add automatic dispute timeout execution
9. Add timeout configuration view function
