# Critical Fixes Required for v2 Architecture
## Validation Against Stated Invariants

**Purpose:** Identify where the v2 architecture document violates its own safety invariants, and provide surgical fixes to close the gaps.

---

## Summary Table

| Issue | Severity | Location | Violation | Fix |
|-------|----------|----------|-----------|-----|
| accepted not persisted | **CRITICAL** | BaseEscrow + AaveModule | Principal accounting incorrect | Store yieldPrincipal in escrow state |
| Balance check vulnerable | **CRITICAL** | _releaseEscrow | Can pass with pre-existing balance | Use delta check (balBefore/balAfter) |
| emergencyUnwind semantics | **CRITICAL** | _handleYieldAndGetActualAmount | "may be less" contradicts "must return or revert" | Pick strict (revert on 0) or permissive (define 0 meaning) |
| Partial recovery handling | **HIGH** | _releaseEscrow | Silently accepts partial principal | Emit PartialRecovery event or revert |
| Approve/pull pattern | **MEDIUM** | Fund flow | Increases allowance/reentrancy risk | Use direct transfer instead |
| Lido async assumption | **MEDIUM** | Examples | Doesn't fit synchronous interface | Remove Lido example; label v2 as sync-only |
| Registry token dimension | **LOW** | Module selection | Missing token-specific routing | Add token to registry key (optional for v1) |
| Aave shares handling | **LOW** | Module example | Incorrect pseudocode for V3 | Fix withdraw() call in example |

---

## Detailed Analysis

### Issue 1: ✋ CRITICAL - Accepted Not Persisted (Principal Accounting Violation)

**Violates:** INVARIANT 3 (Distribution Policy Canonical)

**The Problem:**

From the architecture doc:

```solidity
// IYieldModule interface says:
function initializeYield(...) returns (uint256 accepted)

// AaveYieldModule stores:
positions[msg.sender][escrowId] = YieldPosition({
    token: token,
    shares: aaveShares,
    initialAmount: amount  // ← WRONG: should be "accepted"
});
```

But in unwindToEscrow:

```solidity
// Module does:
principalOut = pos.initialAmount;  // ← Uses stored "initialAmount"
yieldOut = total > principalOut ? total - principalOut : 0;
```

And in BaseEscrow's _releaseEscrow:

```solidity
(uint256 principalOut, uint256 yieldOut) = _handleYieldAndGetActualAmount(...);
// ← No one stored or used the "accepted" value returned by initializeYield
```

**Why This Breaks:**

1. **Fee-on-transfer tokens:** If you try to deposit 100 USDT but only 99 get accepted (1 burned), the module stores 100 but only holds 99. On unwind, yield calculation is wrong.

2. **Partial-accept edge case:** A module might say "I only accept 95 of your 100 requested". The module stores that correctly, but the escrow has no idea 5 tokens remain.

3. **Your own stated requirement:** "principal = units deposited" (from the v2.5 feedback). Right now you're storing "units requested" instead.

**The Fix (Required):**

**Option A (Recommended): Store yieldPrincipal in escrow state**

```solidity
// In BaseEscrow
struct ModuleSnapshot {
    address yieldModule;
    uint256 yieldPrincipal;  // ← NEW: actual amount module accepted
}

function _initializeYield(...) internal {
    address mod = moduleSnapshots[workflowId].yieldModule;
    
    uint256 accepted = IYieldModule(mod).initializeYield(
        workflowId, token, principalAmount, yieldMode
    );
    
    // CRITICAL: Store what was actually accepted
    moduleSnapshots[workflowId].yieldPrincipal = accepted;
}

function _handleYieldAndGetActualAmount(...) internal returns (uint256, uint256) {
    uint256 yieldPrincipal = moduleSnapshots[workflowId].yieldPrincipal;
    
    try IYieldModule(mod).unwindToEscrow(workflowId, token, yieldPrincipal)
        returns (uint256 principal, uint256 yield) {
        return (principal, yield);
    } catch {
        // ... emergency unwind using yieldPrincipal
    }
}
```

**Option B: Store in module state (alternative)**

Module stores principalDeposited instead of initialAmount, and uses that for all yield calcs:

