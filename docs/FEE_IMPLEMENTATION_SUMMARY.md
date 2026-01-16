# Current Fee Implementation in Contracts

**Date:** 2026-01-09  
**Status:** Current Implementation Analysis

---

## Summary

The current contract implementation has **only one fee**: the escrow fee (1% of escrow amount). **No fees are charged on appeal bonds** in DR v2.

---

## 1. Escrow Fee ✅

**Location:** `BaseEscrow.sol`

**Implementation:**
```solidity
uint256 public escrowFee;
uint256 public constant ESCROW_FEE_DENOMINATOR = 10000;

// Calculated at escrow creation (line 476)
uint256 fee = (amount * escrowFee) / ESCROW_FEE_DENOMINATOR;
uint256 amountAfterFee = amount - fee;
```

**Details:**
- **Fee Rate:** Configurable via governance, defaults to 1% (100 basis points)
- **When Collected:** At escrow creation
- **Formula:** `fee = (amount × escrowFee) / 10000`
- **Fee Recipient:** `escrowFeeAddress` (set via governance)
- **Governance:** Fee can be updated via `queueEscrowFee()` + `activateEscrowFee()` (Slow lane, ~9 days)

**Example:**
- Escrow amount: 1000 tokens
- Escrow fee: 100 basis points (1%)
- Fee collected: `(1000 × 100) / 10000 = 10 tokens`
- Amount after fee: `1000 - 10 = 990 tokens`

---

## 2. Appeal Bond Fees ❌ (NOT IMPLEMENTED)

**Location:** `ResolverIncentiveModuleV2.sol`

**Current Implementation:**

### `recordAppealBond()` (lines 129-174)
- Records the full bond amount
- **No fee deducted** - entire bond amount is stored

### `distributeAppealBond()` (lines 185-210)
- **If appeal succeeds (outcomeFlipped = true):**
  - Calls `_refundBond()` (lines 217-236)
  - **Full bond amount refunded** to depositor
  - **No fee deducted**

- **If appeal fails (outcomeFlipped = false):**
  - Calls `_payBondToResolvers()` (lines 246-338)
  - **Full bond amount distributed** to resolvers from prior round
  - **No fee deducted** - entire `bond.amount` is split among resolvers (line 298)

**Code Evidence:**
```solidity
// _refundBond() - line 228 (ETH) or 232 (ERC20)
bond.depositor.call{value: bond.amount}('');  // Full amount
IERC20(bond.token).safeTransfer(bond.depositor, bond.amount);  // Full amount

// _payBondToResolvers() - line 298
uint256 amountPerResolver = bond.amount / count;  // Full bond split among resolvers
```

**Edge Case:**
- If no resolvers found at prior round, bond remains in contract (not counted as "paid" to resolvers)
- This is a failure case, not a fee mechanism

---

## 3. Revenue Streams

**Current Protocol Revenue:**

1. **Escrow fees:** 1% of escrow amounts ✅
2. **Yield share:** 30% of generated yield (when yield enabled) ✅
3. **Appeal bonds:** No protocol fee in DR v2 ❌

---

## Conclusion

**Current Fee Implementation:**
- ✅ **Escrow fee:** 1% of escrow amount (collected at creation)
- ❌ **Appeal bond fee:** None - bonds are refunded in full or paid to resolvers in full

**To Add Appeal Bond Fees (Future):**
Would require changes to `ResolverIncentiveModuleV2`:
1. Add fee parameters (protocol fee percentage, fee recipient)
2. Modify `distributeAppealBond()` to calculate and deduct fee before refund/payment
3. Transfer fee to protocol treasury
4. Update metrics to track fees collected

This would be a module upgrade (deploy new version, swap via governance).
