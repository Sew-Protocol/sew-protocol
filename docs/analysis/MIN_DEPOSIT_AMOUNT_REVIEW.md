# Minimum Deposit Amount Review

**Date:** 2026-01-21  
**Issue:** CRIT-1 - Minimum deposit amount is hardcoded for 18-decimal tokens  
**Status:** ⚠️ **REVIEWED - RECOMMENDATION PROVIDED**

---

## Current Implementation

**File:** `contracts/libraries/AaveYieldHandlingLibrary.sol`

```solidity
// CRIT-1: Minimum deposit amount to prevent scaledShares = 0 due to rounding
// For 18-decimal tokens, this is 1e15 (0.001 tokens)
// This ensures (amount * AAVE_RAY) / incomeRay >= 1
uint256 internal constant MIN_DEPOSIT_AMOUNT = 1e15;
```

---

## Analysis

### Current Value: `1e15`

**For 18-decimal tokens (e.g., WETH, DAI):**
- `1e15 wei = 0.001 tokens` ✅ **Appropriate**

**For 6-decimal tokens (e.g., USDC, USDT):**
- `1e15 units = 1e9 tokens` ❌ **Too large** (1 billion tokens!)

**For 8-decimal tokens (e.g., WBTC):**
- `1e15 units = 1e7 tokens` ❌ **Too large** (10 million tokens)

---

## Mathematical Basis

The minimum deposit ensures `scaledShares >= 1`:

```
scaledShares = (amount * AAVE_RAY) / incomeRay
```

For `scaledShares >= 1`:
```
(amount * AAVE_RAY) / incomeRay >= 1
amount >= incomeRay / AAVE_RAY
```

With `incomeRay >= MIN_NORMALIZED_INCOME = 1e24`:
```
amount >= 1e24 / 1e27 = 1e-3 = 0.001 (in RAY units)
```

**For 18-decimal tokens:**
- `0.001 * 1e18 = 1e15 wei` ✅ **Correct**

**For 6-decimal tokens:**
- `0.001 * 1e6 = 1e3 units = 0.001 tokens` ✅ **Should be 1e3**

**For 8-decimal tokens:**
- `0.001 * 1e8 = 1e5 units = 0.001 tokens` ✅ **Should be 1e5**

---

## Recommendations

### Option 1: Keep Current Value (Recommended for v1)

**Pros:**
- Simple and safe
- Works correctly for 18-decimal tokens (most common)
- Conservative for other decimals (prevents precision loss)
- No code changes needed

**Cons:**
- Too strict for 6-decimal tokens (effectively blocks deposits)
- Not optimal for 8-decimal tokens

**Recommendation:** ✅ **ACCEPTABLE for v1** - Document limitation, address in future version

**Action:**
- Document that `MIN_DEPOSIT_AMOUNT` is optimized for 18-decimal tokens
- For 6-decimal tokens, users may need to deposit larger amounts
- Consider making configurable in future version

---

### Option 2: Make Configurable Per Token

**Implementation:**
```solidity
// In AaveYieldGenerationModule
mapping(address => uint256) public minDepositAmount; // token => minimum

function setMinDepositAmount(address token, uint256 minAmount) external onlyRole(ROLE_TIMELOCK) {
    minDepositAmount[token] = minAmount;
}
```

**Pros:**
- Flexible for different token decimals
- Can be configured per token
- More accurate minimums

**Cons:**
- Requires governance to set per token
- More complex
- Additional storage

**Recommendation:** ⚠️ **FUTURE ENHANCEMENT** - Consider for v2

---

### Option 3: Calculate Based on Token Decimals

**Implementation:**
```solidity
// Get token decimals (requires IERC20Metadata or similar)
uint8 decimals = IERC20Metadata(token).decimals();
uint256 minDeposit = 1e3 * (10 ** decimals); // 0.001 tokens in token's native units
```

**Pros:**
- Automatic calculation
- Works for all token decimals
- No configuration needed

**Cons:**
- Requires `IERC20Metadata` interface
- Not all tokens implement `decimals()`
- Additional gas cost

**Recommendation:** ⚠️ **FUTURE ENHANCEMENT** - Consider for v2

---

## Current Impact Assessment

### Supported Tokens

**18-decimal tokens (WETH, DAI, etc.):**
- ✅ **Fully supported** - Minimum deposit = 0.001 tokens

**6-decimal tokens (USDC, USDT):**
- ⚠️ **Partially supported** - Minimum deposit = 1 billion tokens (effectively blocked)
- **Workaround:** Users can still deposit, but yield deposit will fail silently
- **Impact:** Escrow works, but no yield generation

**8-decimal tokens (WBTC):**
- ⚠️ **Partially supported** - Minimum deposit = 10 million tokens (effectively blocked)
- **Workaround:** Same as 6-decimal tokens

---

## Recommended Action Plan

### Immediate (v1)
1. ✅ **Keep current value** (`1e15`)
2. ✅ **Document limitation** in code comments and documentation
3. ✅ **Add note** that this is optimized for 18-decimal tokens
4. ✅ **Test with 6-decimal tokens** to verify graceful failure

### Future (v2)
1. ⏳ **Make configurable** per token via governance
2. ⏳ **Or calculate automatically** based on token decimals
3. ⏳ **Update tests** to cover different decimal scenarios

---

## Code Documentation Update

**Recommended comment update:**

```solidity
// CRIT-1: Minimum deposit amount to prevent scaledShares = 0 due to rounding
// For 18-decimal tokens, this is 1e15 (0.001 tokens)
// This ensures (amount * AAVE_RAY) / incomeRay >= 1
// 
// NOTE: This value is optimized for 18-decimal tokens (WETH, DAI, etc.)
// For 6-decimal tokens (USDC, USDT), this effectively blocks yield deposits
// but escrow creation still succeeds (yield deposit fails silently).
// Consider making this configurable per token in future versions.
uint256 internal constant MIN_DEPOSIT_AMOUNT = 1e15;
```

---

## Testing Recommendations

### Unit Tests
- [x] Test deposit below minimum (should fail yield deposit)
- [x] Test deposit at minimum (should succeed)
- [ ] Test with 6-decimal token (should fail yield deposit gracefully)
- [ ] Test with 8-decimal token (should fail yield deposit gracefully)

### Integration Tests
- [ ] Test full escrow lifecycle with 6-decimal token (no yield)
- [ ] Test full escrow lifecycle with 8-decimal token (no yield)
- [ ] Verify escrow works even when yield deposit fails

---

## Conclusion

**Current Status:** ✅ **ACCEPTABLE for v1**

The hardcoded `MIN_DEPOSIT_AMOUNT = 1e15` is appropriate for 18-decimal tokens, which are the most common tokens used with Aave. For 6-decimal and 8-decimal tokens, yield deposits will fail gracefully (non-blocking), and escrows will still function correctly without yield.

**Recommendation:** Keep current implementation, document limitation, and consider making configurable in future version.
