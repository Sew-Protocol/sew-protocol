# Per-Escrow Yield Distribution Customization: Discussion & Design

**Date:** 2026-01-28  
**Status:** Design Discussion - Current State & Future Considerations

---

## Executive Summary

**Current State:**
- ✅ Infrastructure exists for per-escrow yield distribution (`distributionData` parameter)
- ❌ Per-escrow yield distribution **not currently implemented**
- ✅ `YieldDistribution` struct exists in types but not stored per-escrow
- ⚠️ Current behavior: All escrows with same module use same distribution (empty `distributionData` → yield stays in contract or falls back to fee recipient)

**Key Question:** Should per-escrow yield distribution be added to `EscrowSettings`?

---

## Current Implementation Analysis

### 1. Infrastructure Already Exists

**Distribution Module Interface:**
```solidity
// IYieldDistributionModule.distributeYield()
function distributeYield(
    uint256 workflowId,
    address token,
    uint256 yieldAmount,
    bytes calldata distributionData  // ✅ Accepts per-escrow data
) external returns (bool success, uint256 distributedAmount);
```

**Distribution Data Format:**
```solidity
// Encoded as: (address[] recipients, uint256[] percentages)
distributionData = abi.encode(recipients, percentages);
```

**Current Usage:**
```solidity
// YieldOps._distributeYieldInternal() - line 221
bytes memory distributionData = ''; // ❌ Empty - no per-escrow config
distModule.distributeYield(workflowId, token, yieldAmount, distributionData);
```

**Result:**
- Empty `distributionData` → `DefaultYieldDistributionModule` returns success with 0 distributed
- Yield stays in distribution module contract (or falls back to fee recipient)

---

### 2. Types Structure Exists But Not Used

**YieldDistribution Struct:**
```solidity
// EscrowTypes.sol - lines 27-31
struct YieldDistribution {
    address[] recipients; // Addresses to receive yield
    uint256[] percentages; // Percentage per recipient (basis points, sum to 10000)
    bool isSet; // Whether distribution is configured
}
```

**Current EscrowSettings:**
```solidity
// EscrowTypes.sol - lines 19-25
struct EscrowSettings {
    address customResolver;
    bool yieldEnabled; // ✅ Per-escrow yield opt-in
    uint256 autoReleaseTime;
    uint256 autoCancelTime;
    EscrowType escrowType;
    // ❌ Missing: YieldDistribution yieldDistribution;
}
```

**Library Functions:**
```solidity
// YieldDistributionLibrary.sol
- validateYieldDistribution(recipients, percentages)
- encodeYieldDistribution(YieldDistribution memory)
- decodeYieldDistribution(bytes memory)
```

**Conclusion:** Infrastructure is ready, but not connected to per-escrow settings.

---

## Use Cases for Per-Escrow Yield Distribution

### Use Case 1: Marketplace with Multiple Sellers

**Scenario:**
- Marketplace with Seller A, Seller B, Seller C
- Different sellers want different yield splits

**Current Limitation:**
```
Escrow 1: Seller A (wants 100% yield to recipient)
Escrow 2: Seller B (wants 50/50 split: seller/buyer)
Escrow 3: Seller C (wants 100% to buyer, 0% to seller)

Current: All escrows use same distribution (module default)
Problem: Cannot customize per-escrow distribution
```

**With Per-Escrow Distribution:**
```
Escrow 1: yieldDistribution = {recipients: [recipient], percentages: [10000]}
Escrow 2: yieldDistribution = {recipients: [seller, buyer], percentages: [5000, 5000]}
Escrow 3: yieldDistribution = {recipients: [buyer], percentages: [10000]}
```

---

### Use Case 2: Escrow with Affiliate/Marketing Split

**Scenario:**
- Escrow includes affiliate program
- Yield should be split: 80% to recipient, 15% to affiliate, 5% to marketing

**Per-Escrow Distribution:**
```
yieldDistribution = {
    recipients: [recipient, affiliate, marketing],
    percentages: [8000, 1500, 500]
}
```

---

### Use Case 3: Multi-Party Escrow

**Scenario:**
- Escrow involves multiple stakeholders
- Yield should be split proportionally among parties

**Per-Escrow Distribution:**
```
yieldDistribution = {
    recipients: [party1, party2, party3],
    percentages: [4000, 3500, 2500]
}
```

---

## Design Considerations

### 1. Storage Impact

