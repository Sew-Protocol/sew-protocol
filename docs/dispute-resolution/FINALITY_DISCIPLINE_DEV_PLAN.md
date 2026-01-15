# Finality Discipline + Pull Model Migration: Development Plan

**Date:** Current  
**Purpose:** Implement appeal-window-safe settlement (finality discipline) with pull-model withdrawals  
**Priority:** Critical (2026 Ethereum-native "must have")  
**Approach:** Migrate to pull model first, then add appeal window enforcement

---

## Overview

This plan implements two critical improvements:

1. **Pull model migration** (withdrawEscrow pattern): Replace push payments with claimable balances
2. **Appeal window enforcement** (finality discipline): No funds move until appeal window expires

**Rationale for doing pull model first:**
- Simplifies the appeal-window fix (finalization is pure state, withdrawals are separate)
- Reduces reentrancy surface in critical dispute logic
- Enables continuous splits (1-99%) without single-point-of-failure
- Makes resolver compensation fairer (payouts withdrawable after finality)

---

## Phase 0: Pull Model Migration (Foundation)

**Goal:** Migrate from push payments (`_transferTokens` during finalization) to pull pattern (`withdrawEscrow`).  
**Timing:** Do this **before** appeal window enforcement.  
**Impact:** All DR phases (v1/v2/v3)

### Design: Claimable Balance Ledger

**Core concept:**
- Store `claimable[workflowId][recipient][token] = amount` (computed at finalization)
- Parties call `withdrawEscrow(workflowId, token)` to pull funds
- Finalization becomes pure state transition (no external transfers)

**State machine addition:**
```
... → FINALIZED → WITHDRAWABLE (claimable balances set)
```

### Changes Required

#### 0.1 Add Claimable Balance Storage

**File:** `contracts/core/BaseEscrow.sol`

- Add mapping: `mapping(uint256 => mapping(address => mapping(address => uint256))) public claimable;` (workflowId → recipient → token → amount)
- Add event: `event ClaimableBalanceSet(uint256 indexed workflowId, address indexed recipient, address indexed token, uint256 amount);`
- Add event: `event EscrowWithdrawn(uint256 indexed workflowId, address indexed recipient, address indexed token, uint256 amount);`

**Tests:**
- Verify claimable balances are set correctly at finalization
- Verify withdrawals are idempotent (set to 0 before transfer)
- Verify multiple recipients can withdraw independently

#### 0.2 Modify Finalization Functions (Remove Push Transfers)

**File:** `contracts/core/BaseEscrow.sol`

**Functions to modify:**
- `_executeFullResolution()`: Remove `_transferTokens()` call; instead set `claimable[workflowId][recipient][token] = amount`
- `_executePartialResolution()`: Remove `_transferTokens()` call; instead set `claimable[workflowId][recipient][token] = result.actualAmount`
- `_cancelAndRefund()`: Remove `_transferTokens()` call; set claimable for sender
- `_releaseEscrowTransfer()`: Remove `_transferTokens()` call; set claimable for recipient

**Invariant:**
- Finalization functions must **never** call `_transferTokens()` directly
- All token movement happens in `withdrawEscrow()`

#### 0.3 Add `withdrawEscrow()` Function

**File:** `contracts/core/BaseEscrow.sol`

```solidity
function withdrawEscrow(uint256 workflowId, address token) external nonReentrant returns (uint256) {
    _validateWorkflowId(workflowId);
    EscrowTransfer storage et = escrowTransfers[workflowId];
    
    // Verify escrow is finalized (or released/cancelled)
    require(
        et.escrowState == EscrowState.RESOLVED ||
        et.escrowState == EscrowState.RELEASED ||
        et.escrowState == EscrowState.REFUNDED,
        "Not finalized"
    );
    
    uint256 amount = claimable[workflowId][msg.sender][token];
    require(amount > 0, "No claimable balance");
    
    // Idempotent: set to 0 before transfer
    claimable[workflowId][msg.sender][token] = 0;
    
    _updateEscrowBalance(token, amount, false);
    _transferTokens(token, msg.sender, amount);
    
    emit EscrowWithdrawn(workflowId, msg.sender, token, amount);
    return amount;
}
```

**Security:**
- `nonReentrant` guard
- Set claimable to 0 before transfer (checks-effects-interactions)
- Verify escrow is in final state

#### 0.4 Handle Yield + Fees in Pull Model

**File:** `contracts/core/BaseEscrow.sol`

**Yield distribution:**
- At finalization, compute yield-to-distribute
- Set `claimable[workflowId][buyer][token] += yieldBuyerShare`
- Set `claimable[workflowId][seller][token] += yieldSellerShare`
- Yield withdrawals use the same `withdrawEscrow()` path

