# Non-Circulating Token Tracking: Benefits & Trade-offs Analysis

**Date:** 2026-01-28  
**Purpose:** Analyze benefits of tracking non-circulating tokens beyond quorum, and compare approaches

---

## Executive Summary

**Key Finding:** Tracking non-circulating tokens has **significant benefits beyond quorum calculation**, including:
- External API requirements (CoinGecko, CoinMarketCap)
- Transparency and investor trust
- Analytics and reporting
- Future-proofing for governance evolution

**Recommendation:** 🟢 **Track non-circulating tokens, but use absolute quorum initially**
- Get benefits of tracking (transparency, APIs, analytics)
- Avoid complexity risks in quorum calculation
- Can migrate to circulating-based quorum later

---

## Benefits of Tracking Non-Circulating Tokens

### 1. External API Requirements (CoinGecko, CoinMarketCap) 🟢 **HIGH VALUE**

**Industry Standard:**
- **CoinGecko** requires circulating supply data for listing
- **CoinMarketCap** distinguishes between total, circulating, and locked supply
- **DeFiLlama** and other analytics platforms use circulating supply
- **DEX aggregators** may use circulating supply for pricing

**CoinGecko Methodology:**
- Defines circulating supply as: `totalSupply - locked - vested - treasury - nonpublic`
- Excludes tokens in vesting contracts, treasury, foundation reserves
- Requires regular updates as tokens unlock
- Uses circulating supply for market cap calculation: `price × circulatingSupply`

**CoinMarketCap Methodology:**
- Tracks "unlocked circulating supply" separately from total supply
- Distinguishes between:
  - **Total Supply:** All minted tokens
  - **Circulating Supply:** Freely tradable tokens
  - **Locked Supply:** Tokens in vesting/locks

**Impact if NOT Tracking:**
- ❌ May not get listed on major platforms
- ❌ Market cap calculations will be wrong (too high)
- ❌ Price per token will appear lower than reality
- ❌ Investors can't assess true scarcity
- ❌ Dilution risk not visible

**Impact if Tracking:**
- ✅ Can provide accurate data to CoinGecko/CoinMarketCap
- ✅ Market cap reflects true circulating supply
- ✅ Price per token more accurate
- ✅ Investors can assess dilution risk
- ✅ Better visibility in analytics platforms

**Value:** 🟢 **HIGH** - Essential for external listings and accurate market data

---

### 2. Transparency & Investor Trust 🟢 **HIGH VALUE**

**Benefits:**
- **Investor Confidence:** Clear visibility into token distribution
- **Dilution Risk Assessment:** Investors can see when tokens unlock
- **Governance Legitimacy:** Shows commitment to transparency
- **Regulatory Compliance:** May help with regulatory clarity

**What Investors Want to Know:**
```
Total Supply: 1B tokens
Circulating: 100M tokens (10%)
Locked/Vesting: 900M tokens (90%)
  - Team vesting: 200M (unlocks over 4 years)
  - Treasury: 300M (reserved for operations)
  - Foundation: 400M (long-term reserves)
```

**Without Tracking:**
- ❌ Investors see 1B tokens and assume all are circulating
- ❌ Can't assess dilution risk
- ❌ Unclear when tokens unlock
- ❌ Appears less transparent

**With Tracking:**
- ✅ Clear breakdown of token distribution
- ✅ Investors can assess dilution risk
- ✅ Unlock schedules visible
- ✅ Appears more transparent and professional

**Value:** 🟢 **HIGH** - Builds trust and attracts investors

---

### 3. Analytics & Reporting 🟡 **MEDIUM VALUE**

**Use Cases:**
- **Dashboard Analytics:** Show circulating vs. total supply over time
- **Tokenomics Visualization:** Charts showing unlock schedules
- **Governance Metrics:** Track voting power distribution
- **Economic Analysis:** Assess supply shock risks