**Adding to EscrowSettings:**
```solidity
struct EscrowSettings {
    address customResolver;
    bool yieldEnabled;
    uint256 autoReleaseTime;
    uint256 autoCancelTime;
    EscrowType escrowType;
    YieldDistribution yieldDistribution; // ✅ NEW
}
```

**Storage Cost:**
- `YieldDistribution` stores arrays (dynamic)
- Arrays stored separately in Solidity (not inline in struct)
- Mapping: `mapping(uint256 => YieldDistribution) public escrowYieldDistributions;`
- Gas cost: ~20,000 gas per recipient (SSTORE for each recipient/percentage)

**Example:**
- 3 recipients: ~60,000 gas at creation
- 10 recipients: ~200,000 gas at creation

**Consideration:** Acceptable tradeoff for flexibility? Or should we limit max recipients?

---

### 2. Immutability Requirements

**Question:** Should yield distribution be immutable per-escrow (like modules and fees)?

**Recommendation:** ✅ **YES** - Snapshot at creation, immutable during escrow lifetime

**Reasons:**
- Consistent with module snapshot pattern
- Prevents unexpected changes during escrow lifetime
- Users know distribution upfront

**Implementation:**
```solidity
// Snapshot yield distribution at creation (like modules/fees)
mapping(uint256 => YieldDistribution) public escrowYieldDistributions;

function createEscrow(...) {
    // ...
    if (settings.yieldDistribution.isSet) {
        escrowYieldDistributions[workflowId] = settings.yieldDistribution;
        emit EscrowYieldDistributionSet(workflowId, settings.yieldDistribution);
    }
}
```

---

### 3. Validation at Creation

**Requirements:**
- Recipients array non-empty
- Recipients and percentages arrays same length
- No zero addresses
- No zero percentages
- Percentages sum to 10000 (100%)

**Implementation:**
```solidity
function _validateYieldDistribution(YieldDistribution memory distribution) internal pure {
    if (!distribution.isSet) return; // Optional - skip if not set
    
    YieldDistributionLibrary.validateYieldDistribution(
        distribution.recipients,
        distribution.percentages
    );
}
```

**Error Handling:**
- Validation in `SettingsValidationLibrary`
- Revert at creation if invalid (prevents invalid escrows)

---

### 4. Integration with YieldOps

**Current Flow:**
```solidity
// YieldOps._distributeYieldInternal() - line 221
bytes memory distributionData = ''; // Empty - no config
```

**Proposed Flow:**
```solidity
// BaseEscrow._releaseEscrowTransfer() or _cancelAndRefund()
if (address(yieldOps) != address(0)) {
    // Get snapshotted yield distribution
    YieldDistribution memory distribution = escrowYieldDistributions[workflowId];
    
    // Encode distribution data
    bytes memory distributionData = '';
    if (distribution.isSet) {
        distributionData = YieldDistributionLibrary.encodeYieldDistribution(distribution);
    }
    
    // Pass to YieldOps (which passes to distribution module)
    yieldOps.handleYield(
        genModule,
        distModule,
        workflowId,
        token,
        amount,
        snapshottedYieldFee,
        escrowFeeAddress,
        distributionData  // ✅ NEW parameter
    );
}
```

**YieldOps Changes:**
```solidity
function handleYield(
    ...
    bytes memory distributionData  // ✅ NEW parameter
) external returns (YieldResult memory result) {
    // ...
    try this._distributeYieldInternal(
        distModule,
        workflowId,
        token,
        yieldToDistribute,
        distributionData  // ✅ Pass to distribution module
    )
}

function _distributeYieldInternal(
    IYieldDistributionModule distModule,
    uint256 workflowId,
    address token,
    uint256 yieldAmount,
    bytes memory distributionData  // ✅ NEW parameter
) public {
    // ...
    (bool success, ) = distModule.distributeYield(
        workflowId,
        token,
        yieldAmount,
        distributionData  // ✅ Use per-escrow data instead of empty
    );
}
```

---

### 5. Fallback Behavior

**When Yield Distribution Not Set:**
- `distribution.isSet = false` or `distributionData.length = 0`
- Current: Distribution module returns success with 0 distributed → yield stays in module
- Current fallback: If distribution fails, yield routed to fee recipient (CRIT-2 fix)

**Recommended Behavior:**
1. **Per-escrow distribution set:** Use per-escrow recipients/percentages
2. **Per-escrow distribution not set:** Use module default (if any)
3. **Module default not set:** Fall back to fee recipient (existing behavior)

