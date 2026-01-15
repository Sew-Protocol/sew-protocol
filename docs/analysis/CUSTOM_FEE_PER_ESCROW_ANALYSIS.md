# Custom Fee Per Escrow - Feature Analysis

**Date**: Current  
**Status**: Analysis Complete - Ready for Implementation  
**Priority**: HIGH (Low complexity, high value)

---

## Executive Summary

**Feature**: Allow per-escrow fee override instead of protocol-wide fee  
**Complexity**: ⭐ **LOW** (~100-200 bytes)  
**Value**: ⭐⭐⭐ **HIGH** (Marketplace use cases)  
**Risk**: ⚠️ **MEDIUM** (Requires governance consideration)

---

## Current State

### Protocol-Wide Fee

**Current Implementation**:

```solidity
uint256 public escrowFee;  // Protocol-wide fee (basis points)
uint256 public constant ESCROW_FEE_DENOMINATOR = 10000;

// In createEscrow():
uint256 fee = amount * escrowFee / ESCROW_FEE_DENOMINATOR;
uint256 amountAfterFee = amount - fee;
```

**Limitations**:

- All escrows use the same fee percentage
- No flexibility for different use cases
- Marketplaces cannot set custom fees per transaction
- High-value escrows pay same fee as low-value escrows

---

## Proposed Feature

### Custom Fee Per Escrow

**Implementation**: Add `customFee` field to `EscrowSettings` struct

```solidity
struct EscrowSettings {
  address customResolver;
  bool yieldEnabled;
  uint256 autoReleaseTime;
  uint256 autoCancelTime;
  EscrowType escrowType;
  uint256 customFee; // NEW: 0 = use default, >0 = override (max 200 bps)
}
```

**Logic**:

- If `customFee == 0`: Use protocol default fee (`escrowFee`)
- If `customFee > 0`: Use custom fee (with validation)
- Maximum custom fee: 200 bps (2%) - same as protocol max

---

## Use Cases

### 1. Marketplace Integration ⭐⭐⭐

**Scenario**: Marketplace wants to charge different fees for different transaction types

**Example**:

- Standard escrows: 1% fee (protocol default)
- Premium escrows: 1.5% fee (custom)
- High-value escrows (>$10k): 0.5% fee (custom, lower for volume)

**Benefit**: Marketplaces can optimize pricing per transaction type

---

### 2. Volume Discounts ⭐⭐

**Scenario**: Large volume buyers/sellers get fee discounts

**Example**:

- First 10 escrows: 1% fee (default)
- Next 50 escrows: 0.75% fee (custom)
- 100+ escrows: 0.5% fee (custom)

**Benefit**: Incentivize high-volume users

---

### 3. Promotional Pricing ⭐⭐

**Scenario**: Temporary fee reductions for marketing

**Example**:

- Launch period: 0.5% fee (custom, lower than default)
- Special events: Fee waivers or reductions

**Benefit**: Marketing flexibility

---

### 4. Tiered Pricing ⭐

**Scenario**: Different fees based on escrow amount

**Example**:

- < $100: 2% fee (custom, higher for small transactions)
- $100-$1000: 1% fee (default)
- > $1000: 0.5% fee (custom, lower for large transactions)

**Benefit**: Optimize fees based on transaction size

---

## Implementation Details

### Step 1: Add Field to EscrowSettings

**File**: `contracts/types/EscrowTypes.sol`

```solidity
struct EscrowSettings {
  address customResolver;
  bool yieldEnabled;
  uint256 autoReleaseTime;
  uint256 autoCancelTime;
  EscrowType escrowType;
  uint256 customFee; // NEW: 0 = use default, >0 = override (max 200 bps)
}
```

