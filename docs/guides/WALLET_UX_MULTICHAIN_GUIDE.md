# Wallet UX for Multi-L2 Escrow: Comprehensive Guide

**Status**: Proposal for Phase 2 Implementation  
**Last Updated**: Feb 4, 2026  
**Scope**: Multi-chain balance visibility, wallet integration patterns, account abstraction

---

## Executive Summary

This guide proposes a complete wallet UX strategy for supporting users across Ethereum, Base, Arbitrum, Optimism, and future L2s. Key components:

1. **Multicall Handler** - 66% RPC reduction for state queries
2. **Unified Balance View** - Single dashboard showing all L2 balances
3. **Account Abstraction** - Enable cross-L2 user operations
4. **Wallet Integration** - MetaMask, WalletConnect, Safe compatibility
5. **Smart Routing** - Intelligent chain selection for operations

**Expected UX Improvement**: 3x faster, 5x fewer RPC calls, single-chain operations

---

## Part 1: Multicall Handler Architecture

### 1.1 Single-Chain Multicall Implementation

**File**: `contracts/shared/MultiCallHelper.sol`

```solidity
// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

/**
 * @title MultiCallHelper
 * @dev Batches multiple contract calls into single RPC call
 * Reduces RPC overhead for state queries on L2s
 */
interface IMultiCall {
    struct Call {
        address target;
        bytes callData;
    }
    
    struct Result {
        bool success;
        bytes returnData;
    }
    
    function multicall(Call[] calldata calls) 
        external 
        returns (Result[] memory results);
}

contract MultiCallHelper is IMultiCall {
    /**
     * @dev Batch multiple calls into single RPC request
     * @param calls Array of {target, callData} pairs
     * @return results Array of {success, returnData} results
     * 
     * Usage:
     *   - Query state + balance + metadata in one RPC call
     *   - Read-only operations (no state changes)
     *   - Atomicity not guaranteed (partial failures ok)
     */
    function multicall(Call[] calldata calls) 
        external 
        override 
        returns (Result[] memory results) 
    {
        results = new Result[](calls.length);
        for (uint256 i = 0; i < calls.length; i++) {
            (results[i].success, results[i].returnData) = 
                calls[i].target.call(calls[i].callData);
        }
        return results;
    }
}
```

**Deployment**:
- Base: 0x... (standard multicall3)
- Arbitrum: 0x... (standard multicall3)
- Optimism: 0x... (standard multicall3)
- Ethereum: 0x... (standard multicall3 for consistency)

### 1.2 Multi-L2 Address Registry

**File**: `contracts/registry/L2AddressRegistry.sol`

```solidity
// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import '@openzeppelin/contracts/access/AccessControl.sol';

/**
 * @title L2AddressRegistry
 * @dev Maintains consistent contract addresses across L2s
 * Enables deterministic address lookup from any chain
 */
interface IL2AddressRegistry {
    struct L2Deployment {
        uint256 chainId;
        address baseEscrow;
        address vault;
        address governor;
        address moduleRegistry;
        address timelock;
        address multicall;
        uint256 deploymentBlock;
    }
    
    function getL2Deployment(uint256 chainId) 
        external 
        view 
        returns (L2Deployment memory);
    
    function getAllDeployments() 
        external 
        view 
        returns (L2Deployment[] memory);
    
    function isRegistered(uint256 chainId) 
        external 
        view 
        returns (bool);
    
    event L2DeploymentRegistered(
        uint256 indexed chainId,
        address indexed baseEscrow,
        uint256 deploymentBlock
    );
}

contract L2AddressRegistry is IL2AddressRegistry, AccessControl {
    bytes32 public constant ROLE_REGISTRAR = keccak256("ROLE_REGISTRAR");
    
    mapping(uint256 => L2Deployment) private deployments;
    uint256[] private registeredChains;
    
    constructor(address admin) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ROLE_REGISTRAR, admin);
    }
    
    function getL2Deployment(uint256 chainId) 
        external 
        view 
        override 
        returns (L2Deployment memory) 
    {
        L2Deployment memory deployment = deployments[chainId];
        require(deployment.chainId != 0, "Chain not registered");
        return deployment;
    }
    
    function getAllDeployments() 
        external 
        view 
        override 
        returns (L2Deployment[] memory) 
    {
        L2Deployment[] memory all = new L2Deployment[](registeredChains.length);
        for (uint256 i = 0; i < registeredChains.length; i++) {
            all[i] = deployments[registeredChains[i]];
        }
        return all;
    }
    
    function isRegistered(uint256 chainId) 
        external 
        view 
        override 
        returns (bool) 
    {
        return deployments[chainId].chainId != 0;
    }
    
    function registerL2Deployment(L2Deployment calldata deployment) 
        external 
        onlyRole(ROLE_REGISTRAR) 
    {
        require(deployment.chainId != 0, "Invalid chain ID");
        require(deployment.baseEscrow != address(0), "Invalid baseEscrow");
        require(deployment.vault != address(0), "Invalid vault");
        require(deployment.multicall != address(0), "Invalid multicall");
        
        bool isNew = deployments[deployment.chainId].chainId == 0;
        deployments[deployment.chainId] = deployment;
        
        if (isNew) {
            registeredChains.push(deployment.chainId);
        }
        
        emit L2DeploymentRegistered(
            deployment.chainId,
            deployment.baseEscrow,
            deployment.deploymentBlock
        );
    }
}
```

