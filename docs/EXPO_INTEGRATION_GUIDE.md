# Expo + Viem Integration Guide for Multi-L2 Balance Aggregator

## Overview

This guide shows how to integrate the Phase 3 Balance Aggregator contracts with your Expo app using **Viem** (already in your stack with wagmi).

**Architecture**: Direct RPC calls from Expo → Multicall3 → Balance Aggregator contracts

**No backend needed** - Simple, low latency, rate limits shared across instances.

---

## Installation

Your existing stack already has what we need:
- ✅ `viem` - For contract interactions
- ✅ `wagmi` - For wallet integration  
- ✅ `ethers` - For hdwallet operations

No new dependencies required!

---

## 1. Contract ABIs

Create `src/abis/index.ts`:

```typescript
export const BalanceAggregatorABI = [
  {
    type: 'function',
    name: 'aggregateBalances',
    inputs: [
      { name: 'user', type: 'address' },
      { name: 'tokens', type: 'address[]' },
      { name: 'calls', type: 'bytes[]' },
    ],
    outputs: [
      {
        type: 'tuple',
        components: [
          { name: 'user', type: 'address' },
          {
            name: 'balances',
            type: 'tuple[]',
            components: [
              { name: 'chainId', type: 'uint256' },
              { name: 'balance', type: 'uint256' },
              { name: 'success', type: 'bool' },
            ],
          },
          { name: 'timestamp', type: 'uint256' },
          { name: 'healthy', type: 'bool' },
        ],
      },
    ],
  },
  {
    type: 'function',
    name: 'encodeBalanceCall',
    inputs: [
      { name: 'token', type: 'address' },
      { name: 'user', type: 'address' },
    ],
    outputs: [{ type: 'bytes' }],
    stateMutability: 'pure',
  },
  {
    type: 'function',
    name: 'decodeBalanceResult',
    inputs: [{ name: 'result', type: 'bytes' }],
    outputs: [{ type: 'uint256' }],
    stateMutability: 'pure',
  },
  {
    type: 'event',
    name: 'BalanceQueried',
    inputs: [
      { name: 'user', type: 'address', indexed: true },
      { name: 'chainCount', type: 'uint256' },
    ],
  },
] as const;

export const MultiL2EscrowAggregatorABI = [
  {
    type: 'function',
    name: 'queryEscrows',
    inputs: [
      { name: 'user', type: 'address' },
      {
        name: 'escrows',
        type: 'tuple[]',
        components: [
          { name: 'chainId', type: 'uint256' },
          { name: 'escrowAddress', type: 'address' },
        ],
      },
    ],
    outputs: [
      {
        type: 'tuple',
        components: [
          { name: 'user', type: 'address' },
          {
            name: 'escrows',
            type: 'tuple[]',
            components: [
              { name: 'chainId', type: 'uint256' },
              { name: 'escrowAddress', type: 'address' },
              { name: 'escrowBalance', type: 'uint256' },
              { name: 'userBalance', type: 'uint256' },
              { name: 'active', type: 'bool' },
              { name: 'success', type: 'bool' },
            ],
          },
          { name: 'totalLocked', type: 'uint256' },
          { name: 'timestamp', type: 'uint256' },
          { name: 'healthyChains', type: 'uint8' },
        ],
      },
    ],
  },
  {
    type: 'function',
    name: 'queryEscrowsWithUSDC',
    inputs: [
      { name: 'user', type: 'address' },
      {
        name: 'escrows',
        type: 'tuple[]',
        components: [
          { name: 'chainId', type: 'uint256' },
          { name: 'escrowAddress', type: 'address' },
        ],
      },
    ],
    outputs: [
      {
        type: 'tuple',
        components: [
          { name: 'user', type: 'address' },
          {
            name: 'escrows',
            type: 'tuple[]',
            components: [
              { name: 'chainId', type: 'uint256' },
              { name: 'escrowAddress', type: 'address' },
              { name: 'escrowBalance', type: 'uint256' },
              { name: 'userBalance', type: 'uint256' },
              { name: 'active', type: 'bool' },
              { name: 'success', type: 'bool' },
            ],
          },
          { name: 'totalLocked', type: 'uint256' },
          { name: 'timestamp', type: 'uint256' },
          { name: 'healthyChains', type: 'uint8' },
        ],
      },
    ],
  },
  {
    type: 'event',
    name: 'QueryExecuted',
    inputs: [
      { name: 'user', type: 'address', indexed: true },
      { name: 'escrowCount', type: 'uint256' },
    ],
  },
] as const;

export const IMulticall3ABI = [
  {
    type: 'function',
    name: 'aggregate3',
    inputs: [
      {
        name: 'calls',
        type: 'tuple[]',
        components: [
          { name: 'target', type: 'address' },
          { name: 'allowFailure', type: 'bool' },
          { name: 'callData', type: 'bytes' },
        ],
      },
    ],
    outputs: [
      {
        name: 'returnData',
        type: 'tuple[]',
        components: [
          { name: 'success', type: 'bool' },
          { name: 'returnData', type: 'bytes' },
        ],
      },
    ],
  },
] as const;
```

