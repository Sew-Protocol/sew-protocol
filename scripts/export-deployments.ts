#!/usr/bin/env ts-node

/**
 * Export Deployments
 *
 * Export deployment registry to various formats (CSV, Markdown, JSON).
 *
 * Usage:
 *   pnpm ts-node scripts/export-deployments.ts csv
 *   pnpm ts-node scripts/export-deployments.ts markdown
 *   pnpm ts-node scripts/export-deployments.ts json
 *   pnpm ts-node scripts/export-deployments.ts all
 */

import {
  getAllDeployments,
  getDeploymentsForChain,
  DeploymentRecord,
  ChainDeployments,
} from '../config/deployments.registry';
import { CHAIN_CONFIGS } from '../config/chains.config';
import fs from 'fs';
import path from 'path';

const EXPORT_DIR = path.join(process.cwd(), 'deploy-exports');

/**
 * Ensure export directory exists
 */
function ensureExportDir(): void {
  if (!fs.existsSync(EXPORT_DIR)) {
    fs.mkdirSync(EXPORT_DIR, { recursive: true });
  }
}

/**
 * Format timestamp for display
 */
function formatTimestamp(timestamp: string): string {
  return new Date(timestamp).toLocaleString();
}

/**
 * Export to CSV format
 */
function exportToCSV(): void {
  ensureExportDir();
  const allDeployments = getAllDeployments();
  
  const csvLines: string[] = [
    'Chain ID,Network Name,Contract Name,Address,Block Number,Deployer,Timestamp,Verified,Explorer URL,Tags',
  ];

  for (const chainDeployments of allDeployments) {
    for (const deployment of chainDeployments.deployments) {
      const tags = deployment.tags?.join(';') || '';
      csvLines.push(
        [
          deployment.chainId,
          deployment.networkName,
          deployment.contractName,
          deployment.address,
          deployment.blockNumber,
          deployment.deployer,
          deployment.timestamp,
          deployment.verified ? 'Yes' : 'No',
          deployment.blockExplorerUrl,
          tags,
        ].join(','),
      );
    }
  }

  const csvContent = csvLines.join('\n');
  const filePath = path.join(EXPORT_DIR, `deployments-${Date.now()}.csv`);
  fs.writeFileSync(filePath, csvContent);
  console.log(`✅ Exported CSV to: ${filePath}`);
}

/**
 * Export to Markdown format
 */