```solidity
struct YieldPosition {
    address token;
    uint256 shares;
    uint256 principalDeposited;  // ← "accepted" value, not requested
}

function initializeYield(...) returns (uint256 accepted) {
    // ... deposit to protocol ...
    positions[msg.sender][escrowId].principalDeposited = accepted;
    return accepted;
}

function unwindToEscrow(...) returns (uint256 principalOut, uint256 yieldOut) {
    uint256 principal = pos.principalDeposited;  // Use actual deposited
    // ... calculate yield relative to actual deposited ...
}
```

**Recommendation:** Use Option A (store in escrow). It makes yieldPrincipal explicit and matches your "store snapshots at creation time" pattern.

---

### Issue 2: ✋ CRITICAL - Balance Verification Vulnerable

**Violates:** INVARIANT 1 (No Silent Fund Loss)

**The Problem:**

From the current code:

```solidity
function _releaseEscrow(...) internal {
    (uint256 principalOut, uint256 yieldOut) = _handleYieldAndGetActualAmount(...);
    
    require(
        token.balanceOf(address(this)) >= principalOut + yieldOut,
        "YieldModule did not return funds"
    );
}
```

This check fails if:

1. Escrow already holds 100 USDC (from another escrow or dust)
2. Module successfully transfers 50 (principal) + 5 (yield) = 55
3. Check passes: balanceOf >= 55 ✓ (it has 155 total)
4. Core thinks funds came from module, but doesn't verify the delta

**Why This Breaks:**

- Module could return 0, but escrow balance is 100 from before → check passes
- You can't prove "module returned funds" vs "funds were already there"
- A faulty/malicious module can be invisible

**The Fix (Required):**

```solidity
function _releaseEscrow(...) internal {
    uint256 balBefore = token.balanceOf(address(this));  // ← Check BEFORE
    
    (uint256 principalOut, uint256 yieldOut) = _handleYieldAndGetActualAmount(...);
    
    // CRITICAL: Use delta, not absolute
    uint256 balAfter = token.balanceOf(address(this));
    uint256 received = balAfter >= balBefore ? balAfter - balBefore : 0;
    
    require(
        received >= principalOut + yieldOut,
        "YieldModule did not return promised funds"
    );
}
```

This **proves** the module returned funds on **this specific call**, not relying on pre-existing balance.

---

### Issue 3: ✋ CRITICAL - emergencyUnwind Semantics Inconsistent

**Violates:** INVARIANT 4 (Clear Recovery Semantics)

**The Problem:**

From the interface comment:

```solidity
/**
 * @notice Emergency recovery path
 * @return recovered Amount recovered (may be less than principal)
 * @dev Called after unwindToEscrow fails
 * @dev MUST return funds or REVERT (never silent loss)
 */
function emergencyUnwind(...) external returns (uint256 recovered);
```

But from the integration code:

```solidity
try IYieldModule(mod).emergencyUnwind(workflowId, token, principalAmount)
    returns (uint256 recovered) {
    
    if (recovered > 0) {
        // Partial recovery - yield is lost
        return (recovered, 0);
    } else {
        revert("YieldModuleRecoveryFailed");  // ← Only revert on 0
    }
}
```

**The Contradiction:**

The comment says "MUST return funds or REVERT" (strict semantics).  
The code says "return 0 is allowed, revert only if 0" (permissive semantics).  

This is **fundamentally inconsistent**. Either:

- **Strict:** emergencyUnwind should never return 0; if it can't recover, it must revert. (Guarantees: recovered > 0 always)
- **Permissive:** emergencyUnwind can return 0, meaning "attempted but got nothing". (Meaning defined, escape hatch available)

**Why This Matters:**

1. If a caller sees recovered == 0, they don't know if it's "I tried and got 0" or "I gave up"
2. The revert condition becomes unclear (revert on 0 implies 0 is recoverable, just unlucky)
3. The invariant "no silent loss" is ambiguous (what does 0 mean?)

**The Fix (Pick One):**

**Option A: Strict (Recommended)**

