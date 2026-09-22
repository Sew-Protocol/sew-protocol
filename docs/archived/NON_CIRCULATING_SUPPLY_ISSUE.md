# Non-Circulating Supply Tracking Issue Analysis

**Date:** 2026-01-28  
**Last Updated:** 2026-01-28 (Implementation of Absolute Quorum + Fixed Circulating Supply)  
**Status:** ✅ **RESOLVED** - Issue fixed, absolute quorum implemented

---

## Problem Statement

Recent change to track non-circulating addresses was not functional for quorum calculation. The implementation has been updated to use absolute quorum for governance, while keeping non-circulating tracking for transparency/APIs.

---

## Current Implementation

### Code Location
- **File:** `contracts/governance/GovGovernor.sol`
- **Functions:**
  - `getCirculatingSupply(uint256 blockNumber)` - Lines 135-154
  - `addNonCirculatingAddress(address addr)` - Lines 170-182
  - `removeNonCirculatingAddress(address addr)` - Lines 190-210

### Implementation Details

```solidity
function getCirculatingSupply(uint256 blockNumber) public view returns (uint256) {
    IVotes token = token();
    uint256 totalSupply = token.getPastTotalSupply(blockNumber);
    uint256 nonCirculating = 0;

    // Sum voting power of all non-circulating addresses
    uint256 length = nonCirculatingAddressesList.length;
    for (uint256 i = 0; i < length; i++) {
        address addr = nonCirculatingAddressesList[i];
        if (nonCirculatingAddresses[addr]) {  // ⚠️ Redundant check?
            nonCirculating += token.getPastVotes(addr, blockNumber);
        }
    }

    unchecked {
        return totalSupply - nonCirculating;
    }
}
```

---

## Potential Issues

### 1. **Redundant Check in Loop** ⚠️

**Issue:**
The check `if (nonCirculatingAddresses[addr])` inside the loop is redundant because:
- We're iterating over `nonCirculatingAddressesList`, which should only contain addresses that are in the mapping
- The check protects against list/mapping desynchronization, but this shouldn't happen in normal operation

**Impact:**
- Low - The check is safe but may hide bugs
- If list and mapping get out of sync, addresses might be skipped silently

**Analysis:**
- The check is actually **necessary** because of how `removeNonCirculatingAddress()` works:
  1. It deletes from mapping first: `delete nonCirculatingAddresses[addr]`
  2. Then removes from array (swap and pop)
- However, in a view function, this shouldn't matter since we're reading state atomically

**Recommendation:**
- Keep the check for safety, but investigate if list/mapping can get out of sync
- Add invariant tests to ensure list and mapping stay synchronized

---

### 2. **Voting Power vs Balance Mismatch** 🔴 **LIKELY ISSUE**

**Issue:**
`getPastVotes(addr, blockNumber)` returns **voting power** (delegated), not **token balance**.

**Problem Scenario:**
```
1. Address receives 100M tokens (but hasn't delegated)
2. Address is added to non-circulating list
3. getPastVotes() returns 0 (no voting power)
4. Circulating supply calculation doesn't exclude these tokens ❌
```

**Impact:**
- **HIGH** - If non-circulating addresses haven't delegated, their tokens won't be excluded
- This defeats the purpose of tracking non-circulating addresses

**Current Behavior:**
- Non-circulating addresses must **delegate** their voting power for it to be excluded
- If tokens are transferred to a non-circulating address but not delegated, they're still counted as circulating

**Example:**
```solidity
// Setup
address vestingContract = 0x123;
token.transfer(vestingContract, 100M tokens);
// ❌ Missing: token.delegate(vestingContract);

// Add to non-circulating
governor.addNonCirculatingAddress(vestingContract);

// Check circulating supply
uint256 circulating = governor.getCirculatingSupply(block.number);
// ❌ Problem: 100M tokens are still counted as circulating
// Because getPastVotes(vestingContract) returns 0 (not delegated)
```

**Root Cause:**
- `getPastVotes()` only returns voting power if the address has delegated
- If tokens are held but not delegated, voting power is 0
- The implementation assumes non-circulating addresses will delegate