---

## 2. Chain Configuration

Create `src/config/chains.ts`:

```typescript
import { mainnet, base, arbitrum, optimism } from 'viem/chains';

export const MULTICALL3_ADDRESS = '0xcA11bde05977b3631167028862bE2a173976CA11' as const;

export interface ChainConfig {
  id: number;
  name: string;
  rpcUrl: string;
  balanceAggregator: `0x${string}`;
  escrowAggregator: `0x${string}`;
  multicall3: `0x${string}`;
  nativeToken: {
    symbol: string;
    decimals: number;
  };
}

// Update these with your deployed contract addresses
export const CHAIN_CONFIGS: Record<number, ChainConfig> = {
  1: {
    id: 1,
    name: 'Ethereum',
    rpcUrl: 'https://eth-mainnet.g.alchemy.com/v2/' + process.env.EXPO_PUBLIC_ALCHEMY_KEY,
    balanceAggregator: '0x...', // Deploy and replace
    escrowAggregator: '0x...',
    multicall3: MULTICALL3_ADDRESS,
    nativeToken: { symbol: 'ETH', decimals: 18 },
  },
  8453: {
    id: 8453,
    name: 'Base',
    rpcUrl: 'https://base-mainnet.g.alchemy.com/v2/' + process.env.EXPO_PUBLIC_ALCHEMY_KEY,
    balanceAggregator: '0x...',
    escrowAggregator: '0x...',
    multicall3: MULTICALL3_ADDRESS,
    nativeToken: { symbol: 'ETH', decimals: 18 },
  },
  42161: {
    id: 42161,
    name: 'Arbitrum',
    rpcUrl: 'https://arbitrum-mainnet.infura.io/v3/' + process.env.EXPO_PUBLIC_INFURA_KEY,
    balanceAggregator: '0x...',
    escrowAggregator: '0x...',
    multicall3: MULTICALL3_ADDRESS,
    nativeToken: { symbol: 'ETH', decimals: 18 },
  },
  10: {
    id: 10,
    name: 'Optimism',
    rpcUrl: 'https://optimism-mainnet.infura.io/v3/' + process.env.EXPO_PUBLIC_INFURA_KEY,
    balanceAggregator: '0x...',
    escrowAggregator: '0x...',
    multicall3: MULTICALL3_ADDRESS,
    nativeToken: { symbol: 'ETH', decimals: 18 },
  },
};

// For testnet
export const TESTNET_CHAINS: Record<number, ChainConfig> = {
  11155111: {
    id: 11155111,
    name: 'Ethereum Sepolia',
    rpcUrl: 'https://sepolia.g.alchemy.com/v2/' + process.env.EXPO_PUBLIC_ALCHEMY_KEY,
    balanceAggregator: '0x...',
    escrowAggregator: '0x...',
    multicall3: MULTICALL3_ADDRESS,
    nativeToken: { symbol: 'ETH', decimals: 18 },
  },
  // ... other testnet chains
};
```

---

## 3. Core Hook: useMultiL2Escrows

