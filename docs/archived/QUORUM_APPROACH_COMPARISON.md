# Quorum Calculation Approach Comparison

**Date:** 2026-01-28  
**Last Updated:** 2026-01-28 (Absolute Quorum Implemented)  
**Purpose:** Compare circulating supply-based quorum vs. absolute quorum approaches

**Status:** ✅ **IMPLEMENTED** - Absolute Quorum approach selected and implemented

---

## Two Approaches

### Approach 1: Circulating Supply-Based Quorum (Not Implemented)
- **Formula:** `quorum = (circulatingSupply * quorumNumerator) / 100`
- **Circulating Supply:** `totalSupply - sum(votingPower of nonCirculatingAddresses)`
- **Dynamic:** Automatically adjusts as tokens circulate
- **Complexity:** High (requires tracking non-circulating addresses)
- **Status:** ❌ Not implemented (too complex, high risk)

### Approach 2: Absolute Quorum (✅ **IMPLEMENTED**)
- **Formula:** `quorum = absoluteQuorumAmount` (e.g., 4M tokens)
- **Updates:** Via governance proposal (can increase as needed)
- **Static:** Fixed amount until governance updates it
- **Complexity:** Low (simple constant or storage variable)
- **Status:** ✅ **IMPLEMENTED** - Simple, safe, and ready for launch

---

## Risk Comparison Matrix

| Risk Category | Circulating Supply Approach | Absolute Quorum Approach |
|--------------|----------------------------|--------------------------|
| **Implementation Complexity** | 🔴 High | 🟢 Low |
| **Bug Surface Area** | 🔴 High | 🟢 Low |
| **Maintenance Burden** | 🔴 High | 🟢 Low |
| **Governance Attack Surface** | 🟡 Medium | 🟢 Low |
| **Accuracy/Flexibility** | 🟢 High | 🟡 Medium |
| **Gas Costs** | 🟡 Medium | 🟢 Low |
| **Historical Accuracy** | 🔴 Limited | 🟢 Perfect |
| **Automatic Scaling** | 🟢 Yes | 🔴 No (manual) |
| **User Understanding** | 🟡 Medium | 🟢 High |

---

## Detailed Risk Analysis

### 1. Implementation Complexity

#### Circulating Supply Approach 🔴 **HIGH RISK**

**Complexity Factors:**
- Requires tracking list of non-circulating addresses
- Need to iterate over addresses in quorum calculation
- Must handle address addition/removal via governance
- Historical block calculations have limitations
- Edge cases: delegation requirements, list/mapping sync

**Code Complexity:**
```solidity
// ~50 lines of code for tracking
mapping(address => bool) public nonCirculatingAddresses;
address[] public nonCirculatingAddressesList;

// ~20 lines for quorum calculation
function quorum(uint256 blockNumber) public view returns (uint256) {
    uint256 circulatingSupply = getCirculatingSupply(blockNumber);
    return (circulatingSupply * quorumNumerator()) / 100;
}

function getCirculatingSupply(uint256 blockNumber) public view returns (uint256) {
    // Iterate over list, check mapping, sum voting power
    // ~15 lines with edge case handling
}
```

**Risk Level:** 🔴 **HIGH**
- More code = more bugs
- Complex logic = harder to audit
- Edge cases can cause incorrect calculations

#### Absolute Quorum Approach 🟢 **LOW RISK**

**Complexity Factors:**
- Single storage variable
- Simple getter function
- Governance can update via proposal

**Code Complexity:**
```solidity
// ~5 lines of code
uint256 public absoluteQuorum;

function quorum(uint256 blockNumber) public view returns (uint256) {
    return absoluteQuorum; // Simple!
}
```

**Risk Level:** 🟢 **LOW**
- Minimal code = fewer bugs
- Simple logic = easy to audit
- No edge cases

**Winner:** 🟢 **Absolute Quorum** (much simpler)

---

### 2. Bug Surface Area

#### Circulating Supply Approach 🔴 **HIGH RISK**

**Known Bugs:**
1. ✅ **FOUND:** Non-delegated addresses not excluded (current issue)
2. ⚠️ **POTENTIAL:** List/mapping desynchronization
3. ⚠️ **POTENTIAL:** Historical block inaccuracy
4. ⚠️ **POTENTIAL:** Gas limit if too many addresses

**Bug Categories:**
- **Logic Bugs:** Incorrect calculation, edge cases
- **State Bugs:** List/mapping out of sync
- **Historical Bugs:** Past blocks inaccurate
- **Gas Bugs:** DoS if too many addresses

