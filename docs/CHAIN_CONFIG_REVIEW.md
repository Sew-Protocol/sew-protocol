# Chain Configuration Review

**Date:** 2026-01-16  
**Status:** Review Complete

## Executive Summary

This document reviews the current chain configuration infrastructure, identifies gaps, and proposes improvements for production-ready testnet and mainnet deployments.

## Current State Analysis

### ✅ What's Working Well

1. **Hardhat Network Configuration** (`hardhat.config.ts`)
   - ✅ Supports multiple networks: `hardhat`, `baseSepolia`, `base`, `ethereum`
   - ✅ Chain IDs properly configured
   - ✅ RPC endpoints via environment variables
   - ✅ Etherscan API keys configured
   - ✅ Safety check: `requireConfirmForMainnetLike()` prevents accidental mainnet deployments

2. **Deployment Tracking** (`scripts/_lib/ledger.ts`)
   - ✅ Timestamped deployment ledgers: `deploy-ledger/<network>/<timestamp>/`
   - ✅ Metadata bundle (network, chainId, timestamp, deployer, blockNumber, gitSha)
   - ✅ Address bundle (all deployed contracts)
   - ✅ ABI snapshots

3. **Network Detection** (`deploy/_config.ts`)
   - ✅ Local network detection: `isLocal = network.name === 'hardhat' || chainId === 31337`
   - ✅ Different validation rules for local vs production

4. **Address Loading** (`scripts/gov/addresses.ts`)
   - ✅ Loads addresses from hardhat-deploy artifacts
   - ✅ Supports placeholder addresses for offline proposal building

### ⚠️ Gaps and Missing Pieces

#### 1. **No Centralized Chain Registry**

**Problem:**
- Chain-specific information scattered across multiple files
- No single source of truth for chain metadata
- Hard to add new networks or query chain information

**Missing Information:**
- Chain names and display names
- Native currency (ETH, etc.)
- Block explorer URLs
- RPC endpoint patterns
- Chain-specific contract addresses (e.g., Aave pools, oracles)
- Network type (mainnet, testnet, local)

#### 2. **No Chain-Specific Contract Addresses Registry**

**Problem:**
- Aave pool addresses, oracle addresses, etc. are hardcoded or in env vars
- No validation that addresses match the current chain
- No easy way to query "what's the Aave pool address on Base?"

**Example:**
```typescript
// Currently: Hardcoded or env var
const aavePool = process.env.AAVE_POOL_ADDRESS;

// Should be:
const aavePool = getChainConfig(hre).aave.poolAddress;
```

#### 3. **Incomplete Deployment Metadata**

**Problem:**
- Deployment ledger has basic metadata but missing:
  - Chain-specific configuration used
  - Governance parameters
  - Initial contract parameters
  - Deployment verification status
  - Links to block explorer

#### 4. **No Network Validation**

**Problem:**
- No validation that chainId matches network name
- No validation that RPC endpoint matches expected chain
- No checks for testnet vs mainnet mismatches

#### 5. **No Deployment Registry**

**Problem:**
- No centralized registry of all deployments across chains
- Hard to answer: "What contracts are deployed on Base mainnet?"
- No easy way to compare deployments across networks

## Proposed Solutions

### Solution 1: Chain Registry Configuration

**File:** `config/chains.config.ts`

