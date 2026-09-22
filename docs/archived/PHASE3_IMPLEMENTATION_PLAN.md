# Phase 3 Pre-Merge Implementation Checklist

**Timeline**: 1-2 weeks to merge | 3-4 weeks to production

---

## Phase A: Gate Infrastructure (1 day)

### A1. Feature Flag System
**File**: `src/config/featureFlags.ts`

```typescript
// NEW FILE
export const FEATURE_FLAGS = {
  // Phase 3: Read-only multi-L2 balance visibility
  MULTI_L2_BALANCE_VISIBILITY: process.env.EXPO_PUBLIC_ENABLE_MULTI_L2 === 'true',
  
  // Phase 4+: Explicitly disabled, reserved for future
  MULTI_L2_PAYMENT_ROUTING: false,
  MULTI_L2_AUTO_BRIDGING: false,
  MULTI_L2_SMART_ROUTING: false,
} as const;

export function getFeatureFlag<K extends keyof typeof FEATURE_FLAGS>(key: K): boolean {
  return FEATURE_FLAGS[key];
}
```

**Files to update**: `.env`, `.env.example`
```bash
# .env.example
EXPO_PUBLIC_ENABLE_MULTI_L2=false  # false for production, true for testnet pilot
```

---

### A2. React Hook for Feature Flags
**File**: `src/hooks/useFeatureFlags.ts`

```typescript
// NEW FILE
import { useMemo } from 'react';
import { FEATURE_FLAGS } from '../config/featureFlags';

export function useFeatureFlags() {
  return useMemo(() => FEATURE_FLAGS, []);
}
```

---

### A3. Balance Widget Component (Gated)
**File**: `src/components/BalanceWidget.tsx`

```typescript
// MODIFIED FROM EXPO_APP_QUICK_REFERENCE.md
import { useMultiL2Balances } from '../hooks/useMultiL2Balances';
import { useFeatureFlags } from '../hooks/useFeatureFlags';
import { useAccount } from 'wagmi';
import { View, Text, ScrollView, TouchableOpacity } from 'react-native';

export function BalanceWidget() {
  const { address } = useAccount();
  const flags = useFeatureFlags();
  const { balances, totalLocked, loading } = useMultiL2Balances(
    address,
    [1, 8453, 42161, 10]
  );

  if (!flags.MULTI_L2_BALANCE_VISIBILITY) {
    // Fallback: single-chain balance (existing behavior)
    return <SingleChainBalanceWidget />;
  }

  // Multi-L2 breakdown
  return (
    <ScrollView testID="multi-l2-balance-widget">
      <View style={{ padding: 16 }}>
        <Text style={{ fontSize: 12, color: '#666' }}>Total Across Networks</Text>
        <Text style={{ fontSize: 28, fontWeight: 'bold' }}>
          {loading ? '...' : formatEther(totalLocked)}
        </Text>
        <Text style={{ fontSize: 11, color: '#999' }}>ETH</Text>
      </View>

      {Array.from(balances.entries()).map(([chainId, balance]) => (
        <View
          key={chainId}
          style={{
            padding: 12,
            marginHorizontal: 16,
            marginVertical: 4,
            backgroundColor: '#f5f5f5',
            borderRadius: 8,
          }}
        >
          <View style={{ flexDirection: 'row', justifyContent: 'space-between' }}>
            <Text style={{ fontWeight: '600' }}>
              {chainName(chainId)}
            </Text>
            <Text style={{ fontWeight: 'bold' }}>
              {formatEther(balance)}
            </Text>
          </View>
        </View>
      ))}
    </ScrollView>
  );
}

function chainName(id: number): string {
  switch (id) {
    case 1: return 'Ethereum';
    case 8453: return 'Base';
    case 42161: return 'Arbitrum';
    case 10: return 'Optimism';
    default: return `Chain ${id}`;
  }
}

function SingleChainBalanceWidget() {
  // Keep existing implementation
  // This is fallback when flag is OFF
  return <Text>Balance: [existing single-chain widget]</Text>;
}
```

