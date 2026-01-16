#!/usr/bin/env ts-node

/**
 * Query Deployments CLI
 *
 * Query and display deployment information across networks.
 *
 * Usage:
 *   pnpm ts-node scripts/query-deployments.ts list
 *   pnpm ts-node scripts/query-deployments.ts chain <chainId>
 *   pnpm ts-node scripts/query-deployments.ts contract <contractName>
 *   pnpm ts-node scripts/query-deployments.ts stats
 */

import {
  getAllDeployments,
  getDeploymentsForChain,
  findDeploymentsByName,
  getDeploymentStats,
  compareDeployments,
  DeploymentRecord,
  ChainDeployments,
} from '../config/deployments.registry';
import { CHAIN_CONFIGS } from '../config/chains.config';

/**
 * Format address for display
 */
function formatAddress(address: string, startChars: number = 6, endChars: number = 4): string {
  if (address.length < startChars + endChars) {
    return address;
  }
  return `${address.slice(0, startChars)}...${address.slice(-endChars)}`;
}

/**
 * Format timestamp for display
 */
function formatTimestamp(timestamp: string): string {
  return new Date(timestamp).toLocaleString();
}

/**
 * Display a deployment record
 */
function displayDeployment(deployment: DeploymentRecord, showDetails: boolean = false): void {
  const verified = deployment.verified ? '✅' : '❌';
  console.log(`\n  ${verified} ${deployment.contractName}`);
  console.log(`     Address: ${deployment.address}`);
  console.log(`     Network: ${deployment.networkName} (Chain ID: ${deployment.chainId})`);
  
  if (showDetails) {
    console.log(`     Deployer: ${deployment.deployer}`);
    console.log(`     Block: ${deployment.blockNumber}`);
    console.log(`     TX: ${deployment.deploymentTxHash}`);
    console.log(`     Deployed: ${formatTimestamp(deployment.timestamp)}`);
    console.log(`     Explorer: ${deployment.blockExplorerUrl}`);
    
    // Phase 3: Enhanced metadata
    if (deployment.gasUsed) {
      console.log(`     Gas Used: ${deployment.gasUsed}`);
    }
    if (deployment.deploymentCost) {
      console.log(`     Cost: ${deployment.deploymentCost} ETH`);
    }
    if (deployment.compilerVersion) {
      console.log(`     Compiler: ${deployment.compilerVersion}`);
    }
    if (deployment.optimizationRuns) {
      console.log(`     Optimizer Runs: ${deployment.optimizationRuns}`);
    }
    if (deployment.contractSize) {
      console.log(`     Size: ${deployment.contractSize} bytes`);
    }
    if (deployment.upgradeable) {
      console.log(`     Upgradeable: Yes (${deployment.proxyType || 'unknown'})`);
    }
    if (deployment.implementationAddress) {
      console.log(`     Implementation: ${deployment.implementationAddress}`);
    }
    if (deployment.proxyAdmin) {
      console.log(`     Proxy Admin: ${deployment.proxyAdmin}`);
    }
    if (deployment.verifiedAt) {
      console.log(`     Verified At: ${formatTimestamp(deployment.verifiedAt)}`);
    }
    if (deployment.tags && deployment.tags.length > 0) {
      console.log(`     Tags: ${deployment.tags.join(', ')}`);
    }
  }
}

/**
 * Display chain deployments
 */
function displayChainDeployments(chainDeployments: ChainDeployments): void {
  const chainConfig = CHAIN_CONFIGS[chainDeployments.networkName];
  const displayName = chainConfig?.displayName || chainDeployments.networkName;
  
  console.log(`\n📦 ${displayName} (Chain ID: ${chainDeployments.chainId})`);
  console.log(`   Deployments: ${chainDeployments.deployments.length}`);
  console.log(`   Deployed at: ${formatTimestamp(chainDeployments.deployedAt)}`);
  console.log(`   Deployer: ${chainDeployments.deployer}`);
  
  if (chainDeployments.deployments.length === 0) {
    console.log(`   ⚠️  No deployments found`);
    return;
  }
  
  for (const deployment of chainDeployments.deployments) {
    displayDeployment(deployment, false);
  }
}

/**
 * List all deployments across all chains
 */
function listAllDeployments(): void {
  const allDeployments = getAllDeployments();
  
  if (allDeployments.length === 0) {
    console.log('📭 No deployments found in registry');
    console.log('   Deploy contracts to populate the registry');
    return;
  }
  
  console.log(`\n📋 All Deployments (${allDeployments.length} chains)\n`);
  
  for (const chainDeployments of allDeployments) {
    displayChainDeployments(chainDeployments);
  }
}

/**
 * Show deployments for a specific chain
 */
function showChainDeployments(chainIdStr: string): void {
  const chainId = parseInt(chainIdStr, 10);
  if (isNaN(chainId)) {
    console.error(`❌ Invalid chain ID: ${chainIdStr}`);
    process.exit(1);
  }
  
  const chainDeployments = getDeploymentsForChain(chainId);
  
  if (!chainDeployments) {
    console.log(`📭 No deployments found for chain ${chainId}`);
    return;
  }
  
  displayChainDeployments(chainDeployments);
  
  // Show details for each deployment
  console.log(`\n📄 Details:`);
  for (const deployment of chainDeployments.deployments) {
    displayDeployment(deployment, true);
  }
}