```typescript
export interface ChainConfig {
  // Basic info
  chainId: number;
  name: string; // "base", "baseSepolia", etc.
  displayName: string; // "Base Mainnet", "Base Sepolia"
  networkType: 'mainnet' | 'testnet' | 'local';
  
  // RPC & Explorer
  rpcUrl: string; // Pattern or actual URL
  blockExplorer: {
    name: string; // "Basescan", "Etherscan"
    url: string; // "https://basescan.org"
    apiUrl?: string; // For verification
  };
  
  // Native currency
  nativeCurrency: {
    name: string; // "Ether"
    symbol: string; // "ETH"
    decimals: number; // 18
  };
  
  // Chain-specific contracts
  contracts: {
    aave?: {
      poolAddress: string;
      poolDataProvider?: string;
    };
    oracles?: {
      [name: string]: string;
    };
    bridges?: {
      [name: string]: string;
    };
  };
  
  // Deployment settings
  deployment: {
    confirmRequired: boolean;
    gasPrice?: string; // Optional gas price override
    gasLimit?: number; // Optional gas limit override
  };
}

export const CHAIN_CONFIGS: Record<string, ChainConfig> = {
  base: {
    chainId: 8453,
    name: 'base',
    displayName: 'Base Mainnet',
    networkType: 'mainnet',
    rpcUrl: process.env.RPC_BASE_MAINNET || '',
    blockExplorer: {
      name: 'Basescan',
      url: 'https://basescan.org',
      apiUrl: 'https://api.basescan.org/api',
    },
    nativeCurrency: {
      name: 'Ether',
      symbol: 'ETH',
      decimals: 18,
    },
    contracts: {
      aave: {
        poolAddress: '0x...', // Base mainnet Aave pool
      },
    },
    deployment: {
      confirmRequired: true,
    },
  },
  baseSepolia: {
    chainId: 84532,
    name: 'baseSepolia',
    displayName: 'Base Sepolia',
    networkType: 'testnet',
    rpcUrl: process.env.RPC_BASE_SEPOLIA || '',
    blockExplorer: {
      name: 'Basescan',
      url: 'https://sepolia.basescan.org',
      apiUrl: 'https://api-sepolia.basescan.org/api',
    },
    nativeCurrency: {
      name: 'Ether',
      symbol: 'ETH',
      decimals: 18,
    },
    contracts: {
      aave: {
        poolAddress: '0x...', // Base Sepolia Aave pool
      },
    },
    deployment: {
      confirmRequired: false,
    },
  },
  ethereum: {
    chainId: 1,
    name: 'ethereum',
    displayName: 'Ethereum Mainnet',
    networkType: 'mainnet',
    rpcUrl: process.env.RPC_ETHEREUM || '',
    blockExplorer: {
      name: 'Etherscan',
      url: 'https://etherscan.io',
      apiUrl: 'https://api.etherscan.io/api',
    },
    nativeCurrency: {
      name: 'Ether',
      symbol: 'ETH',
      decimals: 18,
    },
    contracts: {
      aave: {
        poolAddress: '0x87870Bca3F3fD6335C3F4ce8392A693fcB2bA5Ae', // Ethereum mainnet
      },
    },
    deployment: {
      confirmRequired: true,
    },
  },
  hardhat: {
    chainId: 31337,
    name: 'hardhat',
    displayName: 'Hardhat Local',
    networkType: 'local',
    rpcUrl: 'http://127.0.0.1:8545',
    blockExplorer: {
      name: 'Local',
      url: '',
    },
    nativeCurrency: {
      name: 'Ether',
      symbol: 'ETH',
      decimals: 18,
    },
    deployment: {
      confirmRequired: false,
    },
  },
};

export function getChainConfig(hre: HardhatRuntimeEnvironment): ChainConfig {
  const networkName = hre.network.name;
  const chainId = hre.network.config.chainId ?? 31337;
  
  // Find by network name first
  let config = CHAIN_CONFIGS[networkName];
  
  // Fallback: find by chainId
  if (!config) {
    config = Object.values(CHAIN_CONFIGS).find(c => c.chainId === chainId);
  }
  
  if (!config) {
    throw new Error(
      `Unknown network: ${networkName} (chainId: ${chainId}). ` +
      `Add configuration to config/chains.config.ts`
    );
  }
  
  // Validate chainId matches
  if (config.chainId !== chainId) {
    throw new Error(
      `Chain ID mismatch: network ${networkName} has chainId ${chainId}, ` +
      `but config expects ${config.chainId}`
    );
  }
  
  return config;
}

export function isMainnet(hre: HardhatRuntimeEnvironment): boolean {
  return getChainConfig(hre).networkType === 'mainnet';
}

export function isTestnet(hre: HardhatRuntimeEnvironment): boolean {
  return getChainConfig(hre).networkType === 'testnet';
}

export function isLocal(hre: HardhatRuntimeEnvironment): boolean {
  return getChainConfig(hre).networkType === 'local';
}
```

### Solution 2: Deployment Registry

**File:** `config/deployments.registry.ts`