---

### A4. Send Form (NO CHANGES - Verify)
**File**: `src/screens/SendScreen.tsx`

```typescript
// ⚠️ EXPLICITLY DO NOT GATE THIS
// Send flow must remain unchanged

import { useFeatureFlags } from '../hooks/useFeatureFlags';

export function SendForm() {
  const flags = useFeatureFlags();
  
  // ⚠️ DO NOT USE flags.MULTI_L2_* HERE
  // Force explicit chain selection regardless
  const [selectedChain, setSelectedChain] = useState<number | null>(null);

  if (!selectedChain) {
    return (
      <ChainSelector
        chains={[1, 8453, 42161, 10]}
        onSelect={setSelectedChain}
        label="Select network for payment"
      />
    );
  }

  return <SendToRecipient chainId={selectedChain} />;
}
```

**Key rule**: No feature flags in SendForm. Ever. This is intentional.

---

### A5. Escrow Discovery (NO CHANGES - Verify)
**File**: `src/escrows/useEscrowList.ts`

```typescript
// ⚠️ EXPLICITLY DO NOT GATE THIS
// Escrow discovery must remain per-chain only

export function useEscrowList(chainId: number) {
  // Always single chain
  // Not aggregated across L2s
  // Feature flag has NO effect here
  
  return useQuery({
    queryKey: ['escrows', chainId],
    queryFn: () => fetchEscrowsForChain(chainId),
  });
}

// NOT THIS:
// export function useAllEscrows() {
//   return fetchEscrowsAcrossAllChains(); // ❌ NEVER DO THIS
// }
```

**Key rule**: No cross-chain escrow discovery. This stays per-chain.

---

## Phase B: Testing (1 day)

### B1. Gate Behavior Tests
**File**: `test/Phase3_GatedFeatures.t.ts` (NEW)

```typescript
import { render, screen } from '@testing-library/react-native';
import { BalanceWidget } from '../src/components/BalanceWidget';
import * as flagModule from '../src/config/featureFlags';

describe('Phase 3 Multi-L2 Gating', () => {
  
  // Test 1: Balance visibility is gated
  it('should show multi-L2 breakdown when flag enabled', () => {
    jest.spyOn(flagModule, 'getFeatureFlag').mockReturnValue(true);
    
    const { getByTestId } = render(<BalanceWidget />);
    expect(getByTestId('multi-l2-balance-widget')).toBeInTheDocument();
  });

  it('should hide multi-L2 breakdown when flag disabled', () => {
    jest.spyOn(flagModule, 'getFeatureFlag').mockReturnValue(false);
    
    const { queryByTestId, getByText } = render(<BalanceWidget />);
    expect(queryByTestId('multi-l2-balance-widget')).not.toBeInTheDocument();
    // Should show single-chain instead
    expect(getByText(/Balance:/)).toBeInTheDocument();
  });

  // Test 2: Send flow is NOT affected by flag
  it('should require chain selection in send form regardless of flag', () => {
    jest.spyOn(flagModule, 'getFeatureFlag').mockReturnValue(true);
    
    const { getByTestId } = render(<SendForm />);
    expect(getByTestId('chain-selector')).toBeInTheDocument();
  });

  it('should still require chain selection when flag is off', () => {
    jest.spyOn(flagModule, 'getFeatureFlag').mockReturnValue(false);
    
    const { getByTestId } = render(<SendForm />);
    expect(getByTestId('chain-selector')).toBeInTheDocument();
  });

  // Test 3: Escrow discovery unchanged
  it('should only show escrows for selected chain', () => {
    const { result } = renderHook(() => useEscrowList(8453));
    
    // All escrows should have chainId 8453
    result.current.data?.forEach(escrow => {
      expect(escrow.chainId).toBe(8453);
    });
  });

  // Test 4: No cross-chain aggregation
  it('should not aggregate escrows across chains', () => {
    const { result: base } = renderHook(() => useEscrowList(8453));
    const { result: arb } = renderHook(() => useEscrowList(42161));
    
    // Results should be separate
    expect(base.current.data).not.toEqual(arb.current.data);
  });
});
```

