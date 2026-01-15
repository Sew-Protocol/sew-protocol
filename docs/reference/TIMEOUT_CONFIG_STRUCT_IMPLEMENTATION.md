# TimeoutConfig Struct Implementation Guide

## Overview

This document provides a detailed implementation plan for Option 1: TimeoutConfig Struct, recommended for mainnet to improve code organization and maintainability.

---

## Current State

### Scattered Timeout Variables

```solidity
// In BaseEscrow.sol
uint256 public defaultAutoReleaseTime = 0;
uint256 public defaultAutoCancelTime = 0;
uint256 public constant MAX_AUTO_TIME_DURATION = 10 * 365 * 24 * 60 * 60;
uint256 public maxDisputeDuration = 90 days;
uint256 public appealWindowDuration = 2 days;
```

### Issues

- ❌ Variables scattered across contract
- ❌ No clear grouping/organization
- ❌ Constants mixed with state variables
- ❌ Hard to see all timeout settings at once
- ❌ No bounds validation on `maxDisputeDuration`
- ❌ Duplicate `MAX_AUTO_TIME_DURATION` constant (also in `SettingsValidationLibrary`)

---

## Proposed TimeoutConfig Struct

### Design

```solidity
// In EscrowTypes.sol or new TimeoutTypes.sol
struct TimeoutConfig {
    // Auto-execution defaults (0 = disabled, absolute timestamps)
    uint256 defaultAutoReleaseTime;    // Default auto-release timestamp
    uint256 defaultAutoCancelTime;     // Default auto-cancel timestamp

    // Safety timeouts (durations in seconds)
    uint256 maxDisputeDuration;        // Max time for disputes (7-365 days)
    uint256 appealWindowDuration;      // Time to appeal resolution (1-7 days)
}

// Constants (keep separate - not in struct)
uint256 public constant MAX_AUTO_TIME_DURATION = 10 * 365 * 24 * 60 * 60; // 10 years
uint256 public constant MAX_AUTO_TIME_DAYS = 30 days; // For default validation
```

### Why This Design?

1. **Separates concerns**: Auto-execution vs safety timeouts
2. **Clear semantics**: Absolute timestamps vs durations
3. **Constants separate**: Don't change, don't need to be in struct
4. **Gas efficient**: Struct packing (all uint256, but clear organization)

---

## Implementation Steps

### Step 1: Add TimeoutConfig Struct

**File**: `contracts/types/EscrowTypes.sol`

```solidity
// Add after EscrowSettings struct
struct TimeoutConfig {
  // Auto-execution defaults (0 = disabled)
  uint256 defaultAutoReleaseTime; // Default auto-release timestamp (0 = disabled)
  uint256 defaultAutoCancelTime; // Default auto-cancel timestamp (0 = disabled)
  // Safety timeouts (durations in seconds)
  uint256 maxDisputeDuration; // Max time for disputes (7-365 days)
  uint256 appealWindowDuration; // Time to appeal resolution (1-7 days)
}
```

---

### Step 2: Update BaseEscrow.sol

#### 2.1 Replace State Variables

**Before**:

```solidity
uint256 public defaultAutoReleaseTime = 0;
uint256 public defaultAutoCancelTime = 0;
uint256 public constant MAX_AUTO_TIME_DURATION = 10 * 365 * 24 * 60 * 60;
uint256 public maxDisputeDuration = 90 days;
uint256 public appealWindowDuration = 2 days;
```

**After**:

```solidity
// ============ Timeout Configuration ============
TimeoutConfig public timeoutConfig;

// Constants (keep separate - they don't change)
uint256 public constant MAX_AUTO_TIME_DURATION = 10 * 365 * 24 * 60 * 60; // 10 years
```

#### 2.2 Initialize in Constructor (if BaseEscrow has one)

**Note**: `BaseEscrow` is abstract, so initialization happens in child contracts.

**In EscrowVault.sol constructor**:

```solidity
constructor(uint256 f, address fa, address y, address d) SlowLaneQueueActivate() {
  escrowFee = f;
  escrowFeeAddress = fa;
  yieldOps = YieldOps(y);
  disputeOps = DisputeOps(d);
  _grantRole(DEFAULT_ADMIN_ROLE, _msgSender());

  // Initialize timeout config
  timeoutConfig = TimeoutConfig({
    defaultAutoReleaseTime: 0,
    defaultAutoCancelTime: 0,
    maxDisputeDuration: 90 days,
    appealWindowDuration: 2 days
  });
}
```

**In EscrowableERC20.sol constructor**:

```solidity
constructor(
  string memory n,
  string memory s,
  uint256 f,
  address fa,
  address y,
  address d
) ERC20(n, s) {
  escrowFee = f;
  escrowFeeAddress = fa;
  yieldOps = YieldOps(y);
  disputeOps = DisputeOps(d);
  _grantRole(DEFAULT_ADMIN_ROLE, _msgSender());
  _grantRole(ROLE_TIMELOCK, _msgSender());

  // Initialize timeout config
  timeoutConfig = TimeoutConfig({
    defaultAutoReleaseTime: 0,
    defaultAutoCancelTime: 0,
    maxDisputeDuration: 90 days,
    appealWindowDuration: 2 days
  });
}
```

---

### Step 3: Update All References

#### 3.1 Update Getters

**Before**:

```solidity
// Direct access: defaultAutoReleaseTime, maxDisputeDuration, etc.
```

**After**:

```solidity
// Access via struct: timeoutConfig.defaultAutoReleaseTime, timeoutConfig.maxDisputeDuration, etc.
```

**Add convenience getters** (optional, for backward compatibility):

```solidity
function getDefaultAutoReleaseTime() external view returns (uint256) {
  return timeoutConfig.defaultAutoReleaseTime;
}

function getDefaultAutoCancelTime() external view returns (uint256) {
  return timeoutConfig.defaultAutoCancelTime;
}

function getMaxDisputeDuration() external view returns (uint256) {
  return timeoutConfig.maxDisputeDuration;
}

function getAppealWindowDuration() external view returns (uint256) {
  return timeoutConfig.appealWindowDuration;
}
```

#### 3.2 Update Setters

**Before**:

```solidity
function setDefaultAutoReleaseTime(uint256 time) public onlyRole(ROLE_TIMELOCK) {
  SettingsValidationLibrary.validateAutoRelease(time);
  defaultAutoReleaseTime = time;
}

function setDefaultAutoCancelTime(uint256 time) public onlyRole(ROLE_TIMELOCK) {
  SettingsValidationLibrary.validateAutoCancel(time);
  defaultAutoCancelTime = time;
}

function setMaxDisputeDuration(uint256 duration) external onlyRole(ROLE_TIMELOCK) {
  maxDisputeDuration = duration;
  emit MaxDisputeDurationUpdated(duration);
}
```

**After**:

