# Multi-L2 Branch Merge Strategy & Development Plan

**Decision**: Merge Phase 3 multi-L2 branch with staged gating and focused testnet validation.

**Timeline**: 
- Phase 3a (merge ready): 1-2 days (gating + docs)
- Phase 3b (testnet validation): 3-5 days
- Phase 3c (production merge): After testnet data

---

## Executive Summary

The `multi-L2` branch is **safe to merge if properly gated**. Phase 3 (balance aggregator) is purely observational — it doesn't change signing flows, payment routing, or escrow discovery. 

**Recommendation**: Merge with feature gate, validate on testnet (focused), then ship gated feature to production.

**Key principle**: Balance visibility ✅ now | Payment routing ❌ later

---

## Strategic Rationale

### Why Merge Now

1. **User safety wins immediately**
   - Users with funds on Base/Arbitrum/Optimism think money is missing
   - Balance aggregation solves this without adding complexity

2. **Risk is asymmetric**
   - Benefit: Clarity and trust
   - Risk: Only if payment logic changes (which it doesn't)

3. **Gate enables staging**
   - Feature flag separates concerns
   - Can gather user data before Phase 4 (smart routing)

4. **Code is production-ready**
   - 28/28 tests passing
   - Zero regressions on existing tests
   - No changes to core flows

### Why NOT to Merge Without Gates

If Phase 3 went uncontrolled, it could:
- ❌ Confuse users about which chain holds escrows
- ❌ Enable auto-routing (trust issue)
- ❌ Hide chain identity in payment flows
- ❌ Increase support burden

**Gating prevents all of this.**

---

## Phased Rollout Plan

### Phase 3a: Gate Infrastructure (Before Merge)

**What needs doing**: ~1-2 days

#### 1. Feature Flag System

Add to your app config:

```typescript
// src/config/featureFlags.ts
export const FEATURE_FLAGS = {
  MULTI_L2_BALANCE_VISIBILITY: process.env.EXPO_PUBLIC_ENABLE_MULTI_L2 === 'true',
  MULTI_L2_PAYMENT_ROUTING: false, // Explicitly disabled for Phase 3
  MULTI_L2_AUTO_BRIDGING: false,   // Explicitly disabled for Phase 3
} as const;
```

#### 2. Balance Widget Gate

```typescript
// src/screens/BalanceScreen.tsx
import { FEATURE_FLAGS } from '../config/featureFlags';

export function BalanceWidget() {
  if (!FEATURE_FLAGS.MULTI_L2_BALANCE_VISIBILITY) {
    // Show single-chain balance (existing behavior)
    return <SingleChainBalance />;
  }
  
  // Show multi-L2 breakdown
  return <MultiL2BalanceWidget />;
}
```

#### 3. Send Flow (No Changes)

```typescript
// src/screens/SendScreen.tsx
// ⚠️ INTENTIONALLY UNCHANGED
// Always single chain, explicit selection
// Multi-L2 gating does NOT touch this

export function SendForm() {
  // User MUST select chain before sending
  // No auto-selection even if multi-L2 flag is on
  const [selectedChain, setSelectedChain] = useState<number | null>(null);
  
  if (!selectedChain) {
    return <ChainSelector onSelect={setSelectedChain} />;
  }
  
  return <SendToRecipient chainId={selectedChain} />;
}
```

#### 4. Escrow Discovery (No Changes)

```typescript
// src/escrows/useEscrowList.ts
// ⚠️ INTENTIONALLY UNCHANGED
// Escrows are queried per-chain explicitly
// No "find escrow across all L2s" logic

export function useEscrowList(chainId: number) {
  // Fetch escrows ONLY for this chain
  // Not aggregated across L2s
  return fetchEscrowsForChain(chainId);
}
```

**Key principle**: Feature flag only affects read-only balance display, nothing else.

---

### Phase 3b: Testnet Validation (3-5 days)

**What gets tested**: Everything that does NOT change

#### Test Matrix

| Component | Test | Gate | Status |
|-----------|------|------|--------|
| Balance aggregation | Read balances on 4 L2s | ON | ✅ Unit tests pass |
| Chain labeling | Each balance shows chain | ON | ✅ New test needed |
| RPC failover | Fallback if primary fails | ON | ✅ Unit tests pass |
| Send flow | Only single-chain, explicit | OFF | ✅ Existing tests pass |
| Escrow discovery | Per-chain only | OFF | ✅ Existing tests pass |
| Address identity | No cross-chain confusion | OFF | ✅ Existing tests pass |
| Payment routing | No auto-selection | OFF | ✅ Existing tests pass |

#### New Tests Needed (2-3 hours)

```typescript
// test/Phase3_BalanceAggregator_GatedFeatures.t.ts
describe('Phase 3 Multi-L2 Gating', () => {
  
  // Test 1: Balance visibility is gated
  it('should only show multi-L2 balances if flag enabled', () => {
    const { getByTestId, queryByTestId } = render(
      <BalanceWidget featureFlagEnabled={false} />
    );
    
    expect(getByTestId('single-chain-balance')).toBeInTheDocument();
    expect(queryByTestId('multi-l2-breakdown')).not.toBeInTheDocument();
  });

  // Test 2: Payment routing ignores multi-L2 flag
  it('should require explicit chain selection regardless of multi-L2 flag', () => {
    const { getByTestId } = render(
      <SendForm multiL2Enabled={true} />
    );
    
    // Should still require chain selection
    expect(getByTestId('chain-selector')).toBeInTheDocument();
  });

  // Test 3: Escrow discovery is not aggregated
  it('should only discover escrows for selected chain', () => {
    const { result } = renderHook(() => useEscrowList(chainId));
    
    expect(result.current).toHaveLength(3); // Only for THIS chain
    expect(result.current[0].chainId).toBe(chainId);
  });

  // Test 4: No address confusion
  it('should show which chain holds which escrow', () => {
    const { getByText } = render(
      <EscrowDetails
        escrow={{ address: '0x...', chainId: 8453 }}
        multiL2Enabled={true}
      />
    );
    
    expect(getByText(/Base/)).toBeInTheDocument();
    expect(getByText(/0x.../)).toBeInTheDocument();
  });
});
```

#### Testnet Deployment Strategy

**Question: Do we need live testnet deployment?**

**Short answer**: YES, but focused and scoped.

**Why**:
1. RPC integration is real (Alchemy keys, actual chain calls)
2. Mobile app integration is real (Expo + viem stack)
3. User flow needs validation (does balance visibility help or confuse?)

**What to test** (NOT what):
- ✅ Balance reads across Sepolia, Base Sepolia, Arbitrum Sepolia, Optimism Sepolia
- ✅ Chain labeling in UI
- ✅ RPC failover behavior
- ❌ Payment flows (don't test cross-chain sends)
- ❌ Smart routing (don't implement yet)
- ❌ Auto-bridging (don't implement yet)

**Testnet plan** (~1 day):
1. Deploy Phase 3 contracts to all 4 testnets (use existing deploy script)
2. Fund test accounts with USDC on each chain
3. Create test escrows on each chain (deposit test USDC)
4. Run Expo app with multi-L2 flag ON
5. Verify:
   - Balances appear correctly (4 L2s visible)
   - RPC failover works (disable one endpoint, still works)
   - No UI crashes
   - Performance <1s (all 4 chains)
6. Disable flag, verify:
   - Single-chain view works
   - No multi-L2 UI leaks through
7. Test payment flow separately (always single-chain)

---

## Development Plan (Pre-Merge)

### Tasks (Priority Order)

#### Task 1: Documentation (0.5 day)
**File**: `docs/PHASE3_MERGE_STRATEGY.md`

```markdown
# Phase 3 Merge Strategy

## What Merges Now
- Balance aggregator contracts (read-only)
- Multi-L2 balance visibility UI (gated)
- RPC failover (operational)
- Tests (28 passing)

## What Does NOT Merge Yet
- Payment routing changes
- Auto-chain selection
- Escrow aggregation
- Smart routing

## Feature Gates
- MULTI_L2_BALANCE_VISIBILITY: Controlled at startup
- MULTI_L2_PAYMENT_ROUTING: Hardcoded false
- MULTI_L2_AUTO_BRIDGING: Hardcoded false

## Rollout Schedule
- Week 1: Testnet validation
- Week 2: Merge to main (flag OFF)
- Week 3: Pilot with early users (flag ON for cohort)
- Week 4: Gradual rollout to production
```

#### Task 2: Feature Gate Implementation (0.5 day)
**Files to create**:
- `src/config/featureFlags.ts` (read from env)
- `src/hooks/useFeatureFlags.ts` (React hook)
- `src/components/BalanceWidget.tsx` (gated component)

**Key constraint**: Send flow MUST NOT check any multi-L2 flags

#### Task 3: Integration Tests (1 day)
**File**: `test/Phase3_GatedIntegration.t.ts`

Test the gate itself, not the feature:
- ✅ Verify flag controls visibility
- ✅ Verify payment flow is unchanged
- ✅ Verify no cross-chain leakage

#### Task 4: Testnet Setup (0.5 day)
**Steps**:
1. Run deployment script for all 4 testnets
2. Fund test accounts
3. Create test data (escrows with balances)
4. Document RPC URLs + contract addresses

#### Task 5: Testnet Test Plan (1 day)
**File**: `docs/PHASE3_TESTNET_PLAN.md`

```markdown
# Testnet Validation Checklist

## Balance Visibility Tests
- [ ] Show all 4 L2 balances
- [ ] Correct balance per chain
- [ ] Chain labels clear
- [ ] Total correctly summed

## RPC Failover Tests
- [ ] Primary RPC up: queries succeed
- [ ] Primary RPC down: queries fallback
- [ ] Both down: graceful error
- [ ] Performance <1s per query

## UI Integration Tests
- [ ] No crashes on load
- [ ] Refresh works
- [ ] Deep link to chain-specific view works
- [ ] Mobile responsive

## Separation Tests
- [ ] Send flow unchanged (single chain)
- [ ] Escrow discovery unchanged (per chain)
- [ ] No auto-routing attempted
- [ ] Addresses don't abstract across chains

## User Comprehension Tests
- [ ] Early users understand balance layout
- [ ] No confusion about which chain holds what
- [ ] Users know to check chain before sending
```

---

## Contract Changes Needed

**Short answer: NONE**

Phase 3 contracts are already:
- ✅ Non-invasive (don't touch escrow core)
- ✅ Read-only (no state changes)
- ✅ Tested (28/28)
- ✅ Safe to deploy as-is

**What you must NOT do**:
- ❌ Don't add auto-routing to contracts
- ❌ Don't add cross-chain escrow creation
- ❌ Don't add bridging logic
- ❌ Don't change escrow discovery

These should live in Phase 4, not Phase 3.

---

## Testnet Deployment Details

### Do We Need It?

**Yes, because**:
1. RPC integration is real (not mocked)
2. Mobile integration is real (Expo + viem)
3. User research needs real data ("Do users understand this?")
4. Failover logic needs real failure testing

**But focused on**: Balance visibility only, not payment flows.

### Testnet Scope

```
✅ IN SCOPE:
- Deploy Phase 3 contracts to 4 testnets
- Fund test accounts
- Verify balance reads
- Test RPC failover
- Test UI integration
- Measure performance

❌ OUT OF SCOPE:
- Test cross-chain payments
- Test auto-routing
- Test bridging
- Test account abstraction
- Any payment flow changes
```

### Testnet Success Criteria

| Criterion | How to Verify | Pass/Fail |
|-----------|---------------|-----------|
| Balances aggregate correctly | Query 4 chains, sum matches | ✅ Must pass |
| RPC failover works | Kill endpoint, still works | ✅ Must pass |
| UI doesn't crash | Run Expo app, no errors | ✅ Must pass |
| Performance < 1s | Measure query latency | ✅ Target |
| Users understand layout | Small pilot feedback | ✅ Target |
| No payment flow changes | Send flow works unchanged | ✅ Must pass |
| No address confusion | Users know which chain | ✅ Target |

### Timeline

```
Day 1 (Deploy):
  - Run deploy script for Sepolia, Base Sepolia, Arbitrum Sepolia, Optimism Sepolia
  - Document contract addresses
  - Create test accounts with testnet ETH

Day 2 (Integration):
  - Update Expo app to use testnet contracts
  - Enable multi-L2 flag in testnet build
  - Integrate RPC failover

Day 3 (Testing):
  - Run through success criteria
  - Test balance visibility
  - Test RPC failover
  - Measure performance

Day 4 (User Research):
  - Share with 2-3 early users
  - Observe: do they understand?
  - Collect feedback

Day 5 (Decision):
  - Review testnet data
  - Proceed to merge if criteria met
  - Document findings
```

---

## Pre-Merge Checklist

Before merging `multi-L2` to `main`:

### Code Quality
- [ ] 28/28 Phase 3 tests passing
- [ ] All 328 existing tests still passing
- [ ] No compiler warnings on new code
- [ ] Feature gates implemented and tested
- [ ] Send flow verified unchanged

### Documentation
- [ ] Merge strategy documented
- [ ] Feature gates explained
- [ ] Testnet plan written
- [ ] Rollout schedule defined
- [ ] What's NOT included clearly stated

### Testing
- [ ] Gate behavior tested (3 new tests)
- [ ] Testnet validation passed
- [ ] User feedback collected
- [ ] RPC failover verified
- [ ] Performance baseline established

### Operational
- [ ] Testnet contracts deployed
- [ ] Team briefed on gating approach
- [ ] Support team trained on new feature
- [ ] Rollout plan agreed
- [ ] Monitoring plan in place

---

## Post-Merge, Pre-Production

### Week 1: Monitor Main Branch
- Run full test suite weekly
- Monitor for regressions
- Verify send flow still works

### Week 2: Prepare Rollout
- Build Expo app with flag ON (testnet)
- Test with team internally
- Prepare customer comms

### Week 3: Pilot Rollout
- Enable flag for 10% of users (or specific cohort)
- Monitor balance query latency
- Collect user feedback
- Watch for support issues

### Week 4: Measure Impact
- Analyze: Do users understand multi-L2 balances?
- Measure: Does it reduce support burden?
- Decide: Full rollout or refinement?

### Week 5+: Full Rollout
- Enable for all users if feedback positive
- Keep gates in place (can disable quickly)
- Begin planning Phase 4 (smart routing)

---

## What Happens in Phase 4 (Future)

**Only after Phase 3 testnet + pilot data**:

- Smart chain selection (suggest low-gas chain)
- Gas monitoring per-chain
- Cross-L2 payment abstraction (optional "send from anywhere")
- Operator dashboard

**Each requires**:
- New contracts (different from Phase 3)
- Significant new testing
- Separate testnet validation
- Separate rollout plan

**Decision point**: Can only make after Phase 3 user data.

---

## Recommended Merge Commit Message

```
feat: merge multi-L2 balance visibility (Phase 3) with feature gating

GATED FEATURE: Multi-L2 balance aggregation
- Read-only balance visibility across Ethereum, Base, Arbitrum, Optimism
- Feature flag: MULTI_L2_BALANCE_VISIBILITY (default: off)
- Payment routing: UNCHANGED (always single-chain explicit)
- Escrow discovery: UNCHANGED (per-chain only)

Contracts:
- BalanceAggregator (read balances from any token)
- MultiL2EscrowAggregator (read escrow balances + status)
- MulticallFallbackHandler (RPC endpoint management + failover)
- IMulticall3 (standard multicall interface)

Tests:
- 28 new tests (all passing)
- 328 existing tests (all still passing)
- Zero regressions

Gating:
- Balance widget gated behind feature flag
- Send flow unchanged (gate does NOT affect it)
- Escrow discovery unchanged (gate does NOT affect it)
- Auto-routing disabled (planned for Phase 4)

Rollout:
- Testnet validation: 3-5 days
- Pilot rollout: 10% of users
- Full rollout: After user feedback

Docs:
- PHASE3_MERGE_STRATEGY.md (what/why/when)
- PHASE3_TESTNET_PLAN.md (validation steps)
- EXPO_APP_QUICK_REFERENCE.md (integration guide)

See docs/ for complete strategy and gating approach.
```

---

## Decision Summary

| Question | Answer | Rationale |
|----------|--------|-----------|
| Merge now? | YES (with gates) | Phase 3 is non-invasive, read-only |
| Need testnet deploy? | YES | RPC integration + user research |
| Need contract changes? | NO | Phase 3 is complete as-is |
| Need more testing? | Minimal (3 gate tests) | 28 tests already pass |
| Pay shipping? | NO | Feature flag shipped disabled |
| Timeline to main? | 1-2 weeks | After testnet validation |
| Timeline to users? | 3-4 weeks | After pilot data |

---

## Risk Assessment

### What Could Go Wrong (And Mitigation)

| Risk | Impact | Mitigation |
|------|--------|-----------|
| Users confused by multi-L2 layout | Support burden | Feature flag OFF by default, testnet feedback |
| RPC failover doesn't work | Silent failures | Testnet testing + monitoring |
| Balance reads slow | Poor UX | Performance baseline in testnet |
| Address confusion in send flow | User error | Gate does NOT affect send (unchanged) |
| Auto-routing happens accidentally | Trust broken | Code review (no auto-routing in Phase 3) |

**Overall risk**: LOW

Phase 3 is isolated from payment flows. Worst case: disable the flag.

---

## Next Steps (If You Approve This Plan)

1. **Approve** this merge strategy
2. **Create** feature flag infrastructure (0.5 day)
3. **Write** gate tests (0.5 day)
4. **Deploy** to testnet (0.5 day)
5. **Validate** on testnet (1 day)
6. **Merge** `multi-L2` → `main` with gates enabled
7. **Pilot** with early users
8. **Measure** impact
9. **Plan** Phase 4 (smart routing) based on data

---

**Recommendation**: ✅ Merge with this strategy. The gates protect both code quality and user experience while gathering real data for Phase 4.