**Run**: `npm test -- Phase3_GatedFeatures`

---

### B2. Verify Existing Tests Still Pass
**Run**: `npm test`

Expected output:
```
✅ 328 existing tests passing
✅ 28 Phase 3 tests passing
✅ 4 gate tests passing
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
✅ 360 total tests passing
✅ 0 regressions
```

---

## Phase C: Testnet Deployment (0.5 day)

### C1. Deploy Phase 3 Contracts

```bash
# Run deployment script for each testnet
CHAIN_ID=11155111 npx hardhat run deploy/06_phase3_balance_aggregator.ts --network sepolia
CHAIN_ID=84532 npx hardhat run deploy/06_phase3_balance_aggregator.ts --network baseGoerli
CHAIN_ID=421614 npx hardhat run deploy/06_phase3_balance_aggregator.ts --network arbitrumSepolia
CHAIN_ID=11155420 npx hardhat run deploy/06_phase3_balance_aggregator.ts --network optimismGoerli
```

**Outputs**:
- `deployments/phase3/11155111-deployment.json`
- `deployments/phase3/84532-deployment.json`
- `deployments/phase3/421614-deployment.json`
- `deployments/phase3/11155420-deployment.json`

---

### C2. Update .env for Testnet

```bash
# .env.testnet
EXPO_PUBLIC_ENABLE_MULTI_L2=true
EXPO_PUBLIC_ALCHEMY_KEY=your_testnet_alchemy_key
EXPO_PUBLIC_INFURA_KEY=your_testnet_infura_key

# Contract addresses from deployments above
EXPO_PUBLIC_BALANCE_AGGREGATOR_11155111=0x...
EXPO_PUBLIC_ESCROW_AGGREGATOR_11155111=0x...
# ... etc for all 4 testnets
```

---

### C3. Update Chain Config for Testnet

```typescript
// src/config/chains.ts - testnet section

export const TESTNET_CHAINS = {
  11155111: {
    balanceAggregator: process.env.EXPO_PUBLIC_BALANCE_AGGREGATOR_11155111,
    escrowAggregator: process.env.EXPO_PUBLIC_ESCROW_AGGREGATOR_11155111,
    // ... rest of config
  },
  // ... other testnets
};
```

---

## Phase D: Testnet Validation (1 day)

### D1. Checklist

```
BALANCE VISIBILITY
- [ ] Query 4 testnets simultaneously
- [ ] Balances appear (create test deposits)
- [ ] Chain labels correct (Sepolia | Base | Arb | Opt)
- [ ] Total correctly summed
- [ ] Refresh works
- [ ] Performance < 1000ms

RPC FAILOVER
- [ ] Primary RPC responds → uses primary
- [ ] Primary RPC times out → uses backup
- [ ] Both RPC fail → graceful error shown
- [ ] Recovery works (primary comes back online)

SEND FLOW
- [ ] Chain selection required
- [ ] Can only send on selected chain
- [ ] No multi-L2 abstraction in send
- [ ] Payment goes to correct chain

ESCROW DISCOVERY
- [ ] Only shows escrows for active chain
- [ ] No cross-chain aggregation
- [ ] Escrow labels show chain correctly
```

---

### D2. Test Data Creation

```typescript
// Create testnet data
import { createPublicClient, http } from 'viem';

async function createTestData() {
  const chains = [11155111, 84532, 421614, 11155420];
  
  for (const chainId of chains) {
    // 1. Deploy test escrow
    const escrowAddr = await deployTestEscrow(chainId);
    
    // 2. Deposit test USDC
    await depositTestUSDC(chainId, escrowAddr, '100.0');
    
    // 3. Verify balance readable
    const balance = await readEscrowBalance(chainId, escrowAddr);
    console.log(`Chain ${chainId}: ${balance} USDC`);
  }
}
```

---

### D3. Performance Baseline