**Fee distribution (if paid from escrow):**
- Set `claimable[workflowId][feeRecipient][token] = feeAmount`
- Or handle separately if fees go to treasury immediately

#### 0.5 Edge Cases

**Non-standard ERC20 tokens:**
- Pull model isolates risk to withdrawal calls (not finalization)
- Document that token hooks may revert withdrawals (user's problem, not protocol failure)

**Griefing by never withdrawing:**
- Not a protocol safety issue
- Optional: time-locked sweep to recovery address after long period (controversial; recommend not implementing in v1)

**Continuous splits (1-99%):**
- Store `claimable[buyer]` and `claimable[seller]` separately
- Each party withdraws independently
- No single withdrawal failure blocks the other

---

## Phase 1: DR v1 Changes (Fee-only Escalation + Appeal Window)

**Goal:** Add appeal window enforcement for fee-only escalation (no bonds yet).  
**Assumes:** Pull model migration is complete.

### Design: Decision → Appeal Window → Finalization → Withdrawable

**State machine:**
```
DISPUTED_OPEN → DECIDED_PENDING_APPEAL → FINALIZABLE → FINALIZED → WITHDRAWABLE
                                       ↓ (if escalated)
                                    ESCALATED → DISPUTED_OPEN (next round)
```

### Changes Required

#### 1.1 Modify Resolution Recording Order

**File:** `contracts/core/BaseEscrow.sol`

**Function:** `_executeResolution()` (internal entry point)

**Current behavior:**
1. Transfer tokens (PUSH) ❌
2. Call `recordResolution()` ❌
3. Set state to `RESOLVED` ❌

**Target behavior:**
1. Call `recordResolution()` **first** (sets appeal deadline in module)
2. Query appeal deadline from resolution module
3. If appeal window = 0 (final level) → finalize immediately
4. Else → store pending settlement, emit `PendingSettlement` event
5. Set escrow state to `DISPUTED` (or new `DECIDED_PENDING_APPEAL` state)

#### 1.2 Add Pending Settlement Storage

**File:** `contracts/core/BaseEscrow.sol`

**Storage:**
```solidity
struct PendingSettlement {
    bool exists;
    bool isRelease;
    uint256 amount;
    uint256 appealDeadline;
    uint8 round;
    bytes32 resolutionHash;
}
mapping(uint256 => PendingSettlement) public pendingSettlements;
```

**Logic:**
- Set when resolution is recorded (if appeal window > 0)
- Cancel when escalation happens
- Finalize when appeal window expires

#### 1.3 Add `finalizeAfterAppealWindow()` Function

**File:** `contracts/core/BaseEscrow.sol`

```solidity
function finalizeAfterAppealWindow(uint256 workflowId) external nonReentrant {
    _validateWorkflowId(workflowId);
    PendingSettlement storage pending = pendingSettlements[workflowId];
    require(pending.exists, "No pending settlement");
    require(block.timestamp >= pending.appealDeadline, "Appeal window not expired");
    
    // Check if escalated (status should be DECIDED, not ESCALATED)
    IResolutionModule module = _getResolutionModule(workflowId);
    // Query module: disputeMetadata[workflowId].status
    // If status == Escalated, revert (cancelled by escalation)
    
    // Finalize: set claimable balances
    EscrowTransfer storage et = escrowTransfers[workflowId];
    address recipient = pending.isRelease ? et.to : et.from;
    
    // Handle yield
    if (address(yieldOps) != address(0)) {
        // ... yield handling
    }
    
    // Set claimable (pull model)
    claimable[workflowId][recipient][et.token] += pending.amount;
    
    // Update state
    et.escrowState = EscrowState.RESOLVED;
    delete pendingSettlements[workflowId];
    
    emit EscrowFinalized(workflowId, recipient, pending.amount);
}
```

#### 1.4 Update `escalateDispute()` to Cancel Pending Settlement

**File:** `contracts/core/BaseEscrow.sol`

**Function:** `escalateDispute()`

**Add logic:**
- Before executing escalation, check if `pendingSettlements[workflowId].exists`
- If exists, delete it (cancel pending settlement)
- Emit `PendingSettlementCancelled(workflowId)` event

**Invariant:**
- Escalation deterministically cancels any pending settlement
- Funds never move during appeal window

#### 1.5 Handle Final-Level Resolutions (Immediate Finalization)

**File:** `contracts/core/BaseEscrow.sol`

**Function:** `_executeResolution()`

**Logic:**
- After calling `recordResolution()`, query `appealWindows[currentRound]` from module
- If `appealWindows[currentRound] == 0` (e.g., Kleros round):
  - Finalize immediately (set claimable balances)
  - Skip pending settlement storage
  - Set state to `RESOLVED`

**Tests:**
- Verify final-level resolutions (round 2) finalize immediately
- Verify non-final resolutions require appeal window expiry

#### 1.6 Add EscrowState for Pending Settlement (Optional)

**File:** `contracts/core/BaseEscrow.sol` (if enum needs extension)

**Consideration:**
- Current `EscrowState` enum: `PENDING`, `DISPUTED`, `RESOLVED`, `RELEASED`, `REFUNDED`
- Option A: Reuse `DISPUTED` (simpler, but less explicit)
- Option B: Add `DECIDED_PENDING_APPEAL` state (more explicit, requires enum change)

**Recommendation:** Option A for v1 (reuse `DISPUTED`), Option B can be added later if needed

#### 1.7 Integration with DecentralizedResolutionModule

**File:** `contracts/core/BaseEscrow.sol`

**Query functions needed:**
- Query `appealDeadline[currentRound]` from resolution module
- Query `status` (Decided vs Escalated) from resolution module
- Query `appealWindows[currentRound]` to check if final level

**Interface additions (if needed):**
- Add view function to `IResolutionModule`: `getAppealDeadline(uint256 workflowId, uint8 round) returns (uint256)`
- Or: expose `disputeMetadata[workflowId].appealDeadline[round]` as public

---

## Phase 2: DR v2 Changes (Appeal Bonds + Pull Model)

**Goal:** Add appeal bonds (curve-configured) while maintaining pull model and appeal window enforcement.  
**Assumes:** DR v1 changes are complete (appeal window enforced, pull model working).

### Design: Bond Collection → Appeal Window → Bond Distribution (via Incentive Module)

**Key insight:** Appeal bonds are collected **before** escalation, but distribution happens **after** the next round's decision (via incentive module).

### Changes Required

#### 2.1 Bond Collection (Pull Model Compatible)

**File:** `contracts/core/BaseEscrow.sol` or `contracts/DisputeOps.sol`

**Function:** `escalateDispute()` (already collects escalation fee)

**Add bond collection:**
- Query required bond from resolution module (via incentive module or path config)
- Collect bond from escalator (same pattern as escalation fee)
- Store bond custody: `appealBonds[workflowId][round] = { depositor, amount, token }`
- Bond is held in escrow contract (or dedicated custody)

**Important:** Bond collection doesn't violate pull model because:
- Bonds are collected **separately** from finalization
- Bonds are held in custody (not transferred to recipient yet)
- Bond distribution happens later (via incentive module)

#### 2.2 Bond Distribution (Via Incentive Module, Pull Model)

**File:** `contracts/core/BaseEscrow.sol` or incentive module integration

**Logic:**
- After round k+1 decision is recorded, incentive module computes distribution
- If appeal succeeds (`decision[k+1] != decision[k]`): refund bond to escalator
- If appeal fails: bond goes to prior resolver set (or treasury/protocol cut)

**Distribution pattern (pull model):**
- Set `claimable[workflowId][recipient][token] = bondAmount` (or refundAmount)
- Recipients call `withdrawEscrow()` to claim
- Or: incentive module has separate withdrawal path for bond payouts

**Recommendation:** Use same `claimable` ledger for bonds (simpler UX)

#### 2.3 Integration with Incentive Module

**File:** `contracts/decentralized-resolution-module/DecentralizedResolutionModule.sol`

**Events to emit:**
- `AppealBondPosted(workflowId, round, depositor, amount, token)`
- `AppealBondDistributionComputed(workflowId, round, recipient, amount, token, reason)`

**Incentive module hooks:**
- `onAppealBondPosted(workflowId, round, depositor, amount)` - record bond custody
- `onRoundDecisionRecorded(workflowId, round, outcome)` - compute bond distribution when next round decides
- `distributeAppealBond(workflowId, round)` - set claimable balances for bond payouts

#### 2.4 Bond Curve Configuration (Path Config)

**File:** `contracts/decentralized-resolution-module/DecentralizedResolutionModule.sol`

**Add to path config (future):**
- Per-round bond curve parameters (base, step, curve type)
- Distribution policy (refund on success, pay resolver on failure)

**For now (v2):**
- Bond requirements can be computed in incentive module
- Path config integration can be deferred to v3

---

## Phase 3: DR v3 Changes (Resolver Staking + Pull Model)

**Goal:** Ensure resolver compensation (staking rewards, slash distributions) works with pull model.  
**Assumes:** DR v1/v2 changes are complete.

### Design: Resolver Payouts → Withdrawable After Finality

**Key insight:** Resolver payments (fees, bond rewards) should also use pull model for fairness and simplicity.

### Changes Required

#### 3.1 Resolver Fee Distribution (Pull Model)

**File:** `contracts/core/BaseEscrow.sol` or incentive module

**Current behavior (if any):**
- Resolvers might receive payments during finalization (push)

**Target behavior:**
- Compute resolver payments at finalization
- Set `claimable[workflowId][resolver][token] = paymentAmount`
- Resolvers call `withdrawEscrow(workflowId, token)` or dedicated `withdrawResolverPayment()` function

**Benefits:**
- Prevents "pay resolver, then appeal reverses decision" awkwardness
- Resolver payments only withdrawable after outcome is final
- Aligns with "court" framing (resolvers are service providers, not immediate beneficiaries)

#### 3.2 Slash Distribution (Insurance Pool + Pull Model)

**File:** `contracts/decentralized-resolution-module/InsurancePoolVault.sol`

**Already implemented (check):**
- Insurance pool uses pull model for payouts (slow lane governance)
- Slashed funds go to pool
- Payouts are proposed → activated → withdrawn

**Verification:**
- Ensure insurance pool payouts use pull pattern (not push)
- If not, migrate to `withdrawInsurancePayout()` pattern

#### 3.3 Integration with Staking/Slashing Modules

**File:** `contracts/decentralized-resolution-module/ResolverStakingModuleV1.sol`  
**File:** `contracts/decentralized-resolution-module/ResolverSlashingModuleV1.sol`

**No changes needed:**
- Staking/slashing modules operate independently of escrow settlement
- Slashed funds go to insurance pool (already pull-model)
- Stake locks/unlocks are separate from escrow withdrawals

---

## Testing Strategy

### Phase 0 Tests (Pull Model Migration)

**File:** `test/foundry/core/BaseEscrowPullModel.t.sol` (new)

**Test cases:**
- ✅ `test_WithdrawEscrow_FullResolution()` - buyer/seller can withdraw after finalization
- ✅ `test_WithdrawEscrow_PartialResolution()` - partial splits work independently
- ✅ `test_WithdrawEscrow_ContinuousSplit()` - 1% buyer, 99% seller both withdraw independently
- ✅ `test_WithdrawEscrow_YieldDistribution()` - yield added to claimable, withdrawable separately
- ✅ `test_WithdrawEscrow_Idempotent()` - multiple withdrawals fail after balance exhausted
- ✅ `test_WithdrawEscrow_NonFinalEscrow()` - withdrawal fails if escrow not finalized
- ✅ `test_WithdrawEscrow_NonStandardToken()` - withdrawal reverts on token hook failure (doesn't break finalization)

### Phase 1 Tests (Appeal Window Enforcement)

**File:** `test/foundry/core/BaseEscrowAppealWindow.t.sol` (new)

**Test cases:**
- ✅ `test_FinalizeAfterAppealWindow_Success()` - can finalize after appeal window expires
- ✅ `test_FinalizeAfterAppealWindow_TooEarly()` - finalization fails before appeal deadline
- ✅ `test_FinalizeAfterAppealWindow_Escalated()` - finalization fails if escalated during window
- ✅ `test_EscalationCancelsPendingSettlement()` - escalation deletes pending settlement
- ✅ `test_FinalLevel_ImmediateFinalization()` - round 2 (Kleros) finalizes immediately
- ✅ `test_AppealWindow_TwoDayRoundZero()` - round 0 has 2-day appeal window
- ✅ `test_AppealWindow_ThreeDayRoundOne()` - round 1 has 3-day appeal window
- ✅ `test_RecordResolutionBeforeFinalization()` - `recordResolution()` called before claimable set

### Phase 2 Tests (Appeal Bonds + Pull Model)

**File:** `test/foundry/core/BaseEscrowAppealBonds.t.sol` (new)

**Test cases:**
- ✅ `test_AppealBondCollection()` - bond collected during escalation
- ✅ `test_AppealBondRefund_Success()` - bond refunded to escalator when appeal succeeds
- ✅ `test_AppealBondPayment_Failure()` - bond paid to prior resolver when appeal fails
- ✅ `test_AppealBondWithdrawal_PullModel()` - bond payouts use claimable ledger
- ✅ `test_AppealBondCurve_Quadratic()` - bond costs increase with escalation depth

### Phase 3 Tests (Resolver Compensation + Pull Model)

**File:** `test/foundry/core/BaseEscrowResolverPayments.t.sol` (new)

**Test cases:**
- ✅ `test_ResolverPaymentWithdrawal()` - resolvers can withdraw payments after finality
- ✅ `test_ResolverPayment_PreventedDuringAppeal()` - payments not withdrawable until final
- ✅ `test_InsurancePoolPayout_PullModel()` - insurance payouts use pull pattern

---

## Migration Path

### Step 1: Deploy Pull Model Changes (Phase 0)

**Risk:** Medium (changes core settlement logic, but backward compatible if old push paths are removed)

**Deployment:**
1. Deploy updated `BaseEscrow` with pull model
2. Migrate existing escrows (if any) to use `withdrawEscrow()` pattern
3. Update frontend/UX to show "withdraw" button instead of "automatic transfer"

**Rollback plan:**
- Keep old push paths as emergency fallback (gated by admin)
- Or: deploy as new escrow factory, migrate gradually

### Step 2: Deploy Appeal Window Enforcement (Phase 1)

**Risk:** High (critical security fix, but changes dispute lifecycle)

**Deployment:**
1. Deploy updated `BaseEscrow` with appeal window enforcement
2. Deploy updated `DecentralizedResolutionModule` (if interface changes needed)
3. Test extensively on testnet
4. Monitor for edge cases (timeouts, escalations during window)

**Rollback plan:**
- Emergency function to bypass appeal window (admin-only, time-locked)
- Or: deploy as new module version, swap via governance

### Step 3: Deploy Appeal Bonds (Phase 2)

**Risk:** Medium (adds economic mechanics, but incentive module is swappable)

**Deployment:**
1. Deploy incentive module with bond logic
2. Deploy updated `BaseEscrow` with bond collection
3. Activate bonds via governance (slow lane)

**Rollback plan:**
- Bonds can be disabled via governance (set bond amount to 0)
- Incentive module can be swapped to fee-only version

### Step 4: Verify Resolver Compensation (Phase 3)

**Risk:** Low (mostly verification, resolver modules already exist)

**Deployment:**
1. Verify resolver payment flows use pull model
2. Verify insurance pool payouts use pull model
3. No code changes expected (already implemented)

---

## Related Documentation

- `RESOLUTION_FLOW_ANALYSIS.md` - Current vs target behavior analysis
- `DR_V3_TODO.md` - Section 5.4: Appeal Window Enforcement (Critical)
- `DR_STAGING_PLAN.md` - Overall DR v1/v2/v3 staging plan
- `RESOLVER_ECONOMICS.md` - 2026 expectations and design principles

---

## Success Criteria

### Phase 0 (Pull Model)
- ✅ All token transfers happen in `withdrawEscrow()` (no push payments)
- ✅ Finalization functions are pure state transitions (no external calls)
- ✅ Continuous splits work independently (1% buyer, 99% seller)
- ✅ Yield distribution uses claimable ledger

### Phase 1 (Appeal Window)
- ✅ Funds never move until appeal window expires (or final level)
- ✅ Escalation cancels pending settlement deterministically
- ✅ Final-level resolutions (Kleros) finalize immediately
- ✅ `recordResolution()` is called before claimable balances are set

### Phase 2 (Appeal Bonds)
- ✅ Bonds are collected during escalation
- ✅ Bond distribution uses pull model (claimable ledger)
- ✅ Bond refunds/payments work correctly with appeal outcomes

### Phase 3 (Resolver Compensation)
- ✅ Resolver payments use pull model
- ✅ Insurance pool payouts use pull model
- ✅ No push payments anywhere in dispute lifecycle

---

## Open Questions

1. **EscrowState enum extension:** Should we add `DECIDED_PENDING_APPEAL` state, or reuse `DISPUTED`?
   - Recommendation: Reuse `DISPUTED` for v1, add explicit state later if needed

2. **Bond custody location:** Should bonds be held in `BaseEscrow` contract or separate custody?
   - Recommendation: Hold in `BaseEscrow` (simpler, one less contract)

3. **Resolver payment withdrawal:** Separate `withdrawResolverPayment()` or use same `withdrawEscrow()`?
   - Recommendation: Same `withdrawEscrow()` for simplicity (one withdrawal function)

4. **Migration of existing escrows:** How to handle escrows created before pull model migration?
   - Recommendation: They use old push pattern (grandfathered), or migrate via admin function

---

## Next Steps

1. **Review this plan** with team/governance
2. **Start Phase 0** (pull model migration) - foundational change
3. **Test Phase 0** extensively before proceeding
4. **Proceed to Phase 1** (appeal window enforcement) after Phase 0 is stable
5. **Phase 2/3** follow naturally once Phase 0/1 are complete
