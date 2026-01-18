# Governor Implementation Analysis: Absolute vs Percentage-Based Quorum

**Date:** 2026-01-28  
**Last Updated:** 2026-01-28 (Absolute Quorum Implemented)  
**Status:** ✅ **IMPLEMENTED** - Absolute Quorum approach selected and implemented

---

## Current Implementation Summary

### Standard OpenZeppelin Components ✅

**Confirmed: Using Standard OZ Governor Stack**

1. **`Governor`** (Base contract)
   - Core governance functionality
   - Proposal lifecycle management

2. **`GovernorSettings`** (Extension)
   - Voting delay, voting period, proposal threshold
   - All configurable via constructor

3. **`GovernorCountingSimple`** (Extension)
   - Simple vote counting (For/Against/Abstain)
   - Standard OZ implementation

4. **`GovernorVotes`** (Extension)
   - Token-weighted voting using `ERC20Votes`
   - Uses `getPastVotes()` for historical voting power

5. **`GovernorVotesQuorumFraction`** (Extension) ⚠️ **PERCENTAGE-BASED**
   - Quorum as **percentage of total supply**
   - Formula: `quorum = (totalSupply * quorumNumerator) / 100`
   - Uses `token.getPastTotalSupply(blockNumber)` - **total supply, not circulating**

6. **`GovernorTimelockControl`** (Extension)
   - Execution via `TimelockController`
   - All proposals go through timelock

### Custom Code Analysis

**✅ CUSTOM QUORUM LOGIC IMPLEMENTED** - Absolute Quorum

**Current `GovGovernor.sol` contains:**
- ✅ Standard inheritance from OZ extensions
- ✅ Required function overrides (for multiple inheritance)
- ✅ **Custom quorum calculation:** Returns `absoluteQuorum` (absolute amount)
- ✅ **Non-circulating tracking:** For transparency/APIs (CoinGecko, etc.)
- ✅ **Circulating supply function:** `getCirculatingSupply()` for external APIs
- ✅ **Governance functions:** `setAbsoluteQuorum()`, address management

**Code Breakdown:**
```solidity
// Lines 28-35: Standard inheritance
contract GovGovernor is
    Governor,
    GovernorSettings,
    GovernorCountingSimple,
    GovernorVotes,
    GovernorVotesQuorumFraction,  // ⚠️ Percentage-based
    GovernorTimelockControl

// Lines 45-60: Constructor - all standard OZ
constructor(...) {
    Governor('Sew Protocol DAO')
    GovernorSettings(...)
    GovernorVotes(...)
    GovernorVotesQuorumFraction(quorumBps)  // ⚠️ Percentage of total supply
    GovernorTimelockControl(...)
}

// Lines 65-176: Required overrides - all just call super
// NO CUSTOM LOGIC
```

---

## Absolute Quorum Support

### OpenZeppelin's Options

**Option 1: `GovernorVotesQuorumFraction`** (Current - Percentage-Based)
- ✅ Percentage of **total supply**
- ❌ Does NOT support absolute quorum
- ❌ Does NOT support circulating supply

**Option 2: `GovernorQuorumAbsolute`** (Available in OZ)
- ✅ **Absolute quorum** (fixed token amount)
- ✅ Simple: `quorum(blockNumber) = fixedAmount`
- ❌ Does NOT scale with supply
- ❌ Requires governance updates as supply changes

**Option 3: Custom Override** (Required for Circulating Supply)
- ✅ Can implement any logic (absolute, percentage of circulating, etc.)
- ⚠️ Requires custom code
- ⚠️ Must override `quorum()` function

---

## Answer: Does Our Implementation Support Absolute Quorum?

### Current State: ✅ **YES - IMPLEMENTED**

**Current Implementation:**
- Overrides `quorum()` to return `absoluteQuorum` (absolute amount)
- Uses `GovernorVotesQuorumFraction` with `quorumNumerator = 0` (not used)
- Quorum = `absoluteQuorum` (e.g., 4M tokens)
- Can be updated via governance: `setAbsoluteQuorum(uint256)`

### Can We Switch to Absolute Quorum?

**✅ YES - Two Options:**

#### Option A: Switch to `GovernorQuorumAbsolute` (Simple)

**Changes Required:**
1. Replace `GovernorVotesQuorumFraction` with `GovernorQuorumAbsolute`
2. Update constructor to accept absolute quorum amount (not percentage)
3. Update deployment scripts

**Pros:**
- ✅ Clean OZ implementation
- ✅ Simple: fixed quorum amount
- ✅ No custom code needed

**Cons:**
- ❌ Doesn't scale with supply
- ❌ Requires governance updates as supply changes
- ❌ Not ideal for long-term

**Implementation:**
```solidity
// Replace this:
import '@openzeppelin/contracts/governance/extensions/GovernorVotesQuorumFraction.sol';
contract GovGovernor is
    ...
    GovernorVotesQuorumFraction,  // ❌ Remove
    ...

// With this:
import '@openzeppelin/contracts/governance/extensions/GovernorQuorumAbsolute.sol';
contract GovGovernor is
    ...
    GovernorQuorumAbsolute,  // ✅ Add
    ...

// Constructor change:
constructor(
    ...
    uint256 absoluteQuorumTokens  // ✅ Fixed amount instead of percentage
) {
    ...
    GovernorQuorumAbsolute(absoluteQuorumTokens)  // ✅ 4M tokens
    ...
}
```

#### Option B: Custom Override for Circulating Supply (Recommended)

**Changes Required:**
1. Keep `GovernorVotesQuorumFraction` (for interface compatibility)
2. Override `quorum()` to use circulating supply
3. Add circulating supply tracking

**Pros:**
- ✅ Scales automatically with circulating supply
- ✅ Accurate quorum calculation
- ✅ Handles launch scenario (10% circulating)

**Cons:**
- ⚠️ Requires custom code
- ⚠️ Need to track non-circulating addresses

---

## Recommendation

### For Absolute Quorum (Fixed Amount)

**✅ Use `GovernorQuorumAbsolute`** - Clean OZ implementation

**At Launch:**
- Set absolute quorum = 4M tokens
- Works immediately, no custom code

**Tradeoff:**
- Will need governance updates as supply unlocks
- But simple and clean

### For Circulating Supply Quorum (Percentage of Circulating)

**✅ Override `quorum()` with custom logic** - More accurate long-term

**At Launch:**
- Circulating: 100M tokens
- Quorum: 4% of 100M = 4M tokens
- Auto-scales as supply unlocks

**Tradeoff:**
- Requires custom code
- But scales automatically

---

## Implementation Comparison

| Approach | OZ Standard | Custom Code | Scales with Supply | Launch Ready |
|----------|-------------|-------------|-------------------|--------------|
| **Current (Percentage of Total)** | ✅ Yes | ❌ No | ❌ No (uses total) | ❌ No (too high) |
| **Absolute Quorum** | ✅ Yes | ❌ No | ❌ No | ✅ Yes |
| **Circulating Supply** | ⚠️ Partial | ✅ Yes | ✅ Yes | ✅ Yes |

---

## Next Steps

**If using Absolute Quorum:**
1. Replace `GovernorVotesQuorumFraction` with `GovernorQuorumAbsolute`
2. Update constructor parameter
3. Set quorum = 4M tokens
4. Update deployment scripts

**If using Circulating Supply:**
1. Keep `GovernorVotesQuorumFraction` (for interface)
2. Override `quorum()` function
3. Add circulating supply tracking
4. Implement `getCirculatingSupply()` function
