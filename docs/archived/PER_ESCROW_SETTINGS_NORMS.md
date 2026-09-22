# Per-Escrow Settings: Industry Norms & Implementation Analysis

**Date**: 2026-01-27  
**Scope**: Per-escrow configuration, yield fees, settings validation, and community expectations

---

## Executive Summary

**Current State**: ✅ **MOSTLY ALIGNED** with industry norms, with some gaps

**Key Findings**:
- ✅ **Global protocol fees** (snapshotted per-escrow) - Aligned with best practices
- ✅ **Per-escrow yield opt-in** - Standard approach
- ⚠️ **No per-escrow fee override** - Deviation from some industry norms (flexibility vs. simplicity trade-off)
- ✅ **Settings validation** - Meets industry expectations
- ✅ **Transparent fee structure** - Well documented

---

## Current Implementation Analysis

### Per-Escrow Settings (`EscrowSettings`)

**Current Fields**:
```solidity
struct EscrowSettings {
    address customResolver;      // ✅ Per-escrow resolver override
    bool yieldEnabled;           // ✅ Per-escrow yield opt-in
    uint256 autoReleaseTime;     // ✅ Per-escrow timeout configuration
    uint256 autoCancelTime;      // ✅ Per-escrow timeout configuration
}
```

**What's NOT Per-Escrow** (Global Protocol-Level):
- `escrowFee` - Global fee rate (basis points)
- `yieldProtocolFeeBps` - Global protocol fee on yield (0-30%)
- `appealBondProtocolFeeBps` - Global protocol fee on appeal bonds
- `disputeResolutionModule` - Global default resolver

**Snapshot Pattern**:
- Protocol-level fees are **snapshotted** at escrow creation via `moduleSnapshots`
- This ensures escrow behavior doesn't change if protocol fees are updated later
- **This is a best practice** ✅

---

## Industry Norms for Per-Escrow Settings

### 1. **Fee Configuration Norms**

#### Industry Standard Approaches:

| Approach | Examples | Pros | Cons |
|----------|----------|------|------|
| **Fixed Global Fee** | StableEscrow (1 DAI flat) | Simple, predictable | Not flexible |
| **Percentage Global Fee** | Most DeFi protocols | Simple, scales with amount | May penalize large escrows |
| **Sliding Scale Fee** | Zenland (decreases with size) | Fair, encourages large escrows | More complex |
| **Per-Escrow Fee Override** | Some enterprise escrows | Maximum flexibility | Complexity, gas costs |

#### Current Implementation:
- ✅ **Global percentage fee** (`escrowFee` in basis points)
- ✅ **Capped at 2%** via `SettingsValidationLibrary.MAX_FEE_BPS = 200`
- ✅ **Snapshotted** per escrow (ensures consistency)
- ❌ **No per-escrow fee override** - All escrows use same fee rate

**Assessment**: ✅ **ALIGNED** - Simple, predictable approach. Trade-off: less flexibility but lower complexity.

---

### 2. **Yield Fee Configuration Norms**

#### Industry Expectations:

1. **Protocol Fee on Yield**:
   - Most protocols take 10-30% of generated yield as protocol fee
   - Fee should be transparent and disclosed upfront
   - Fee rate should be reasonable (community pushback if >50%)

2. **Per-Escrow Yield Fee Override**:
   - **Less common** - Most protocols use global fee
   - Some enterprise escrows allow per-escrow negotiation
   - Often used for volume discounts or special arrangements

#### Current Implementation:
```solidity
// Global protocol fee (snapshotted per escrow)
uint256 public yieldProtocolFeeBps; // 0-3000 bps = 0-30% (capped)

// Snapshotted at creation
moduleSnapshots[workflowId].yieldProtocolFeeBps = yieldProtocolFeeBps;
```

