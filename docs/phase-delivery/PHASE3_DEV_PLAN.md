# Phase 3 Dev Plan: What to Build Before Merge

**Status**: Ready to implement
**Estimated**: 4-5 days
**Scope**: Feature gates + testing + validation

---

## Summary

Phase 3 contracts are production-ready. We need:
1. **Feature gate infrastructure** (1 day)
2. **Gate behavior tests** (1 day)
3. **Testnet deployment** (0.5 day)
4. **Testnet validation** (1 day)
5. **Merge prep** (0.5 day)

**No contract changes needed.** We're wrapping existing code with gates.

---

## Phase A: Feature Gate Infrastructure (1 day)

### Task A1: Create Feature Flags System

**File**: `src/config/featureFlags.ts`

```typescript
// Feature flags with environment override
export const featureFlags = {
  MULTI_L2_BALANCE_VISIBILITY: process.env.MULTI_L2_BALANCE_VISIBILITY === 'true',
};

// Useful for testing
export const setFeatureFlag = (flag: string, enabled: boolean) => {
  featureFlags[flag as keyof typeof featureFlags] = enabled;
};
```

**Acceptance**:
- [ ] Flag can be set via environment variable
- [ ] Flag can be overridden in tests
- [ ] Default is OFF (false)

### Task A2: Create Feature Flag Hook

**File**: `src/hooks/useFeatureFlags.ts`

```typescript
import { featureFlags } from '../config/featureFlags';

export const useFeatureFlags = () => {
  return {
    multiL2BalanceVisibility: featureFlags.MULTI_L2_BALANCE_VISIBILITY,
  };
};
```

**Acceptance**:
- [ ] Hook returns current flag values
- [ ] Can be used in React components
- [ ] Works in tests

### Task A3: Gate Balance Widget

**File**: `src/components/BalanceWidget.tsx` (NEW or modified)

```typescript
import { useFeatureFlags } from '../hooks/useFeatureFlags';

export const BalanceWidget = ({ balances }) => {
  const { multiL2BalanceVisibility } = useFeatureFlags();

  if (!multiL2BalanceVisibility) {
    // Fallback: show single-chain only
    return <SingleChainBalance balance={balances[0]} />;
  }

  // Show multi-L2 breakdown
  return <MultiL2BalanceBreakdown balances={balances} />;
};
```

**Acceptance**:
- [ ] When flag is OFF, shows single chain only
- [ ] When flag is ON, shows all L2s
- [ ] No errors in either mode
- [ ] Graceful fallback

### Task A4: Verify Send Form NOT Gated

**File**: `src/components/SendForm.tsx` (review, no changes)

```typescript
// SendForm implementation MUST:
// - Always show chain selector
// - Never reference MULTI_L2_BALANCE_VISIBILITY flag
// - Always require explicit chain selection
// - NEVER change behavior based on balance visibility flag

export const SendForm = ({ chains }) => {
  const [selectedChain, setSelectedChain] = useState(null);
  
  const handleSend = async () => {
    // ALWAYS require chain selection
    if (!selectedChain) throw new Error('Chain required');
    // Rest of send logic...
  };
  
  return (
    <>
      <ChainSelector onChange={setSelectedChain} />
      {/* Send form fields... */}
    </>
  );
};
```

**Acceptance**:
- [ ] Review code confirms no feature flag references
- [ ] Chain selector always present
- [ ] Explicit chain requirement enforced
- [ ] No conditional logic based on MULTI_L2 flag

### Task A5: Verify Escrow Discovery NOT Gated

**File**: `src/components/EscrowList.tsx` (review, no changes)

```typescript
// EscrowList implementation MUST:
// - Always show per-chain escrows only
// - Never aggregate across chains
// - Never reference MULTI_L2_BALANCE_VISIBILITY flag
// - Always require chain selection first

export const EscrowList = ({ selectedChain }) => {
  // ALWAYS per-chain only
  if (!selectedChain) {
    return <div>Select a chain to see escrows</div>;
  }
  
  const escrows = query.getEscrowsByChain(selectedChain);
  return <Escrows data={escrows} />;
};
```

**Acceptance**:
- [ ] Review code confirms no feature flag references
- [ ] Per-chain filtering enforced
- [ ] No cross-chain aggregation
- [ ] Requires chain selection

---

## Phase B: Gate Behavior Tests (1 day)

### Task B1: Create Gate Tests File

**File**: `test/Phase3_GatedFeatures.t.ts`

