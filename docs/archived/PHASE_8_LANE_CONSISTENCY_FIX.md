# Phase 8: Lane Consistency Fix

## Issue Identified

**Critical Governance Inconsistency**: EscrowVault had direct default module setters in Standard lane (48h delay), while EscrowableERC20 used Slow lane (queue/activate, ~9 days delay) for the same class of change.

This created a **governance lane escape hatch**:
- Module swaps could be done via EscrowVault with only 48h review
- Same change via EscrowableERC20 required ~9 days
- Reviewers would question: "Why is it slow for one contract but fast for another?"

## Fix Applied

**Option A (Preferred)**: Made EscrowVault default module setters use Slow lane (queue/activate) to match EscrowableERC20.

### Changes Made

1. **EscrowVault.sol**:
   - Added `SlowLaneQueueActivate` import (inherited via BaseEscrow)
   - Added pending storage for all 4 default modules:
     - `_pendingDefaultReleaseStrategy`
     - `_pendingDefaultResolutionModule`
     - `_pendingDefaultYieldGenerationModule`
     - `_pendingDefaultYieldDistributionModule`
   - Replaced direct setters with queue/activate pattern:
     - `setDefaultReleaseStrategy()` → `queueDefaultReleaseStrategy()` / `activateDefaultReleaseStrategy()`
     - `setDefaultResolutionModule()` → `queueDefaultResolutionModule()` / `activateDefaultResolutionModule()`
     - `setDefaultYieldGenerationModule()` → `queueDefaultYieldGenerationModule()` / `activateDefaultYieldGenerationModule()`
     - `setDefaultYieldDistributionModule()` → `queueDefaultYieldDistributionModule()` / `activateDefaultYieldDistributionModule()`
   - Added queue/activate events matching EscrowableERC20
   - Added getter functions for pending changes

2. **Tests Updated**:
   - `MainnetReleaseSequence.test.ts` - Updated to use queue/activate with time manipulation
   - `05_ModuleSnapshotting.test.ts` - Updated to use queue/activate with time manipulation
   - `setupResolutionModule.ts` - Updated to handle both EscrowableERC20 and EscrowVault queue/activate pattern

3. **Documentation Updated**:
   - `GOVERNANCE_SURFACE_MAP.md` - Updated EscrowVault function table to show Slow lane
   - `MODULE_MAP.md` - Updated change mechanisms to show queue/activate for EscrowVault

## Result

**Before Fix**:
- EscrowableERC20 defaults = Slow (queue/activate) ✅
- EscrowVault defaults = Standard (direct setters) ❌

**After Fix**:
- EscrowableERC20 defaults = Slow (queue/activate) ✅
- EscrowVault defaults = Slow (queue/activate) ✅

**Consistency Achieved**: Both contracts now use the same governance lane for the same class of change, eliminating the escape hatch.

## Impact

- **Security**: Module swaps now require ~9 days review for both contracts
- **Credibility**: No governance lane inconsistencies for reviewers to question
- **Coherence**: Same change type = same governance lane across all contracts

## References

- User feedback on lane inconsistency
- `GOVERNANCE_SURFACE_MAP.md` - Updated function mapping
- `MODULE_MAP.md` - Updated change mechanisms