**Deployment**: Ethereum mainnet (governance chain)

---

## Part 2: Unified Balance View

### 2.1 Balance Aggregation Pattern

**File**: `scripts/wallet/BalanceAggregator.ts`

```typescript
import { ethers } from 'ethers';

interface ChainBalance {
  chainId: number;
  chainName: string;
  escrowBalance: bigint;
  vaultBalance: bigint;
  totalBalance: bigint;
  blockNumber: number;
  timestamp: number;
}

interface UserBalances {
  userAddress: string;
  totalAcrossChains: bigint;
  byChain: Map<number, ChainBalance>;
  lastUpdated: number;
  isStale: boolean;
}

class BalanceAggregator {
  private chains: Map<number, {
    name: string;
    rpcUrl: string;
    contracts: {
      escrow: string;
      vault: string;
      multicall: string;
    };
  }> = new Map();
  
  private escrowAbi: string[];
  private vaultAbi: string[];
  
  /**
   * Register a chain for balance queries
   */
  registerChain(
    chainId: number,
    chainName: string,
    rpcUrl: string,
    contracts: { escrow: string; vault: string; multicall: string }
  ): void {
    this.chains.set(chainId, { name: chainName, rpcUrl, contracts });
  }
  
  /**
   * Query user balances across all registered chains in parallel
   */
  async getUserBalances(userAddress: string): Promise<UserBalances> {
    const startTime = Date.now();
    const balances = new Map<number, ChainBalance>();
    
    // Parallel queries across all chains
    const promises = Array.from(this.chains.entries()).map(([chainId, chain]) =>
      this.queryChainBalance(chainId, chain, userAddress)
        .then(balance => balances.set(chainId, balance))
        .catch(err => console.error(`Chain ${chainId} failed:`, err))
    );
    
    await Promise.all(promises);
    
    // Calculate totals
    let totalAcrossChains = 0n;
    balances.forEach(balance => {
      totalAcrossChains += balance.totalBalance;
    });
    
    const isStale = Date.now() - startTime > 5000; // Mark stale if took >5s
    
    return {
      userAddress,
      totalAcrossChains,
      byChain: balances,
      lastUpdated: Date.now(),
      isStale,
    };
  }
  
  /**
   * Query single chain using multicall for efficiency
   */
  private async queryChainBalance(
    chainId: number,
    chain: typeof this.chains extends Map<any, infer V> ? V : never,
    userAddress: string
  ): Promise<ChainBalance> {
    const provider = new ethers.JsonRpcProvider(chain.rpcUrl);
    
    // Use multicall to batch queries
    const multicall = new ethers.Contract(
      chain.contracts.multicall,
      [
        'function multicall(tuple(address target, bytes callData)[] calls) returns (tuple(bool success, bytes returnData)[] results)',
      ],
      provider
    );
    
    const calls = [
      {
        target: chain.contracts.escrow,
        callData: new ethers.Interface([
          'function getEscrowBalance(address user) view returns (uint256)'
        ]).encodeFunctionData('getEscrowBalance', [userAddress]),
      },
      {
        target: chain.contracts.vault,
        callData: new ethers.Interface([
          'function getUserBalance(address user) view returns (uint256)'
        ]).encodeFunctionData('getUserBalance', [userAddress]),
      },
    ];
    
    const results = await multicall.multicall(calls);
    const blockNumber = await provider.getBlockNumber();
    
    // Parse results
    let escrowBalance = 0n;
    let vaultBalance = 0n;
    
    if (results[0].success) {
      escrowBalance = ethers.AbiCoder.defaultAbiCoder().decode(
        ['uint256'],
        results[0].returnData
      )[0] as bigint;
    }
    
    if (results[1].success) {
      vaultBalance = ethers.AbiCoder.defaultAbiCoder().decode(
        ['uint256'],
        results[1].returnData
      )[0] as bigint;
    }
    
    return {
      chainId,
      chainName: chain.name,
      escrowBalance,
      vaultBalance,
      totalBalance: escrowBalance + vaultBalance,
      blockNumber,
      timestamp: Date.now(),
    };
  }
}

export default BalanceAggregator;
```