**Implementation:**
```solidity
// In YieldOps or BaseEscrow
bytes memory distributionData = '';
if (escrowYieldDistributions[workflowId].isSet) {
    // Use per-escrow distribution
    distributionData = YieldDistributionLibrary.encodeYieldDistribution(
        escrowYieldDistributions[workflowId]
    );
}
// Else: empty distributionData → module can use default or return 0

// Module behavior (DefaultYieldDistributionModule):
if (distributionData.length == 0) {
    // No per-escrow config - use module default or return 0
    return (true, 0); // Yield stays in contract (or module uses default)
}
```

---

## Implementation Options

### Option 1: Full Per-Escrow Configuration (Recommended)

**Changes:**
1. Add `YieldDistribution yieldDistribution` to `EscrowSettings`
2. Store per-escrow distribution in `mapping(uint256 => YieldDistribution)`
3. Snapshot at creation (immutable)
4. Encode and pass to `YieldOps.handleYield()`
5. `YieldOps` passes to distribution module

**Pros:**
- ✅ Maximum flexibility
- ✅ Consistent with other per-escrow settings
- ✅ Immutable per-escrow (matches module snapshot pattern)

**Cons:**
- ⚠️ Gas cost for storage (~20k gas per recipient)
- ⚠️ Requires `YieldOps.handleYield()` signature change (new parameter)

**Gas Impact:**
- Per escrow creation: +20,000 gas per recipient
- 3 recipients: ~+60,000 gas
- 10 recipients: ~+200,000 gas

---

### Option 2: Module-Level Default Only (Current State)

**Changes:**
- None (keep current behavior)
- All escrows use module default distribution

**Pros:**
- ✅ Simple (no changes needed)
- ✅ Lower gas costs

**Cons:**
- ❌ No per-escrow customization
- ❌ Limited flexibility for marketplaces
- ❌ Cannot support different splits per escrow

---

### Option 3: Hybrid Approach

**Design:**
- Per-escrow distribution optional
- If not set, use module default
- If module default not set, fall back to fee recipient

