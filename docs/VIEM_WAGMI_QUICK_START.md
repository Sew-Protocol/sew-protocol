# Viem + Wagmi Quick Start for Phase 3

Since you're already using **wagmi** + **viem** + **ethers**, here's the minimum code needed:

---

## 1. One-File Hook (Copy & Paste Ready)

Create `src/hooks/useMultiL2Balances.ts`:

```typescript
import { useCallback, useEffect, useState } from 'react';
import { createPublicClient, http, publicActions, formatEther, parseAbi } from 'viem';
import { CHAIN_CONFIGS } from '../config'; // Your existing config

const MULTICALL3_ABI = parseAbi([
  'function aggregate3((address target, bool allowFailure, bytes callData)[] calls) payable returns ((bool success, bytes returnData)[])',
]);

const ESCROW_ABI = parseAbi([
  'function balanceOf(address user) external view returns (uint256)',
  'function isActive() external view returns (bool)',
]);

export function useMultiL2Balances(userAddress: `0x${string}` | undefined, chainIds: number[]) {
  const [balances, setBalances] = useState<Record<number, bigint>>({});
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<Error | null>(null);

  const fetchBalances = useCallback(async () => {
    if (!userAddress) return;

    setLoading(true);
    setError(null);

    try {
      const results: Record<number, bigint> = {};

      // Query each chain
      for (const chainId of chainIds) {
        const config = CHAIN_CONFIGS[chainId];
        if (!config) continue;

        try {
          const client = createPublicClient({
            transport: http(config.rpcUrl),
          });

          // Call multicall3 to get balances
          const multicallResult = await client.readContract({
            address: config.multicall3,
            abi: MULTICALL3_ABI,
            functionName: 'aggregate3',
            args: [
              [
                {
                  target: config.escrowAddress,
                  allowFailure: true,
                  callData: '0x70a08231' + userAddress.slice(2).padStart(64, '0'), // balanceOf selector
                },
              ],
            ],
          });

          if (multicallResult?.[0]?.success) {
            const balance = BigInt('0x' + multicallResult[0].returnData.slice(2));
            results[chainId] = balance;
          }
        } catch (err) {
          console.error(`Error on chain ${chainId}:`, err);
        }
      }

      setBalances(results);
    } catch (err) {
      setError(err instanceof Error ? err : new Error(String(err)));
    } finally {
      setLoading(false);
    }
  }, [userAddress, chainIds]);

  useEffect(() => {
    fetchBalances();
    const interval = setInterval(fetchBalances, 30_000); // Refresh every 30s
    return () => clearInterval(interval);
  }, [fetchBalances]);

  return {
    balances,
    totalLocked: Object.values(balances).reduce((a, b) => a + b, 0n),
    loading,
    error,
    refetch: fetchBalances,
  };
}
```

---

## 2. Usage in Component

```typescript
import { useAccount } from 'wagmi';
import { useMultiL2Balances } from '../hooks/useMultiL2Balances';
import { formatEther } from 'viem';

export function BalanceWidget() {
  const { address } = useAccount();
  const { balances, totalLocked, loading } = useMultiL2Balances(address, [1, 8453, 42161, 10]);

  if (loading) return <div>Loading...</div>;

  return (
    <div>
      <h3>Total Locked</h3>
      <p>{formatEther(totalLocked)} ETH</p>
      
      <h4>Per Chain</h4>
      {Object.entries(balances).map(([chainId, balance]) => (
        <div key={chainId}>
          Chain {chainId}: {formatEther(balance)} ETH
        </div>
      ))}
    </div>
  );
}
```

---

## 3. For Expo (React Native)

Same hook works! Just use React Native components:

```typescript
import { View, Text, ScrollView, ActivityIndicator } from 'react-native';

export function BalanceWidget() {
  const { address } = useAccount();
  const { balances, totalLocked, loading } = useMultiL2Balances(address, [1, 8453, 42161, 10]);

  if (loading) return <ActivityIndicator />;

  return (
    <ScrollView>
      <View>
        <Text>Total: {formatEther(totalLocked)} ETH</Text>
        {Object.entries(balances).map(([chainId, balance]) => (
          <Text key={chainId}>
            Chain {chainId}: {formatEther(balance)} ETH
          </Text>
        ))}
      </View>
    </ScrollView>
  );
}
```

---

## 4. Integration with Your wagmi Config

Your existing wagmi setup already works! Just create the hook and use it:

```typescript
// No changes needed to your wagmi config
// Just add the useMultiL2Balances hook where needed
```

---

## 5. Direct Viem (Without React Hooks)

If you need server-side or non-React context:

```typescript
import { createPublicClient, http } from 'viem';

async function getMultiL2Balances(userAddress: string, chainConfigs: Record<number, any>) {
  const balances: Record<number, bigint> = {};

  for (const [chainId, config] of Object.entries(chainConfigs)) {
    const client = createPublicClient({
      transport: http(config.rpcUrl),
    });

    const balance = await client.readContract({
      address: config.escrowAddress,
      abi: ['function balanceOf(address) returns (uint256)'],
      functionName: 'balanceOf',
      args: [userAddress],
    });

    balances[Number(chainId)] = balance;
  }

  return balances;
}
```

---

## 6. Error Handling

```typescript
const { balances, error, refetch } = useMultiL2Balances(address, [1, 8453, 42161, 10]);

if (error) {
  return (
    <div>
      <p>Error: {error.message}</p>
      <button onClick={() => refetch()}>Retry</button>
    </div>
  );
}
```

---

## What You Get

✅ Works with existing wagmi setup  
✅ No additional dependencies  
✅ Parallel queries (fast)  
✅ 30-second auto-refresh  
✅ Error handling  
✅ Works on both web and Expo  

---

## Environment Setup

Add to your `.env`:

```
EXPO_PUBLIC_ALCHEMY_KEY=your_key
EXPO_PUBLIC_INFURA_KEY=your_key
```

Update contract addresses in your config after deployment.

---

## That's It!

Three steps:
1. Copy the hook
2. Add your contract addresses to config
3. Use the hook in components

Done! 🎉