```solidity
/**
 * @notice Update timeout configuration
 * @param config New timeout configuration
 * @dev Validates all fields and updates atomically
 */
function setTimeoutConfig(TimeoutConfig calldata config) external onlyRole(ROLE_TIMELOCK) {
  // Validate bounds
  require(
    config.maxDisputeDuration >= 7 days && config.maxDisputeDuration <= 365 days,
    'Invalid maxDisputeDuration: must be 7-365 days'
  );
  require(
    config.appealWindowDuration >= 1 days && config.appealWindowDuration <= 7 days,
    'Invalid appealWindowDuration: must be 1-7 days'
  );

  // Validate auto times (if set)
  SettingsValidationLibrary.validateAutoRelease(config.defaultAutoReleaseTime);
  SettingsValidationLibrary.validateAutoCancel(config.defaultAutoCancelTime);

  // Update struct atomically
  timeoutConfig = config;

  // Emit events
  emit TimeoutConfigUpdated(config);
  if (config.maxDisputeDuration != timeoutConfig.maxDisputeDuration) {
    emit MaxDisputeDurationUpdated(config.maxDisputeDuration);
  }
  if (config.appealWindowDuration != timeoutConfig.appealWindowDuration) {
    emit AppealWindowDurationUpdated(config.appealWindowDuration);
  }
  if (config.defaultAutoReleaseTime != timeoutConfig.defaultAutoReleaseTime) {
    emit DefaultAutoReleaseTimeUpdated(config.defaultAutoReleaseTime);
  }
  if (config.defaultAutoCancelTime != timeoutConfig.defaultAutoCancelTime) {
    emit DefaultAutoCancelTimeUpdated(config.defaultAutoCancelTime);
  }
}

// Keep individual setters for backward compatibility (deprecated)
function setDefaultAutoReleaseTime(uint256 time) public onlyRole(ROLE_TIMELOCK) {
  SettingsValidationLibrary.validateAutoRelease(time);
  timeoutConfig.defaultAutoReleaseTime = time;
  emit DefaultAutoReleaseTimeUpdated(time);
}

function setDefaultAutoCancelTime(uint256 time) public onlyRole(ROLE_TIMELOCK) {
  SettingsValidationLibrary.validateAutoCancel(time);
  timeoutConfig.defaultAutoCancelTime = time;
  emit DefaultAutoCancelTimeUpdated(time);
}

function setMaxDisputeDuration(uint256 duration) external onlyRole(ROLE_TIMELOCK) {
  require(duration >= 7 days && duration <= 365 days, 'Invalid duration: 7-365 days');
  timeoutConfig.maxDisputeDuration = duration;
  emit MaxDisputeDurationUpdated(duration);
}

function setAppealWindowDuration(uint256 duration) external onlyRole(ROLE_TIMELOCK) {
  require(duration >= 1 days && duration <= 7 days, 'Invalid duration: 1-7 days');
  timeoutConfig.appealWindowDuration = duration;
  emit AppealWindowDurationUpdated(duration);
}
```

#### 3.3 Update All Internal References

**Search and replace**:

- `defaultAutoReleaseTime` → `timeoutConfig.defaultAutoReleaseTime`
- `defaultAutoCancelTime` → `timeoutConfig.defaultAutoCancelTime`
- `maxDisputeDuration` → `timeoutConfig.maxDisputeDuration`
- `appealWindowDuration` → `timeoutConfig.appealWindowDuration`

**Key locations**:

- `_applyEscrowSettings()` - uses `defaultAutoReleaseTime` and `defaultAutoCancelTime`
- `autoCancelDisputedEscrow()` - uses `maxDisputeDuration`
- `isDisputeTimedOut()` - uses `maxDisputeDuration`
- `_executeResolution()` - uses `appealWindowDuration`

---

### Step 4: Add Events

```solidity
event TimeoutConfigUpdated(TimeoutConfig config);
event DefaultAutoReleaseTimeUpdated(uint256 newTime);
event DefaultAutoCancelTimeUpdated(uint256 newTime);
// MaxDisputeDurationUpdated already exists
// AppealWindowDurationUpdated already exists
```

---

### Step 5: Remove Duplicate Constant

**Remove from BaseEscrow.sol**:

```solidity
// REMOVE THIS:
uint256 public constant MAX_AUTO_TIME_DURATION = 10 * 365 * 24 * 60 * 60;
```

**Use from SettingsValidationLibrary**:

```solidity
// Import and use:
import '../libraries/SettingsValidationLibrary.sol';
// Access via: SettingsValidationLibrary.MAX_AUTO_TIME_DURATION
```

**Or add to TimeoutConfig struct** (if you want it accessible):

```solidity
struct TimeoutConfig {
  // ... fields ...
  // Constants (read-only, set in constructor)
  uint256 maxAutoTimeDuration; // 10 years
  uint256 maxAutoTimeDays; // 30 days
}
```

**Recommendation**: Keep constants separate (not in struct) - they don't change and don't need governance.

---

## Complete Implementation Example

### EscrowTypes.sol

```solidity
struct TimeoutConfig {
  // Auto-execution defaults (0 = disabled)
  uint256 defaultAutoReleaseTime; // Default auto-release timestamp
  uint256 defaultAutoCancelTime; // Default auto-cancel timestamp
  // Safety timeouts (durations in seconds)
  uint256 maxDisputeDuration; // Max time for disputes (7-365 days)
  uint256 appealWindowDuration; // Time to appeal resolution (1-7 days)
}
```

### BaseEscrow.sol