Create `src/hooks/useMultiL2Escrows.ts`:

```typescript
import { useCallback, useEffect, useState } from 'react';
import { createPublicClient, http } from 'viem';
import { CHAIN_CONFIGS, ChainConfig } from '../config/chains';
import { MultiL2EscrowAggregatorABI } from '../abis';

interface EscrowQuery {
  chainId: number;
  escrowAddress: `0x${string}`;
}

interface EscrowBalance {
  chainId: number;
  escrowAddress: `0x${string}`;
  balance: bigint;
  active: boolean;
  healthy: boolean;
}

interface UseMultiL2EscrowsReturn {
  balances: Map<number, EscrowBalance>;
  totalLocked: bigint;
  loading: boolean;
  error: Error | null;
  healthyChains: number;
  totalChains: number;
  refetch: () => Promise<void>;
}

export function useMultiL2Escrows(
  userAddress: `0x${string}` | undefined,
  escrowQueries: EscrowQuery[],
  options?: { enabled?: boolean; refetchInterval?: number }
): UseMultiL2EscrowsReturn {
  const [balances, setBalances] = useState<Map<number, EscrowBalance>>(new Map());
  const [totalLocked, setTotalLocked] = useState(0n);
  const [healthyChains, setHealthyChains] = useState(0);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<Error | null>(null);

  const fetchBalances = useCallback(async () => {
    if (!userAddress || escrowQueries.length === 0) return;

    setLoading(true);
    setError(null);

    try {
      const newBalances = new Map<number, EscrowBalance>();
      let total = 0n;
      let healthy = 0;

      // Query each chain in parallel
      const queryPromises = escrowQueries.map(async (query) => {
        const config = CHAIN_CONFIGS[query.chainId];
        if (!config) {
          console.warn(`No config for chain ${query.chainId}`);
          return null;
        }

        try {
          const client = createPublicClient({
            chain: { id: query.chainId } as any,
            transport: http(config.rpcUrl),
          });

          // Call the queryEscrows function on the aggregator
          const result = await client.readContract({
            address: config.escrowAggregator as `0x${string}`,
            abi: MultiL2EscrowAggregatorABI,
            functionName: 'queryEscrows',
            args: [userAddress, [query]],
          });

          if (result && result.escrows && result.escrows[0]) {
            const escrowData = result.escrows[0];
            if (escrowData.success) {
              newBalances.set(query.chainId, {
                chainId: query.chainId,
                escrowAddress: query.escrowAddress,
                balance: BigInt(escrowData.userBalance),
                active: escrowData.active,
                healthy: true,
              });
              total += BigInt(escrowData.userBalance);
              healthy++;
            } else {
              newBalances.set(query.chainId, {
                chainId: query.chainId,
                escrowAddress: query.escrowAddress,
                balance: 0n,
                active: false,
                healthy: false,
              });
            }
          }
        } catch (err) {
          console.error(`Error querying escrow on chain ${query.chainId}:`, err);
          newBalances.set(query.chainId, {
            chainId: query.chainId,
            escrowAddress: query.escrowAddress,
            balance: 0n,
            active: false,
            healthy: false,
          });
        }
      });

      await Promise.all(queryPromises);

      setBalances(newBalances);
      setTotalLocked(total);
      setHealthyChains(healthy);
    } catch (err) {
      setError(err instanceof Error ? err : new Error(String(err)));
    } finally {
      setLoading(false);
    }
  }, [userAddress, escrowQueries]);

  // Fetch on mount and when dependencies change
  useEffect(() => {
    if (options?.enabled !== false) {
      fetchBalances();
    }
  }, [fetchBalances, options?.enabled]);

  // Refetch interval
  useEffect(() => {
    if (!options?.refetchInterval || options.enabled === false) return;

    const interval = setInterval(fetchBalances, options.refetchInterval);
    return () => clearInterval(interval);
  }, [fetchBalances, options?.refetchInterval, options?.enabled]);

  return {
    balances,
    totalLocked,
    loading,
    error,
    healthyChains,
    totalChains: escrowQueries.length,
    refetch: fetchBalances,
  };
}
```