**How it Works**:
- ✅ Global fee rate (default 30%)
- ✅ Capped at 30% (`MAX_PROTOCOL_FEE_BPS = 3000`)
- ✅ Snapshotted at escrow creation (escrow fee doesn't change)
- ✅ Per-escrow opt-in (`yieldEnabled: bool`)
- ❌ No per-escrow fee override

**Assessment**: ✅ **ALIGNED WITH NORMS** - Global fee with snapshots is standard. Per-escrow overrides are rare and add complexity.

---

### 3. **Fee Payer Configuration Norms**

#### Industry Standards:

| Model | Description | Examples |
|-------|-------------|----------|
| **Payer Pays** | Creator/payer pays all fees | Most simple escrows |
| **Payee Pays** | Recipient pays fees | Some marketplaces |
| **Split Fees** | 50/50 or custom split | Zenland, some enterprise |
| **Dynamic** | Based on escrow parameters | Advanced platforms |

#### Current Implementation:
- ❌ **Fixed**: Fee deducted from `amount` before escrow creation
- ❌ **No configuration**: Always deducted from sender/payer
- ❌ **No split option**: Cannot split fees between parties

**Assessment**: ⚠️ **SIMPLER THAN NORMS** - Most platforms offer fee splitting. Current approach is simpler but less flexible.

**Community Expectation Gap**:
- Some users expect fee splitting option
- Larger escrows may prefer split fees for fairness
- Consider adding `feePayer` option to `EscrowSettings` for v2.0

---

### 4. **Yield Distribution Configuration Norms**

#### Industry Standards:

1. **Recipients**:
   - Most common: Yield goes to **sender** (escrow creator)
   - Alternative: Yield to **recipient** (seller)
   - Split: Yield shared between parties
   - Custom: Per-escrow distribution configuration

2. **Distribution Method**:
   - Fixed percentage splits
   - Dynamic based on escrow outcome
   - Protocol takes cut first, then distributes remainder

#### Current Implementation:
```solidity
// Per-escrow yield distribution (via YieldDistributionModule)
struct YieldDistribution {
    address[] recipients;      // Custom recipients per escrow
    uint256[] percentages;     // Percentage per recipient (basis points)
    bool isSet;                // Whether configured
}

// Used via distributionData parameter in distributeYield()
```

**How it Works**:
- ✅ **Fully configurable** per-escrow via `distributionData`
- ✅ **Protocol fee deducted first** (via `YieldOps`)
- ✅ **Remainder distributed** to configured recipients
- ✅ **Validated** (percentages sum to 10000 bps)

**Assessment**: ✅ **EXCEEDS NORMS** - More flexible than most platforms. Per-escrow distribution is advanced feature.

---

### 5. **Settings Validation Norms**

#### Industry Standards:

1. **Bounds Validation**:
   - ✅ Minimum/maximum fee rates
   - ✅ Maximum escrow duration
   - ✅ Minimum escrow amount
   - ✅ Maximum timeout values

2. **Input Validation**:
   - ✅ Address validation (non-zero, contract checks)
   - ✅ Amount validation (positive, minimums)
   - ✅ Time validation (future times, reasonable ranges)

3. **Consistency Checks**:
   - ✅ Cannot set conflicting options
   - ✅ Distribution percentages sum correctly
   - ✅ No duplicate recipients

#### Current Implementation:
```solidity
// SettingsValidationLibrary enforces:
MAX_FEE_BPS = 200;                    // 2% max fee
MAX_AUTO_TIME_DAYS = 30 days;         // Max timeout
MAX_ESCROW_DURATION = 365 days;       // Max escrow duration
MIN_ESCROW_AMOUNT = 1000;             // Minimum amount
MIN_YIELD_DEPOSIT = 1000e6;           // Minimum for yield
MAX_YIELD_RECIPIENTS = 10;            // Max distribution recipients
```

**Assessment**: ✅ **MEETS NORMS** - Comprehensive validation with reasonable bounds.

---

### 6. **Transparency & Documentation Norms**

#### Industry Expectations:

1. **Upfront Disclosure**:
   - All fees visible before escrow creation
   - Yield terms clear if enabled
   - Dispute resolution process explained

2. **On-Chain Events**:
   - Fees collected → events emitted
   - Yield distributed → events emitted
   - Settings updated → events emitted

3. **Documentation**:
   - Clear fee structure
   - Yield calculation methodology
   - Settings validation rules

#### Current Implementation:
- ✅ **Events**: `EscrowFeeUpdated`, `YieldProtocolFeeCollected`, `EscrowSettingsUpdated`
- ✅ **Public getters**: `getEscrowSettings()`, `getPendingYieldProtocolFeeBps()`
- ✅ **Documentation**: NatSpec on key functions
- ⚠️ **Fee visibility**: Could be clearer in `createEscrow` (user must calculate)

**Assessment**: ✅ **MOSTLY ALIGNED** - Good event emission, could improve upfront fee visibility.

---

## Gap Analysis: Current vs. Industry Norms

### ✅ **Aligned with Norms**

1. **Global Protocol Fees** - Standard approach, snapshotted per-escrow ✅
2. **Settings Validation** - Comprehensive bounds checking ✅
3. **Yield Distribution** - Flexible per-escrow configuration ✅
4. **Transparency** - Events and getters for all key operations ✅

### ⚠️ **Simpler Than Norms** (Trade-offs)

1. **No Per-Escrow Fee Override**
   - **Industry norm**: Some platforms allow per-escrow fee negotiation
   - **Current**: Global fee only
   - **Trade-off**: Simplicity vs. flexibility
   - **Recommendation**: ✅ **KEEP AS-IS** for v1.0 - Add per-escrow fee override in v2.0 if needed

2. **No Fee Splitting**
   - **Industry norm**: Many platforms offer buyer/seller/both fee payment
   - **Current**: Fee always deducted from sender
   - **Trade-off**: Simplicity vs. fairness perception
   - **Recommendation**: ⚠️ **CONSIDER** for v2.0 - Adds complexity but improves fairness

3. **No Sliding Scale Fees**
   - **Industry norm**: Larger escrows get lower percentage fees
   - **Current**: Fixed percentage regardless of size
   - **Trade-off**: Simplicity vs. fairness
   - **Recommendation**: ✅ **KEEP AS-IS** - Can be added as governance parameter (not per-escrow)

### 🔴 **Potential Issues** (Not Currently Problematic)

1. **Fee Calculation Transparency**
   - Users must calculate `amount * escrowFee / 10000` themselves
   - No view function: `getEscrowFee(amount)` → returns `(fee, amountAfterFee)`
   - **Recommendation**: 🟡 **CONSIDER** adding helper function for UX

2. **Yield Fee Disclosure**
   - `yieldProtocolFeeBps` is global but users may not know current value
   - Should be visible in UI/documentation
   - **Recommendation**: ✅ **ACCEPTABLE** - Public getter exists, frontend should display

---

## Recommendations

### ✅ **Keep Current Design** (Aligned with Norms)

1. **Global Protocol Fees with Snapshots**
   - Standard, predictable, easy to audit
   - Snapshots ensure escrow behavior doesn't change
   - **No change needed**

2. **Per-Escrow Yield Opt-In**
   - `yieldEnabled: bool` in `EscrowSettings`
   - Clear opt-in pattern
   - **No change needed**

3. **Comprehensive Settings Validation**
   - All bounds enforced via `SettingsValidationLibrary`
   - Prevents abuse and misconfiguration
   - **No change needed**

### 🟡 **Consider for v2.0** (Enhancement Opportunities)

1. **Fee Splitting Option**
   ```solidity
   enum FeePayer {
       SENDER,      // Current behavior
       RECIPIENT,   // Recipient pays
       SPLIT        // 50/50 split
   }
   
   struct EscrowSettings {
       // ... existing fields
       FeePayer feePayer; // Optional: default to SENDER
   }
   ```
   - **Effort**: Medium
   - **Benefit**: Better fairness perception
   - **Risk**: Added complexity, gas costs

2. **Fee Calculation Helper**
   ```solidity
   function getEscrowFeeBreakdown(uint256 amount) 
       public view returns (uint256 fee, uint256 amountAfterFee) {
       fee = (amount * escrowFee) / ESCROW_FEE_DENOMINATOR;
       amountAfterFee = amount - fee;
   }
   ```
   - **Effort**: Low
   - **Benefit**: Better UX, transparency
   - **Risk**: Minimal

3. **Per-Escrow Fee Override** (Enterprise Feature)
   ```solidity
   struct EscrowSettings {
       // ... existing fields
       uint256 customFeeBps; // 0 = use global, >0 = override
   }
   ```
   - **Effort**: High (requires validation, gas optimization)
   - **Benefit**: Maximum flexibility
   - **Risk**: Complexity, potential for confusion

### ✅ **Documentation Improvements**

1. **Add Fee Examples to NatSpec**:
   ```solidity
   /**
    * @notice Create a new escrow transfer
    * @param amount Total amount (fee will be deducted)
    * @dev Fee calculation: fee = amount * escrowFee / 10000
    *      Example: amount=1000, escrowFee=100 (1%) → fee=10, amountAfterFee=990
    */
   ```

2. **Document Yield Fee Flow**:
   - How protocol fee is calculated
   - When it's deducted
   - Who receives remaining yield

3. **Clear Default Values**:
   - Document all default settings
   - Explain what happens when settings are omitted

---

## Community Perception Assessment

### ✅ **Positive Aspects**

1. **Transparent Fee Structure**
   - Global fees are clear and documented
   - No hidden fees
   - Snapshot pattern ensures predictability

2. **Flexible Yield Distribution**
   - Per-escrow configuration exceeds industry norms
   - Protocol fee is reasonable (0-30%)

3. **Comprehensive Validation**
   - Prevents abuse
   - Clear bounds

### ⚠️ **Potential Concerns**

1. **Fee Fairness**
   - Large escrows pay same percentage as small (no sliding scale)
   - **Mitigation**: Can be addressed via governance (not per-escrow)

2. **Fee Payer**
   - Always sender pays (no split option)
   - **Mitigation**: Document clearly, consider for v2.0

3. **Yield Fee Transparency**
   - Users may not realize 30% default yield fee
   - **Mitigation**: Frontend should display prominently

---

## Summary: Norms Compliance Score

| Category | Score | Notes |
|----------|-------|-------|
| **Fee Configuration** | ✅ 8/10 | Global fee is standard, missing per-escrow override (intentional trade-off) |
| **Yield Fee Configuration** | ✅ 9/10 | Global snapshotted fee with per-escrow opt-in is best practice |
| **Fee Payer Flexibility** | ⚠️ 6/10 | Fixed payer is simpler but less flexible than norms |
| **Yield Distribution** | ✅ 10/10 | Exceeds norms with per-escrow configuration |
| **Settings Validation** | ✅ 10/10 | Comprehensive bounds and input validation |
| **Transparency** | ✅ 9/10 | Good events, could improve fee calculation helpers |
| **Overall** | ✅ **8.7/10** | **WELL ALIGNED** with industry norms |

---

## Conclusion

**Current implementation is well-aligned with industry norms** for per-escrow settings. The design prioritizes:

- ✅ **Simplicity** over maximum flexibility (global fees, fixed fee payer)
- ✅ **Transparency** (comprehensive events, validation)
- ✅ **Security** (bounds checking, snapshot patterns)

**Key Strengths**:
1. Global fees with snapshots (best practice)
2. Flexible yield distribution (exceeds norms)
3. Comprehensive validation (meets security norms)

**Trade-offs Made** (All Reasonable):
1. No per-escrow fee override → Simplicity
2. No fee splitting → Lower complexity
3. No sliding scale → Consistent, predictable

**Recommendations**:
- ✅ **Keep current design** for v1.0
- 🟡 **Consider fee splitting** for v2.0 (if user demand)
- ✅ **Add fee calculation helpers** (low effort, high UX value)
- ✅ **Improve documentation** (fee examples, yield flow)

---

**Status**: ✅ **READY FOR DEPLOYMENT** - Design aligns with industry norms and best practices.

---

**Review Completed**: 2026-01-27  
**Next Review**: Post-launch (optional enhancements for v2.0)