**Example Analytics:**
```
Circulating Supply Over Time:
Month 1: 100M (10%)
Month 6: 150M (15%) - 50M unlocked from vesting
Month 12: 200M (20%) - 50M more unlocked
Month 24: 300M (30%) - 100M more unlocked
```

**Without Tracking:**
- ❌ Can't show circulating supply trends
- ❌ Can't visualize unlock schedules
- ❌ Limited analytics capabilities

**With Tracking:**
- ✅ Rich analytics and reporting
- ✅ Visualize token distribution
- ✅ Track unlock schedules
- ✅ Better economic analysis

**Value:** 🟡 **MEDIUM** - Nice to have, not essential

---

### 4. Future-Proofing for Governance Evolution 🟡 **MEDIUM VALUE**

**Benefits:**
- **Migration Path:** Can switch to circulating-based quorum later
- **Flexibility:** Infrastructure ready if needed
- **No Breaking Changes:** Can evolve without major refactoring

**Scenario:**
```
Year 1: Use absolute quorum (4M tokens)
Year 2: Circulating supply grows to 200M
Year 3: Community wants percentage-based quorum
Year 3: Switch to circulating-based quorum (already have tracking)
```

**Without Tracking:**
- ❌ Would need to build infrastructure from scratch
- ❌ More complex migration
- ❌ Higher risk of bugs

**With Tracking:**
- ✅ Infrastructure already exists
- ✅ Easier migration
- ✅ Lower risk

**Value:** 🟡 **MEDIUM** - Future flexibility

---

### 5. Governance Legitimacy 🟡 **MEDIUM VALUE**

**Benefits:**
- **Fairness:** Shows commitment to fair governance
- **Transparency:** Non-circulating addresses are public
- **Accountability:** Can verify which addresses are excluded

**Without Tracking:**
- ❌ Less transparent
- ❌ Harder to verify fairness

**With Tracking:**
- ✅ More transparent
- ✅ Easier to verify fairness
- ✅ Public list of non-circulating addresses

**Value:** 🟡 **MEDIUM** - Governance optics

---

## Approach Comparison: Track But Don't Use for Quorum

### Option 1: Track + Absolute Quorum (Recommended) 🟢

**Implementation:**
```solidity
// Track non-circulating addresses (for transparency/APIs)
mapping(address => bool) public nonCirculatingAddresses;
address[] public nonCirculatingAddressesList;

// But use absolute quorum for governance
uint256 public absoluteQuorum = 4_000_000 ether;

function quorum(uint256 /* blockNumber */) public view override returns (uint256) {
    return absoluteQuorum; // Simple, safe
}

// Provide circulating supply for external APIs
function getCirculatingSupply(uint256 blockNumber) public view returns (uint256) {
    // Calculate for CoinGecko/analytics, but don't use for quorum
    IVotes token = token();
    uint256 totalSupply = token.getPastTotalSupply(blockNumber);
    uint256 nonCirculating = 0;
    
    // Sum balances of non-circulating addresses
    uint256 length = nonCirculatingAddressesList.length;
    for (uint256 i = 0; i < length; i++) {
        address addr = nonCirculatingAddressesList[i];
        if (nonCirculatingAddresses[addr]) {
            if (blockNumber == block.number) {
                nonCirculating += IERC20(address(token)).balanceOf(addr);
            } else {
                nonCirculating += token.getPastVotes(addr, blockNumber);
            }
        }
    }
    
    return totalSupply - nonCirculating;
}
```

**Benefits:**
- ✅ Get all benefits of tracking (APIs, transparency, analytics)
- ✅ Simple, safe quorum calculation
- ✅ Can migrate to circulating-based quorum later
- ✅ Best of both worlds

**Trade-offs:**
- ⚠️ Slight code complexity (but isolated to `getCirculatingSupply()`)
- ⚠️ Gas cost for `getCirculatingSupply()` (but only called by external APIs, not governance)

