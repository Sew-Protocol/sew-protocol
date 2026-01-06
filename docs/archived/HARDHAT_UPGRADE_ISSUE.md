# Hardhat Upgrade Issue

## Problem

After upgrading Hardhat, tests fail with:
```
TypeError: Class extends value undefined is not a constructor or null
    at Object.<anonymous> (/home/user/Code/scaffold-eth-2/starter-scaffold-eth/packages/hardhat/node_modules/@nomicfoundation/hardhat-ethers/src/internal/errors.ts:3:41)
```

## Root Cause

The `@nomicfoundation/hardhat-ethers` package is trying to import `NomicLabsHardhatPluginError` from `hardhat/plugins`, but in Hardhat 3.x, this export path has changed.

**Current versions:**
- `hardhat`: `~3.1.2`
- `@nomicfoundation/hardhat-ethers`: `~3.0.8`
- `ethers`: `~6.13.2`

## Investigation

1. ✅ Removed `hardhat-deploy-ethers` (incompatible with Hardhat 3.x)
2. ✅ Verified `hardhat/plugins` exports `HardhatPluginError` (not `NomicLabsHardhatPluginError`)
3. ⚠️ `@nomicfoundation/hardhat-ethers@3.0.8` still uses old import path

## Solutions

### Option 1: Downgrade Hardhat (Quick Fix)
```bash
yarn add -D hardhat@~2.19.0
```

### Option 2: Update @nomicfoundation/hardhat-ethers (Recommended)
```bash
yarn add -D @nomicfoundation/hardhat-ethers@latest
```

### Option 3: Wait for Compatible Version
The issue is in `@nomicfoundation/hardhat-ethers@3.0.8` - it needs to be updated to use the new Hardhat 3.x plugin error import.

## Current Status

- ❌ Tests failing due to import error
- ✅ `hardhat-deploy-ethers` removed
- ⚠️ Need to update `@nomicfoundation/hardhat-ethers` to compatible version

## Workaround

For now, Aave tests are created but cannot run until this issue is resolved.

**Files created:**
- ✅ `packages/hardhat/contracts/mocks/MockAavePool.sol`
- ✅ `packages/hardhat/test/AaveIntegration.test.ts`

**Next Steps:**
1. Resolve Hardhat compatibility issue
2. Run Aave integration tests
3. Fix any test failures

---

**Priority**: HIGH - Blocking test execution  
**Status**: ⚠️ In Progress



