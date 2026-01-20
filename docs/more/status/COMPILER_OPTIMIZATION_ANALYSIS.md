# Compiler Optimization Analysis

**Date:** 2025-01-27  
**Current Settings:**

- Solidity: 0.8.28
- Optimizer: enabled, runs: 50000
- viaIR: true
- EVM Version: cancun

## Solidity Version Upgrade: 0.8.28 → 0.8.31

### Potential Benefits

1. **Improved Yul Optimizer (0.8.26+)**
   - Better optimization sequences
   - Faster compilation
   - Potentially smaller bytecode

2. **IR Pipeline Improvements**
   - Better inlining decisions
   - Improved code generation
   - More efficient bytecode

3. **Bug Fixes**
   - Various compiler bug fixes
   - Better error handling
   - More accurate size reporting

### Potential Risks

1. **Breaking Changes**
   - Review changelog for breaking changes
   - Test all contracts thoroughly
   - Verify ABI compatibility

2. **Size Impact Unknown**
   - May increase or decrease size
   - Depends on contract structure
   - Need to test and measure

### Recommendation

**Test upgrade in separate branch:**

1. Upgrade to 0.8.31
2. Compile and measure sizes
3. Run all tests
4. Compare results

**Expected Impact:** Unknown - could be -1 KB to +0.5 KB

---

## Current Compiler Settings Analysis

### Current Settings

```typescript
optimizer: {
  enabled: true,
  runs: 50000,  // Very high - optimized for size
},
viaIR: true,    // IR-based compilation
evmVersion: "cancun"
```

### Settings Explanation

**`runs: 50000`**

- **Purpose:** Optimize for contract size (not gas cost)
- **Trade-off:** Higher `runs` = smaller bytecode but higher gas cost per transaction
- **Current:** Already at very high value (50000)
- **Max Recommended:** 100000 (but diminishing returns)

**`viaIR: true`**

- **Purpose:** Use Intermediate Representation pipeline
- **Benefits:** Better optimizations, smaller bytecode in some cases
- **Drawbacks:** Can increase size if functions are called many times (inlining)
- **Current:** Already enabled

**`evmVersion: "cancun"`**

- **Purpose:** Use Cancun EVM features (mcopy instruction)
- **Benefits:** More efficient memory operations
- **Current:** Latest, good choice

---

## Additional Optimization Options

### 1. Increase Optimizer Runs Further

**Option:** `runs: 100000` or `runs: 200000`

**Expected Impact:** ~0.2-0.5 KB additional savings

**Trade-off:** Higher gas costs, longer compilation time

**Recommendation:** Test with 100000 first, measure impact

### 2. Disable viaIR (Test)

**Option:** `viaIR: false`

**Expected Impact:** Unknown - could increase or decrease size

**Why Test:** IR can sometimes increase size due to inlining

**Recommendation:** Test both `viaIR: true` and `viaIR: false`, compare

### 3. Optimizer Details

**Option:** Add optimizer details configuration

```typescript
optimizer: {
  enabled: true,
  runs: 50000,
  details: {
    yul: true,
    yulDetails: {
      stackAllocation: true,
      optimizerSteps: "dhfoDgvulfnTUtnIf" // Default
    }
  }
}
```

**Expected Impact:** Minimal, but worth testing

### 4. Metadata Settings

**Option:** Reduce metadata size

```typescript
metadata: {
  bytecodeHash: 'none'; // or "ipfs" instead of default
}
```

**Expected Impact:** ~0.1-0.2 KB (metadata not in deployed bytecode, but affects compilation)

**Note:** Metadata is not included in deployed bytecode size

### 5. Output Selection

**Option:** Optimize output selection

```typescript
outputSelection: {
  "*": {
    "*": ["abi", "evm.bytecode"]
  }
}
```

**Expected Impact:** None on deployed size, but faster compilation

---

## Recommended Testing Plan

### Test 1: Solidity Version Upgrade

1. Upgrade to 0.8.31
2. Compile and measure sizes
3. Run all tests
4. Compare with baseline

### Test 2: Optimizer Runs

1. Test `runs: 100000`
2. Test `runs: 200000`
3. Measure size impact
4. Test gas costs (if significant)

### Test 3: viaIR Setting

1. Test `viaIR: false`
2. Compare sizes with `viaIR: true`
3. Choose best option

### Test 4: Combined Optimizations

1. Best Solidity version
2. Best `runs` value
3. Best `viaIR` setting
4. Measure final sizes

---

## Expected Results

### Best Case Scenario

- Solidity 0.8.31: -0.5 KB
- Optimizer runs 100000: -0.3 KB
- viaIR optimization: -0.2 KB
- **Total: ~-1 KB per contract**

### Realistic Scenario

- Solidity 0.8.31: -0.2 KB to +0.1 KB
- Optimizer runs 100000: -0.2 KB
- viaIR: No change or slight improvement
- **Total: ~-0.3 to -0.5 KB per contract**

### Worst Case Scenario

- Solidity 0.8.31: +0.2 KB (unlikely)
- Optimizer: No improvement
- **Total: ~+0.2 KB per contract**

---

## Implementation Priority

1. **Test Solidity 0.8.31** - Easy to test, potential benefits
2. **Test viaIR: false** - Quick test, could reveal issues
3. **Test runs: 100000** - Easy to test, measure impact
4. **Combine best settings** - Final optimization

---

## Notes

- Compiler optimizations have diminishing returns
- Current settings are already quite aggressive
- Focus on code-level optimizations for larger gains
- Always test thoroughly after compiler changes

---

## Quick Test Script

A test script has been created at `scripts/test-compiler-settings.ts` to automatically test different compiler configurations:

```bash
# Run compiler settings test
ts-node scripts/test-compiler-settings.ts
```

This will:

1. Test current settings (0.8.28, 50k runs, viaIR)
2. Test Solidity 0.8.31 with various settings
3. Compare sizes and show differences
4. Save results to `docs/COMPILER_TEST_RESULTS.json`

**Note:** This script temporarily modifies `hardhat.config.ts` - make sure you have a clean git state before running.
