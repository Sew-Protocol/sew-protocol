# Module Developer Role Removal Analysis

**Date:** 2026-01-06  
**Purpose:** Analyze removing ROLE_MODULE_DEVELOPER for consistency with governance model  
**Context:** Extracting DecentralizedResolutionModule into separate package/repo

---

## Current State

### ROLE_MODULE_DEVELOPER Scope

**Where it exists:**
- `DecentralizedResolutionModule.sol` (line 33)
- `ResolverIncentiveModule.sol` (line 33)

**What it allows:**
- Upgrade `DecentralizedResolutionModule` via UUPS (with staged delays)
- Upgrade `ResolverIncentiveModule` via UUPS (with staged delays)
- Queue/activate upgrades with time-based delays (1h/24h/7d)

**What it cannot do:**
- Swap modules in BaseEscrow (requires ROLE_TIMELOCK + slow lane)
- Modify access control
- Bypass governance delays
- Change other protocol parameters

### Current Governance Model

**Three governance lanes:**
1. **Standard Lane** (48h delay) - TimelockController
2. **Slow Lane** (~9 days) - TimelockController  
3. **Emergency Lane** (0h delay) - Guardian Multisig (down-only)

**ROLE_MODULE_DEVELOPER is an exception:**
- Creates a "fourth lane" for module upgrades
- Staged delays (1h/24h/7d) different from standard lanes
- Only applies to two specific modules
- Adds complexity to governance model

---

## Arguments for Removal

### 1. Governance Model Consistency ⭐⭐⭐⭐⭐

**Current inconsistency:**
- All other upgrades go through TimelockController
- Module developer role creates special exception
- Inconsistent delay mechanisms (staged vs fixed)

**After removal:**
- All upgrades go through standard governance lanes
- Consistent delay mechanisms
- Simpler mental model
- Easier to explain to users/auditors

**Impact:** High - Makes governance model cleaner and more predictable

### 2. Security Surface Reduction ⭐⭐⭐⭐⭐

**Current attack surface:**
- Additional role to manage
- Role grant/revoke process
- Role holder compromise risk
- Upgrade authorization logic complexity

**After removal:**
- One less role to manage
- One less attack vector
- Simpler access control
- Fewer edge cases in upgrade logic

**Impact:** High - Reduces security complexity and attack surface

### 3. Alignment with Extraction Strategy ⭐⭐⭐⭐⭐

**Extraction rationale:**
- DecentralizedResolutionModule should be tested in isolation
- Should be proven before mainnet integration
- No need for rapid iteration on mainnet
- Can be swapped in via slow-lane governance once proven

**Module developer role rationale:**
- Was designed for "rapid iteration during early phases"
- Contradicts the "test in isolation first" strategy
- Not needed if module is proven before swap

**Impact:** High - Removing role aligns with extraction strategy

### 4. Simplicity ⭐⭐⭐⭐

**Current complexity:**
- Special role just for two modules
- Staged delay system (different from standard lanes)
- Queue/activate pattern specific to module developer
- Additional documentation and processes

**After removal:**
- Standard governance lanes only
- Consistent upgrade process
- Less documentation needed
- Easier onboarding

**Impact:** Medium-High - Significantly simplifies governance model

### 5. Principle of Least Privilege ⭐⭐⭐⭐

**Current state:**
- Module developer has upgrade authority
- Even with delays, still bypasses full governance process
- Creates privileged class of actors

**After removal:**
- All upgrades require full governance process
- No privileged upgrade paths
- Consistent with principle of least privilege

**Impact:** Medium-High - Better security posture

---

## Arguments Against Removal

### 1. Rapid Iteration Capability ⭐⭐

**Current benefit:**
- Can fix bugs quickly (1h delay in launch phase)
- Faster response to issues
- Less friction for module improvements

**After removal:**
- All upgrades require full slow-lane process (~9 days)
- Slower response to critical bugs
- More friction for improvements

**Counter-argument:**
- If module is tested in isolation first, bugs should be caught before mainnet
- Critical bugs can use emergency pause + slow-lane fix
- ~9 days is acceptable for non-critical improvements
- Rapid iteration contradicts "proven before swap" strategy

**Impact:** Low - Not a strong argument given extraction strategy

### 2. Module-Specific Needs ⭐

**Current benefit:**
- Recognizes that modules may need different upgrade cadence
- Allows module-specific governance

**After removal:**
- All modules follow same governance process
- Less flexibility

**Counter-argument:**
- Consistency is more valuable than flexibility
- Standard governance lanes are sufficient
- Module-specific needs can be addressed via standard governance

**Impact:** Low - Flexibility not worth the complexity

### 3. Migration Effort ⭐⭐

**Current state:**
- Role is implemented and documented
- Removal requires code changes

