# Compiler Upgrade & Optimization Recommendations

**Date:** 2025-01-27  
**Current:** Solidity 0.8.28, runs: 50000, viaIR: true  
**Available:** Solidity 0.8.31

## Summary

### Will 0.8.31 Help?

**Likely Yes, but Impact is Small:**
- Solidity 0.8.26+ introduced improved Yul optimizer
- 0.8.31 likely has additional optimizations
- Expected savings: **-0.2 to -0.5 KB per contract**
- **Not enough to solve the 24KB problem alone** (need ~15 KB reduction)

### Other Tweaks Available

1. **Increase Optimizer Runs** (runs: 100000)
   - Expected: -0.2 to -0.5 KB
   - Trade-off: Higher gas costs, longer compilation

2. **Test viaIR: false**
   - Could help if IR inlining is hurting size
   - Expected: -0.2 to +0.2 KB (unpredictable)

3. **Combined Optimizations**
   - Best case: -1 KB total
   - Realistic: -0.5 KB total

---

## Recommendation

### Priority 1: Test Solidity 0.8.31 ⭐

**Why:**
- Easy to test (just change version)
- Low risk (backward compatible)
- Potential small savings
- Bug fixes and improvements

**Steps:**
1. Update `hardhat.config.ts`: `version: "0.8.31"`
2. Update all `pragma solidity ^0.8.28` to `^0.8.31`
3. Compile and measure sizes
4. Run all tests
5. Compare results

**Expected Impact:** -0.2 to -0.5 KB per contract

### Priority 2: Test Higher Optimizer Runs

**Why:**
- Easy to test
- Known to reduce size
- Already at 50000, can go higher

**Steps:**
1. Test `runs: 100000`
2. Test `runs: 200000` (if 100k helps)
3. Measure size impact
4. Test gas costs (if significant)

**Expected Impact:** -0.2 to -0.5 KB per contract

### Priority 3: Test viaIR: false

**Why:**
- IR can sometimes increase size due to inlining
- Worth testing both options

**Steps:**
1. Test `viaIR: false` with 0.8.31
2. Compare with `viaIR: true`
3. Choose best option

**Expected Impact:** -0.2 to +0.2 KB (unpredictable)

---

## Implementation Plan

### Step 1: Upgrade to 0.8.31 (Quick Win)

```typescript
// hardhat.config.ts
solidity: {
  version: "0.8.31",  // Changed from 0.8.28
  settings: {
    optimizer: {
      enabled: true,
      runs: 50000,
    },
    viaIR: true,
    evmVersion: "cancun",
  },
}
```

```solidity
// All contracts
pragma solidity ^0.8.31;  // Changed from ^0.8.28
```

**Test:**
```bash
pnpm compile
pnpm size:check
pnpm test
```

**Expected:** -0.2 to -0.5 KB per contract

### Step 2: Test Optimizer Runs

```typescript
// Test 1: runs: 100000
optimizer: {
  enabled: true,
  runs: 100000,  // Changed from 50000
}

// Test 2: runs: 200000 (if 100k helps)
optimizer: {
  enabled: true,
  runs: 200000,
}
```

**Test:**
```bash
# Update hardhat.config.ts
pnpm compile
pnpm size:check
# Compare sizes
```

**Expected:** -0.2 to -0.5 KB additional savings

### Step 3: Test viaIR Setting

```typescript
// Test: viaIR: false
settings: {
  optimizer: { enabled: true, runs: 100000 },
  viaIR: false,  // Changed from true
  evmVersion: "cancun",
}
```

**Test:**
```bash
# Update hardhat.config.ts
pnpm compile
pnpm size:check
# Compare with viaIR: true
```

**Expected:** -0.2 to +0.2 KB (unpredictable)

### Step 4: Combine Best Settings

Use the configuration that gives the best results:
- Solidity 0.8.31
- Best `runs` value (likely 100000)
- Best `viaIR` setting (likely true, but test both)

---

## Automated Testing

Use the test script to automatically test all configurations:

```bash
ts-node scripts/test-compiler-settings.ts
```

This will:
1. Test current settings
2. Test 0.8.31 with various configurations
3. Show size comparisons
4. Save results to `docs/COMPILER_TEST_RESULTS.json`

**Note:** Script temporarily modifies `hardhat.config.ts` - ensure clean git state.

---

## Expected Final Results

### Best Case Scenario
- Solidity 0.8.31: -0.5 KB
- Optimizer runs 100000: -0.5 KB
- viaIR optimization: -0.2 KB
- **Total: ~-1.2 KB per contract**

### Realistic Scenario
- Solidity 0.8.31: -0.3 KB
- Optimizer runs 100000: -0.3 KB
- viaIR: No change
- **Total: ~-0.6 KB per contract**

### Current Status
- EscrowVault: 38.91 KB
- EscrowableERC20: 38.90 KB

### After Compiler Optimizations (Realistic)
- EscrowVault: ~38.3 KB (still 59% over limit)
- EscrowableERC20: ~38.3 KB (still 59% over limit)

**Conclusion:** Compiler optimizations alone won't solve the problem. Need code-level optimizations (Module Management Contract, etc.)

---

## Additional Hardhat Tweaks

### 1. Output Selection

Reduce compilation output (doesn't affect deployed size, but faster):

```typescript
outputSelection: {
  "*": {
    "*": ["abi", "evm.bytecode"]
  }
}
```

### 2. Metadata Settings

```typescript
metadata: {
  bytecodeHash: "none"  // or "ipfs"
}
```

**Note:** Metadata is not included in deployed bytecode size, so this doesn't help with 24KB limit.

### 3. Compiler Cache

```typescript
// Already handled by Hardhat automatically
// But can clear cache if needed:
// rm -rf cache artifacts
```

---

## Risk Assessment

### Solidity 0.8.31 Upgrade
- **Risk:** Low - Backward compatible
- **Testing:** Run all tests
- **Rollback:** Easy (just change version back)

### Optimizer Runs Increase
- **Risk:** Low - Only affects compilation
- **Testing:** Test gas costs if significant
- **Rollback:** Easy (just change runs value)

### viaIR Change
- **Risk:** Medium - Can affect bytecode generation
- **Testing:** Run all tests, check gas costs
- **Rollback:** Easy (just change setting)

---

## Final Recommendation

1. **Upgrade to 0.8.31** - Low risk, potential small benefit
2. **Test runs: 100000** - Easy to test, known to help
3. **Test viaIR: false** - Quick test, could reveal issues
4. **Focus on code optimizations** - This is where the real savings are

**Remember:** Compiler optimizations are incremental. The real solution is architectural (Module Management Contract, etc.)