```typescript
import { featureFlags, setFeatureFlag } from '../src/config/featureFlags';

describe('Phase 3 Feature Gates', () => {
  
  // TEST 1: Balance visibility with flag ON
  test('shows multi-L2 breakdown when MULTI_L2_BALANCE_VISIBILITY=true', () => {
    setFeatureFlag('MULTI_L2_BALANCE_VISIBILITY', true);
    const { getByText } = render(
      <BalanceWidget balances={[{ chain: 'base', amount: '100' }, ...]} />
    );
    expect(getByText(/Base/i)).toBeInTheDocument();
    expect(getByText(/Arbitrum/i)).toBeInTheDocument();
  });
  
  // TEST 2: Balance visibility with flag OFF
  test('shows single chain only when MULTI_L2_BALANCE_VISIBILITY=false', () => {
    setFeatureFlag('MULTI_L2_BALANCE_VISIBILITY', false);
    const { queryByText, getByText } = render(
      <BalanceWidget balances={[{ chain: 'base', amount: '100' }, ...]} />
    );
    // Should only show primary chain
    expect(getByText(/100/)).toBeInTheDocument();
    // Should NOT show other chains in multi-L2 format
    expect(queryByText(/Multi-L2/)).not.toBeInTheDocument();
  });
  
  // TEST 3: Send form requires chain regardless of flag
  test('send form requires explicit chain selection (flag independent)', () => {
    setFeatureFlag('MULTI_L2_BALANCE_VISIBILITY', true);
    const { getByText, getByRole } = render(<SendForm />);
    
    // Chain selector always present
    expect(getByRole('combobox', { name: /chain/i })).toBeInTheDocument();
    
    // Can't send without selecting chain
    const sendButton = getByText(/send/i);
    fireEvent.click(sendButton);
    expect(screen.getByText(/chain required/i)).toBeInTheDocument();
  });
  
  // TEST 4: Escrow discovery per-chain only (flag independent)
  test('escrow list always per-chain only (flag independent)', () => {
    setFeatureFlag('MULTI_L2_BALANCE_VISIBILITY', true);
    const { getByText, queryByText } = render(
      <EscrowList selectedChain="base" />
    );
    
    // Should show Base escrows
    expect(getByText(/Escrow on Base/)).toBeInTheDocument();
    
    // Should NOT show escrows from other chains
    expect(queryByText(/Escrow on Arbitrum/)).not.toBeInTheDocument();
    expect(queryByText(/All chains/)).not.toBeInTheDocument();
  });
});
```

**Acceptance**:
- [ ] All 4 tests passing
- [ ] Tests verify gate logic (ON/OFF)
- [ ] Tests verify send flow unchanged
- [ ] Tests verify escrow discovery unchanged
- [ ] Total tests: 360/360 passing (328 existing + 28 Phase3 + 4 gates)

---

## Phase C: Testnet Deployment (0.5 day)

### Task C1: Update Deployment Script Chains

**File**: `deploy/06_phase3_balance_aggregator.ts` (review)

Verify script supports:
- [ ] Sepolia (11155111)
- [ ] Base Sepolia (84531)
- [ ] Arbitrum Sepolia (421614)
- [ ] Optimism Sepolia (11155420)

### Task C2: Deploy to All 4 Testnets

```bash
# Sepolia
CHAIN_ID=11155111 npx hardhat run deploy/06_phase3_balance_aggregator.ts

# Base Sepolia
CHAIN_ID=84531 npx hardhat run deploy/06_phase3_balance_aggregator.ts

# Arbitrum Sepolia
CHAIN_ID=421614 npx hardhat run deploy/06_phase3_balance_aggregator.ts

# Optimism Sepolia
CHAIN_ID=11155420 npx hardhat run deploy/06_phase3_balance_aggregator.ts
```

**Acceptance**:
- [ ] All 4 deployments succeed
- [ ] Contract addresses saved to `deployments/phase3/{chainId}.json`
- [ ] Addresses same across all 4 chains (deterministic)
- [ ] RPC endpoints configured in deployment config

### Task C3: Fund Test Accounts

**Setup**:
- [ ] 1 testnet ETH per account on each chain
- [ ] 1000 USDC per account on each chain (if available)
- [ ] Document addresses in testnet config

---

## Phase D: Testnet Validation (1 day)

### Task D1: Build Expo App (Flag ON)

```bash
# Set environment variable
export MULTI_L2_BALANCE_VISIBILITY=true

# Build for testnet
npm run build:testnet
```