```solidity
// ============ Timeout Configuration ============
TimeoutConfig public timeoutConfig;

// Constants (keep separate - they don't change)
// Note: MAX_AUTO_TIME_DURATION is in SettingsValidationLibrary

// Events
event TimeoutConfigUpdated(TimeoutConfig config);
event DefaultAutoReleaseTimeUpdated(uint256 newTime);
event DefaultAutoCancelTimeUpdated(uint256 newTime);

// Setters
function setTimeoutConfig(TimeoutConfig calldata config) external onlyRole(ROLE_TIMELOCK) {
    // Validation
    require(
        config.maxDisputeDuration >= 7 days && config.maxDisputeDuration <= 365 days,
        "Invalid maxDisputeDuration"
    );
    require(
        config.appealWindowDuration >= 1 days && config.appealWindowDuration <= 7 days,
        "Invalid appealWindowDuration"
    );
    SettingsValidationLibrary.validateAutoRelease(config.defaultAutoReleaseTime);
    SettingsValidationLibrary.validateAutoCancel(config.defaultAutoCancelTime);

    // Update
    timeoutConfig = config;
    emit TimeoutConfigUpdated(config);
}

// Individual setters (for backward compatibility)
function setDefaultAutoReleaseTime(uint256 time) public onlyRole(ROLE_TIMELOCK) {
    SettingsValidationLibrary.validateAutoRelease(time);
    timeoutConfig.defaultAutoReleaseTime = time;
    emit DefaultAutoReleaseTimeUpdated(time);
}

function setDefaultAutoCancelTime(uint256 time) public onlyRole(ROLE_TIMELOCK) {
    SettingsValidationLibrary.validateAutoCancel(time);
    timeoutConfig.defaultAutoCancelTime = time;
    emit DefaultAutoCancelTimeUpdated(time);
}

function setMaxDisputeDuration(uint256 duration) external onlyRole(ROLE_TIMELOCK) {
    require(duration >= 7 days && duration <= 365 days, "Invalid duration");
    timeoutConfig.maxDisputeDuration = duration;
    emit MaxDisputeDurationUpdated(duration);
}

function setAppealWindowDuration(uint256 duration) external onlyRole(ROLE_TIMELOCK) {
    require(duration >= 1 days && duration <= 7 days, "Invalid duration");
    timeoutConfig.appealWindowDuration = duration;
    emit AppealWindowDurationUpdated(duration);
}

// View function
function getTimeoutConfig() external view returns (TimeoutConfig memory) {
    return timeoutConfig;
}
```

### Update Internal References

**In `_applyEscrowSettings()`**:

```solidity
// Before:
bool def = (settings.autoReleaseTime == 0 && settings.autoCancelTime == 0);
et.autoReleaseTime = settings.autoReleaseTime > 0
    ? uint64(settings.autoReleaseTime)
    : (def ? uint64(defaultAutoReleaseTime) : 0);
et.autoCancelTime = settings.autoCancelTime > 0
    ? uint64(settings.autoCancelTime)
    : (def ? uint64(defaultAutoCancelTime) : 0);

// After:
bool def = (settings.autoReleaseTime == 0 && settings.autoCancelTime == 0);
et.autoReleaseTime = settings.autoReleaseTime > 0
    ? uint64(settings.autoReleaseTime)
    : (def ? uint64(timeoutConfig.defaultAutoReleaseTime) : 0);
et.autoCancelTime = settings.autoCancelTime > 0
    ? uint64(settings.autoCancelTime)
    : (def ? uint64(timeoutConfig.defaultAutoCancelTime) : 0);
```

**In `autoCancelDisputedEscrow()`**:

```solidity
// Before:
require(ts > 0 && block.timestamp >= ts + maxDisputeDuration, "T");

// After:
require(ts > 0 && block.timestamp >= ts + timeoutConfig.maxDisputeDuration, "T");
```

**In `isDisputeTimedOut()`**:

```solidity
// Before:
return DisputeManagementLibrary.isTimedOut(
    workflowId,
    escrowTransfers[workflowId].escrowState,
    disputeRaisedTimestamp[workflowId],
    maxDisputeDuration
);

// After:
return DisputeManagementLibrary.isTimedOut(
    workflowId,
    escrowTransfers[workflowId].escrowState,
    disputeRaisedTimestamp[workflowId],
    timeoutConfig.maxDisputeDuration
);
```