/**
 * Find deployments by contract name
 */
function findContractDeployments(contractName: string): void {
  const deployments = findDeploymentsByName(contractName);
  
  if (deployments.length === 0) {
    console.log(`📭 No deployments found for contract: ${contractName}`);
    return;
  }
  
  console.log(`\n🔍 Found ${deployments.length} deployment(s) for: ${contractName}\n`);
  
  for (const deployment of deployments) {
    displayDeployment(deployment, true);
  }
}

/**
 * Show deployment statistics
 */
function showStats(): void {
  const stats = getDeploymentStats();
  
  console.log(`\n📊 Deployment Statistics\n`);
  console.log(`   Total Chains: ${stats.totalChains}`);
  console.log(`   Total Deployments: ${stats.totalDeployments}`);
  
  if (stats.byChain.length > 0) {
    console.log(`\n   By Chain:`);
    for (const chain of stats.byChain) {
      const chainConfig = Object.values(CHAIN_CONFIGS).find(
        (c) => c.chainId === chain.chainId,
      );
      const displayName = chainConfig?.displayName || chain.networkName;
      const verifiedPct = chain.count > 0
        ? Math.round((chain.verified / chain.count) * 100)
        : 0;
      
      console.log(`     ${displayName} (${chain.chainId}):`);
      console.log(`       Deployments: ${chain.count}`);
      console.log(`       Verified: ${chain.verified}/${chain.count} (${verifiedPct}%)`);
    }
  }
}

/**
 * Compare deployments across chains
 */
function compareContractDeployments(contractName: string): void {
  const comparison = compareDeployments(contractName);
  
  if (!comparison) {
    console.log(`📭 No deployments found for contract: ${contractName}`);
    return;
  }
  
  console.log(`\n🔍 Comparison: ${contractName}\n`);
  console.log(`   Deployed on ${comparison.chains.length} chain(s)`);
  console.log(`   All addresses same: ${comparison.allSame ? '✅ Yes' : '❌ No'}`);
  console.log(`   All verified: ${comparison.allVerified ? '✅ Yes' : '❌ No'}`);
  console.log('');
  
  for (const chain of comparison.chains) {
    const chainConfig = Object.values(CHAIN_CONFIGS).find(
      (c) => c.chainId === chain.chainId,
    );
    const displayName = chainConfig?.displayName || chain.networkName;
    
    console.log(`   📦 ${displayName} (${chain.chainId}):`);
    console.log(`      Address: ${chain.address}`);
    console.log(`      Block: ${chain.blockNumber}`);
    console.log(`      Verified: ${chain.verified ? '✅' : '❌'}`);
    if (chain.differences && chain.differences.length > 0) {
      console.log(`      ⚠️  Differences:`);
      for (const diff of chain.differences) {
        console.log(`         - ${diff}`);
      }
    }
    console.log('');
  }
}

/**
 * Show usage information
 */
function showUsage(): void {
  console.log(`
📋 Query Deployments CLI

Usage:
  pnpm ts-node scripts/query-deployments.ts <command> [args]

Commands:
  list                          List all deployments across all chains
  chain <chainId>               Show deployments for a specific chain
  contract <contractName>       Find deployments by contract name
  compare <contractName>        Compare deployments across chains
  stats                         Show deployment statistics
  help                          Show this help message

Examples:
  pnpm ts-node scripts/query-deployments.ts list
  pnpm ts-node scripts/query-deployments.ts chain 8453
  pnpm ts-node scripts/query-deployments.ts contract SewToken
  pnpm ts-node scripts/query-deployments.ts compare SewToken
  pnpm ts-node scripts/query-deployments.ts stats
`);
}

/**
 * Main function
 */
async function main() {
  const args = process.argv.slice(2);
  
  if (args.length === 0 || args[0] === 'help' || args[0] === '--help' || args[0] === '-h') {
    showUsage();
    process.exit(0);
  }
  
  const command = args[0];
  
  try {
    switch (command) {
      case 'list':
        listAllDeployments();
        break;
        
      case 'chain':
        if (args.length < 2) {
          console.error('❌ Chain ID required');
          console.log('Usage: pnpm ts-node scripts/query-deployments.ts chain <chainId>');
          process.exit(1);
        }
        showChainDeployments(args[1]);
        break;
        
      case 'contract':
        if (args.length < 2) {
          console.error('❌ Contract name required');
          console.log('Usage: pnpm ts-node scripts/query-deployments.ts contract <contractName>');
          process.exit(1);
        }
        findContractDeployments(args[1]);
        break;
        
      case 'compare':
        if (args.length < 2) {
          console.error('❌ Contract name required');
          console.log('Usage: pnpm ts-node scripts/query-deployments.ts compare <contractName>');
          process.exit(1);
        }
        compareContractDeployments(args[1]);
        break;
        
      case 'stats':
        showStats();
        break;
        
      default:
        console.error(`❌ Unknown command: ${command}`);
        showUsage();
        process.exit(1);
    }
  } catch (error) {
    console.error('❌ Error:', error);
    process.exit(1);
  }
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
