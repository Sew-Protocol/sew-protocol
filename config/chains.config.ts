/**
 * Chain Configuration Registry
 *
 * Centralized configuration for all supported networks.
 * This provides a single source of truth for chain-specific information.
 */

import { HardhatRuntimeEnvironment } from 'hardhat/types';

/**
 * Chain configuration interface
 */
export interface ChainConfig {
  // Basic info
  chainId: number;
  name: string; // "base", "baseSepolia", etc.
  displayName: string; // "Base Mainnet", "Base Sepolia"
  networkType: 'mainnet' | 'testnet' | 'local';

  // RPC & Explorer
  rpcUrl: string; // Pattern or actual URL (from env)
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
      poolAddressesProvider: string;
      poolAddress?: string; // Can be derived from provider
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

/**
 * Chain configurations for all supported networks
 */
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
        // Base Mainnet Aave V3 Pool Addresses Provider
        poolAddressesProvider: '0xe20fCBdBfFC4Dd138cE8b2E6FBb6CB49777ad64D',
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
        // Base Sepolia Aave V3 Pool Addresses Provider
        poolAddressesProvider: '0x012bAC54348C0E635dCAc9D5FB99f06F24136C9A',
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
        // Ethereum Mainnet Aave V3 Pool Addresses Provider
        poolAddressesProvider: '0x2f39d218133AFaB8F2B819B1066c7E434Ad94E9e',
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
    contracts: {
      // No chain-specific contracts for local network
    },
    deployment: {
      confirmRequired: false,
    },
  },
};

/**
 * Get chain configuration for the current network
 *
 * @param hre Hardhat runtime environment
 * @returns Chain configuration
 * @throws Error if network is not configured
 */
export function getChainConfig(hre: HardhatRuntimeEnvironment): ChainConfig {
  const networkName = hre.network.name;
  const chainId = hre.network.config.chainId ?? 31337;

  // Find by network name first
  let config = CHAIN_CONFIGS[networkName];

  // Fallback: find by chainId
  if (!config) {
    const found = Object.values(CHAIN_CONFIGS).find((c) => c.chainId === chainId);
    if (found) {
      config = found;
    }
  }

  if (!config) {
    throw new Error(
      `Unknown network: ${networkName} (chainId: ${chainId}). ` +
        `Add configuration to config/chains.config.ts`,
    );
  }

  // Validate chainId matches
  if (config.chainId !== chainId) {
    throw new Error(
      `Chain ID mismatch: network ${networkName} has chainId ${chainId}, ` +
        `but config expects ${config.chainId}`,
    );
  }

  return config;
}

/**
 * Check if current network is mainnet
 */
export function isMainnet(hre: HardhatRuntimeEnvironment): boolean {
  return getChainConfig(hre).networkType === 'mainnet';
}

/**
 * Check if current network is testnet
 */
export function isTestnet(hre: HardhatRuntimeEnvironment): boolean {
  return getChainConfig(hre).networkType === 'testnet';
}

/**
 * Check if current network is local
 */
export function isLocal(hre: HardhatRuntimeEnvironment): boolean {
  return getChainConfig(hre).networkType === 'local';
}

/**
 * Get block explorer URL for an address
 */
export function getBlockExplorerUrl(
  hre: HardhatRuntimeEnvironment,
  address: string,
): string {
  const config = getChainConfig(hre);
  if (!config.blockExplorer.url) {
    return '';
  }
  return `${config.blockExplorer.url}/address/${address}`;
}

/**
 * Get block explorer URL for a transaction
 */
export function getBlockExplorerTxUrl(
  hre: HardhatRuntimeEnvironment,
  txHash: string,
): string {
  const config = getChainConfig(hre);
  if (!config.blockExplorer.url) {
    return '';
  }
  return `${config.blockExplorer.url}/tx/${txHash}`;
}