**Example Bug Scenarios:**
```solidity
// Bug 1: Address not excluded if not delegated
address vesting = 0x123;
token.transfer(vesting, 100M); // No delegation
governor.addNonCirculatingAddress(vesting);
// ❌ 100M still counted as circulating

// Bug 2: Historical block inaccuracy
// Block 1000: Address has 50M tokens, not delegated
// Block 2000: Address delegates, now has voting power
// getCirculatingSupply(1000) = incorrect (doesn't exclude 50M)
```

**Risk Level:** 🔴 **HIGH**
- Multiple bug vectors
- Complex interactions
- Hard to test all edge cases

#### Absolute Quorum Approach 🟢 **LOW RISK**

**Known Bugs:**
- None (too simple to have bugs)

**Bug Categories:**
- **Logic Bugs:** None (just returns a value)
- **State Bugs:** None (single variable)
- **Historical Bugs:** None (same value for all blocks)
- **Gas Bugs:** None (constant gas)

**Risk Level:** 🟢 **LOW**
- Minimal bug surface
- Simple logic
- Easy to verify correctness

**Winner:** 🟢 **Absolute Quorum** (much safer)

---

### 3. Maintenance Burden

#### Circulating Supply Approach 🔴 **HIGH RISK**

**Maintenance Tasks:**
1. **Add/Remove Addresses:** Governance must manage list
2. **Monitor Delegation:** Ensure addresses delegate (or fix calculation)
3. **Audit List:** Verify addresses are still non-circulating
4. **Update Logic:** Fix bugs as they're discovered
5. **Document Edge Cases:** Explain limitations to users

**Ongoing Costs:**
- Governance proposals to manage addresses
- Monitoring and verification
- Code updates for bug fixes
- Documentation updates

**Example Maintenance Scenario:**
```
Month 1: Deploy with vesting addresses
Month 3: Add new vesting contract (governance proposal)
Month 6: Remove old vesting contract (governance proposal)
Month 9: Discover bug - fix calculation
Month 12: Update documentation
```

**Risk Level:** 🔴 **HIGH**
- Ongoing governance overhead
- Requires active management
- Technical debt accumulates

#### Absolute Quorum Approach 🟢 **LOW RISK**

**Maintenance Tasks:**
1. **Update Quorum:** Governance can increase if needed (rare)
2. **Monitor Token Distribution:** Optional (for decision-making)

**Ongoing Costs:**
- Rare governance proposals (only when quorum needs adjustment)
- No code maintenance
- No address management

**Example Maintenance Scenario:**
```
Month 1: Deploy with 4M quorum
Month 12: Increase to 5M if needed (single governance proposal)
Year 2: Increase to 6M if needed (single governance proposal)
```

**Risk Level:** 🟢 **LOW**
- Minimal governance overhead
- Set-and-forget approach
- No technical debt

**Winner:** 🟢 **Absolute Quorum** (much less maintenance)

---

### 4. Governance Attack Surface

#### Circulating Supply Approach 🟡 **MEDIUM RISK**

**Attack Vectors:**
1. **Manipulate List:** Add/remove addresses to change quorum
2. **Timing Attacks:** Add address before tokens arrive, remove after
3. **Delegation Gaming:** Control delegation to affect circulating supply
4. **Complexity Exploitation:** Use bugs in calculation logic

**Example Attack:**
```
Attacker controls governance:
1. Add attacker's address to non-circulating list
2. Transfer tokens to address (but don't delegate)
3. Quorum doesn't change (bug!)
4. Use this to pass proposals with lower actual quorum
```

**Mitigations:**
- Timelock delays (48h)
- Governance transparency
- Community oversight

**Risk Level:** 🟡 **MEDIUM**
- More attack vectors
- Complex interactions
- Harder to detect manipulation

#### Absolute Quorum Approach 🟢 **LOW RISK**

**Attack Vectors:**
1. **Change Quorum:** Governance can increase/decrease
2. **That's it!** (too simple for complex attacks)

**Example Attack:**
```
Attacker controls governance:
1. Propose to change quorum
2. Community votes (transparent)
3. Timelock delay (48h)
4. Community can see change coming
```

**Mitigations:**
- Timelock delays (48h)
- Governance transparency
- Community oversight
- Simple change = easy to understand

**Risk Level:** 🟢 **LOW**
- Fewer attack vectors
- Simple interactions
- Easy to detect manipulation

**Winner:** 🟢 **Absolute Quorum** (simpler = safer)

---

### 5. Accuracy/Flexibility

#### Circulating Supply Approach 🟢 **HIGH ACCURACY**

**Benefits:**
- Automatically adjusts as tokens circulate
- Reflects actual economic reality
- No manual intervention needed
- Scales with token distribution

