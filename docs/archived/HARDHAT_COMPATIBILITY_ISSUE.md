# Hardhat 3.x Compatibility Issue

## Summary

After upgrading to Hardhat 3.1.2, `@nomicfoundation/hardhat-ethers@3.0.8` is incompatible due to breaking changes in Hardhat's plugin system.

## Errors Encountered

1. **First Error**: `Class extends value undefined is not a constructor or null`
   - **Cause**: `NomicLabsHardhatPluginError` doesn't exist in Hardhat 3.x
   - **Fix Applied**: Patched to use `HardhatPluginError` from `@nomicfoundation/hardhat-errors`

2. **Second Error**: `extendEnvironment is not a function`
   - **Cause**: `extendEnvironment` doesn't exist in Hardhat 3.x plugin system
   - **Status**: ⚠️ **BLOCKING** - No workaround found

## Root Cause

Hardhat 3.x has a completely redesigned plugin system:
- `extendEnvironment` removed
- Plugin architecture changed
- `@nomicfoundation/hardhat-ethers@3.0.8` was built for Hardhat 2.x

## Solutions

### Option 1: Downgrade Hardhat (Recommended for now)
```bash
cd packages/hardhat
yarn add -D hardhat@~2.19.0
```

### Option 2: Wait for Compatible Package
Wait for `@nomicfoundation/hardhat-ethers` to release a version compatible with Hardhat 3.x

### Option 3: Use Alternative
Consider using `hardhat-ethers` or another ethers integration that supports Hardhat 3.x

## Current Status

- ✅ Solidity upgraded to 0.8.31
- ✅ All contracts updated to `pragma solidity ^0.8.31;`
- ❌ Tests blocked by Hardhat compatibility issue
- ⚠️ Manual patches applied but incomplete

## Next Steps

1. **Immediate**: Downgrade Hardhat to 2.x to unblock testing
2. **Short-term**: Monitor for `@nomicfoundation/hardhat-ethers` update
3. **Long-term**: Migrate to Hardhat 3.x when full compatibility is available

---

**Recommendation**: Downgrade to Hardhat 2.19.x until compatibility is resolved.