**Risk:** 🟢 **LOW** - Tracking code is separate from quorum logic

---

### Option 2: Track + Circulating-Based Quorum (Current)

**Implementation:**
- Use `getCirculatingSupply()` for quorum calculation
- More complex, higher risk
- But automatically scales

**Benefits:**
- ✅ Automatic scaling
- ✅ All tracking benefits

**Trade-offs:**
- 🔴 High complexity
- 🔴 Bug risk (current issue)
- 🔴 Maintenance burden

**Risk:** 🔴 **HIGH** - Complex quorum calculation

---

### Option 3: Don't Track (Absolute Quorum Only)

**Implementation:**
- Just use absolute quorum
- No tracking of non-circulating addresses

**Benefits:**
- ✅ Simplest possible
- ✅ Lowest risk

**Trade-offs:**
- ❌ No CoinGecko/CoinMarketCap data
- ❌ Less transparency
- ❌ No analytics
- ❌ Harder to migrate later

**Risk:** 🟢 **LOW** - But misses important benefits

---

## Detailed Comparison Table

| Factor | Track + Absolute Quorum | Track + Circulating Quorum | Don't Track |
|--------|------------------------|---------------------------|-------------|
| **Quorum Complexity** | 🟢 Low | 🔴 High | 🟢 Low |
| **Quorum Risk** | 🟢 Low | 🔴 High | 🟢 Low |
| **CoinGecko Support** | 🟢 Yes | 🟢 Yes | 🔴 No |
| **Transparency** | 🟢 High | 🟢 High | 🔴 Low |
| **Analytics** | 🟢 Yes | 🟢 Yes | 🔴 No |
| **Future Migration** | 🟢 Easy | 🟢 N/A | 🔴 Hard |
| **Code Complexity** | 🟡 Medium | 🔴 High | 🟢 Low |
| **Maintenance** | 🟡 Medium | 🔴 High | 🟢 Low |
| **Gas Cost (Quorum)** | 🟢 Low | 🟡 Medium | 🟢 Low |
| **Auto-Scaling** | 🔴 No | 🟢 Yes | 🔴 No |

**Winner:** 🟢 **Track + Absolute Quorum** (best balance)

---

## Implementation Strategy

### Phase 1: Launch (Recommended)

**Implement:**
1. ✅ Track non-circulating addresses (for transparency/APIs)
2. ✅ Use absolute quorum for governance (4M tokens)
3. ✅ Provide `getCirculatingSupply()` function (for external APIs)
4. ✅ Document non-circulating addresses publicly

**Benefits:**
- Get all tracking benefits (CoinGecko, transparency, analytics)
- Simple, safe quorum calculation
- Low risk launch

**Code:**
```solidity
// Track addresses (for APIs/transparency)
mapping(address => bool) public nonCirculatingAddresses;
address[] public nonCirculatingAddressesList;

// Simple quorum (for governance)
uint256 public absoluteQuorum = 4_000_000 ether;

function quorum(uint256 /* blockNumber */) public view override returns (uint256) {
    return absoluteQuorum;
}

// Circulating supply (for external APIs)
function getCirculatingSupply(uint256 blockNumber) public view returns (uint256) {
    // Calculate for CoinGecko, but don't use for quorum
    // ... (implementation)
}
```

---

### Phase 2: Growth (Optional Migration)

**When to Consider:**
- After protocol is stable (6-12 months)
- When circulating supply has grown significantly
- When community wants percentage-based quorum

**Migration:**
1. Governance proposal to switch to circulating-based quorum
2. Community votes
3. Update `quorum()` to use `getCirculatingSupply()`
4. Keep tracking infrastructure (already exists)

**Benefits:**
- Automatic scaling
- Percentage-based quorum
- Infrastructure already in place

---

## Risk Assessment

### Track + Absolute Quorum Approach