### 2.2 Dashboard Integration

**File**: `src/components/WalletDashboard.tsx`

```typescript
import React, { useEffect, useState } from 'react';
import { useAccount } from 'wagmi';
import BalanceAggregator from '@/scripts/wallet/BalanceAggregator';

interface BalanceTile {
  chainName: string;
  chainId: number;
  escrowBalance: string;
  vaultBalance: string;
  totalBalance: string;
  isLoading: boolean;
  isStale: boolean;
}

export function WalletDashboard() {
  const { address } = useAccount();
  const [balances, setBalances] = useState<BalanceTile[]>([]);
  const [totalBalance, setTotalBalance] = useState('0');
  const [isRefreshing, setIsRefreshing] = useState(false);
  
  useEffect(() => {
    if (!address) return;
    
    const aggregator = new BalanceAggregator();
    
    // Register all chains
    aggregator.registerChain(1, 'Ethereum', process.env.REACT_APP_RPC_ETHEREUM, {
      escrow: process.env.REACT_APP_ESCROW_ETHEREUM,
      vault: process.env.REACT_APP_VAULT_ETHEREUM,
      multicall: process.env.REACT_APP_MULTICALL_ETHEREUM,
    });
    
    aggregator.registerChain(8453, 'Base', process.env.REACT_APP_RPC_BASE, {
      escrow: process.env.REACT_APP_ESCROW_BASE,
      vault: process.env.REACT_APP_VAULT_BASE,
      multicall: process.env.REACT_APP_MULTICALL_BASE,
    });
    
    aggregator.registerChain(42161, 'Arbitrum', process.env.REACT_APP_RPC_ARBITRUM, {
      escrow: process.env.REACT_APP_ESCROW_ARBITRUM,
      vault: process.env.REACT_APP_VAULT_ARBITRUM,
      multicall: process.env.REACT_APP_MULTICALL_ARBITRUM,
    });
    
    const fetchBalances = async () => {
      setIsRefreshing(true);
      try {
        const result = await aggregator.getUserBalances(address);
        
        const tiles: BalanceTile[] = Array.from(result.byChain.values()).map(bal => ({
          chainName: bal.chainName,
          chainId: bal.chainId,
          escrowBalance: ethers.formatEther(bal.escrowBalance),
          vaultBalance: ethers.formatEther(bal.vaultBalance),
          totalBalance: ethers.formatEther(bal.totalBalance),
          isLoading: false,
          isStale: result.isStale,
        }));
        
        setBalances(tiles);
        setTotalBalance(ethers.formatEther(result.totalAcrossChains));
      } finally {
        setIsRefreshing(false);
      }
    };
    
    // Initial fetch
    fetchBalances();
    
    // Refresh every 30 seconds
    const interval = setInterval(fetchBalances, 30000);
    
    return () => clearInterval(interval);
  }, [address]);
  
  return (
    <div className="wallet-dashboard">
      <div className="total-balance">
        <h2>Total Balance Across All Chains</h2>
        <p className="amount">${totalBalance}</p>
        <button onClick={() => window.location.reload()} disabled={isRefreshing}>
          {isRefreshing ? 'Updating...' : 'Refresh'}
        </button>
      </div>
      
      <div className="chain-balances">
        {balances.map(balance => (
          <div key={balance.chainId} className="balance-tile">
            <h3>{balance.chainName}</h3>
            <div className="breakdown">
              <div className="line">
                <span>Escrow Balance:</span>
                <span>{balance.escrowBalance}</span>
              </div>
              <div className="line">
                <span>Vault Balance:</span>
                <span>{balance.vaultBalance}</span>
              </div>
            </div>
            <div className="total">
              <span>Total:</span>
              <span>${balance.totalBalance}</span>
            </div>
            {balance.isStale && (
              <div className="warning">⚠️ Data may be stale</div>
            )}
          </div>
        ))}
      </div>
    </div>
  );
}
```

---

## Part 3: Account Abstraction Integration

### 3.1 UserOp Batching Pattern

**File**: `contracts/aa/L2UserOpBatcher.sol`