**Accuracy:**
- ✅ Accurate for current block (if fixed)
- ⚠️ Less accurate for historical blocks
- ✅ Automatically reflects token movements

**Example:**
```
Launch: 100M circulating → 4M quorum (4%)
Year 1: 200M circulating → 8M quorum (4%) - automatic
Year 2: 300M circulating → 12M quorum (4%) - automatic
```

**Risk Level:** 🟢 **LOW** (high accuracy, high flexibility)

#### Absolute Quorum Approach 🟡 **MEDIUM ACCURACY**

**Benefits:**
- Simple and predictable
- No calculation errors
- Same quorum for all blocks (historical accuracy)

**Limitations:**
- Doesn't automatically scale
- Requires manual updates
- May become too high or too low over time

**Example:**
```
Launch: 4M quorum (4% of 100M)
Year 1: 4M quorum (2% of 200M) - too low?
Year 2: 4M quorum (1.3% of 300M) - too low?
Need governance to increase to 8M, then 12M
```

**Risk Level:** 🟡 **MEDIUM** (requires manual updates)

**Winner:** 🟢 **Circulating Supply** (more accurate, more flexible)

---

### 6. Gas Costs

#### Circulating Supply Approach 🟡 **MEDIUM COST**

**Gas Costs:**
- Quorum calculation: ~5k-50k gas (depends on list length)
- Add address: ~50k gas
- Remove address: ~50k gas
- Iteration over addresses: O(n) where n = number of addresses

**Example:**
```
10 addresses: ~10k gas per quorum call
50 addresses: ~30k gas per quorum call
100 addresses: ~50k gas per quorum call (max)
```

**Risk Level:** 🟡 **MEDIUM**
- Acceptable but not optimal
- Scales with number of addresses
- Could be DoS vector if too many addresses

#### Absolute Quorum Approach 🟢 **LOW COST**

**Gas Costs:**
- Quorum calculation: ~100 gas (SLOAD)
- Update quorum: ~20k gas (SSTORE)
- No iteration needed

**Risk Level:** 🟢 **LOW**
- Minimal gas cost
- Constant time
- No DoS vector

**Winner:** 🟢 **Absolute Quorum** (much cheaper)

---

### 7. Historical Accuracy

#### Circulating Supply Approach 🔴 **LIMITED ACCURACY**

**Problem:**
- Historical blocks can only use `getPastVotes()` (voting power)
- If address didn't delegate at block N, tokens aren't excluded
- Creates inaccuracy in historical quorum calculations

**Example:**
```
Block 1000: Address has 50M tokens, not delegated
Block 2000: Address delegates
getCirculatingSupply(1000) = incorrect (doesn't exclude 50M)
```

**Risk Level:** 🔴 **HIGH**
- Historical calculations may be wrong
- Can't fix retroactively
- Affects proposal validation

#### Absolute Quorum Approach 🟢 **PERFECT ACCURACY**

**Benefit:**
- Same quorum for all blocks
- No historical calculation needed
- Perfect accuracy for all historical blocks

**Risk Level:** 🟢 **LOW**
- No historical inaccuracy
- Simple and correct

**Winner:** 🟢 **Absolute Quorum** (perfect historical accuracy)

---

### 8. Automatic Scaling

#### Circulating Supply Approach 🟢 **AUTOMATIC**

**Benefit:**
- Automatically adjusts as tokens circulate
- No governance intervention needed
- Always reflects current state

**Risk Level:** 🟢 **LOW** (high benefit)

#### Absolute Quorum Approach 🔴 **MANUAL**

**Limitation:**
- Requires governance to update
- May lag behind actual circulation
- Requires monitoring and proposals

**Risk Level:** 🟡 **MEDIUM** (requires active management)

**Winner:** 🟢 **Circulating Supply** (automatic scaling)

---

### 9. User Understanding

#### Circulating Supply Approach 🟡 **MEDIUM CLARITY**

**Complexity:**
- Users need to understand:
  - What is "circulating supply"?
  - Which addresses are non-circulating?
  - How is it calculated?
  - Why might it differ from total supply?

**Documentation Needs:**
- Explain calculation method
- List non-circulating addresses
- Explain edge cases
- Update as addresses change

**Risk Level:** 🟡 **MEDIUM**
- More complex to explain
- Requires more documentation

#### Absolute Quorum Approach 🟢 **HIGH CLARITY**

**Simplicity:**
- Users understand: "Quorum is 4M tokens"
- No calculation needed
- Easy to verify
- Transparent

**Documentation Needs:**
- Just state the quorum amount
- Explain how it can be updated