**Recommendation:**
- **Option 1:** Use `getPastTotalSupply()` and subtract `balanceOf()` for non-circulating addresses
  - Problem: `balanceOf()` doesn't have historical lookups
  - Would need to track historical balances (complex)
  
- **Option 2:** **Document requirement** that non-circulating addresses must delegate
  - Add validation in `addNonCirculatingAddress()` to check if address has delegated
  - Or add a check that warns if voting power is 0
  
- **Option 3:** Use `getPastVotes()` but also check current balance
  - For current block: `circulating = totalSupply - sum(getPastVotes(nonCirculating)) - sum(balanceOf(nonCirculating))`
  - For historical blocks: Only use `getPastVotes()` (limitation)

---

### 3. **Historical Block Calculation Limitation** 🟡

**Issue:**
For historical blocks, we can only use `getPastVotes()` because `balanceOf()` doesn't have historical lookups.

**Problem:**
- If a non-circulating address received tokens but didn't delegate at block N
- We can't exclude those tokens when calculating circulating supply for block N
- This is a fundamental limitation of ERC20Votes

**Impact:**
- **MEDIUM** - Historical quorum calculations may be inaccurate
- Current block calculations can be fixed (see Option 3 above)

**Recommendation:**
- Document this limitation
- For current block, consider hybrid approach (voting power + balance)
- For historical blocks, accept limitation (only exclude if delegated)

---

### 4. **List/Mapping Synchronization** 🟡

**Issue:**
The `removeNonCirculatingAddress()` function:
1. Deletes from mapping first
2. Then removes from array

**Potential Race Condition:**
- If `getCirculatingSupply()` is called between steps 1 and 2, the address won't be excluded
- However, this is a single transaction, so it shouldn't matter

**Analysis:**
- The order is actually correct (delete mapping first prevents re-adding)
- The redundant check in `getCirculatingSupply()` protects against this
- Not a real issue in practice

**Recommendation:**
- Keep current implementation
- The redundant check is actually necessary for safety

---

## Verification Steps

### 1. Test Current Behavior

```solidity
// Test: Non-circulating address without delegation
address vesting = 0x123;
token.transfer(vesting, 100M);
// ❌ Don't delegate
governor.addNonCirculatingAddress(vesting);

uint256 circulating = governor.getCirculatingSupply(block.number);
// Expected: Should exclude 100M
// Actual: Probably doesn't exclude (if not delegated)
```

### 2. Test With Delegation

```solidity
// Test: Non-circulating address WITH delegation
address vesting = 0x123;
token.transfer(vesting, 100M);
token.delegate(vesting); // ✅ Delegate
governor.addNonCirculatingAddress(vesting);

uint256 circulating = governor.getCirculatingSupply(block.number);
// Expected: Should exclude 100M
// Actual: Should work correctly
```

### 3. Check Test Suite

Review `test/foundry/governance/CirculatingSupplyQuorum.t.sol`:
- Line 63-66: Non-circulating addresses DO delegate in tests
- This is why tests pass, but real-world usage might fail

---

## Recommended Fixes

### Fix 1: Add Delegation Check (Quick Fix)

```solidity
function addNonCirculatingAddress(address addr) external {
    require(msg.sender == address(timelock()), 'Only timelock');
    require(addr != address(0), 'Zero address');
    require(!nonCirculatingAddresses[addr], 'Already added');
    require(
        nonCirculatingAddressesList.length < MAX_NON_CIRCULATING_ADDRESSES,
        'Max addresses reached'
    );

    // ⚠️ WARNING: Address must delegate voting power for exclusion to work
    // Check if address has voting power (delegated)
    IVotes token = token();
    uint256 votingPower = token.getVotes(addr);
    if (votingPower == 0) {
        // Emit warning event (don't revert - allow adding)
        emit NonCirculatingAddressAddedWithoutVotingPower(addr);
    }

    nonCirculatingAddresses[addr] = true;
    nonCirculatingAddressesList.push(addr);
    emit NonCirculatingAddressAdded(addr);
}
```

### Fix 2: Hybrid Approach for Current Block (Better Fix)