**After removal:**
- Need to remove role from contracts
- Update documentation
- Update governance processes

**Counter-argument:**
- Effort is minimal (role only in 2 contracts)
- Part of extraction process anyway
- Cleanup is beneficial

**Impact:** Low - Minimal effort, part of extraction

---

## Impact Analysis

### Code Changes Required

**Contracts to modify:**
1. `DecentralizedResolutionModule.sol`
   - Remove `ROLE_MODULE_DEVELOPER` constant (line 33)
   - Update `_authorizeUpgrade()` to only allow `ROLE_TIMELOCK` (line 324-353)
   - Remove `queueUpgrade()` function (line 1818) - or keep for timelock use?
   - Remove `activateUpgrade()` function (line 1851) - or keep for timelock use?
   - Remove staged delay logic (or simplify to timelock-only)

2. `ResolverIncentiveModule.sol`
   - Remove `ROLE_MODULE_DEVELOPER` constant (line 33)
   - Update `_authorizeUpgrade()` to only allow `ROLE_TIMELOCK` (line 185-193)
   - Remove any module developer-specific functions

**Decision point:** Keep queue/activate functions for timelock use?
- **Option A:** Remove entirely, use standard UUPS `upgradeTo()` via timelock
- **Option B:** Keep functions but require `ROLE_TIMELOCK` instead
- **Recommendation:** Option A - Use standard governance, no special queue/activate needed

### Documentation Changes Required

**Files to update:**
1. `docs/governance.md` - Remove Module Developer section (lines 246-270)
2. `docs/GOVERNANCE_SURFACE_MAP.md` - Remove module developer role references
3. `docs/SECURITY_MODEL.md` - Remove ROLE_MODULE_DEVELOPER from governance roles
4. `docs/MODULE_DEVELOPER_ROLE_DESIGN.md` - Archive or move to extracted module repo
5. `docs/MODULE_DEVELOPER_ROLE_SUMMARY.md` - Archive or move to extracted module repo
6. `docs/MODULE_UPGRADE_STRATEGY.md` - Update to remove module developer references
7. `docs/MODULE_UPGRADE_IMPLEMENTATION_PLAN.md` - Update if module developer-specific

### Governance Process Changes

**Before removal:**
- Module developer can queue/activate upgrades with staged delays
- Timelock can also upgrade (instant, via slow-lane governance)

**After removal:**
- Only Timelock can upgrade (via slow-lane governance)
- All upgrades follow standard ~9 day process
- No special queue/activate pattern needed

---

## Recommendation: Remove ROLE_MODULE_DEVELOPER

### Strong Arguments for Removal

1. **Governance Consistency** ⭐⭐⭐⭐⭐
   - Aligns with standard three-lane governance model
   - Removes exception case
   - Simpler mental model

2. **Security** ⭐⭐⭐⭐⭐
   - Reduces attack surface
   - Fewer roles to manage
   - Simpler access control

3. **Strategy Alignment** ⭐⭐⭐⭐⭐
   - Aligns with "test in isolation first" extraction strategy
   - Module should be proven before swap
   - No need for rapid iteration on mainnet

4. **Simplicity** ⭐⭐⭐⭐
   - Removes special case
   - Less documentation
   - Easier to understand

### Weak Arguments Against Removal

1. **Rapid iteration** - Contradicts extraction strategy
2. **Flexibility** - Not worth the complexity
3. **Migration effort** - Minimal, part of extraction anyway

### Implementation Approach

#### Option 1: Remove Entirely (Recommended)

**Changes:**
- Remove `ROLE_MODULE_DEVELOPER` constant
- Simplify `_authorizeUpgrade()` to only allow `ROLE_TIMELOCK`
- Remove `queueUpgrade()` and `activateUpgrade()` functions
- Use standard UUPS `upgradeTo()` via timelock

**Benefits:**
- Cleanest approach
- No special cases
- Standard governance only

**Upgrade process:**
1. Governance proposal to upgrade module
2. Timelock queues upgrade (48h delay)
3. Timelock executes upgrade (after 48h)
4. Total: ~48h (standard lane) or ~9 days (slow lane if high-impact)

#### Option 2: Keep Queue/Activate for Timelock

**Changes:**
- Remove `ROLE_MODULE_DEVELOPER` constant
- Update `queueUpgrade()` and `activateUpgrade()` to require `ROLE_TIMELOCK`
- Keep staged delay logic (optional - could simplify)

**Benefits:**
- Maintains queue/activate pattern
- Can still use staged delays if desired

**Drawbacks:**
- More complex than needed
- Staged delays not necessary for timelock (already has delays)

**Recommendation:** Option 1 - Remove entirely, use standard governance

---

## Consistency Benefits

### Before Removal