function exportToMarkdown(): void {
  ensureExportDir();
  const allDeployments = getAllDeployments();
  
  const mdLines: string[] = [
    '# Deployment Registry',
    '',
    `Generated: ${new Date().toISOString()}`,
    '',
    `Total Chains: ${allDeployments.length}`,
    `Total Deployments: ${allDeployments.reduce((sum, chain) => sum + chain.deployments.length, 0)}`,
    '',
    '---',
    '',
  ];

  for (const chainDeployments of allDeployments) {
    const chainConfig = CHAIN_CONFIGS[chainDeployments.networkName];
    const displayName = chainConfig?.displayName || chainDeployments.networkName;
    
    mdLines.push(`## ${displayName} (Chain ID: ${chainDeployments.chainId})`);
    mdLines.push('');
    mdLines.push(`- **Network Type:** ${chainConfig?.networkType || 'unknown'}`);
    mdLines.push(`- **Deployments:** ${chainDeployments.deployments.length}`);
    mdLines.push(`- **Deployed At:** ${formatTimestamp(chainDeployments.deployedAt)}`);
    mdLines.push(`- **Deployer:** ${chainDeployments.deployer}`);
    if (chainDeployments.gitSha) {
      mdLines.push(`- **Git SHA:** ${chainDeployments.gitSha}`);
    }
    mdLines.push('');

    if (chainDeployments.deployments.length === 0) {
      mdLines.push('*No deployments*');
      mdLines.push('');
      continue;
    }

    mdLines.push('| Contract | Address | Block | Verified | Explorer |');
    mdLines.push('|----------|---------|-------|----------|----------|');

    for (const deployment of chainDeployments.deployments) {
      const verified = deployment.verified ? '✅' : '❌';
      const explorerLink = deployment.blockExplorerUrl
        ? `[View](${deployment.blockExplorerUrl})`
        : '-';
      
      mdLines.push(
        `| ${deployment.contractName} | \`${deployment.address}\` | ${deployment.blockNumber} | ${verified} | ${explorerLink} |`,
      );
    }

    mdLines.push('');
    mdLines.push('### Details');
    mdLines.push('');

    for (const deployment of chainDeployments.deployments) {
      mdLines.push(`#### ${deployment.contractName}`);
      mdLines.push('');
      mdLines.push(`- **Address:** \`${deployment.address}\``);
      mdLines.push(`- **Block Number:** ${deployment.blockNumber}`);
      mdLines.push(`- **Transaction:** \`${deployment.deploymentTxHash}\``);
      mdLines.push(`- **Deployer:** \`${deployment.deployer}\``);
      mdLines.push(`- **Timestamp:** ${formatTimestamp(deployment.timestamp)}`);
      mdLines.push(`- **Verified:** ${deployment.verified ? 'Yes' : 'No'}`);
      if (deployment.verifiedAt) {
        mdLines.push(`- **Verified At:** ${formatTimestamp(deployment.verifiedAt)}`);
      }
      if (deployment.tags && deployment.tags.length > 0) {
        mdLines.push(`- **Tags:** ${deployment.tags.join(', ')}`);
      }
      if (deployment.gasUsed) {
        mdLines.push(`- **Gas Used:** ${deployment.gasUsed}`);
      }
      if (deployment.deploymentCost) {
        mdLines.push(`- **Deployment Cost:** ${deployment.deploymentCost} ETH`);
      }
      if (deployment.upgradeable) {
        mdLines.push(`- **Upgradeable:** Yes (${deployment.proxyType || 'unknown'})`);
      }
      if (deployment.implementationAddress) {
        mdLines.push(`- **Implementation:** \`${deployment.implementationAddress}\``);
      }
      if (deployment.blockExplorerUrl) {
        mdLines.push(`- **Explorer:** [View on ${chainConfig?.blockExplorer.name || 'Explorer'}](${deployment.blockExplorerUrl})`);
      }
      mdLines.push('');
    }

    mdLines.push('---');
    mdLines.push('');
  }

  const mdContent = mdLines.join('\n');
  const filePath = path.join(EXPORT_DIR, `deployments-${Date.now()}.md`);
  fs.writeFileSync(filePath, mdContent);
  console.log(`✅ Exported Markdown to: ${filePath}`);
}

/**
 * Export to JSON format
 */
function exportToJSON(): void {
  ensureExportDir();
  const allDeployments = getAllDeployments();
  
  const filePath = path.join(EXPORT_DIR, `deployments-${Date.now()}.json`);
  fs.writeFileSync(filePath, JSON.stringify(allDeployments, null, 2) + '\n');
  console.log(`✅ Exported JSON to: ${filePath}`);
}

/**
 * Show usage information
 */
function showUsage(): void {
  console.log(`
📤 Export Deployments

Usage:
  pnpm ts-node scripts/export-deployments.ts <format>

Formats:
  csv        Export to CSV format
  markdown   Export to Markdown format
  json       Export to JSON format
  all        Export to all formats

Examples:
  pnpm ts-node scripts/export-deployments.ts csv
  pnpm ts-node scripts/export-deployments.ts markdown
  pnpm ts-node scripts/export-deployments.ts all
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
  
  const format = args[0].toLowerCase();
  
  try {
    switch (format) {
      case 'csv':
        exportToCSV();
        break;
        
      case 'markdown':
      case 'md':
        exportToMarkdown();
        break;
        
      case 'json':
        exportToJSON();
        break;
        
      case 'all':
        exportToCSV();
        exportToMarkdown();
        exportToJSON();
        console.log('\n✅ Exported to all formats');
        break;
        
      default:
        console.error(`❌ Unknown format: ${format}`);
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