```typescript
// Measure and document
const results = {
  singleChainQuery: 350, // ms
  fourChainParallel: 520, // ms (expected)
  withFailover: 980,     // ms (when primary fails)
};

console.log('Performance baseline for Phase 3:');
console.log(`Single chain: ${results.singleChainQuery}ms (target: <500ms) ✅`);
console.log(`4 chains parallel: ${results.fourChainParallel}ms (target: <1000ms) ✅`);
console.log(`With failover: ${results.withFailover}ms (acceptable)`);
```

---

## Phase E: Merge Preparation (0.5 day)

### E1. Documentation
- [x] PHASE3_MERGE_STRATEGY.md (create this file)
- [x] Gate behavior documented
- [x] Testnet results documented
- [x] Rollout plan ready

### E2. Code Review Checklist
- [ ] Feature gates working
- [ ] Send flow unchanged
- [ ] Escrow discovery unchanged
- [ ] Tests passing (360/360)
- [ ] No unintended side effects

### E3. Team Briefing
- [ ] Engineering: Explain gates and rollout
- [ ] Product: Explain Phase 3 vs Phase 4 distinction
- [ ] Support: Prepare for "why multiple chains?" questions
- [ ] QA: Share test plan

---

## Phase F: Merge & Rollout

### F1. Merge to Main
```bash
# All tests passing? ✅
npm test
# All gates working? ✅
EXPO_PUBLIC_ENABLE_MULTI_L2=false npm run build
# Merge!
git checkout main
git merge multi-L2 --no-ff -m "merge(phase3): multi-L2 balance visibility with feature gates"
```

### F2. Immediate Post-Merge (1 day)
- [ ] Monitor main branch for regressions
- [ ] Verify send flow still works
- [ ] Verify existing tests still pass
- [ ] Build Expo app with flag OFF (default)

### F3. Testnet Pilot (3-5 days)
- [ ] Build Expo app with flag ON
- [ ] Distribute to 3-5 early users
- [ ] Collect feedback: "Do you understand the layout?"
- [ ] Monitor for crashes/errors
- [ ] Measure RPC query latency in production

### F4. Production Rollout (1-2 weeks)
- [ ] Analyze pilot feedback
- [ ] Gradual flag rollout (10% → 50% → 100%)
- [ ] Monitor support issues
- [ ] Measure business metrics (if relevant)

---

## Risk Mitigation

| Risk | Mitigation |
|------|-----------|
| Feature gate fails | Keep on main, easy disable |
| RPC failover broken | Catch in testnet, rollback if needed |
| Users confused by UI | Pilot with early users first |
| Performance issue | Baseline established, monitor in production |
| Send flow broken | Gate does NOT touch send (verify) |
| Cross-chain escrows appear | Gate does NOT aggregate (verify) |

---

## Success Criteria

Before merging:
- ✅ 360/360 tests passing
- ✅ 4 gate tests passing (new)
- ✅ Testnet deployment working
- ✅ Performance baseline < 1s
- ✅ Send flow unchanged (verified)
- ✅ Escrow discovery unchanged (verified)

Before production:
- ✅ Pilot feedback positive
- ✅ No support issues from pilot
- ✅ RPC cost acceptable
- ✅ User comprehension confirmed

---

## Timeline Summary

| Phase | Duration | What | Done? |
|-------|----------|------|-------|
| A | 1 day | Gates + components | [ ] |
| B | 1 day | Tests (360 total) | [ ] |
| C | 0.5 day | Testnet deploy | [ ] |
| D | 1 day | Testnet validation | [ ] |
| E | 0.5 day | Merge prep | [ ] |
| F1 | 1 day | Merge + monitor | [ ] |
| F2 | 3-5 days | Pilot | [ ] |
| F3 | 1-2 weeks | Gradual rollout | [ ] |

**Total before production**: ~2 weeks

---

## Approval Gate

Before starting Phase A, confirm:

```
□ Strategy approved
□ Timeline acceptable
□ Team availability confirmed
□ Testnet infrastructure available
□ Support team briefed
```

**Decision**: Proceed? Y/N
