# Contract Size Issue - Quick Fix

**Issue**: Contracts exceed EIP-170 24,576 byte limit when running `forge build --sizes`

**Affected Contracts**:
- EscrowVault: 31,672 bytes (exceeds by ~7,096)
- EscrowableERC20: 32,785 bytes (exceeds by ~8,209)
- EscrowableERC20Factory: 35,423 bytes (exceeds by ~10,847)

## Quick Fix Options

### Option 1: Increase Optimizer Runs (Temporary)

**foundry.toml**:
```toml
[profile.default]
optimizer_runs = 20000  # Increase from 1000 (smaller bytecode, higher gas)
```

**Warning**: This will reduce gas efficiency at runtime (more expensive transactions).

### Option 2: Disable Size Check (Development Only)

**For development/testing**:
```bash
forge build  # Regular build (no size check)
forge test   # Tests work fine
```

**Note**: `forge build --sizes` will still fail, but regular compilation works.

### Option 3: Contract Optimization (Long-term)

1. Extract libraries (already done - continues optimization)
2. Remove unused code
3. Use immutable variables where possible
4. Split large contracts if needed

## Status

**Current**: `forge build` ✅ works (no errors)  
**Issue**: `forge build --sizes` ❌ fails (size check)

**Recommendation**: For now, use `forge build` without `--sizes` flag for development. Address size issues before mainnet deployment.