```solidity
function getCirculatingSupply(uint256 blockNumber) public view returns (uint256) {
    IVotes token = token();
    uint256 totalSupply = token.getPastTotalSupply(blockNumber);
    uint256 nonCirculating = 0;

    uint256 length = nonCirculatingAddressesList.length;
    for (uint256 i = 0; i < length; i++) {
        address addr = nonCirculatingAddressesList[i];
        if (nonCirculatingAddresses[addr]) {
            // For current block, use both voting power and balance
            if (blockNumber == block.number) {
                uint256 votingPower = token.getVotes(addr);
                uint256 balance = IERC20(address(token)).balanceOf(addr);
                // Use maximum of voting power and balance (covers both cases)
                nonCirculating += votingPower > balance ? votingPower : balance;
            } else {
                // For historical blocks, only voting power is available
                nonCirculating += token.getPastVotes(addr, blockNumber);
            }
        }
    }

    unchecked {
        return totalSupply - nonCirculating;
    }
}
```

**Problem with Fix 2:**
- Assumes token is ERC20 (need to cast)
- May double-count if address has both voting power and balance
- Better approach: Use `max(votingPower, balance)` or just `balance` for current block

### Fix 3: Use Balance for Current Block (Recommended)

```solidity
function getCirculatingSupply(uint256 blockNumber) public view returns (uint256) {
    IVotes token = token();
    uint256 totalSupply = token.getPastTotalSupply(blockNumber);
    uint256 nonCirculating = 0;

    uint256 length = nonCirculatingAddressesList.length;
    for (uint256 i = 0; i < length; i++) {
        address addr = nonCirculatingAddressesList[i];
        if (nonCirculatingAddresses[addr]) {
            if (blockNumber == block.number) {
                // For current block, use balance (more accurate)
                // Voting power might be less than balance if not fully delegated
                nonCirculating += IERC20(address(token)).balanceOf(addr);
            } else {
                // For historical blocks, use voting power (only available historical data)
                nonCirculating += token.getPastVotes(addr, blockNumber);
            }
        }
    }

    unchecked {
        return totalSupply - nonCirculating;
    }
}
```

**Benefits:**
- ✅ Accurate for current block (uses actual token balance)
- ✅ Works even if address hasn't delegated
- ⚠️ Historical blocks still limited to voting power

**Trade-offs:**
- Requires ERC20 interface (need to import/cast)
- Historical calculations may be less accurate
- But current block (used for quorum) will be accurate

---

## Impact Assessment

### Current State
- **Functionality:** Partially working
- **Issue:** Only excludes voting power, not balance
- **Impact:** Non-circulating addresses must delegate for exclusion to work

### After Fix
- **Functionality:** Fully working for current block
- **Issue:** Historical blocks still limited (acceptable)
- **Impact:** Accurate circulating supply calculation for quorum

---

## Next Steps

1. **Verify Issue:** Test with non-delegated non-circulating address
2. **Implement Fix 3:** Use balance for current block, voting power for historical
3. **Update Tests:** Add test case for non-delegated address
4. **Update Documentation:** Document requirement for historical blocks

---

## Related Files

- `contracts/governance/GovGovernor.sol` - Main implementation
- `test/foundry/governance/CirculatingSupplyQuorum.t.sol` - Test suite
- `deploy/40_governor.ts` - Deployment script
- `docs/security/FUNCTIONAL_ECONOMIC_DESIGN_REVIEW.md` - Design review

---

**Status:** ✅ **RESOLVED** - Implementation updated:
- ✅ **Absolute Quorum Implemented:** Quorum now uses absolute amount (4M tokens) instead of circulating supply percentage
- ✅ **Circulating Supply Fixed:** `getCirculatingSupply()` now uses `balanceOf()` for current block (works even if not delegated)
- ✅ **Tracking Preserved:** Non-circulating addresses still tracked for transparency/APIs (CoinGecko, etc.)
- ✅ **Governance Functions:** `setAbsoluteQuorum()` and address management are timelock-protected

**Current Implementation:**
- Quorum: Absolute amount (4M tokens) - simple and safe
- Circulating Supply: Uses balance for current block, voting power for historical
- Non-Circulating Tracking: For external APIs only, not used for quorum