```solidity
/**
 * @notice Emergency recovery path
 * @return recovered Amount recovered (always > 0, or reverts)
 * @dev Called after unwindToEscrow fails
 * @dev MUST recover principal or REVERT (never return 0)
 * @dev If recovery impossible, revert with clear reason
 */
function emergencyUnwind(
    uint256 escrowId,
    address token,
    uint256 principalExpected
) external returns (uint256 recovered);

// In implementation:
function emergencyUnwind(...) external onlyEscrow returns (uint256) {
    // ... attempt withdrawal ...
    uint256 out = aavePool.withdraw(...);
    
    if (out == 0) {
        revert("EmergencyUnwind: No balance recovered; protocol may be down");
    }
    return out;
}

// In escrow integration:
try IYieldModule(mod).emergencyUnwind(...)
    returns (uint256 recovered) {
    // recovered > 0 guaranteed here; distribute it
    return (recovered, 0);
} catch {
    revert("YieldModuleUnwindFailed: emergency recovery did not succeed");
}
```

**Option B: Permissive (Alternative)**

```solidity
/**
 * @notice Emergency recovery path
 * @return recovered Amount recovered (may be 0 if impossible)
 * @dev Called after unwindToEscrow fails
 * @dev Returns what can be recovered; may be partial or zero
 * @dev Caller must handle zero appropriately
 */
function emergencyUnwind(...) external returns (uint256 recovered);

// In implementation:
function emergencyUnwind(...) external onlyEscrow returns (uint256) {
    try aavePool.withdraw(...) returns (uint256 out) {
        return out;  // Could be 0 if nothing was deposited
    } catch {
        return 0;  // Withdrawal failed; nothing recovered
    }
}

// In escrow integration:
try IYieldModule(mod).emergencyUnwind(...)
    returns (uint256 recovered) {
    
    if (recovered > 0) {
        return (recovered, 0);
    } else {
        // Explicit: no recovery possible
        revert("YieldModuleEmergency: Principal unrecoverable; escrow locked");
    }
}
```

**Strong recommendation: Use Option A (strict).** It's simpler, matches "MUST return or revert", and avoids ambiguity.

---

### Issue 4: 🔴 HIGH - Partial Recovery Silently Accepted

**Violates:** INVARIANT 3 (Distribution Policy Canonical)

**The Problem:**

From the code:

```solidity
if (recovered > 0) {
    // Partial recovery - yield is lost but principal recovered
    return (recovered, 0);  // ← Silent acceptance of less principal
}
```

This means:

1. User's escrow promised to release 100 USDC principal
2. Module recovers only 95 (5 lost to slippage/protocol)
3. Code calls `distribute(95, 0)` and emits `Release(95)`
4. User sees "Release" but gets 95, not 100

**Why This Breaks Product Logic:**

- Users expect escrow to be atomic: "Release with full principal or fail"
- Partial settlement is a critical semantic change
- It needs explicit handling in state machine (e.g., "PartialRelease" state)
- UI/caller won't know if they got shorted

**The Fix (Required):**

**Option A: Require full principal or revert**

```solidity
if (recovered > 0) {
    if (recovered < yieldPrincipal) {
        // Partial recovery is a critical error
        revert("YieldModuleEmergency: Recovered less than principal; funds lost");
    }
    // Full recovery; safe to distribute
    return (recovered, 0);
} else {
    revert(...);
}
```

**Option B: New state/event for partial settlement**

```solidity
if (recovered > 0) {
    if (recovered < yieldPrincipal) {
        // Log partial loss and create a "recovery" outcome state
        emit YieldRecoveryPartial(
            workflowId,
            recovered,      // what we got back
            yieldPrincipal, // what we tried to recover
            yieldPrincipal - recovered  // what was lost
        );
        
        // Keep escrow in "Recovered" state (not Released)
        // User must manually accept partial or retry
        positions[workflowId].status = Status.PartiallyRecovered;
        return (recovered, 0);
    }
}
```

**Strong recommendation: Use Option A for v1.** Partial settlement is a future feature, not part of the core invariant.

---

### Issue 5: 🟡 MEDIUM - Approve/Pull Pattern (Fund Flow Risk)