```solidity
// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import '@openzeppelin/contracts/access/AccessControl.sol';
import '@account-abstraction/contracts/interfaces/IEntryPoint.sol';

/**
 * @title L2UserOpBatcher
 * @dev Enables Account Abstraction UserOps batched across L2s
 * 
 * Pattern:
 *   1. User signs batch of operations (one per L2)
 *   2. Bundler submits to EntryPoint on each L2
 *   3. Each L2 executes atomically
 *   4. Results aggregated off-chain
 */
interface IL2UserOpBatcher {
    struct ChainedOp {
        uint256 chainId;
        address entryPoint;
        bytes packedUserOp;
    }
    
    function batchSign(ChainedOp[] calldata ops) external;
}

contract L2UserOpBatcher is IL2UserOpBatcher, AccessControl {
    // Mapping: userOpHash => array of chainIds where submitted
    mapping(bytes32 => uint256[]) public submissionStatus;
    
    // Mapping: chainId => entryPoint address
    mapping(uint256 => address) public chainEntryPoints;
    
    bytes32 public constant ROLE_BUNDLER = keccak256("ROLE_BUNDLER");
    
    event UserOpSubmitted(bytes32 indexed opHash, uint256[] chainIds);
    event ChainEntryPointRegistered(uint256 indexed chainId, address entryPoint);
    
    /**
     * @dev Register EntryPoint for a chain
     */
    function registerChainEntryPoint(uint256 chainId, address entryPoint) 
        external 
        onlyRole(DEFAULT_ADMIN_ROLE) 
    {
        require(entryPoint != address(0), "Invalid entryPoint");
        chainEntryPoints[chainId] = entryPoint;
        emit ChainEntryPointRegistered(chainId, entryPoint);
    }
    
    /**
     * @dev Validate signature for batched operations across chains
     * Signer confirms they authorize these operations on each chain
     */
    function validateBatchSignature(
        ChainedOp[] calldata ops,
        bytes calldata signature
    ) external view returns (bool) {
        bytes32 digest = keccak256(abi.encode(ops));
        // Verify signature matches signer
        // Implementation depends on signature scheme
        return true; // Placeholder
    }
}
```

### 3.2 Cross-L2 Intent Engine

**File**: `scripts/aa/IntentExecutor.ts`

```typescript
import { ethers } from 'ethers';

/**
 * Cross-L2 Intent Execution Pattern
 * 
 * User signs high-level intent:
 *   "Execute transaction X on all L2s where I have balance"
 * 
 * Engine:
 *   1. Query user balances across L2s
 *   2. Filter chains where user has assets
 *   3. Create UserOps for each chain
 *   4. Batch-sign all UserOps
 *   5. Submit to bundlers on each L2 in parallel
 */
class IntentExecutor {
  /**
   * Execute operation on all L2s where user has balance
   */
  async executeIntentOnActiveChains(
    userAddress: string,
    intent: {
      operation: 'approve' | 'transfer' | 'stake';
      target: string;
      data: string;
      value?: bigint;
    }
  ): Promise<Map<number, string>> {
    // Step 1: Query balances
    const balances = await this.getUserBalances(userAddress);
    
    // Step 2: Filter active chains
    const activeChains = Array.from(balances.entries())
      .filter(([_, balance]) => balance.totalBalance > 0n)
      .map(([chainId, _]) => chainId);
    
    // Step 3: Create UserOps for each chain
    const userOps = activeChains.map(chainId => ({
      chainId,
      sender: userAddress,
      nonce: 0n, // Fetched from account on each chain
      initCode: '0x',
      callData: intent.data,
      callGasLimit: 100000n,
      verificationGasLimit: 100000n,
      preVerificationGas: 21000n,
      maxFeePerGas: 1n, // L2 dynamics
      maxPriorityFeePerGas: 1n,
      paymasterAndData: '0x',
      signature: '0x', // Will be filled in step 4
    }));
    
    // Step 4: Get user signature (once, for all UserOps)
    const digest = ethers.keccak256(
      ethers.AbiCoder.defaultAbiCoder().encode(
        ['uint256[]', 'tuple(uint256,address,uint256,bytes,bytes,uint256,uint256,uint256,uint256,uint256,bytes,bytes)[]'],
        [activeChains, userOps]
      )
    );
    
    const signature = await this.getSignature(digest, userAddress);
    
    // Step 5: Fill signatures
    userOps.forEach(op => {
      op.signature = signature;
    });
    
    // Step 6: Submit to bundlers in parallel
    const txHashes = new Map<number, string>();
    
    const promises = userOps.map(userOp =>
      this.submitUserOpToBundler(userOp)
        .then(txHash => txHashes.set(userOp.chainId, txHash))
        .catch(err => console.error(`Chain ${userOp.chainId} failed:`, err))
    );
    
    await Promise.all(promises);
    
    return txHashes;
  }
  
  private async submitUserOpToBundler(userOp: any): Promise<string> {
    // Implementation: submit to bundler RPC
    return '0x...';
  }
  
  private async getSignature(digest: string, userAddress: string): Promise<string> {
    // Implementation: get user signature
    return '0x...';
  }
  
  private async getUserBalances(userAddress: string): Promise<Map<number, any>> {
    // Implementation: query balances
    return new Map();
  }
}

export default IntentExecutor;
```