**Size Impact**: ~0 bytes (struct field addition doesn't affect bytecode)

---

### Step 2: Add Validation

**File**: `contracts/libraries/SettingsValidationLibrary.sol`

```solidity
/**
 * @dev Validate custom fee
 * @param customFee Custom fee in basis points (0 = use default)
 * @param maxFee Maximum allowed fee (200 bps = 2%)
 * @dev Reverts if customFee > maxFee
 */
function validateCustomFee(uint256 customFee, uint256 maxFee) internal pure {
  if (customFee > maxFee) {
    revert InvalidEscrowFee(customFee, maxFee);
  }
  // 0 is valid (means use default)
}
```

**Size Impact**: ~50-100 bytes

---

### Step 3: Update Fee Calculation

**File**: `contracts/EscrowVault.sol` and `contracts/EscrowableERC20.sol`

**Current**:

```solidity
uint256 fee = amount * escrowFee / ESCROW_FEE_DENOMINATOR;
uint256 amountAfterFee = amount - fee;
```

**Updated**:

```solidity
uint256 fee;
if (settings.customFee > 0) {
    // Validate custom fee
    SettingsValidationLibrary.validateCustomFee(settings.customFee, 200);
    fee = amount * settings.customFee / ESCROW_FEE_DENOMINATOR;
} else {
    fee = amount * escrowFee / ESCROW_FEE_DENOMINATOR;
}
uint256 amountAfterFee = amount - fee;
```

**Size Impact**: ~100-150 bytes

---

### Step 4: Update Validation Function

**File**: `contracts/libraries/SettingsValidationLibrary.sol`

Add custom fee validation to `validateEscrowSettings()`:

```solidity
function validateEscrowSettings(EscrowSettings memory settings, uint256 currentTime) internal pure {
  // ... existing validations ...

  // Validate custom fee if set
  if (settings.customFee > 0) {
    validateCustomFee(settings.customFee, 200);
  }
}
```

**Size Impact**: ~20-30 bytes

---

## Total Size Impact

| Component                  | Size Impact        |
| -------------------------- | ------------------ |
| Struct field addition      | 0 bytes            |
| Validation function        | +50-100 bytes      |
| Fee calculation logic      | +100-150 bytes     |
| Settings validation update | +20-30 bytes       |
| **Total**                  | **+170-280 bytes** |

**Note**: Actual size may vary based on optimizer settings.

---

## Validation Requirements

### 1. Maximum Fee Limit

**Requirement**: Custom fee must be ≤ 200 bps (2%)

**Rationale**:

- Matches protocol maximum fee
- Prevents excessive fees
- Protects users

**Implementation**:

```solidity
if (settings.customFee > 200) {
    revert InvalidEscrowFee(settings.customFee, 200);
}
```

---

### 2. Minimum Fee Limit (Optional)

**Question**: Should there be a minimum custom fee?

**Options**:

- **Option A**: No minimum (allow 0% fees for promotions)
- **Option B**: Minimum = protocol fee (prevent undercutting)
- **Option C**: Minimum = 50 bps (0.5%) (prevent abuse)

**Recommendation**: **Option A** - No minimum

- Allows promotional pricing
- Marketplaces can subsidize fees
- Governance can set protocol fee to prevent abuse

---

### 3. Who Can Set Custom Fees?

**Options**:

**Option A: Anyone** (Recommended)

- Any user can set custom fee when creating escrow
- Simple, flexible
- Risk: Users could set very high fees (mitigated by max limit)

**Option B: Whitelist Only**

- Only whitelisted addresses can set custom fees
- More control
- Risk: Less flexible, requires governance for whitelist management

**Option C: Governance Only**

- Only governance can set custom fees
- Maximum control
- Risk: Not useful for marketplace use cases

**Recommendation**: **Option A** - Anyone can set

- Max fee limit (200 bps) provides protection
- Users can see fee before creating escrow
- Marketplaces can set appropriate fees

---

## Governance Considerations

### 1. Fee Competition

**Risk**: Users could set fees lower than protocol fee, reducing protocol revenue

**Mitigation Options**:

- **Option 1**: Require customFee >= protocol fee (prevents undercutting)
- **Option 2**: Allow any custom fee, but protocol fee applies to all (custom fee is additional)
- **Option 3**: Allow any custom fee (current recommendation)

**Recommendation**: **Option 3** - Allow any custom fee

- Marketplaces may want to subsidize fees
- Promotional pricing is valuable
- Protocol can adjust default fee if needed

---

### 2. Fee Transparency

**Requirement**: Users must see fee before creating escrow

**Current**: Fee is visible in `EscrowSettings` struct

**Enhancement**: Consider adding fee preview function:

```solidity
function calculateFee(
  uint256 amount,
  EscrowSettings memory settings
) public view returns (uint256 fee, uint256 amountAfterFee) {
  uint256 feeRate = settings.customFee > 0 ? settings.customFee : escrowFee;
  fee = (amount * feeRate) / ESCROW_FEE_DENOMINATOR;
  amountAfterFee = amount - fee;
  return (fee, amountAfterFee);
}
```

**Size Impact**: +50-100 bytes (optional enhancement)

---

### 3. Fee Tracking

**Question**: Should we track custom fees separately?

**Options**:

- **Option A**: Track all fees together (simpler)
- **Option B**: Track custom fees separately (more analytics)

**Recommendation**: **Option A** - Track together

- Simpler implementation
- Analytics can be done off-chain
- No additional storage needed

---

## Security Considerations

### 1. Fee Manipulation

**Risk**: Malicious users could set very high fees

**Mitigation**:

- ✅ Maximum fee limit (200 bps)
- ✅ Fee is visible in settings before creation
- ✅ Users can see fee in transaction

**Assessment**: **LOW RISK** - Max limit provides protection

---

### 2. Fee Bypass

**Risk**: Users could set 0% fee to bypass protocol fees

**Mitigation Options**:

- **Option 1**: Require minimum fee = protocol fee
- **Option 2**: Allow 0% (for promotions), but track separately
- **Option 3**: Allow 0% (current recommendation)

**Recommendation**: **Option 3** - Allow 0% fees

- Useful for promotional pricing
- Marketplaces may want to subsidize
- Governance can adjust protocol fee if revenue is concern

---

### 3. Front-Running

**Risk**: Attacker could front-run escrow creation with high custom fee

**Mitigation**:

- Fee is set by creator, not attacker
- Front-running would require attacker to create escrow (not useful)
- **Assessment**: **NO RISK** - Not applicable

---

## Code Implementation

### Complete Implementation

**File**: `contracts/types/EscrowTypes.sol`

```solidity
struct EscrowSettings {
  address customResolver;
  bool yieldEnabled;
  uint256 autoReleaseTime;
  uint256 autoCancelTime;
  EscrowType escrowType;
  uint256 customFee; // 0 = use default, >0 = override (max 200 bps)
}
```

**File**: `contracts/libraries/SettingsValidationLibrary.sol`

```solidity
/**
 * @dev Validate custom fee
 * @param customFee Custom fee in basis points (0 = use default)
 * @param maxFee Maximum allowed fee (200 bps = 2%)
 * @dev Reverts if customFee > maxFee
 */
function validateCustomFee(uint256 customFee, uint256 maxFee) internal pure {
  if (customFee > maxFee) {
    revert InvalidEscrowFee(customFee, maxFee);
  }
  // 0 is valid (means use default)
}

/**
 * @dev Validate escrow settings (updated to include custom fee)
 */
function validateEscrowSettings(EscrowSettings memory settings, uint256 currentTime) internal pure {
  // ... existing validations ...

  // Validate custom fee if set
  if (settings.customFee > 0) {
    validateCustomFee(settings.customFee, 200);
  }
}
```

**File**: `contracts/EscrowVault.sol` (and `EscrowableERC20.sol`)

```solidity
function createEscrow(
  address token,
  address seller,
  uint256 amount,
  EscrowSettings memory settings
) public nonReentrant whenNotPaused returns (uint256) {
  // ... existing validation ...

  // Calculate fee with custom override
  uint256 fee;
  if (settings.customFee > 0) {
    // Validate custom fee (max 200 bps)
    if (settings.customFee > 200) {
      revert InvalidEscrowFee(settings.customFee, 200);
    }
    fee = (amount * settings.customFee) / ESCROW_FEE_DENOMINATOR;
  } else {
    fee = (amount * escrowFee) / ESCROW_FEE_DENOMINATOR;
  }
  uint256 amountAfterFee = amount - fee;

  // ... rest of function ...
}
```

---

## Testing Requirements

### Unit Tests

1. **Custom Fee Validation**:
   - [ ] Test customFee = 0 (uses default)
   - [ ] Test customFee = 100 (1%, valid)
   - [ ] Test customFee = 200 (2%, valid, max)
   - [ ] Test customFee = 201 (reverts, exceeds max)
   - [ ] Test customFee = 10000 (reverts, exceeds max)

2. **Fee Calculation**:
   - [ ] Test fee calculation with custom fee
   - [ ] Test fee calculation with default fee
   - [ ] Test amountAfterFee calculation
   - [ ] Test edge cases (very small amounts, very large amounts)

3. **Integration**:
   - [ ] Test escrow creation with custom fee
   - [ ] Test fee withdrawal (custom fees included)
   - [ ] Test fee tracking (totalFees includes custom fees)

### Edge Cases

1. **Zero Fee**:
   - [ ] Test customFee = 0 (uses default, not zero)
   - [ ] Consider: Should we allow 0% custom fee for promotions?

2. **Very Small Amounts**:
   - [ ] Test fee calculation with 1 wei amount
   - [ ] Test rounding behavior

3. **Very Large Amounts**:
   - [ ] Test fee calculation with max uint256
   - [ ] Test overflow protection

---

## Gas Cost Analysis

### Additional Gas Costs

**Per Escrow Creation**:

- Custom fee validation: ~50-100 gas
- Conditional check: ~20-30 gas
- **Total Additional**: ~70-130 gas per escrow

**Assessment**: **NEGLIGIBLE** - Minimal gas impact

---

## Backward Compatibility

### Existing Escrows

**Impact**: ✅ **NONE**

- Existing escrows use protocol default fee
- New field is optional (0 = use default)
- No migration needed

### API Compatibility

**Breaking Changes**: ❌ **NONE**

- New field is optional
- Default behavior unchanged
- Existing code continues to work

---

## Alternative Approaches

### Option 1: Per-Escrow Fee (Recommended) ✅

**Implementation**: Custom fee in EscrowSettings

- **Pros**: Flexible, per-escrow control
- **Cons**: Slightly more complex
- **Size**: +170-280 bytes

### Option 2: Fee Tiers

**Implementation**: Predefined fee tiers based on amount

- **Pros**: Simpler, no custom fee needed
- **Cons**: Less flexible
- **Size**: Similar

**Recommendation**: **Option 1** - More flexible

### Option 3: Marketplace Fee Override

**Implementation**: Whitelisted addresses can set fees

- **Pros**: More control
- **Cons**: Requires whitelist management
- **Size**: Similar + whitelist storage

**Recommendation**: **Option 1** - Simpler, more flexible

---

## Decision Points

### 1. Minimum Fee Requirement

**Question**: Should custom fees have a minimum?

**Options**:

- **A**: No minimum (allow 0% for promotions) ✅ **RECOMMENDED**
- **B**: Minimum = protocol fee (prevent undercutting)
- **C**: Minimum = 50 bps (0.5%)

**Decision**: **Option A** - No minimum

- Allows promotional pricing
- Marketplaces can subsidize
- Max limit (200 bps) provides upper bound

---

### 2. Fee Visibility

**Question**: Should we add fee preview function?

**Options**:

- **A**: Add `calculateFee()` view function ✅ **RECOMMENDED**
- **B**: Fee visible in EscrowSettings (current)

**Decision**: **Option A** - Add preview function

- Better UX
- Users can calculate fee before creating
- Small size impact (+50-100 bytes)

---

### 3. Fee Tracking

**Question**: Should we track custom fees separately?

**Options**:

- **A**: Track all fees together ✅ **RECOMMENDED**
- **B**: Separate tracking for analytics

**Decision**: **Option A** - Track together

- Simpler
- Analytics can be done off-chain
- No additional storage

---

## Implementation Checklist

### Pre-Implementation

- [ ] Review and approve approach
- [ ] Decide on minimum fee requirement
- [ ] Decide on fee preview function
- [ ] Review governance implications

### Implementation

- [ ] Add `customFee` to EscrowSettings struct
- [ ] Add validation function
- [ ] Update fee calculation in createEscrow()
- [ ] Update settings validation
- [ ] Add fee preview function (optional)
- [ ] Update documentation

### Testing

- [ ] Unit tests for validation
- [ ] Unit tests for fee calculation
- [ ] Integration tests
- [ ] Edge case tests
- [ ] Gas cost verification

### Deployment

- [ ] Code review
- [ ] Security audit (if needed)
- [ ] Testnet deployment
- [ ] Mainnet deployment (after testnet validation)

---

## Example Usage

### Marketplace Use Case

```solidity
// Marketplace creates escrow with custom 1.5% fee
EscrowSettings memory settings = _getDefaultSettings();
settings.customFee = 150; // 1.5%

uint256 workflowId = createEscrow(
    token,
    seller,
    amount,
    settings
);
```

### Promotional Pricing

```solidity
// Launch promotion: 0.5% fee (lower than default)
EscrowSettings memory settings = _getDefaultSettings();
settings.customFee = 50; // 0.5%

uint256 workflowId = createEscrow(
    token,
    seller,
    amount,
    settings
);
```

### High-Value Discount

```solidity
// Large transaction: 0.5% fee (discount)
EscrowSettings memory settings = _getDefaultSettings();
if (amount > 1000000 * 1e18) { // > 1M tokens
    settings.customFee = 50; // 0.5%
}

uint256 workflowId = createEscrow(
    token,
    seller,
    amount,
    settings
);
```

---

## Risks and Mitigations

### Risk 1: Fee Revenue Reduction

**Risk**: Users set lower fees, reducing protocol revenue

**Mitigation**:

- Governance can adjust protocol default fee
- Marketplaces may subsidize (still good for adoption)
- Volume may increase with lower fees

**Assessment**: **LOW RISK** - Governance can adjust

---

### Risk 2: User Confusion

**Risk**: Users might not understand custom fees

**Mitigation**:

- Clear documentation
- Fee preview function
- Fee visible in settings

**Assessment**: **LOW RISK** - Good UX mitigates

---

### Risk 3: Fee Manipulation

**Risk**: Malicious users set very high fees

**Mitigation**:

- Maximum fee limit (200 bps)
- Fee visible before creation
- Users can see fee in transaction

**Assessment**: **LOW RISK** - Max limit provides protection

---

## Success Metrics

### Adoption Metrics

- % of escrows using custom fees
- Average custom fee vs. default fee
- Marketplace adoption rate

### Revenue Metrics

- Total fees collected (custom + default)
- Average fee per escrow
- Revenue impact of custom fees

### User Metrics

- User satisfaction with fee flexibility
- Marketplace integration success
- Promotional campaign effectiveness

---

## Conclusion

### Recommendation: ✅ **IMPLEMENT**

**Rationale**:

- ✅ Low complexity (~170-280 bytes)
- ✅ High value (marketplace use cases)
- ✅ Low risk (max limit provides protection)
- ✅ Backward compatible (optional field)
- ✅ No breaking changes

### Implementation Priority

**Priority**: **HIGH**

- Can be implemented alongside other improvements
- Low risk, high value
- Enables marketplace integrations

### Timeline

**Estimated Time**: 2-3 hours

- Implementation: 1-2 hours
- Testing: 1 hour
- Documentation: 0.5 hours

---

## Next Steps

1. **Review Analysis** - Confirm approach
2. **Decide on Minimum Fee** - No minimum recommended
3. **Implement Feature** - Add to EscrowSettings
4. **Test Thoroughly** - Unit and integration tests
5. **Deploy to Testnet** - Verify in production-like environment
6. **Monitor Usage** - Track adoption and revenue impact

---

**Status**: Ready for Implementation  
**Last Updated**: Current

#Feedback

Only makes sense if the escrow is created for the buyer, otherwise it's the buyer specifying the fee they pay

Having flexibility to adjust fees is useful

How could we add a module for determining fees?