**Violates (indirectly):** INVARIANT 2 (Module Cannot Redirect Funds)

**The Problem:**

Current fund flow in diagram:

```
escrow.token.approve(module, principal)
module.initializeYield(...)
module deposits from escrow balance
```

Issues:

1. **Stale allowance:** If initializeYield only uses 95 of 100, 5 remains approved → module can pull it later
2. **USDT quirk:** USDT requires setting allowance to 0 before changing amount; this flow requires reset logic
3. **Reentrancy:** Approve can call arbitrary code (if token is untrusted)

**The Fix (Recommended):**

Use direct transfer (push) instead of approve (pull):

```solidity
// Current (pull model):
token.approve(module, principalAmount);
uint256 accepted = mod.initializeYield(...);

// Better (push model):
token.transfer(module, principalAmount);  // Module receives principal
uint256 accepted = mod.initializeYield(...);  // Module deposits what it has

// Module in Aave:
function initializeYield(...) external onlyEscrow returns (uint256 accepted) {
    uint256 available = token.balanceOf(address(this));  // What we received
    uint256 toDeposit = min(available, amount);
    
    aavePool.deposit(token, toDeposit, address(this), 0);
    
    // Send unused tokens back (if any)
    if (available > toDeposit) {
        token.transfer(msg.sender, available - toDeposit);
    }
    
    return toDeposit;
}
```

**Advantages:**

- No lingering allowances
- Fund flow is explicit (transfer, deposit, withdraw)
- Simpler for USDT/nonstandard tokens
- Module can't pull unexpected tokens later

---

### Issue 6: 🟡 MEDIUM - Lido Example Doesn't Fit Synchronous Interface

**Violates:** Architecture scope definition

**The Problem:**

From the doc:

```solidity
// Lido example assumes:
function unwindToEscrow(...) returns (uint256, uint256)
// But Lido unstaking is async (1-2 day queue)

// Can't synchronously return funds from an async protocol
```

Lido flow is:

1. stake(100) → get stETH immediately (synchronous)
2. requestUnstake(stETH) → get NFT receipt
3. Wait 1-2 days
4. Claim() → get ETH

The interface assumes step 2+3 happen in `unwindToEscrow()`, but you can't wait 1-2 days in a transaction.

**The Fix (Required for v1):**

Remove Lido from examples and explicitly state:

```markdown
## Protocol Scope (v2 - Synchronous Only)

v2 Interface assumes synchronous deposit/withdrawal:

✅ **Supported:**
- Aave (deposit → aToken immediately, withdraw immediately)
- Morpho (same as Aave)
- Curve (deposit → LP token immediately, withdraw immediately)

❌ **Not Supported (v2):**
- Lido (async unstaking, 1-2 day queue)
- Rocket Pool (same)
- Any protocol requiring async claims

**Why:** Core escrow must release atomically. Async protocols require a separate state machine for recovery.

**Future:** v3 will support async via separate "ClaimableYield" state.
```

---

### Issue 7: 🟢 LOW - Registry Missing Token Dimension

**Violates (indirectly):** Module selection flexibility

**The Problem:**

Current registry:

```solidity
mapping(YieldPreset preset => mapping(bytes32 protocolId => address module)) 
    public yieldModules;
```

But in practice:

- Aave V3 supports USDC, USDT, DAI on Ethereum
- But on Arbitrum, it supports different tokens
- Morpho supports subset of Aave tokens
- You end up calling canHandle() anyway to validate token

**The Fix (Optional for v1, helpful later):**

```solidity
// Better registry:
mapping(
    YieldPreset preset => 
    mapping(bytes32 protocolId => 
        mapping(address token => 
            address module
        )
    )
) public yieldModules;

function getYieldModule(
    YieldPreset preset,
    bytes32 protocolId,
    address token
) external view returns (address) {
    return yieldModules[preset][protocolId][token];
}
```

**For v1:** Keep it simple (current registry), rely on canHandle() for validation.

**For v2+:** Add token dimension when multi-token support becomes critical.

---

### Issue 8: 🟢 LOW - Aave Module Example Uses Incorrect shares Logic

