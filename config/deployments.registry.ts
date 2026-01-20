/**
 * Deployment Registry
 *
 * Tracks all contract deployments across networks.
 * Provides persistence and querying capabilities.
 */

import { HardhatRuntimeEnvironment } from 'hardhat/types';
import { getChainConfig, getBlockExplorerUrl } from './chains.config';
import fs from 'fs';
import path from 'path';

/**
 * Deployment record for a single contract
 */
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
  tags?: string[]; // Deployment tags
  
  // Phase 3: Enhanced metadata
  contractVersion?: string; // Contract version if available
  compilerVersion?: string; // Solidity compiler version
  optimizationRuns?: number; // Optimizer runs
  gasUsed?: string; // Gas used for deployment
  contractSize?: number; // Contract size in bytes
  deploymentCost?: string; // Deployment cost in ETH
  salt?: string; // CREATE2 salt if used
  factoryAddress?: string; // Factory address if deployed via factory
  upgradeable?: boolean; // Whether contract is upgradeable
  proxyType?: 'transparent' | 'uups' | 'beacon' | 'none'; // Proxy type
  verificationTxHash?: string; // Transaction hash for verification
  verifiedAt?: string; // Timestamp when verified
}

/**
 * All deployments for a single chain
 */
export interface ChainDeployments {
  chainId: number;
  networkName: string;
  deployments: DeploymentRecord[];
  deployedAt: string;
  deployer: string;
  gitSha?: string;
  chainConfig?: {
    name: string;
    displayName: string;
    networkType: string;
  };
  
  // Phase 3: Enhanced metadata
  deploymentEnvironment?: {
    nodeVersion?: string;
    hardhatVersion?: string;
    ethersVersion?: string;
  };
  deploymentNotes?: string; // Free-form notes about this deployment
}

/**
 * Deployment comparison result
 */
export interface DeploymentComparison {
  contractName: string;
  chains: Array<{
    chainId: number;
    networkName: string;
    address: string;
    blockNumber: number;
    timestamp: string;
    verified: boolean;
    differences?: string[]; // Differences from other chains
  }>;
  allSame: boolean; // True if all addresses are the same
  allVerified: boolean; // True if all are verified
}

/**
 * Registry storage path
 */
const REGISTRY_DIR = path.join(process.cwd(), 'deploy-registry');

/**
 * Ensure registry directory exists
 */
function ensureRegistryDir(): void {
  if (!fs.existsSync(REGISTRY_DIR)) {
    fs.mkdirSync(REGISTRY_DIR, { recursive: true });
  }
}

/**
 * Get registry file path for a chain
 */
function getRegistryFilePath(chainId: number): string {
  ensureRegistryDir();
  return path.join(REGISTRY_DIR, `chain-${chainId}.json`);
}

/**
 * Load deployments for a chain from disk
 */
export function loadDeploymentsForChain(chainId: number): ChainDeployments | null {
  const filePath = getRegistryFilePath(chainId);
  if (!fs.existsSync(filePath)) {
    return null;
  }

  try {
    const content = fs.readFileSync(filePath, 'utf-8');
    return JSON.parse(content) as ChainDeployments;
  } catch (error) {
    console.error(`Failed to load deployments for chain ${chainId}:`, error);
    return null;
  }
}

/**
 * Save deployments for a chain to disk
 */
export function saveDeploymentsForChain(
  chainDeployments: ChainDeployments,
): void {
  ensureRegistryDir();
  const filePath = getRegistryFilePath(chainDeployments.chainId);
  fs.writeFileSync(filePath, JSON.stringify(chainDeployments, null, 2) + '\n');
}

/**
 * Register a deployment
 *
 * @param hre Hardhat runtime environment
 * @param contractName Contract name
 * @param deployment Deployment information
 */