**Risk Level:** 🟢 **LOW**
- Simple to understand
- Easy to verify

**Winner:** 🟢 **Absolute Quorum** (much clearer)

---

## Risk Summary

### Circulating Supply Approach

**High Risks:**
- 🔴 Implementation complexity
- 🔴 Bug surface area
- 🔴 Maintenance burden
- 🔴 Historical accuracy limitations

**Benefits:**
- 🟢 Automatic scaling
- 🟢 High accuracy (when working)
- 🟢 Flexibility

**Overall Risk:** 🔴 **HIGH** - Complex, bug-prone, high maintenance

### Absolute Quorum Approach

**Low Risks:**
- 🟢 Implementation simplicity
- 🟢 Minimal bug surface
- 🟢 Low maintenance
- 🟢 Perfect historical accuracy

**Limitations:**
- 🔴 Manual updates required
- 🔴 Doesn't auto-scale

**Overall Risk:** 🟢 **LOW** - Simple, safe, low maintenance

---

## Recommendation

### For Launch: 🟢 **Absolute Quorum (4M tokens)**

**Rationale:**
1. **Lower Risk:** Simpler = fewer bugs = safer launch
2. **Proven Approach:** Many protocols use absolute quorum
3. **Easy to Understand:** Users can verify quorum easily
4. **Low Maintenance:** Set and forget
5. **Can Migrate Later:** Can switch to circulating supply approach via governance

**Implementation:**
```solidity
uint256 public constant INITIAL_QUORUM = 4_000_000 ether; // 4M tokens
uint256 public absoluteQuorum = INITIAL_QUORUM;

function quorum(uint256 /* blockNumber */) public view override returns (uint256) {
    return absoluteQuorum;
}

// Governance can update via proposal
function setAbsoluteQuorum(uint256 newQuorum) external {
    require(msg.sender == address(timelock()), 'Only timelock');
    require(newQuorum > 0, 'Quorum must be positive');
    absoluteQuorum = newQuorum;
    emit AbsoluteQuorumUpdated(newQuorum);
}
```

**Migration Path:**
- Start with absolute quorum (4M)
- Monitor token distribution
- If needed, increase via governance (e.g., to 5M, 6M)
- Later, can migrate to circulating supply approach if desired
- Migration requires governance proposal (can be done safely)

### For Future: Consider Circulating Supply (After Maturity)

**When to Consider:**
- After protocol is stable and battle-tested
- When token distribution is well-understood
- When community wants automatic scaling
- After fixing current bugs

**Migration Strategy:**
1. Deploy new governor with circulating supply logic
2. Test thoroughly
3. Governance proposal to upgrade
4. Community votes
5. Timelock execution

---

## Comparison Table: Quick Reference

| Factor | Circulating Supply | Absolute Quorum | Winner |
|--------|-------------------|----------------|--------|
| **Complexity** | High | Low | 🟢 Absolute |
| **Bug Risk** | High | Low | 🟢 Absolute |
| **Maintenance** | High | Low | 🟢 Absolute |
| **Gas Cost** | Medium | Low | 🟢 Absolute |
| **Historical Accuracy** | Limited | Perfect | 🟢 Absolute |
| **User Clarity** | Medium | High | 🟢 Absolute |
| **Auto-Scaling** | Yes | No | 🟢 Circulating |
| **Accuracy** | High (when working) | Medium | 🟢 Circulating |
| **Governance Attacks** | Medium | Low | 🟢 Absolute |

**Score:** Absolute Quorum: **7 wins** | Circulating Supply: **2 wins**

---

## Conclusion

**Recommendation:** 🟢 **Use Absolute Quorum for Launch**

**Reasons:**
1. **Safety First:** Lower risk = safer launch
2. **Simplicity:** Easier to audit and verify
3. **Proven:** Many successful protocols use this approach
4. **Flexible:** Can increase via governance as needed
5. **Migratable:** Can switch to circulating supply later if desired

**Action Plan:** ✅ **COMPLETE**
1. ✅ Implement absolute quorum (4M tokens)
2. ✅ Add governance function to update quorum (`setAbsoluteQuorum()`)
3. ✅ Document quorum update process (see GOVERNANCE_STRUCTURE.md)
4. ⏳ Monitor token distribution (post-launch)
5. ⏳ Increase quorum via governance if needed (e.g., when 4M becomes <2% of circulating)
6. ⏳ Consider migrating to circulating supply approach in future (optional)

**Risk Reduction:** 🔴 **HIGH RISK** → 🟢 **LOW RISK** ✅ **ACHIEVED**

**Status:** ✅ **IMPLEMENTED** - All code changes complete, ready for launch