---

## 4. Usage in Components

### Example: Balance Display Screen

```typescript
import React from 'react';
import { View, Text, ScrollView, ActivityIndicator } from 'react-native';
import { useAccount } from 'wagmi';
import { useMultiL2Escrows } from '../hooks/useMultiL2Escrows';
import { formatEther } from 'viem';

const escrowAddresses = {
  1: '0x...', // Ethereum escrow
  8453: '0x...', // Base escrow
  42161: '0x...', // Arbitrum escrow
  10: '0x...', // Optimism escrow
};

export function MultiL2BalanceScreen() {
  const { address } = useAccount();

  const escrowQueries = Object.entries(escrowAddresses).map(([chainId, escrowAddress]) => ({
    chainId: Number(chainId),
    escrowAddress: escrowAddress as `0x${string}`,
  }));

  const { balances, totalLocked, loading, error, healthyChains, totalChains, refetch } =
    useMultiL2Escrows(address, escrowQueries, {
      refetchInterval: 30_000, // Refresh every 30 seconds
    });

  if (!address) {
    return <Text>Please connect wallet</Text>;
  }

  if (loading && balances.size === 0) {
    return <ActivityIndicator />;
  }

  if (error) {
    return (
      <View>
        <Text>Error: {error.message}</Text>
        <Text onPress={refetch} style={{ color: 'blue' }}>
          Retry
        </Text>
      </View>
    );
  }

  return (
    <ScrollView>
      {/* Total */}
      <View style={{ padding: 16, backgroundColor: '#f5f5f5', borderRadius: 8 }}>
        <Text style={{ fontSize: 12, color: '#666' }}>Total Locked (All L2s)</Text>
        <Text style={{ fontSize: 24, fontWeight: 'bold' }}>
          {formatEther(totalLocked)} ETH
        </Text>
        <Text style={{ fontSize: 11, color: '#999' }}>
          {healthyChains}/{totalChains} chains healthy
        </Text>
      </View>

      {/* Per-chain breakdown */}
      {Array.from(balances.entries()).map(([chainId, balance]) => (
        <View key={chainId} style={{ padding: 12, borderBottomWidth: 1, borderBottomColor: '#eee' }}>
          <Text style={{ fontWeight: '600' }}>
            {chainId === 1 ? 'Ethereum' : chainId === 8453 ? 'Base' : `Chain ${chainId}`}
          </Text>
          <Text style={{ fontSize: 16 }}>{formatEther(balance.balance)} ETH</Text>
          <Text style={{ fontSize: 12, color: balance.healthy ? '#10b981' : '#ef4444' }}>
            {balance.healthy ? '✓ Healthy' : '✗ Failed'}
          </Text>
          {balance.active ? (
            <Text style={{ fontSize: 11, color: '#666' }}>Active</Text>
          ) : (
            <Text style={{ fontSize: 11, color: '#999' }}>Inactive</Text>
          )}
        </View>
      ))}
    </ScrollView>
  );
}
```

---

## 5. Environment Setup

Create `.env.local`:

```bash
# Alchemy key (for Ethereum, Base)
EXPO_PUBLIC_ALCHEMY_KEY=your_alchemy_key

# Infura key (for Arbitrum, Optimism)
EXPO_PUBLIC_INFURA_KEY=your_infura_key

# Contract addresses (after deployment)
EXPO_PUBLIC_BALANCE_AGGREGATOR_1=0x...
EXPO_PUBLIC_ESCROW_AGGREGATOR_1=0x...
# ... etc for each chain
```

---

## 6. Integration with Existing wagmi Setup

If you're already using wagmi, you can extend your existing config:

```typescript
// In your wagmi config
import { configureChains, createConfig } from 'wagmi';
import { mainnet, base, arbitrum, optimism } from 'wagmi/chains';
import { alchemyProvider } from 'wagmi/providers/alchemy';

export const { chains, publicClient } = configureChains(
  [mainnet, base, arbitrum, optimism],
  [alchemyProvider({ apiKey: process.env.EXPO_PUBLIC_ALCHEMY_KEY })],
);

export const config = createConfig({
  autoConnect: true,
  connectors: [
    // your existing connectors
  ],
  publicClient,
});
```

