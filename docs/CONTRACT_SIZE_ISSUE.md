# Contract Size Issue

## Problem

Contracts are exceeding the 24KB (24576 bytes) size limit introduced in Spurious Dragon upgrade.

**Current Status** (as of latest refactor):
- BaseEscrow: ~33KB (exceeds limit by ~9KB)
- EscrowVault: ~34KB (exceeds limit by ~10KB)
- EscrowableERC20: ~36KB (exceeds limit by ~12KB)

## Impact

- ❌ Contracts cannot be deployed to mainnet
- ⚠️ Tests fail with "trying to deploy a contract whose code is too large"
- ⚠️ Deployment scripts will fail

## Solutions Implemented

### ✅ 1. Library Extraction (IN PROGRESS)

**Status**: Partially Complete

**Libraries Created**:
- ✅ `SettingsValidationLibrary` - Settings validation logic
- ✅ `YieldDistributionLibrary` - Yield distribution validation and encoding
- ✅ `EscrowEncodingLibrary` - Encoding/decoding utilities
- ✅ `EscrowTypes` - Shared types and errors

**Functions Extracted**:
- ✅ `_validateAutoTime()` → `SettingsValidationLibrary.validateAutoTime()`
- ✅ `_validateEscrowSettings()` → `SettingsValidationLibrary.validateEscrowSettings()`
- ✅ `_getDefaultSettings()` → `SettingsValidationLibrary.getDefaultSettings()`
- ✅ `_encodeResolutionData()` → `EscrowEncodingLibrary.encodeEscrowTransferData()`
- ✅ `_validateYieldDistribution()` → `YieldDistributionLibrary.validateYieldDistribution()`
- ✅ `_encodeYieldDistribution()` → `YieldDistributionLibrary.encodeYieldDistribution()`

**Impact**: Medium - Reduced contract size, but more extraction needed

### ✅ 2. Module Architecture (COMPLETE)

**Status**: Complete

**Modules Created**:
- ✅ `AaveYieldGenerationModule` - All Aave-specific logic moved here
- ✅ `DefaultYieldDistributionModule` - Yield distribution logic
- ✅ Module registries in EscrowVault/EscrowableERC20

**Impact**: High - Aave logic no longer in BaseEscrow, but wrapper functions remain

### ✅ 3. Optimizer Configuration

**Status**: ✅ Applied  
**Configuration**: `runs: 10000` with `viaIR: true`  
**Impact**: Medium - Reduces size but not enough alone

## Current Workaround

For testing purposes:
1. ✅ Use `viaIR: true` with high optimizer runs (already done)
2. ✅ Enable `allowUnlimitedContractSize: true` in Hardhat network config (for tests only)
3. ⚠️ **Note**: This only works in test environment. Production deployment still requires size reduction.

**Applied Configuration**:
```typescript
hardhat: {
  allowUnlimitedContractSize: true, // Test environment only
  // ...
}
```

## Next Steps - Proposed Optimizations

### 🔄 1. Simplify Module Wrapper Functions (HIGH IMPACT)

**Current State**: BaseEscrow has thin wrapper functions that just delegate to modules:
- `_depositToAave()` - 17 lines, just delegates
- `_withdrawFromAave()` - 17 lines, just delegates
- `_withdrawFromAaveProportional()` - 17 lines, just delegates
- `_calculateYield()` - 11 lines, just delegates

**Proposal**: Inline these functions directly at call sites. This would:
- Remove ~60 lines of wrapper code
- Reduce contract size by ~2-3KB
- Simplify codebase (less indirection)

**Effort**: 1-2 hours  
**Impact**: Medium-High

### 🔄 2. Extract Yield Distribution Fallback Logic (MEDIUM IMPACT)

**Current State**: `_distributeYield()` has ~60 lines of fallback logic when no module is set.

**Proposal**: Extract fallback distribution logic to `YieldDistributionLibrary`:
- Move fallback distribution loop to library
- Keep module delegation in BaseEscrow
- Library handles both module and fallback cases

**Effort**: 2-3 hours  
**Impact**: Medium (~1-2KB reduction)

### 🔄 3. Extract Resolver Logic (MEDIUM IMPACT)

**Current State**: Resolver functions (`resolverRelease`, `resolverPartialRelease`, etc.) have complex logic.

**Proposal**: Extract common resolver patterns to `ResolverLogicLibrary`:
- Extract payout calculation logic
- Extract state transition logic
- Extract yield calculation for resolvers

**Effort**: 4-6 hours  
**Impact**: Medium-High (~2-3KB reduction)

### 🔄 4. Extract Attachment Handling (LOW-MEDIUM IMPACT)

**Current State**: Attachment functions (`addAttachment`, `addAttachmentSet`, etc.) have validation and storage logic.

**Proposal**: Extract to `AttachmentLibrary`:
- Validation logic
- Storage updates
- Event emission patterns

**Effort**: 2-3 hours  
**Impact**: Low-Medium (~1KB reduction)

### 🔄 5. Extract Settings Application Logic (LOW IMPACT)

**Current State**: `_applyEscrowSettings()` has complex conditional logic for auto times.

**Proposal**: Extract to `SettingsApplicationLibrary`:
- Auto time application logic
- Default settings merging
- State updates

**Effort**: 2-3 hours  
**Impact**: Low (~0.5-1KB reduction)

### 🔄 6. Remove Unused/Optional Features (MEDIUM IMPACT)

**Proposal**: Review and potentially remove/disable:
- Permit functionality (if not critical)
- Complex attachment handling (if simplified version works)
- Some resolver flexibility (if standard resolution is sufficient)

**Effort**: 1-2 days (requires analysis)  
**Impact**: Variable (could be 2-5KB if significant features removed)

### 🔄 7. Split BaseEscrow (HIGH IMPACT, HIGH EFFORT)

**Proposal**: Split BaseEscrow into:
- `BaseEscrowCore` - Core escrow logic (create, release, cancel)
- `BaseEscrowResolvers` - Resolver functions
- `BaseEscrowSettings` - Settings management
- `BaseEscrowAttachments` - Attachment handling

**Effort**: 3-5 days  
**Impact**: High (could reduce each contract by 5-10KB)

## Recommended Priority

1. **Immediate** (1-2 days):
   - Simplify module wrapper functions (#1)
   - Extract yield distribution fallback (#2)

2. **Short-term** (3-5 days):
   - Extract resolver logic (#3)
   - Extract attachment handling (#4)

3. **Medium-term** (1-2 weeks):
   - Extract settings application (#5)
   - Review unused features (#6)

4. **Long-term** (if still needed):
   - Consider contract splitting (#7)

## Notes on Aave Logic

**Important**: Aave-specific logic has already been moved to `AaveYieldGenerationModule`. The functions in BaseEscrow (`_depositToAave`, etc.) are just thin wrappers that delegate to modules. These can be inlined or simplified, but there's no Aave logic to extract to a library - it's already modularized.

## References

- [EIP-170: Contract code size limit](https://eips.ethereum.org/EIPS/eip-170)
- [Solidity Optimizer Documentation](https://docs.soliditylang.org/en/latest/using-the-compiler.html#optimizer-options)
- [Hardhat viaIR Configuration](https://hardhat.org/hardhat-runner/docs/config#solidity-config)
- [Library Extraction Best Practices](https://docs.soliditylang.org/en/latest/contracts.html#libraries)

---

**Priority**: HIGH  
**Status**: ⚠️ Blocking deployment  
**Last Updated**: After library extraction and module refactoring