**Violates:** Code correctness in example

**The Problem:**

From the pseudocode:

```solidity
// Module claims:
aavePool.withdraw(token, pos.shares, address(msg.sender))

// But Aave V3 signature is:
function withdraw(
    address asset,      // token address
    uint256 amount,     // amount of underlying (NOT aToken)
    address to
) external returns (uint256)
```

So `pos.shares` should actually be an amount, not shares. This confuses the implementation.

**The Fix (Update Example):**

```solidity
struct YieldPosition {
    address token;
    uint256 depositedAmount;  // ← Store what we deposited, not "shares"
}

function initializeYield(...) external onlyEscrow returns (uint256 accepted) {
    // Query balance before
    uint256 balBefore = token.balanceOf(address(this));
    
    // Deposit to Aave
    aavePool.deposit(token, amount, address(this), 0);
    
    // Track actual deposited
    uint256 balAfter = token.balanceOf(address(this));
    uint256 actualDeposited = balBefore - balAfter;  // Fee-on-transfer safe
    
    positions[msg.sender][escrowId] = YieldPosition({
        token: token,
        depositedAmount: actualDeposited
    });
    
    return actualDeposited;
}

function unwindToEscrow(...) external onlyEscrow returns (uint256, uint256) {
    YieldPosition memory pos = positions[msg.sender][escrowId];
    
    // Withdraw the full aToken balance (principal + yield as aTokens)
    uint256 aTokenBalance = aToken.balanceOf(address(this));
    uint256 received = aavePool.withdraw(
        pos.token,
        aTokenBalance,  // Withdraw all, not pos.shares
        address(msg.sender)
    );
    
    uint256 principal = pos.depositedAmount;
    uint256 yield = received > principal ? received - principal : 0;
    
    delete positions[msg.sender][escrowId];
    return (principal, yield);
}
```

---

## Summary: Fixes by Priority

### Must Fix Before Implementation (CRITICAL)

1. **Principal Accounting (Issue 1)**
   - Store yieldPrincipal in ModuleSnapshot
   - Use accepted value from initializeYield
   - Pass yieldPrincipal to unwindToEscrow, not originalAmount

2. **Balance Verification (Issue 2)**
   - Change from absolute check to delta check
   - Use balBefore and balAfter
   - Verify: received >= principalOut + yieldOut

3. **emergencyUnwind Semantics (Issue 3)**
   - Pick strict: revert on 0, never return 0
   - Update interface comment and code to match
   - Make invariant unambiguous

4. **Partial Recovery (Issue 4)**
   - Reject partial principal; require full recovery or revert
   - Don't silently accept less than promised

### Should Fix Before Implementation (HIGH)

5. **Approve/Pull Pattern (Issue 5)**
   - Switch to direct transfer (push)
   - Module receives principal, deposits from balance
   - Simpler, safer, no lingering allowances

6. **Lido Scope (Issue 6)**
   - Remove Lido from v2 examples
   - Explicitly mark v2 as synchronous-only
   - Plan async support for v3

### Can Fix Later (LOW)

7. **Registry Token Dimension (Issue 7)**
   - Current registry works with canHandle() fallback
   - Add token dimension in v2+

8. **Aave Example Clarity (Issue 8)**
   - Fix pseudocode to use depositedAmount, not shares
   - Update example to match V3 API

---

## Implementation Checklist

Before starting Session 1, update ARCHITECTURE_YIELD_MODULES_V2.md:

- [ ] Fix Issue 1: Add yieldPrincipal to ModuleSnapshot (CRITICAL)
- [ ] Fix Issue 2: Change balance check to delta (CRITICAL)
- [ ] Fix Issue 3: Make emergencyUnwind strict (revert on 0) (CRITICAL)
- [ ] Fix Issue 4: Reject partial recovery (CRITICAL)
- [ ] Fix Issue 5: Switch to direct transfer (push model) (HIGH)
- [ ] Fix Issue 6: Remove Lido; mark v2 sync-only (HIGH)
- [ ] Fix Issue 8: Update Aave example pseudocode (LOW)
- [ ] Mark Issue 7 as v2+ enhancement (optional)