export async function registerDeployment(
  hre: HardhatRuntimeEnvironment,
  contractName: string,
  deployment: {
    address: string;
    txHash: string;
    blockNumber: number;
    constructorArgs?: any[];
    implementationAddress?: string;
    proxyAdmin?: string;
    tags?: string[];
    verified?: boolean;
    // Phase 3: Enhanced metadata
    contractVersion?: string;
    compilerVersion?: string;
    optimizationRuns?: number;
    gasUsed?: string;
    contractSize?: number;
    deploymentCost?: string;
    salt?: string;
    factoryAddress?: string;
    upgradeable?: boolean;
    proxyType?: 'transparent' | 'uups' | 'beacon' | 'none';
  },
): Promise<void> {
  const chainConfig = getChainConfig(hre);
  const signers = await hre.ethers.getSigners();
  const signer = signers[0];

  // Get receipt for enhanced metadata
  let receipt;
  try {
    receipt = await hre.ethers.provider.getTransactionReceipt(deployment.txHash);
  } catch {
    // Receipt not available
  }

  // Calculate deployment cost if receipt available
  let deploymentCost: string | undefined;
  if (receipt) {
    const block = await hre.ethers.provider.getBlock(receipt.blockNumber);
    if (block && receipt.gasUsed) {
      const gasPrice = receipt.gasPrice || 0n;
      const cost = receipt.gasUsed * gasPrice;
      deploymentCost = hre.ethers.formatEther(cost);
    }
  }

  const record: DeploymentRecord = {
    chainId: chainConfig.chainId,
    networkName: chainConfig.name,
    contractName,
    address: deployment.address,
    deploymentTxHash: deployment.txHash,
    blockNumber: deployment.blockNumber,
    deployer: signer.address,
    timestamp: new Date().toISOString(),
    verified: deployment.verified || false,
    blockExplorerUrl: getBlockExplorerUrl(hre, deployment.address),
    constructorArgs: deployment.constructorArgs,
    implementationAddress: deployment.implementationAddress,
    proxyAdmin: deployment.proxyAdmin,
    tags: deployment.tags,
    // Phase 3: Enhanced metadata
    contractVersion: deployment.contractVersion,
    compilerVersion: deployment.compilerVersion || '0.8.33',
    optimizationRuns: deployment.optimizationRuns || 1000,
    gasUsed: deployment.gasUsed || receipt?.gasUsed?.toString(),
    contractSize: deployment.contractSize,
    deploymentCost: deploymentCost || deployment.deploymentCost,
    salt: deployment.salt,
    factoryAddress: deployment.factoryAddress,
    upgradeable: deployment.upgradeable,
    proxyType: deployment.proxyType || 'none',
  };

  // Load existing deployments or create new
  let chainDeployments = loadDeploymentsForChain(chainConfig.chainId);
  if (!chainDeployments) {
    chainDeployments = {
      chainId: chainConfig.chainId,
      networkName: chainConfig.name,
      deployments: [],
      deployedAt: new Date().toISOString(),
      deployer: signer.address,
      gitSha: process.env.GIT_SHA,
      chainConfig: {
        name: chainConfig.name,
        displayName: chainConfig.displayName,
        networkType: chainConfig.networkType,
      },
      // Phase 3: Enhanced metadata
      deploymentEnvironment: {
        nodeVersion: process.version,
        hardhatVersion: process.env.npm_package_dependencies_hardhat,
        ethersVersion: process.env.npm_package_dependencies_ethers,
      },
    };
  }

  // Add or update deployment
  const existingIndex = chainDeployments.deployments.findIndex(
    (d) => d.contractName === contractName,
  );
  if (existingIndex >= 0) {
    chainDeployments.deployments[existingIndex] = record;
    console.log(`📝 Updated deployment: ${contractName} on ${chainConfig.displayName}`);
  } else {
    chainDeployments.deployments.push(record);
    console.log(`✅ Registered deployment: ${contractName} on ${chainConfig.displayName}`);
  }

  // Save to disk
  saveDeploymentsForChain(chainDeployments);
}

/**
 * Get deployment for a specific contract on a chain
 */
export function getDeployment(
  chainId: number,
  contractName: string,
): DeploymentRecord | undefined {
  const chainDeployments = loadDeploymentsForChain(chainId);
  return chainDeployments?.deployments.find(
    (d) => d.contractName === contractName,
  );
}

/**
 * Get all deployments for a chain
 */
export function getDeploymentsForChain(
  chainId: number,
): ChainDeployments | null {
  return loadDeploymentsForChain(chainId);
}