```typescript
export interface DeploymentRecord {
  chainId: number;
  networkName: string;
  contractName: string;
  address: string;
  deploymentTxHash: string;
  blockNumber: number;
  deployer: string;
  timestamp: string;
  verified: boolean;
  blockExplorerUrl: string;
  constructorArgs?: any[];
  implementationAddress?: string; // For proxies
  proxyAdmin?: string; // For transparent proxies
}

export interface ChainDeployments {
  chainId: number;
  networkName: string;
  deployments: DeploymentRecord[];
  deployedAt: string;
  deployer: string;
  gitSha?: string;
}

// In-memory registry (could be persisted to JSON)
const deploymentsRegistry: Map<number, ChainDeployments> = new Map();

export function registerDeployment(
  hre: HardhatRuntimeEnvironment,
  contractName: string,
  deployment: {
    address: string;
    txHash: string;
    blockNumber: number;
    constructorArgs?: any[];
    implementationAddress?: string;
    proxyAdmin?: string;
  }
): void {
  const chainConfig = getChainConfig(hre);
  const [signer] = hre.ethers.getSigners();
  
  const record: DeploymentRecord = {
    chainId: chainConfig.chainId,
    networkName: chainConfig.name,
    contractName,
    address: deployment.address,
    deploymentTxHash: deployment.txHash,
    blockNumber: deployment.blockNumber,
    deployer: signer.address,
    timestamp: new Date().toISOString(),
    verified: false, // Set after verification
    blockExplorerUrl: `${chainConfig.blockExplorer.url}/address/${deployment.address}`,
    constructorArgs: deployment.constructorArgs,
    implementationAddress: deployment.implementationAddress,
    proxyAdmin: deployment.proxyAdmin,
  };
  
  // Get or create chain deployments
  let chainDeployments = deploymentsRegistry.get(chainConfig.chainId);
  if (!chainDeployments) {
    chainDeployments = {
      chainId: chainConfig.chainId,
      networkName: chainConfig.name,
      deployments: [],
      deployedAt: new Date().toISOString(),
      deployer: signer.address,
      gitSha: process.env.GIT_SHA,
    };
    deploymentsRegistry.set(chainConfig.chainId, chainDeployments);
  }
  
  // Add or update deployment
  const existing = chainDeployments.deployments.findIndex(
    d => d.contractName === contractName
  );
  if (existing >= 0) {
    chainDeployments.deployments[existing] = record;
  } else {
    chainDeployments.deployments.push(record);
  }
}

export function getDeploymentsForChain(
  chainId: number
): ChainDeployments | undefined {
  return deploymentsRegistry.get(chainId);
}

export function getAllDeployments(): ChainDeployments[] {
  return Array.from(deploymentsRegistry.values());
}

export function getDeployment(
  chainId: number,
  contractName: string
): DeploymentRecord | undefined {
  const chainDeployments = deploymentsRegistry.get(chainId);
  return chainDeployments?.deployments.find(
    d => d.contractName === contractName
  );
}
```

### Solution 3: Enhanced Deployment Metadata

**File:** `scripts/_lib/ledger.ts` (enhanced)

```typescript
import { getChainConfig } from '../../config/chains.config';
import { registerDeployment } from '../../config/deployments.registry';

export async function enhancedMetaBundle(hre: HardhatRuntimeEnvironment) {
  const chainConfig = getChainConfig(hre);
  const [signer] = await ethers.getSigners();
  const net = await ethers.provider.getNetwork();
  const blockNumber = await ethers.provider.getBlockNumber();
  const gitSha = process.env.GIT_SHA;
  
  return {
    // Existing
    network: hre.network.name,
    chainId: Number(net.chainId),
    timestamp: new Date().toISOString(),
    deployer: await signer.getAddress(),
    blockNumber,
    gitSha,
    
    // New: Chain info
    chain: {
      name: chainConfig.name,
      displayName: chainConfig.displayName,
      networkType: chainConfig.networkType,
      blockExplorer: chainConfig.blockExplorer.url,
    },
    
    // New: Deployment config
    deploymentConfig: {
      governance: await getGovConfig(hre), // If available
      chainContracts: chainConfig.contracts,
    },
  };
}
```

### Solution 4: Network Validation Utility

**File:** `scripts/_lib/network-validation.ts`