**Risks:**
- 🟡 **Medium:** Code complexity (but isolated)
- 🟡 **Medium:** Gas cost for `getCirculatingSupply()` (but only for APIs)
- 🟢 **Low:** Quorum calculation risk (simple absolute value)

**Mitigations:**
- Isolate tracking code from quorum logic
- `getCirculatingSupply()` only called by external APIs
- Quorum calculation remains simple

**Overall Risk:** 🟢 **LOW** - Best balance of benefits and safety

---

### Track + Circulating Quorum Approach

**Risks:**
- 🔴 **High:** Quorum calculation complexity
- 🔴 **High:** Bug risk (current issue)
- 🔴 **High:** Maintenance burden

**Overall Risk:** 🔴 **HIGH** - Too complex for launch

---

### Don't Track Approach

**Risks:**
- 🟢 **Low:** Code complexity
- 🔴 **High:** Missing CoinGecko/transparency benefits
- 🔴 **High:** Hard to migrate later

**Overall Risk:** 🟡 **MEDIUM** - Safe but misses important benefits

---

## CoinGecko/External API Requirements

### What CoinGecko Needs

**Required Data:**
1. **Circulating Supply:** `totalSupply - nonCirculating`
2. **Total Supply:** All minted tokens
3. **Update Frequency:** Regular updates as tokens unlock
4. **Transparency:** Public list of non-circulating addresses

**How to Provide:**
- **On-chain:** `getCirculatingSupply()` function
- **Off-chain:** API endpoint or subgraph
- **Documentation:** Public list of non-circulating addresses

**Example API Response:**
```json
{
  "totalSupply": "1000000000000000000000000000",
  "circulatingSupply": "100000000000000000000000000",
  "nonCirculatingAddresses": [
    {
      "address": "0x123...",
      "balance": "450000000000000000000000000",
      "type": "vesting"
    },
    {
      "address": "0x456...",
      "balance": "450000000000000000000000000",
      "type": "treasury"
    }
  ]
}
```

**Impact:**
- ✅ Can get listed on CoinGecko
- ✅ Accurate market cap
- ✅ Better price discovery
- ✅ Investor confidence

---

## Recommendation

### 🟢 **Track Non-Circulating Tokens + Use Absolute Quorum**

**Rationale:**
1. **Get All Benefits:** CoinGecko support, transparency, analytics
2. **Low Risk:** Simple quorum calculation
3. **Future-Proof:** Can migrate to circulating-based quorum later
4. **Best Balance:** Benefits without complexity

**Implementation:**
- Track addresses in `nonCirculatingAddresses` mapping
- Use `absoluteQuorum` for governance (4M tokens)
- Provide `getCirculatingSupply()` for external APIs
- Document addresses publicly

**Migration Path:**
- Launch with absolute quorum
- Monitor token distribution
- If needed, migrate to circulating-based quorum later
- Infrastructure already in place

**Risk Reduction:**
- 🔴 **HIGH RISK** (circulating quorum) → 🟢 **LOW RISK** (absolute quorum)
- ✅ **All Benefits** (tracking for APIs/transparency)
- ✅ **Future Flexibility** (can migrate later)

---

## Summary

### Benefits of Tracking (Beyond Quorum)

1. 🟢 **CoinGecko/External APIs** - Essential for listings
2. 🟢 **Transparency** - Builds investor trust
3. 🟡 **Analytics** - Better reporting
4. 🟡 **Future-Proofing** - Easy migration later
5. 🟡 **Governance Legitimacy** - Fairness optics

### Best Approach

**Track + Absolute Quorum:**
- ✅ Get all tracking benefits
- ✅ Simple, safe quorum
- ✅ Can migrate later
- ✅ Best balance of benefits and safety

**Risk:** 🟢 **LOW** | **Benefits:** 🟢 **HIGH**

---

**Conclusion:** Track non-circulating tokens for external APIs and transparency, but use absolute quorum for governance safety. Best of both worlds.