**Governance model:**
- Standard Lane (48h) - Timelock
- Slow Lane (~9d) - Timelock
- Emergency Lane (0h) - Guardian
- **Module Upgrade Lane (1h/24h/7d) - Module Developer** ← Exception

**Upgrade mechanisms:**
- Standard: Direct function calls via timelock
- Slow: Queue/activate via timelock
- Emergency: Direct function calls via guardian
- **Module: Queue/activate via module developer** ← Exception

**Role management:**
- ROLE_TIMELOCK - Standard governance
- ROLE_GUARDIAN - Emergency controls
- **ROLE_MODULE_DEVELOPER - Module upgrades** ← Exception

### After Removal

**Governance model:**
- Standard Lane (48h) - Timelock
- Slow Lane (~9d) - Timelock
- Emergency Lane (0h) - Guardian
- **No exceptions** ✅

**Upgrade mechanisms:**
- Standard: Direct function calls via timelock
- Slow: Queue/activate via timelock (if needed)
- Emergency: Direct function calls via guardian
- **Module: Standard UUPS upgrade via timelock** ✅

**Role management:**
- ROLE_TIMELOCK - Standard governance
- ROLE_GUARDIAN - Emergency controls
- **No special roles** ✅

---

## Extraction Context

### If Extracting DecentralizedResolutionModule

**Natural fit:**
- Role is specific to DecentralizedResolutionModule
- Should be extracted with the module
- Or removed entirely if not needed

**Decision:**
- **Extract with module:** If module needs rapid iteration in its own repo
- **Remove entirely:** If module should be proven before mainnet swap (recommended)

**Recommendation:** Remove entirely - aligns with "test in isolation first" strategy

### If Keeping DecentralizedResolutionModule in Main Repo

**Still recommend removal:**
- Consistency with governance model
- Security surface reduction
- Simplicity
- Standard governance is sufficient

---

## Implementation Checklist

### Code Changes
- [ ] Remove `ROLE_MODULE_DEVELOPER` from `DecentralizedResolutionModule.sol`
- [ ] Simplify `_authorizeUpgrade()` to only allow `ROLE_TIMELOCK`
- [ ] Remove `queueUpgrade()` function (or update to require `ROLE_TIMELOCK`)
- [ ] Remove `activateUpgrade()` function (or update to require `ROLE_TIMELOCK`)
- [ ] Remove staged delay logic (or simplify)
- [ ] Remove `ROLE_MODULE_DEVELOPER` from `ResolverIncentiveModule.sol`
- [ ] Update `ResolverIncentiveModule._authorizeUpgrade()` to only allow `ROLE_TIMELOCK`
- [ ] Remove any module developer-specific functions from `ResolverIncentiveModule`

### Documentation Changes
- [ ] Remove Module Developer section from `docs/governance.md`
- [ ] Update `docs/GOVERNANCE_SURFACE_MAP.md` - Remove module developer references
- [ ] Update `docs/SECURITY_MODEL.md` - Remove ROLE_MODULE_DEVELOPER
- [ ] Archive `docs/MODULE_DEVELOPER_ROLE_DESIGN.md`
- [ ] Archive `docs/MODULE_DEVELOPER_ROLE_SUMMARY.md`
- [ ] Update `docs/MODULE_UPGRADE_STRATEGY.md`
- [ ] Update `docs/MODULE_UPGRADE_IMPLEMENTATION_PLAN.md`
- [ ] Update `docs/DECENTRALIZED_RESOLUTION_MODULE_EXTRACTION_PLAN.md`

### Testing
- [ ] Update tests to remove module developer role tests
- [ ] Add tests for timelock-only upgrades
- [ ] Verify upgrade process works via timelock
- [ ] Update integration tests

### Deployment
- [ ] Remove module developer role from deployment scripts
- [ ] Update role grant scripts
- [ ] Verify no module developer roles are granted

---

## Conclusion

**Strong recommendation: Remove ROLE_MODULE_DEVELOPER entirely**

### Key Reasons

1. **Consistency** - Aligns with standard three-lane governance model
2. **Security** - Reduces attack surface and complexity
3. **Strategy** - Aligns with "test in isolation first" extraction approach
4. **Simplicity** - Removes exception case, easier to understand

### Implementation

- Remove role from both contracts
- Simplify upgrade authorization to timelock-only
- Remove queue/activate functions (or update to timelock-only)
- Use standard UUPS `upgradeTo()` via timelock governance

### Timing

- **Best:** Remove as part of DecentralizedResolutionModule extraction
- **Alternative:** Remove before extraction (cleaner extraction)
- **Not recommended:** Keep role after extraction (inconsistent)

**Bottom line:** The role was designed for rapid iteration, but the extraction strategy is to test in isolation first. Once proven, the module can be swapped in via standard governance. The role adds complexity without clear benefit and contradicts the conservative approach.