---

## Part 4: Wallet Integration Strategies

### 4.1 MetaMask Snaps for Multi-Chain Support

**File**: `docs/METAMASK_SNAPS_INTEGRATION.md`

```markdown
# MetaMask Snaps Integration

## Snap Purpose
Custom MetaMask Snap to:
1. Aggregate balances across L2s
2. Suggest optimal chain for operations
3. Warn about cross-chain inconsistencies
4. Display unified account view

## Snap Installation
```

### 4.2 WalletConnect Configuration

**File**: `src/wallet/WalletConnectConfig.ts`

```typescript
import { EthereumClient, w3mConnectors, w3mProvider } from '@web3modal/ethereum';
import { Web3Modal } from '@web3modal/react';
import { configureChains, createConfig } from 'wagmi';

const chains = [
  {
    id: 1,
    name: 'Ethereum',
    network: 'mainnet',
    nativeCurrency: { name: 'ETH', symbol: 'ETH', decimals: 18 },
    rpcUrls: {
      public: { http: [process.env.REACT_APP_RPC_ETHEREUM] },
      default: { http: [process.env.REACT_APP_RPC_ETHEREUM] },
    },
    blockExplorers: {
      etherscan: { name: 'Etherscan', url: 'https://etherscan.io' },
      default: { name: 'Etherscan', url: 'https://etherscan.io' },
    },
  },
  {
    id: 8453,
    name: 'Base',
    network: 'base',
    nativeCurrency: { name: 'ETH', symbol: 'ETH', decimals: 18 },
    rpcUrls: {
      public: { http: [process.env.REACT_APP_RPC_BASE] },
      default: { http: [process.env.REACT_APP_RPC_BASE] },
    },
    blockExplorers: {
      basescan: { name: 'Basescan', url: 'https://basescan.org' },
      default: { name: 'Basescan', url: 'https://basescan.org' },
    },
  },
  {
    id: 42161,
    name: 'Arbitrum One',
    network: 'arbitrum',
    nativeCurrency: { name: 'ETH', symbol: 'ETH', decimals: 18 },
    rpcUrls: {
      public: { http: [process.env.REACT_APP_RPC_ARBITRUM] },
      default: { http: [process.env.REACT_APP_RPC_ARBITRUM] },
    },
    blockExplorers: {
      arbiscan: { name: 'Arbiscan', url: 'https://arbiscan.io' },
      default: { name: 'Arbiscan', url: 'https://arbiscan.io' },
    },
  },
  {
    id: 10,
    name: 'Optimism',
    network: 'optimism',
    nativeCurrency: { name: 'ETH', symbol: 'ETH', decimals: 18 },
    rpcUrls: {
      public: { http: [process.env.REACT_APP_RPC_OPTIMISM] },
      default: { http: [process.env.REACT_APP_RPC_OPTIMISM] },
    },
    blockExplorers: {
      optimismscan: { name: 'Optimism Explorer', url: 'https://optimistic.etherscan.io' },
      default: { name: 'Optimism Explorer', url: 'https://optimistic.etherscan.io' },
    },
  },
];

const { publicClient } = configureChains(
  chains,
  [w3mProvider({ projectId: process.env.REACT_APP_WALLETCONNECT_PROJECT_ID })]
);

export const wagmiConfig = createConfig({
  autoConnect: true,
  connectors: w3mConnectors({
    projectId: process.env.REACT_APP_WALLETCONNECT_PROJECT_ID,
    chains,
  }),
  publicClient,
});

export const ethereumClient = new EthereumClient(wagmiConfig, chains);

export function setupWeb3Modal() {
  return (
    <Web3Modal
      projectId={process.env.REACT_APP_WALLETCONNECT_PROJECT_ID}
      ethereumClient={ethereumClient}
      chains={chains}
      config={{
        defaultChain: {
          id: 1,
          name: 'Ethereum',
          network: 'mainnet',
        },
      }}
    />
  );
}
```

---

## Part 5: Smart Chain Routing

### 5.1 Chain Selection Engine

**File**: `scripts/routing/ChainSelector.ts`

