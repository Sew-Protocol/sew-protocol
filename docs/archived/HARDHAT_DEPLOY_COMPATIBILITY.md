# Hardhat-Deploy Compatibility - RESOLVED ✅

## Problem (Historical)

Previously, when running `pnpm deploy:local`, the following errors occurred:

1. `TypeError: network.provider.getSignerFrom is not a function`
2. `Error: unknown transaction override deploymentType`
3. `Error: invalid object key - customData`

## Root Cause

There was a compatibility issue between:
- `hardhat-deploy@0.13.0` 
- `hardhat-deploy-ethers@0.4.2`
- `@nomicfoundation/hardhat-ethers@3.0.2` (ethers v6)

## Resolution

**The issue has been resolved by downgrading `hardhat-deploy` from `0.13.0` to `0.12.0`.**

The `0.12.0` version is compatible with:
- `hardhat-deploy-ethers@0.4.2`
- `@nomicfoundation/hardhat-ethers@3.1.3`

## Current Solution

### 1. getSignerFrom Workaround (Still Required)

The `getSignerFrom` method workaround in `hardhat.config.ts` is still needed:

```typescript
extendEnvironment(async (hre) => {
  if (hre.network.provider && !(hre.network.provider as any).getSignerFrom) {
    const provider = hre.network.provider;
    (provider as any).getSignerFrom = function(address: string) {
      return (hre.ethers.provider as any).getSigner(address);
    };
  }
});
```

This workaround is minimal and doesn't require patching.

### 2. Removed Patch System

The patch system has been completely removed:
- ✅ Removed `postinstall` script from `package.json`
- ✅ Removed `patch-package` dependency
- ✅ Removed `postinstall-postinstall` dependency
- ✅ Deleted patch files from `patches/` directory

## Current Status

- ✅ Using `hardhat-deploy@0.12.0` (compatible version)
- ✅ `getSignerFrom` workaround in place (minimal, no patching needed)
- ✅ No patches required
- ✅ Deployments working successfully
- ✅ Clean dependency tree

## Package Versions

Current compatible versions:
- `hardhat-deploy@0.12.0`
- `hardhat-deploy-ethers@0.4.2`
- `@nomicfoundation/hardhat-ethers@3.1.3`

## Notes

- The `0.12.0` version of `hardhat-deploy` doesn't have the `deploymentType` and `customData` issues
- The `getSignerFrom` workaround is a simple compatibility shim and doesn't require patching
- Future upgrades to `hardhat-deploy@0.13.0+` may require re-evaluation