**In `_executeResolution()`**:

```solidity
// Before:
uint256 appealDeadline = block.timestamp + appealWindowDuration;

// After:
uint256 appealDeadline = block.timestamp + timeoutConfig.appealWindowDuration;
```

---

## Migration Strategy

### Phase 1: Add Struct (Non-Breaking)

1. Add `TimeoutConfig` struct to `EscrowTypes.sol`
2. Add `timeoutConfig` state variable to `BaseEscrow.sol`
3. Initialize in child constructors
4. **Keep old variables** for now (backward compatibility)

### Phase 2: Update References

1. Update all internal references to use struct
2. Update getters to read from struct
3. Update setters to write to struct
4. **Keep old getters/setters** (deprecated but functional)

### Phase 3: Remove Old Variables (Breaking)

1. Remove old state variables
2. Remove deprecated getters/setters
3. Update external interfaces if needed

**Recommendation**: Do Phase 1-2 for mainnet, defer Phase 3 to post-launch.

---

## Testing Checklist

- [ ] TimeoutConfig initialized correctly in constructors
- [ ] `setTimeoutConfig()` validates all bounds
- [ ] Individual setters still work (backward compatibility)
- [ ] All internal references updated correctly
- [ ] Auto-release/cancel still works with defaults
- [ ] Dispute timeout still works
- [ ] Appeal window still works
- [ ] Events emitted correctly
- [ ] View functions return correct values
- [ ] Gas costs acceptable (struct access vs direct)

---

## Gas Impact Analysis

### Struct Access vs Direct Access

**Direct access**:

```solidity
uint256 duration = maxDisputeDuration; // SLOAD: ~2100 gas
```

**Struct access**:

```solidity
uint256 duration = timeoutConfig.maxDisputeDuration; // SLOAD: ~2100 gas (same)
```

**Conclusion**: **No gas difference** - struct access is same as direct access for single field.

### Struct Update vs Individual Updates

**Individual updates** (4 separate transactions):

```solidity
setDefaultAutoReleaseTime(time1);  // ~45,000 gas
setDefaultAutoCancelTime(time2);   // ~45,000 gas
setMaxDisputeDuration(duration1);  // ~45,000 gas
setAppealWindowDuration(duration2); // ~45,000 gas
Total: ~180,000 gas
```

**Struct update** (1 transaction):

```solidity
setTimeoutConfig(config); // ~60,000 gas (single transaction, more validation)
```

**Conclusion**: **Gas savings** when updating multiple values (single transaction vs multiple).

---

## Benefits Summary

### ✅ Code Organization

- All timeout settings in one place
- Clear grouping of related values
- Easier to understand relationships

### ✅ Safety

- Bounds validation on all fields
- Atomic updates (all or nothing)
- Prevents inconsistent configurations

### ✅ Maintainability

- Single source of truth
- Easier to document
- Easier to audit

### ✅ Gas Efficiency

- No gas cost for struct access
- Gas savings for multi-field updates
- Struct packing (if using smaller types)

### ✅ Backward Compatibility

- Keep individual setters
- Keep individual getters
- Gradual migration possible

---

## Risks & Mitigations

### Risk 1: Breaking Changes

**Mitigation**: Keep old getters/setters, mark as deprecated

### Risk 2: Initialization Issues

**Mitigation**: Initialize in all constructors, add tests

### Risk 3: Missing References

**Mitigation**: Comprehensive search/replace, thorough testing

### Risk 4: Gas Regression

**Mitigation**: Benchmark before/after, struct access is same cost

---

## Timeline Estimate

- **Design & Review**: 2-4 hours
- **Implementation**: 4-6 hours
- **Testing**: 4-6 hours
- **Code Review**: 2-4 hours
- **Total**: **1.5-2.5 days**

---

## Recommendation

**For 6 Weeks to Mainnet**:

✅ **DO IT** - The benefits outweigh the risks:

- Better code organization (critical for audit)
- Safety improvements (bounds validation)
- Low risk (backward compatible)
- Manageable timeline (1.5-2.5 days)

**Priority**: **Medium-High** - Do after critical fixes, before final audit prep.