Then use the public client directly:

```typescript
import { usePublicClient } from 'wagmi';

export function useMultiL2BalancesWithWagmi(userAddress: string) {
  const publicClient = usePublicClient();

  // publicClient is already configured for the current chain
  // For multi-chain, create clients for each chain as shown in useMultiL2Escrows hook
}
```

---

## 7. Performance Tips for Mobile

### 1. **Debounce Refetches**
```typescript
const [lastRefetch, setLastRefetch] = useState(0);
const handleRefetch = useCallback(async () => {
  const now = Date.now();
  if (now - lastRefetch < 5000) return; // Don't refetch within 5 seconds
  
  setLastRefetch(now);
  await refetch();
}, [lastRefetch, refetch]);
```

### 2. **Cache Results Locally**
```typescript
import AsyncStorage from '@react-native-async-storage/async-storage';

const cacheKey = `escrow_balances_${userAddress}`;
const cached = await AsyncStorage.getItem(cacheKey);
if (cached && Date.now() - JSON.parse(cached).timestamp < 60_000) {
  // Use cache if less than 1 minute old
  setBalances(JSON.parse(cached).data);
}
```

### 3. **Parallel Queries**
The hook already does this with `Promise.all()` - queries all chains in parallel for best performance.

### 4. **Error Boundaries**
```typescript
export function BalanceScreenWithBoundary() {
  const [error, setError] = useState<Error | null>(null);

  if (error) {
    return <ErrorFallback error={error} onRetry={() => setError(null)} />;
  }

  return (
    <ErrorBoundary onError={setError}>
      <MultiL2BalanceScreen />
    </ErrorBoundary>
  );
}
```

---

## 8. Testing

```typescript
import { renderHook, waitFor } from '@testing-library/react-native';
import { useMultiL2Escrows } from './useMultiL2Escrows';

describe('useMultiL2Escrows', () => {
  it('should fetch balances for multiple chains', async () => {
    const { result } = renderHook(() =>
      useMultiL2Escrows('0x742d35Cc6634C0532925a3b844Bc2e7c1b0d14d7', [
        { chainId: 1, escrowAddress: '0x...' },
        { chainId: 8453, escrowAddress: '0x...' },
      ])
    );

    await waitFor(() => {
      expect(result.current.loading).toBe(false);
      expect(result.current.balances.size).toBeGreaterThan(0);
    });
  });

  it('should handle errors gracefully', async () => {
    const { result } = renderHook(() =>
      useMultiL2Escrows('0xinvalid', [
        { chainId: 999, escrowAddress: '0x...' }, // Invalid chain
      ])
    );

    await waitFor(() => {
      expect(result.current.error).toBeDefined();
    });
  });
});
```

---

## 9. Full Working Example