/**
 * Get all deployments across all chains
 */
export function getAllDeployments(): ChainDeployments[] {
  ensureRegistryDir();
  const deployments: ChainDeployments[] = [];

  if (!fs.existsSync(REGISTRY_DIR)) {
    return deployments;
  }

  const files = fs.readdirSync(REGISTRY_DIR);
  for (const file of files) {
    if (file.startsWith('chain-') && file.endsWith('.json')) {
      const chainId = parseInt(file.replace('chain-', '').replace('.json', ''), 10);
      if (!isNaN(chainId)) {
        const chainDeployments = loadDeploymentsForChain(chainId);
        if (chainDeployments) {
          deployments.push(chainDeployments);
        }
      }
    }
  }

  return deployments;
}

/**
 * Find deployments by contract name across all chains
 */
export function findDeploymentsByName(
  contractName: string,
): DeploymentRecord[] {
  const allDeployments = getAllDeployments();
  const results: DeploymentRecord[] = [];

  for (const chainDeployments of allDeployments) {
    const deployment = chainDeployments.deployments.find(
      (d) => d.contractName === contractName,
    );
    if (deployment) {
      results.push(deployment);
    }
  }

  return results;
}

/**
 * Compare deployments of the same contract across chains
 */
export function compareDeployments(contractName: string): DeploymentComparison | null {
  const deployments = findDeploymentsByName(contractName);
  
  if (deployments.length === 0) {
    return null;
  }

  const addresses = deployments.map(d => d.address.toLowerCase());
  const allSame = addresses.every(addr => addr === addresses[0]);
  const allVerified = deployments.every(d => d.verified);

  const chains = deployments.map(deployment => {
    const differences: string[] = [];
    
    // Compare with other deployments
    for (const other of deployments) {
      if (deployment.chainId === other.chainId) continue;
      
      if (deployment.address.toLowerCase() !== other.address.toLowerCase()) {
        differences.push(`Different address on ${other.networkName}`);
      }
      if (deployment.blockNumber !== other.blockNumber) {
        differences.push(`Different block number on ${other.networkName}`);
      }
      if (deployment.verified !== other.verified) {
        differences.push(`Verification status differs from ${other.networkName}`);
      }
    }

    return {
      chainId: deployment.chainId,
      networkName: deployment.networkName,
      address: deployment.address,
      blockNumber: deployment.blockNumber,
      timestamp: deployment.timestamp,
      verified: deployment.verified,
      differences: differences.length > 0 ? differences : undefined,
    };
  });

  return {
    contractName,
    chains,
    allSame,
    allVerified,
  };
}

/**
 * Mark a deployment as verified
 */
export function markDeploymentAsVerified(
  chainId: number,
  contractName: string,
  verificationTxHash?: string,
): void {
  const chainDeployments = loadDeploymentsForChain(chainId);
  if (!chainDeployments) {
    throw new Error(`No deployments found for chain ${chainId}`);
  }

  const deployment = chainDeployments.deployments.find(
    (d) => d.contractName === contractName,
  );
  if (!deployment) {
    throw new Error(
      `Deployment ${contractName} not found on chain ${chainId}`,
    );
  }

  deployment.verified = true;
  deployment.verifiedAt = new Date().toISOString();
  if (verificationTxHash) {
    deployment.verificationTxHash = verificationTxHash;
  }
  saveDeploymentsForChain(chainDeployments);
}

/**
 * Get deployment statistics
 */
export function getDeploymentStats(): {
  totalChains: number;
  totalDeployments: number;
  byChain: Array<{
    chainId: number;
    networkName: string;
    count: number;
    verified: number;
  }>;
} {
  const allDeployments = getAllDeployments();
  const byChain = allDeployments.map((chain) => ({
    chainId: chain.chainId,
    networkName: chain.networkName,
    count: chain.deployments.length,
    verified: chain.deployments.filter((d) => d.verified).length,
  }));

  return {
    totalChains: allDeployments.length,
    totalDeployments: allDeployments.reduce(
      (sum, chain) => sum + chain.deployments.length,
      0,
    ),
    byChain,
  };
}