```typescript
import { HardhatRuntimeEnvironment } from 'hardhat/types';
import { getChainConfig } from '../../config/chains.config';

export async function validateNetwork(
  hre: HardhatRuntimeEnvironment
): Promise<void> {
  const chainConfig = getChainConfig(hre);
  const network = await hre.ethers.provider.getNetwork();
  
  // Validate chainId matches
  if (Number(network.chainId) !== chainConfig.chainId) {
    throw new Error(
      `Chain ID mismatch: RPC returned ${network.chainId}, ` +
      `but config expects ${chainConfig.chainId} for ${chainConfig.name}`
    );
  }
  
  // Validate RPC endpoint (basic check)
  if (chainConfig.rpcUrl && !chainConfig.rpcUrl.includes('localhost')) {
    try {
      const blockNumber = await hre.ethers.provider.getBlockNumber();
      console.log(`✅ Network validated: ${chainConfig.displayName} (block ${blockNumber})`);
    } catch (error) {
      throw new Error(
        `Failed to connect to RPC endpoint for ${chainConfig.displayName}: ${error}`
      );
    }
  }
  
  // Warn if deploying to mainnet without confirmation
  if (chainConfig.networkType === 'mainnet' && chainConfig.deployment.confirmRequired) {
    if (process.env.DEPLOY_CONFIRM !== 'YES') {
      throw new Error(
        `Mainnet deployment requires DEPLOY_CONFIRM=YES. ` +
        `Current value: ${process.env.DEPLOY_CONFIRM || 'not set'}`
      );
    }
  }
}
```

## Implementation Plan

### Phase 1: Chain Registry (High Priority)

1. ✅ Create `config/chains.config.ts` with chain configurations
2. ✅ Update `hardhat.config.ts` to use chain registry
3. ✅ Add network validation utility
4. ✅ Update deployment scripts to use chain config

### Phase 2: Deployment Registry (Medium Priority)

1. ✅ Create `config/deployments.registry.ts`
2. ✅ Integrate with deployment scripts
3. ✅ Add persistence (JSON file per chain)
4. ✅ Create CLI tool to query deployments

### Phase 3: Enhanced Metadata (Low Priority)

1. ✅ Enhance `metaBundle()` with chain info
2. ✅ Add deployment config to metadata
3. ✅ Update export-ledger script

## Files to Create/Modify

### New Files

1. `config/chains.config.ts` - Chain registry
2. `config/deployments.registry.ts` - Deployment registry
3. `scripts/_lib/network-validation.ts` - Network validation
4. `scripts/query-deployments.ts` - CLI to query deployments

### Modified Files

1. `hardhat.config.ts` - Use chain registry
2. `deploy/_config.ts` - Use chain config helpers
3. `scripts/_lib/ledger.ts` - Enhanced metadata
4. `deploy/*.ts` - Register deployments

## Benefits

1. **Single Source of Truth**: All chain info in one place
2. **Type Safety**: TypeScript interfaces prevent errors
3. **Easy Network Addition**: Add new networks by adding to registry
4. **Deployment Tracking**: Know what's deployed where
5. **Validation**: Catch configuration errors early
6. **Documentation**: Self-documenting chain configurations
7. **Tooling**: Easy to build scripts that query chain info

## Example Usage

```typescript
// In deployment script
import { getChainConfig, isMainnet } from '../config/chains.config';
import { validateNetwork } from '../scripts/_lib/network-validation';
import { registerDeployment } from '../config/deployments.registry';

const func: DeployFunction = async function (hre) {
  // Validate network
  await validateNetwork(hre);
  
  // Get chain config
  const chainConfig = getChainConfig(hre);
  console.log(`Deploying to ${chainConfig.displayName}`);
  
  // Use chain-specific addresses
  const aavePool = chainConfig.contracts.aave?.poolAddress;
  if (!aavePool) {
    throw new Error(`Aave pool not configured for ${chainConfig.name}`);
  }
  
  // Deploy
  const deployment = await deploy('MyContract', {
    args: [aavePool],
  });
  
  // Register deployment
  registerDeployment(hre, 'MyContract', {
    address: deployment.address,
    txHash: deployment.transactionHash || '',
    blockNumber: deployment.receipt?.blockNumber || 0,
    constructorArgs: [aavePool],
  });
  
  // Get block explorer URL
  console.log(`Contract: ${chainConfig.blockExplorer.url}/address/${deployment.address}`);
};
```

## Next Steps

1. **Review and approve** this proposal
2. **Implement Phase 1** (Chain Registry) - highest priority
3. **Test with existing deployments**
4. **Implement Phase 2** (Deployment Registry)
5. **Update documentation**