```typescript
import React, { useCallback } from 'react';
import { View, Text, ScrollView, ActivityIndicator, TouchableOpacity } from 'react-native';
import { useAccount } from 'wagmi';
import { useMultiL2Escrows } from '../hooks/useMultiL2Escrows';
import { formatEther } from 'viem';

const ESCROW_QUERIES = [
  { chainId: 1, escrowAddress: '0x...' },
  { chainId: 8453, escrowAddress: '0x...' },
  { chainId: 42161, escrowAddress: '0x...' },
  { chainId: 10, escrowAddress: '0x...' },
];

export function MultiL2BalanceWidget() {
  const { address } = useAccount();
  const [showDetails, setShowDetails] = React.useState(false);

  const { balances, totalLocked, loading, error, healthyChains, totalChains, refetch } =
    useMultiL2Escrows(address, ESCROW_QUERIES, {
      refetchInterval: 30_000,
    });

  if (!address) return <Text>Connect wallet</Text>;

  return (
    <View style={{ flex: 1 }}>
      {/* Header */}
      <View style={{ padding: 16, backgroundColor: '#f0f9ff', borderRadius: 12 }}>
        <Text style={{ fontSize: 14, color: '#666', marginBottom: 4 }}>
          Total Locked (All L2s)
        </Text>
        <View style={{ flexDirection: 'row', alignItems: 'baseline', justifyContent: 'space-between' }}>
          <Text style={{ fontSize: 32, fontWeight: 'bold' }}>
            {loading ? '...' : formatEther(totalLocked)}
          </Text>
          <Text style={{ fontSize: 12, color: '#999' }}>ETH</Text>
        </View>
        <Text style={{ fontSize: 11, color: '#666', marginTop: 4 }}>
          {healthyChains}/{totalChains} chains responsive
        </Text>
      </View>

      {/* Error */}
      {error && (
        <View style={{ padding: 12, backgroundColor: '#fee2e2', marginVertical: 8, borderRadius: 8 }}>
          <Text style={{ color: '#dc2626' }}>Error: {error.message}</Text>
          <TouchableOpacity onPress={refetch}>
            <Text style={{ color: '#0ea5e9', marginTop: 8, fontWeight: '600' }}>Retry</Text>
          </TouchableOpacity>
        </View>
      )}

      {/* Details Toggle */}
      <TouchableOpacity
        onPress={() => setShowDetails(!showDetails)}
        style={{ paddingHorizontal: 16, paddingVertical: 12 }}
      >
        <Text style={{ color: '#0ea5e9', fontWeight: '600' }}>
          {showDetails ? 'Hide' : 'Show'} Details
        </Text>
      </TouchableOpacity>

      {/* Per-chain Details */}
      {showDetails && (
        <ScrollView style={{ flex: 1 }}>
          {Array.from(balances.entries()).map(([chainId, balance]) => (
            <View
              key={chainId}
              style={{
                padding: 12,
                marginHorizontal: 16,
                marginVertical: 4,
                backgroundColor: balance.healthy ? '#f0fdf4' : '#fef2f2',
                borderLeftWidth: 4,
                borderLeftColor: balance.healthy ? '#10b981' : '#ef4444',
                borderRadius: 8,
              }}
            >
              <View style={{ flexDirection: 'row', justifyContent: 'space-between' }}>
                <Text style={{ fontWeight: '600' }}>
                  {chainId === 1
                    ? 'Ethereum'
                    : chainId === 8453
                      ? 'Base'
                      : chainId === 42161
                        ? 'Arbitrum'
                        : chainId === 10
                          ? 'Optimism'
                          : `Chain ${chainId}`}
                </Text>
                <Text style={{ fontWeight: 'bold', fontSize: 16 }}>
                  {formatEther(balance.balance)}
                </Text>
              </View>
              <View style={{ flexDirection: 'row', marginTop: 8, gap: 8 }}>
                <Text style={{ fontSize: 12, color: balance.healthy ? '#10b981' : '#ef4444' }}>
                  {balance.healthy ? '✓ Healthy' : '✗ Failed'}
                </Text>
                <Text style={{ fontSize: 12, color: '#666' }}>
                  {balance.active ? 'Active' : 'Inactive'}
                </Text>
              </View>
            </View>
          ))}
        </ScrollView>
      )}

      {/* Loading */}
      {loading && balances.size === 0 && <ActivityIndicator size="large" style={{ marginTop: 20 }} />}
    </View>
  );
}
```

---

## 10. Deployment Checklist

Before going to production:

- [ ] Deploy Phase 3 contracts to all mainnet L2s
- [ ] Update contract addresses in `config/chains.ts`
- [ ] Test on testnet first (Sepolia, Base Sepolia, etc.)
- [ ] Set up Alchemy + Infura keys in `.env`
- [ ] Test with real transactions
- [ ] Monitor gas costs per query
- [ ] Set up analytics to track balance queries
- [ ] Create rate limiting if needed (per IP/user)

---

## Summary

Your Expo app can now query multi-L2 balances directly using Viem:

✅ No backend needed
✅ Direct RPC calls via Alchemy  
✅ Parallel queries for speed
✅ Error handling + fallbacks
✅ Mobile optimized

**Next**: Deploy Phase 3 contracts, update addresses, and ship! 🚀