**Acceptance**:
- [ ] Build succeeds
- [ ] No errors in console
- [ ] App runs on iOS simulator
- [ ] App runs on Android emulator
- [ ] App runs on web

### Task D2: Test Balance Visibility

**Manual Tests**:
- [ ] Open wallet on testnet
- [ ] Navigate to Balances screen
- [ ] Verify multi-L2 breakdown shows
- [ ] Verify Base balance displays correctly
- [ ] Verify Arbitrum balance displays correctly
- [ ] Verify Optimism balance displays correctly
- [ ] Verify total sum is correct
- [ ] Verify chain labels are clear

### Task D3: Test RPC Failover

**Manual Tests**:
```javascript
// Simulate RPC failure by temporarily disabling endpoint in config
1. Kill primary RPC endpoint
2. Wait for failover trigger (3 consecutive failures)
3. Verify backup endpoint is used
4. Verify balances still load (slower, but functional)
5. Restore primary endpoint
6. Verify recovery (automatic after success)
```

**Acceptance**:
- [ ] Failover triggers automatically
- [ ] Backup endpoint works
- [ ] Primary endpoint recovery works
- [ ] User sees no errors

### Task D4: Performance Baseline

**Measurement**:
- [ ] Query all 4 L2s in parallel
- [ ] Measure time to first balance display
- [ ] Target: < 1000ms
- [ ] Record in TESTNET_BASELINE.md

```
Expected:
- Sepolia: 150-250ms
- Base Sepolia: 150-250ms
- Arbitrum Sepolia: 150-250ms
- Optimism Sepolia: 150-250ms
Total: 300-500ms (parallel, not sequential)
```

### Task D5: User Research (Early Testers)

**Procedure**:
1. Build Expo app with flag ON
2. Give to 3-5 early testers on testnet
3. Ask 3 questions:
   - "What do you see on the balances screen?"
   - "Does it make sense why money is split?"
   - "Would this help you feel more confident?"
4. Record feedback
5. Document in TESTNET_FEEDBACK.md

**Success**: No "I'm confused" responses about cross-chain identity.

### Task D6: Send Flow Verification

**Manual Tests**:
- [ ] Open SendForm
- [ ] Verify chain selector always visible
- [ ] Verify must select chain before sending
- [ ] Verify flag OFF doesn't remove chain selector
- [ ] Verify flag ON doesn't add auto-selection
- [ ] Verify send completes to selected chain only

**Acceptance**:
- [ ] All send tests pass
- [ ] No auto-routing
- [ ] No implicit chain selection
- [ ] No cross-chain sends

### Task D7: Escrow Discovery Verification

**Manual Tests**:
- [ ] Open EscrowList
- [ ] Verify only shows escrows on selected chain
- [ ] Switch chains
- [ ] Verify list updates per-chain
- [ ] Verify flag ON doesn't aggregate across chains
- [ ] Verify flag OFF shows same per-chain view

**Acceptance**:
- [ ] Always per-chain only
- [ ] No cross-chain aggregation
- [ ] Clear chain labeling

---

## Phase E: Merge Prep (0.5 day)

### Task E1: Final Code Review

**Checklist**:
- [ ] All 360 tests passing
- [ ] No console errors
- [ ] Feature gates working (ON/OFF)
- [ ] Send form unchanged
- [ ] Escrow discovery unchanged
- [ ] No auto-routing code
- [ ] No cross-chain aggregation

**Review Against**:
- PHASE3_MERGE_STRATEGY.md (lines 30-95)
- PHASE3_IMPLEMENTATION_PLAN.md (Phase A-B checklist)

### Task E2: Documentation Complete

**Files Ready**:
- [ ] PHASE3_EXECUTIVE_SUMMARY.md (decision framework)
- [ ] PHASE3_MERGE_STRATEGY.md (technical strategy)
- [ ] PHASE3_IMPLEMENTATION_PLAN.md (detailed plan)
- [ ] TESTNET_BASELINE.md (performance data)
- [ ] TESTNET_FEEDBACK.md (user research)
- [ ] Deployment addresses (in deployments/phase3/)

### Task E3: Team Briefing

**Prepare**:
- [ ] Copy PHASE3_EXECUTIVE_SUMMARY.md to team
- [ ] Highlight decision gates (on page 1)
- [ ] Highlight risk summary (green lights)
- [ ] Highlight timeline (2 weeks to main)
- [ ] Get approval to proceed

### Task E4: Create Merge Commit

**Commit Message Template**:

```
Merge multi-L2 branch (Phase 3 - Balance Aggregator)

FEATURE: Multi-L2 balance visibility with feature gating

WHAT MERGES:
✅ Balance aggregator contracts (read-only)
✅ RPC failover infrastructure
✅ Feature flag infrastructure
✅ 360 comprehensive tests
✅ Complete documentation

GATING:
- MULTI_L2_BALANCE_VISIBILITY flag (default OFF)
- Balance widget gated
- Send form unchanged (chain always required)
- Escrow discovery unchanged (per-chain only)

TESTING:
- 360/360 tests passing (328 existing + 28 Phase3 + 4 gates)
- Testnet validated (4 chains, user feedback positive)
- RPC failover tested and working
- Performance baseline established (< 1s)

ROLLOUT:
- Main branch: flag OFF (no visible change)
- Testnet pilot: flag ON (early user validation)
- Production: Gradual rollout after feedback

RISK: 🟢 LOW (reversible, well-tested, staged)
BENEFIT: HIGH (users see L2 balances clearly)

Related: #XXX (link to PR/issue)
Docs: PHASE3_EXECUTIVE_SUMMARY.md
```

---

## Definition of Done

Before merging to main:

### Code
- [ ] All 360 tests passing
- [ ] No console errors
- [ ] Feature gates working
- [ ] Send flow unchanged
- [ ] Escrow discovery unchanged
- [ ] No auto-routing code
- [ ] No cross-chain aggregation

### Testing
- [ ] Unit tests: 4/4 gate tests passing
- [ ] Integration tests: all passing
- [ ] Testnet: all 4 chains deployed
- [ ] RPC failover: tested and working
- [ ] Performance: baseline established

### Documentation
- [ ] PHASE3_EXECUTIVE_SUMMARY.md complete
- [ ] PHASE3_MERGE_STRATEGY.md complete
- [ ] PHASE3_IMPLEMENTATION_PLAN.md complete
- [ ] TESTNET_BASELINE.md complete
- [ ] TESTNET_FEEDBACK.md complete
- [ ] Deployment addresses documented

### Approval
- [ ] Team agrees to merge
- [ ] Product agrees to gating strategy
- [ ] Security review complete
- [ ] No blockers identified

---

## Success Criteria

**Merge**: All gates working, 360 tests passing, testnet validated
**Post-Merge**: Flag OFF, no visible change, no regressions
**Pre-Rollout**: Pilot feedback positive, user research clear, RPC costs acceptable
**Production**: Gradual rollout, monitoring active, support team briefed

---

## Timeline

| Task | Duration | Owner | Dates |
|------|----------|-------|-------|
| A: Gate infrastructure | 1 day | Dev | Week 1, Day 1-2 |
| B: Gate tests | 1 day | Dev | Week 1, Day 2-3 |
| C: Testnet deploy | 0.5 day | Dev | Week 1, Day 3 |
| D: Testnet validation | 1 day | Dev+QA | Week 1, Day 4 |
| E: Merge prep | 0.5 day | Dev | Week 1, Day 5 |
| Merge to main | 0.5 day | Lead | Week 2, Day 1 |
| Pilot + feedback | 5 days | Product | Week 2 |
| Analyze + plan Phase 4 | 2 days | Team | Week 3 |
| Gradual rollout | 1-2 weeks | Ops | Week 3-4 |

**Total**: 4-5 days prep + 2 weeks to production

---

## Risks & Mitigations

| Risk | Severity | Mitigation |
|------|----------|-----------|
| Feature gates don't work | HIGH | Task A1-2, test immediately |
| Tests fail on testnet | HIGH | Task D comprehensive testing |
| RPC failover flaky | MEDIUM | Task D3 detailed testing + monitoring |
| Users confused by layout | MEDIUM | Task D5 user research + feedback |
| Send form broken | CRITICAL | Task A4 verification + Task D6 testing |
| Escrows aggregated by mistake | CRITICAL | Task A5 verification + Task D7 testing |
| Performance too slow | MEDIUM | Task D4 baseline + optimization if needed |

---

## Next Steps

1. ✅ Review this plan
2. ✅ Get team approval
3. Start Phase A (Gate infrastructure) immediately
4. Proceed through phases sequentially
5. After Phase E, ready to merge

**Checkpoint**: After Phase B (1-2 days), all tests should pass. If not, debug before proceeding.

---

**Owner**: Development team
**Status**: Ready to implement
**Branch**: `multi-L2` (commit `487aaa0`)
**Date**: February 5, 2026