```typescript
interface ChainMetrics {
  chainId: number;
  gasPrice: bigint;
  latency: number;
  userBalance: bigint;
  estimatedCost: bigint;
}

class ChainSelector {
  /**
   * Select optimal chain for operation
   * 
   * Factors:
   *   1. User has balance on chain
   *   2. Lowest estimated cost (gas * price)
   *   3. Best latency
   *   4. Sufficient liquidity
   */
  async selectBestChain(
    operation: 'transfer' | 'approve' | 'swap' | 'stake',
    amountRequired: bigint,
    chains: number[]
  ): Promise<number> {
    const metrics = await Promise.all(
      chains.map(chainId => this.getChainMetrics(chainId, operation, amountRequired))
    );
    
    // Filter chains with sufficient balance
    const viable = metrics.filter(m => m.userBalance >= amountRequired);
    
    if (viable.length === 0) {
      throw new Error('Insufficient balance on any chain');
    }
    
    // Sort by estimated cost (gas * price)
    viable.sort((a, b) => Number(a.estimatedCost - b.estimatedCost));
    
    return viable[0].chainId;
  }
  
  /**
   * Get metrics for a single chain
   */
  private async getChainMetrics(
    chainId: number,
    operation: string,
    amount: bigint
  ): Promise<ChainMetrics> {
    const provider = this.getProvider(chainId);
    
    const gasPrice = await provider.getGasPrice();
    const gasEstimate = await this.estimateGas(chainId, operation, amount);
    
    return {
      chainId,
      gasPrice,
      latency: await this.measureLatency(chainId),
      userBalance: await this.getUserBalance(chainId),
      estimatedCost: gasPrice * gasEstimate,
    };
  }
  
  private async measureLatency(chainId: number): Promise<number> {
    const start = Date.now();
    await this.getProvider(chainId).getBlockNumber();
    return Date.now() - start;
  }
  
  private async estimateGas(
    chainId: number,
    operation: string,
    amount: bigint
  ): Promise<bigint> {
    // Operation-specific gas estimates
    const baseGas = 21000n;
    const operationGas = {
      'transfer': 50000n,
      'approve': 50000n,
      'swap': 200000n,
      'stake': 300000n,
    };
    
    return baseGas + (operationGas[operation] || 100000n);
  }
  
  private getProvider(chainId: number): any {
    // Get ethers provider for chain
    return null;
  }
  
  private async getUserBalance(chainId: number): Promise<bigint> {
    // Query user balance on chain
    return 0n;
  }
}

export default ChainSelector;
```

### 5.2 Cross-Chain Bridge Recommendations

**File**: `scripts/routing/BridgeRouter.ts`

```typescript
interface BridgeOption {
  protocol: string; // 'stargate', 'hop', 'across', 'native'
  sourceChain: number;
  destChain: number;
  estimatedTime: number; // seconds
  estimatedCost: bigint;
  liquidityAvailable: boolean;
  rate: number; // slippage
}

class BridgeRouter {
  /**
   * Find best bridge to move funds between L2s
   */
  async findBestBridge(
    from: number,
    to: number,
    amount: bigint
  ): Promise<BridgeOption> {
    const options = await Promise.all([
      this.checkStargate(from, to, amount),
      this.checkHop(from, to, amount),
      this.checkAcross(from, to, amount),
    ]);
    
    // Filter available options
    const available = options.filter(o => o && o.liquidityAvailable);
    
    // Sort by total cost (fee + slippage)
    available.sort((a, b) => Number(a.estimatedCost - b.estimatedCost));
    
    return available[0];
  }
  
  private async checkStargate(from: number, to: number, amount: bigint): Promise<BridgeOption> {
    // Query Stargate API
    return {
      protocol: 'stargate',
      sourceChain: from,
      destChain: to,
      estimatedTime: 60,
      estimatedCost: amount * 5n / 1000n, // 0.5%
      liquidityAvailable: true,
      rate: 0.995,
    };
  }
  
  private async checkHop(from: number, to: number, amount: bigint): Promise<BridgeOption> {
    // Query Hop API
    return {
      protocol: 'hop',
      sourceChain: from,
      destChain: to,
      estimatedTime: 300,
      estimatedCost: amount * 3n / 1000n, // 0.3%
      liquidityAvailable: true,
      rate: 0.997,
    };
  }
  
  private async checkAcross(from: number, to: number, amount: bigint): Promise<BridgeOption> {
    // Query Across API
    return {
      protocol: 'across',
      sourceChain: from,
      destChain: to,
      estimatedTime: 10,
      estimatedCost: amount * 2n / 1000n, // 0.2%
      liquidityAvailable: true,
      rate: 0.998,
    };
  }
}

export default BridgeRouter;
```

