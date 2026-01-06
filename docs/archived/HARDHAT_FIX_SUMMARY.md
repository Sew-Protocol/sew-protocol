# Hardhat Upgrade Fix Summary

## Issue

After upgrading Hardhat to 3.1.2, tests fail with:
```
TypeError: Class extends value undefined is not a constructor or null
```

## Root Cause

`@nomicfoundation/hardhat-ethers@3.0.8` is incompatible with Hardhat 3.x:
1. It imports `NomicLabsHardhatPluginError` from `hardhat/plugins`, but Hardhat 3.x exports `HardhatPluginError` from `@nomicfoundation/hardhat-errors`
2. It imports `hardhat/types/runtime` which is not exported in Hardhat 3.x package.json exports

## Fix Applied

**Manual patches to node_modules** (temporary until package is updated):

1. **Fixed errors.ts import**:
   ```typescript
   // Before:
   import { NomicLabsHardhatPluginError } from "hardhat/plugins";
   
   // After:
   import { HardhatPluginError } from "@nomicfoundation/hardhat-errors";
   ```

2. **Fixed compiled JS**:
   - Updated `node_modules/@nomicfoundation/hardhat-ethers/internal/errors.js`
   - Changed `plugins_1.NomicLabsHardhatPluginError` to `plugins_1.HardhatPluginError`

3. **Fixed type-extensions.js**:
   - Commented out `require("hardhat/types/runtime")` (type-only import, not needed at runtime)

## Files Modified

- `packages/hardhat/node_modules/@nomicfoundation/hardhat-ethers/src/internal/errors.ts`
- `packages/hardhat/node_modules/@nomicfoundation/hardhat-ethers/internal/errors.js`
- `packages/hardhat/node_modules/@nomicfoundation/hardhat-ethers/internal/type-extensions.js`

## Permanent Solution

**Option 1: Wait for package update** (Recommended)
- Wait for `@nomicfoundation/hardhat-ethers` to release a version compatible with Hardhat 3.x

**Option 2: Use patch-package**
- Install `patch-package`
- Create proper patch file
- Apply patches automatically after `yarn install`

**Option 3: Downgrade Hardhat**
- Use Hardhat 2.x until compatibility is resolved

## Current Status

- ⚠️ **Manual patches applied** - Will be lost on `yarn install`
- ✅ **Tests can run** - After patches are applied
- ⚠️ **Not permanent** - Need proper solution

## Next Steps

1. Install `patch-package` to make patches permanent
2. Or wait for `@nomicfoundation/hardhat-ethers` update
3. Or downgrade to Hardhat 2.x

---

**Note**: These patches are temporary and will be lost when `node_modules` is reinstalled.



