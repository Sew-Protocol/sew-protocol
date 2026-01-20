# Quorum Calculation: Circulating Supply Analysis

**Date:** 2026-01-28  
**Status:** Analysis & Implementation Proposal  
**Issue:** Quorum must be based on circulating supply, not total supply

---

## Problem Statement

### Current Situation

**Configuration:**
- **Total Supply:** 1B tokens (1,000,000,000)
- **Circulating Supply at Launch:** 100M tokens (10% of total)
- **Current Quorum:** 4% of total supply = 40M tokens
- **Actual Circulating Supply:** 100M tokens

**Problem:**
- OpenZeppelin's `GovernorVotesQuorumFraction` calculates quorum as: `quorum = (totalSupply * quorumNumerator) / 100`
- This uses **total supply** (1B tokens), not **circulating supply** (100M tokens)
- Result: Quorum = 4% of 1B = **40M tokens**
- But 40M / 100M = **40% of circulating supply** (way too high!)
- Desired: Quorum = 4% of 100M = **4M tokens**

**Impact:**
- Governance would be effectively frozen at launch (40% of circulating supply needed)
- Proposals would be nearly impossible to pass
- Only becomes reasonable as circulating supply approaches total supply

---

## Understanding: OpenZeppelin's Quorum Calculation

### How `GovernorVotesQuorumFraction` Works

```solidity
// OpenZeppelin GovernorVotesQuorumFraction.quorum()
function quorum(uint256 blockNumber) public view override returns (uint256) {
    return (token.getPastTotalSupply(blockNumber) * quorumNumerator) / 100;
}
```

**Key Point:** Uses `getPastTotalSupply()` which returns **total supply**, not circulating supply.

**Calculation:**
- `quorumNumerator = 4` (4%)
- `totalSupply = 1B tokens`
- `quorum = (1B * 4) / 100 = 40M tokens`

---

## Solution Approaches

### Approach 1: Override `quorum()` to Use Circulating Supply ✅ **RECOMMENDED**

**Implementation:**
- Override `quorum()` function in `GovGovernor`
- Calculate circulating supply = total supply - locked/vested/treasury tokens
- Track non-circulating addresses (treasury, vesting contracts, etc.)
- Calculate quorum as: `(circulatingSupply * quorumNumerator) / 100`

**Pros:**
- ✅ Accurate quorum calculation based on actual voting power
- ✅ Scales automatically as tokens unlock
- ✅ No governance action needed as supply changes
- ✅ Transparent and auditable

**Cons:**
- ⚠️ Requires tracking non-circulating addresses
- ⚠️ Need to define what "circulating" means
- ⚠️ Slightly more complex implementation

**Complexity:** Medium  
**Maintenance:** Low (addresses tracked once, updates via governance)

---

### Approach 2: Adjust Quorum Numerator to Account for Circulating Supply

**Implementation:**
- Set `quorumNumerator = 0.4` (0.4% of total supply)
- At launch: 0.4% of 1B = 4M tokens ✅
- As circulating increases to 50% (500M): 0.4% of 1B = 4M tokens (0.8% of circulating) ⚠️
- As circulating increases to 100% (1B): 0.4% of 1B = 4M tokens (0.4% of circulating) ❌

**Pros:**
- ✅ Simple implementation (no code changes)
- ✅ Works at launch

**Cons:**
- ❌ Doesn't scale - quorum becomes too low as supply unlocks
- ❌ Requires frequent governance updates
- ❌ Not accurate long-term

**Complexity:** Low  
**Maintenance:** High (requires governance updates as supply changes)

---

### Approach 3: Fixed Quorum Amount (Not Percentage)

**Implementation:**
- Set quorum to fixed amount: 4M tokens
- Doesn't scale with supply

**Pros:**
- ✅ Simple
- ✅ Works at launch

**Cons:**
- ❌ Doesn't scale - becomes too low as supply increases
- ❌ Not percentage-based (unusual for governance)

**Complexity:** Low  
**Maintenance:** Medium (may need updates)

---

### Approach 4: Custom Quorum Module with Circulating Supply Tracking

**Implementation:**
- Create custom quorum module that tracks circulating supply
- More sophisticated tracking (vesting schedules, unlock events)
- Can handle complex tokenomics

**Pros:**
- ✅ Most flexible
- ✅ Can handle complex scenarios

**Cons:**
- ❌ Most complex implementation
- ❌ Overkill for current needs
- ❌ Higher gas costs

**Complexity:** High  
**Maintenance:** High

---

## Recommended Approach: Override `quorum()` with Circulating Supply

### Implementation Design

**Step 1: Define Circulating Supply**

```solidity
// Circulating Supply = Total Supply - Non-Circulating Tokens
// Non-Circulating = Tokens in:
// - Treasury/Safe (if not voting)
// - Vesting contracts (locked tokens)
// - Timelock (if holding tokens)
// - Any other locked/escrowed addresses
```

**Step 2: Track Non-Circulating Addresses**

```solidity
mapping(address => bool) public nonCirculatingAddresses;

function setNonCirculatingAddress(address addr, bool isNonCirculating) 
    external onlyRole(ROLE_TIMELOCK) {
    nonCirculatingAddresses[addr] = isNonCirculating;
    emit NonCirculatingAddressUpdated(addr, isNonCirculating);
}
```

**Step 3: Calculate Circulating Supply**