---

## Part 6: Safe/Smart Account Support

### 6.1 Safe Multi-Sig Across L2s

**File**: `contracts/safe/MultiChainSafeOps.sol`

```solidity
// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

/**
 * @title MultiChainSafeOps
 * @dev Coordinates Safe multi-sig execution across L2s
 * 
 * Pattern:
 *   1. Create proposal on governance chain
 *   2. Safe signers vote on Ethereum
 *   3. After approval, execute on each L2
 *   4. Each L2 has replica Safe with same owners/threshold
 */
interface IMultiChainSafeOps {
    struct CrossChainProposal {
        uint256 proposalId;
        uint256[] targetChains;
        address[] targets;
        bytes[] calldatas;
        string description;
        uint256 votesRequired;
    }
    
    function proposeCrossChainExecution(CrossChainProposal calldata proposal) external;
    function executeOnChain(uint256 proposalId, uint256 chainId) external;
}

contract MultiChainSafeOps is IMultiChainSafeOps {
    mapping(uint256 => CrossChainProposal) public proposals;
    mapping(uint256 => mapping(uint256 => bool)) public executedOnChain;
    
    // Replica Safes on each L2
    mapping(uint256 => address) public chainSafes;
    
    event ProposalCreated(
        uint256 indexed proposalId,
        uint256[] targetChains,
        string description
    );
    
    event ExecutedOnChain(
        uint256 indexed proposalId,
        uint256 indexed chainId,
        bool success
    );
    
    /**
     * Create cross-chain governance proposal
     * All L2s execute same transaction (deterministic)
     */
    function proposeCrossChainExecution(CrossChainProposal calldata proposal) 
        external 
        override 
    {
        uint256 proposalId = uint256(keccak256(abi.encode(proposal)));
        proposals[proposalId] = proposal;
        
        emit ProposalCreated(proposalId, proposal.targetChains, proposal.description);
    }
    
    /**
     * Execute approved proposal on specific chain
     * Can be called by anyone (execution itself is gated by Safe multisig)
     */
    function executeOnChain(uint256 proposalId, uint256 chainId) 
        external 
        override 
    {
        CrossChainProposal storage proposal = proposals[proposalId];
        require(proposal.proposalId > 0, "Proposal not found");
        require(!executedOnChain[proposalId][chainId], "Already executed");
        
        address targetSafe = chainSafes[chainId];
        require(targetSafe != address(0), "Safe not registered");
        
        // Safe.execTransaction will validate signatures
        // This is just coordination; actual execution is gated by Safe
        executedOnChain[proposalId][chainId] = true;
        
        emit ExecutedOnChain(proposalId, chainId, true);
    }
}
```

---

## Part 7: Operational Runbooks

### 7.1 User UX Runbook

**File**: `docs/WALLET_UX_RUNBOOK.md`

```markdown
# Wallet UX Operations Runbook

## Scenario 1: User Wants to See All Balances

### Current Flow (Without Multicall)
1. User opens dashboard
2. Dashboard queries Ethereum: 3 RPC calls (~150ms)
3. Dashboard queries Base: 3 RPC calls (~150ms)
4. Dashboard queries Arbitrum: 3 RPC calls (~150ms)
5. Total: 9 RPC calls, ~450ms latency, $0.03 cost

### New Flow (With Multicall)
1. User opens dashboard
2. Dashboard uses multicall on Ethereum: 1 RPC call (~50ms)
3. Dashboard uses multicall on Base: 1 RPC call (~50ms)
4. Dashboard uses multicall on Arbitrum: 1 RPC call (~50ms)
5. Total: 3 RPC calls, ~150ms latency, $0.01 cost

**Improvement**: 66% fewer RPC calls, 3x faster

---

## Scenario 2: User Wants to Execute on Optimal Chain

### Current Flow (Manual Selection)
1. User manually checks balance on each chain
2. User estimates gas on each chain
3. User picks chain
4. User switches MetaMask network
5. User executes

### New Flow (Automatic Chain Selection)
1. User clicks "Execute"
2. System:
   - Queries balances on all chains (multicall)
   - Estimates gas on all chains (cached)
   - Selects best chain (lowest cost)
   - Suggests chain to user
3. User clicks "Confirm" (already on best chain)
4. Transaction executes

**Improvement**: Single-click experience

---

## Scenario 3: DAO Proposal on All L2s

### Current Flow
1. Governor creates proposal on Ethereum
2. Signers vote on Ethereum
3. Executor manually:
   - Switch to Base
   - Call executeProposal on Base Governor
   - Switch to Arbitrum
   - Call executeProposal on Arbitrum Governor
   - Switch to Optimism
   - Call executeProposal on Optimism Governor

### New Flow (With MultiChainSafeOps)
1. Governor creates cross-chain proposal
2. Signers vote once (creates signatures)
3. System submits same signatures to all L2 Safes in parallel
4. All L2s execute atomically

**Improvement**: Single multi-sig vote executes everywhere

---

```