**Pros:**
- ✅ Flexibility when needed
- ✅ Simpler for basic use cases (don't set distribution)
- ✅ Backward compatible

**Cons:**
- ⚠️ More complex implementation
- ⚠️ Two code paths (per-escrow vs module default)

---

## Recommended Implementation

### Phase 1: Add Per-Escrow Distribution to EscrowSettings

```solidity
struct EscrowSettings {
    address customResolver;
    bool yieldEnabled;
    uint256 autoReleaseTime;
    uint256 autoCancelTime;
    EscrowType escrowType;
    YieldDistribution yieldDistribution; // ✅ NEW - optional (isSet=false if not configured)
}
```

### Phase 2: Store and Snapshot at Creation

```solidity
mapping(uint256 => YieldDistribution) public escrowYieldDistributions;

function createEscrow(...) public returns (uint256 workflowId) {
    // ... existing code ...
    
    // Validate yield distribution if set
    if (settings.yieldDistribution.isSet) {
        YieldDistributionLibrary.validateYieldDistribution(
            settings.yieldDistribution.recipients,
            settings.yieldDistribution.percentages
        );
        
        // Snapshot distribution (immutable per-escrow)
        escrowYieldDistributions[workflowId] = settings.yieldDistribution;
        emit EscrowYieldDistributionSet(workflowId, settings.yieldDistribution);
    }
    
    // ... rest of creation ...
}
```

### Phase 3: Update YieldOps to Accept Distribution Data

```solidity
function handleYield(
    IYieldGenerationModule genModule,
    IYieldDistributionModule distModule,
    uint256 workflowId,
    address token,
    uint256 amount,
    uint256 protocolFeeBps,
    address feeRecipient,
    bytes memory distributionData  // ✅ NEW
) external returns (YieldResult memory result) {
    // ... existing code ...
    
    // Pass distributionData to _distributeYieldInternal
    try this._distributeYieldInternal(
        distModule,
        workflowId,
        token,
        yieldToDistribute,
        distributionData  // ✅ Use per-escrow data
    )
}

function _distributeYieldInternal(
    IYieldDistributionModule distModule,
    uint256 workflowId,
    address token,
    uint256 yieldAmount,
    bytes memory distributionData  // ✅ NEW
) public {
    // ... existing code ...
    
    distModule.distributeYield(
        workflowId,
        token,
        yieldAmount,
        distributionData  // ✅ Pass to module (empty if not configured)
    );
}
```

### Phase 4: Update BaseEscrow to Encode and Pass Distribution

```solidity
function _releaseEscrowTransfer(uint256 workflowId) internal {
    // ... existing code ...
    
    if (address(yieldOps) != address(0)) {
        // Get snapshotted yield distribution
        YieldDistribution memory distribution = escrowYieldDistributions[workflowId];
        
        // Encode distribution data (empty if not set)
        bytes memory distributionData = '';
        if (distribution.isSet) {
            distributionData = YieldDistributionLibrary.encodeYieldDistribution(distribution);
        }
        
        try yieldOps.handleYield(
            genModule,
            distModule,
            workflowId,
            token,
            amount,
            snapshottedYieldFee,
            escrowFeeAddress,
            distributionData  // ✅ NEW - per-escrow config
        )
    }
}
```

---

## Validation & Limits

### Recommended Limits

**Max Recipients:**
- **Recommendation:** 10 recipients maximum
- **Reason:** Gas cost + loop iteration limits
- **Validation:** Revert if `recipients.length > 10`

**Zero Address Check:**
- Revert if any recipient is `address(0)`

**Percentage Validation:**
- Each percentage > 0
- Sum equals 10000 (100%)

**Array Length Match:**
- `recipients.length == percentages.length`

---

## Event Addition

**New Event:**
```solidity
event EscrowYieldDistributionSet(
    uint256 indexed workflowId,
    address[] recipients,
    uint256[] percentages
);
```

**Emit at:**
- Escrow creation (if distribution is set)
- Distribution used (at yield distribution time, for transparency)

---

## Gas Cost Analysis

**Per Escrow Creation:**
- Storage for `YieldDistribution`: ~20,000 gas per recipient
- 3 recipients: ~60,000 gas
- 10 recipients: ~200,000 gas
- Encoding: ~1,000 gas

**Per Yield Distribution:**
- Reading from storage: ~2,100 gas per recipient (warm)
- Encoding: ~1,000 gas
- Passing to module: ~375 gas per byte

**Net Impact:**
- One-time cost at creation: ~60,000 gas for 3 recipients
- Ongoing cost at distribution: ~10,000 gas for 3 recipients
- **Acceptable tradeoff for flexibility**

---

## Backward Compatibility

**For Existing Escrows:**
- `escrowYieldDistributions[workflowId].isSet = false` (default)
- Empty `distributionData` → module uses default or returns 0
- No changes needed for existing escrows

**For New Escrows:**
- Optional: Only set if needed
- If not set, use module default (or fee recipient fallback)

---

## Testing Considerations

1. **Per-Escrow Distribution Tests:**
   - Single recipient (100%)
   - Multiple recipients (e.g., 50/50, 70/30)
   - Maximum recipients (10)
   - Invalid distributions (sum != 100%, zero addresses, etc.)

2. **Fallback Tests:**
   - No per-escrow distribution → module default
   - No module default → fee recipient fallback

3. **Immutability Tests:**
   - Distribution snapshot at creation
   - Cannot change during escrow lifetime

4. **Gas Tests:**
   - Measure gas cost with various recipient counts
   - Ensure limits are reasonable

---

## Summary & Recommendation

### Current State
- ✅ Infrastructure exists (`distributionData` parameter, `YieldDistribution` struct, encoding/decoding library)
- ❌ Not connected to per-escrow settings
- ⚠️ All escrows use same distribution (module default or empty)

### Recommendation: **Implement Per-Escrow Distribution**

**Why:**
1. Infrastructure already exists (minimal changes needed)
2. Addresses real use cases (marketplaces, multi-party escrows, affiliate splits)
3. Consistent with other per-escrow customizations (`yieldEnabled`, `customResolver`, etc.)
4. Immutable per-escrow (matches module snapshot pattern)
5. Gas costs acceptable (~60k for 3 recipients)

**Implementation Priority:**
- **Priority:** 🟠 **HIGH** (enhancement, not blocker)
- **Complexity:** 🟡 **MEDIUM** (infrastructure exists, needs integration)
- **Impact:** 🟢 **HIGH** (enables important use cases)

**Next Steps:**
1. Add `YieldDistribution` to `EscrowSettings` struct
2. Add mapping and snapshot logic
3. Update `YieldOps.handleYield()` signature
4. Update `BaseEscrow` to encode and pass distribution data
5. Add validation and limits
6. Add tests

---

**Discussion Points:**
1. **Max Recipients Limit:** 10 recipients reasonable? Or should we allow more?
2. **Gas Costs:** Acceptable tradeoff for flexibility?
3. **Fallback Behavior:** Module default → fee recipient acceptable?
4. **Validation:** Strict validation at creation (revert if invalid) or graceful degradation?