```solidity
function getCirculatingSupply(uint256 blockNumber) public view returns (uint256) {
    uint256 totalSupply = token.getPastTotalSupply(blockNumber);
    uint256 nonCirculating = 0;
    
    // Sum balances of all non-circulating addresses
    for (uint256 i = 0; i < nonCirculatingAddressesList.length; i++) {
        address addr = nonCirculatingAddressesList[i];
        if (nonCirculatingAddresses[addr]) {
            nonCirculating += token.getPastVotes(addr, blockNumber);
        }
    }
    
    return totalSupply - nonCirculating;
}
```

**Step 4: Override Quorum Calculation**

```solidity
function quorum(uint256 blockNumber) 
    public 
    view 
    override(Governor, GovernorVotesQuorumFraction) 
    returns (uint256) 
{
    uint256 circulatingSupply = getCirculatingSupply(blockNumber);
    return (circulatingSupply * quorumNumerator()) / 100;
}
```

---

## Configuration at Launch

**Initial Setup:**
- Total Supply: 1B tokens
- Circulating: 100M tokens (10%)
- Non-Circulating: 900M tokens (90%)
  - Treasury/Safe: ~900M tokens (locked)
  - Vesting contracts: 0M (if any, add to list)

**Quorum Calculation:**
- Circulating Supply: 100M tokens
- Quorum Numerator: 4%
- Required Quorum: 4M tokens (4% of 100M)

**As Supply Unlocks:**
- Circulating increases to 200M → Quorum = 8M tokens (4% of 200M)
- Circulating increases to 500M → Quorum = 20M tokens (4% of 500M)
- Circulating increases to 1B → Quorum = 40M tokens (4% of 1B)

**Automatic Scaling:** ✅ Quorum scales proportionally with circulating supply

---

## Edge Cases & Considerations

### 1. Treasury Tokens Voting

**Question:** Should treasury tokens be able to vote?

**Options:**
- **Option A:** Treasury tokens excluded from circulating supply (can't vote)
- **Option B:** Treasury tokens included in circulating supply (can vote)

**Recommendation:** Option A - Treasury tokens should be excluded from circulating supply and cannot vote. This prevents treasury from controlling governance.

### 2. Vesting Contracts

**Question:** Should locked/vesting tokens be excluded?

**Recommendation:** Yes - Tokens in vesting contracts should be excluded until they vest and are transferred to recipients.

### 3. Staking Contracts

**Question:** Should staked tokens be excluded?

**Recommendation:** No - Staked tokens should be included if they retain voting rights (delegation). If staking removes voting rights, exclude them.

### 4. Escrow Contracts

**Question:** Should tokens in escrow be excluded?

**Recommendation:** Depends - If escrow tokens can vote (via delegation), include them. If not, exclude them.

### 5. Minimum Quorum Floor

**Consideration:** Should there be a minimum quorum floor?

**Example:**
```solidity
uint256 MINIMUM_QUORUM = 1_000_000 * 10**18; // 1M tokens minimum

function quorum(uint256 blockNumber) public view override returns (uint256) {
    uint256 circulatingSupply = getCirculatingSupply(blockNumber);
    uint256 calculatedQuorum = (circulatingSupply * quorumNumerator()) / 100;
    return calculatedQuorum > MINIMUM_QUORUM ? calculatedQuorum : MINIMUM_QUORUM;
}
```

**Recommendation:** Optional - Only needed if circulating supply is very low (< 25M tokens). At 100M circulating, 4% = 4M tokens, which is reasonable.

---

## Implementation Checklist

- [ ] Define "circulating supply" criteria (treasury, vesting, locked tokens)
- [ ] Add `nonCirculatingAddresses` mapping to `GovGovernor`
- [ ] Add `setNonCirculatingAddress()` function (governance-controlled)
- [ ] Implement `getCirculatingSupply()` function
- [ ] Override `quorum()` to use circulating supply
- [ ] Add events for transparency
- [ ] Update deployment scripts to set initial non-circulating addresses
- [ ] Update documentation
- [ ] Add tests for quorum calculation
- [ ] Test with various circulating supply scenarios

---

## Testing Scenarios

1. **Launch Scenario:**
   - Total: 1B, Circulating: 100M (10%)
   - Expected Quorum: 4M tokens (4% of 100M)

2. **Mid-Term Scenario:**
   - Total: 1B, Circulating: 500M (50%)
   - Expected Quorum: 20M tokens (4% of 500M)

3. **Full Unlock Scenario:**
   - Total: 1B, Circulating: 1B (100%)
   - Expected Quorum: 40M tokens (4% of 1B)

4. **Treasury Exclusion:**
   - Treasury holds 900M tokens
   - Verify treasury balance excluded from circulating supply

5. **Vesting Unlock:**
   - Vesting contract unlocks 100M tokens
   - Remove vesting contract from non-circulating list
   - Verify quorum increases proportionally

---

## Recommendation Summary

**✅ IMPLEMENTED: Absolute Quorum Approach (Selected Over Circulating Supply)**

**Decision:** After analysis, absolute quorum was selected for launch:
- Lower risk (simpler implementation)
- Easier to audit and verify
- Can be updated via governance
- Non-circulating tracking preserved for transparency/APIs
- Can migrate to circulating-based quorum later if desired

**Implementation:**
- ✅ Absolute quorum implemented (4M tokens)
- ✅ `quorum()` function returns `absoluteQuorum`
- ✅ Non-circulating addresses tracked (for transparency/APIs)
- ✅ `getCirculatingSupply()` fixed (uses balance for current block)
- ✅ Governance functions protected (timelock-only)

**Status:** ✅ **COMPLETE** - Ready for launch

**Note:** While circulating supply approach was analyzed, absolute quorum was selected for launch due to lower risk and simplicity. Infrastructure is in place to migrate to circulating-based quorum later if desired.