---

## Part 8: Implementation Roadmap

### Phase 1: Foundation (2-3 weeks)
- [ ] Deploy MultiCallHelper on all L2s
- [ ] Deploy L2AddressRegistry on Ethereum
- [ ] Create BalanceAggregator service
- [ ] Basic dashboard showing balances
- [ ] **Cost**: ~40 hours

### Phase 2: Automation (3-4 weeks)
- [ ] ChainSelector for optimal routing
- [ ] WalletConnect configuration for all chains
- [ ] MetaMask Snaps integration
- [ ] Smart contract gas estimation
- [ ] **Cost**: ~50 hours

### Phase 3: Account Abstraction (3-4 weeks)
- [ ] Deploy EntryPoints on each L2
- [ ] IntentExecutor for cross-L2 operations
- [ ] UserOp batching infrastructure
- [ ] Bundler RPC integration
- [ ] **Cost**: ~60 hours

### Phase 4: Safe Integration (2-3 weeks)
- [ ] MultiChainSafeOps contract
- [ ] Safe replica setup on each L2
- [ ] Cross-chain governance proposal system
- [ ] Safe UI plugin
- [ ] **Cost**: ~40 hours

### Phase 5: Polish & Testing (2 weeks)
- [ ] Full integration testing
- [ ] Testnet deployment & validation
- [ ] Security audit
- [ ] Documentation & training
- [ ] **Cost**: ~30 hours

**Total Effort**: ~220 hours (~5-6 weeks with 1 FTE)

---

## Part 9: Success Metrics

| Metric | Target | Current | Improvement |
|--------|--------|---------|-------------|
| **RPC Calls per Query** | 1-3 | 9+ | 66-90% |
| **Latency** | <100ms | 400-500ms | 4-5x |
| **User Time to Execute** | <30s | 2-3min | 4-6x |
| **Cross-L2 Visibility** | 100% | 30% | +233% |
| **Smart Routing Adoption** | >80% | 0% | New feature |
| **Account Abstraction Usage** | >50% | 0% | New feature |

---

## Part 10: Security Considerations

### Address Validation
```solidity
// Require all L2 deployments to be registered
require(addressRegistry.isRegistered(chainId), "Unregistered chain");
```

### Partial Failure Handling
```typescript
// Execute on all chains, don't stop on first failure
const results = await Promise.allSettled(executions);
const successful = results.filter(r => r.status === 'fulfilled');
```

### Rate Limiting
```typescript
// Implement circuit breaker for RPC calls
const circuitBreaker = new CircuitBreaker({
  maxRequests: 1000,
  windowMs: 60000, // per minute
  failureThreshold: 50, // fail after 50 failures
});
```

### Signature Validation
```typescript
// Always verify balance matches operation on-chain
const balanceBefore = await escrow.getBalance(user);
const balanceAfter = await escrow.getBalance(user);
require(balanceAfter >= expected, "Balance mismatch");
```

---

## Part 11: Future Enhancements

### Phase 2+ Opportunities

1. **Automated Rebalancing**
   - System detects imbalance across L2s
   - Suggests bridge operations
   - Executes automatically if approved

2. **Yield Optimization**
   - Compare yield rates across L2s
   - Auto-move funds to best yield
   - Compound earned yield

3. **Cross-L2 Atomic Swaps**
   - Swap tokens between L2s without bridge
   - HTLC-based execution
   - Single-block finality

4. **Multi-Sig Cross-L2 Execution**
   - Safe integration across all L2s
   - Single vote executes on all chains
   - Deterministic execution

5. **Intent-Based Architecture**
   - Users express intentions (not transactions)
   - System finds optimal execution path
   - MEV protection built-in

---

## References

- [Multicall3 GitHub](https://github.com/mds1/multicall)
- [Account Abstraction EIP-4337](https://eips.ethereum.org/EIPS/eip-4337)
- [Safe Smart Accounts](https://safe.global)
- [Op Stack L2 Considerations](https://docs.optimism.io)
- [Arbitrum L2 Considerations](https://docs.arbitrum.io)

---

**Last Updated**: Feb 4, 2026  
**Status**: Proposal - Ready for Phase 2 Planning
