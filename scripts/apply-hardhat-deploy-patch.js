#!/usr/bin/env node
/**
 * Script to apply hardhat-deploy compatibility patch
 * 
 * This fixes compatibility issues between hardhat-deploy@0.13.0 and
 * @nomicfoundation/hardhat-ethers v3.x by removing hardhat-deploy-specific
 * parameters from transaction overrides before they're passed to ethers.
 */

const fs = require('fs');
const path = require('path');

const filePath = path.join(
  __dirname,
  '..',
  'node_modules',
  '.pnpm',
  'hardhat-deploy@0.13.0',
  'node_modules',
  'hardhat-deploy',
  'dist',
  'src',
  'DeploymentFactory.js'
);

if (!fs.existsSync(filePath)) {
  console.error('❌ DeploymentFactory.js not found. Make sure hardhat-deploy is installed.');
  process.exit(1);
}

let content = fs.readFileSync(filePath, 'utf8');

// Check if already patched
if (content.includes('// Always delete hardhat-deploy specific parameters (not just for zkSync)')) {
  console.log('✓ Patch already applied');
  process.exit(0);
}

// Apply patch: add cleanup code after zkSync block, before return statement
const pattern = /(delete overrides\.deploymentType;\s+delete overrides\.additionalFactoryDeps;\s+\})\s+return this\.factory\.getDeployTransaction\(/;

if (pattern.test(content)) {
  const replacement = `delete overrides.deploymentType;
            delete overrides.additionalFactoryDeps;
        }
        // Always delete hardhat-deploy specific parameters (not just for zkSync)
        if (overrides) {
            delete overrides.deploymentType;
            delete overrides.additionalFactoryDeps;
            // Also delete zkSync-specific customData for non-zkSync deployments
            if (!this.isZkSync) {
                delete overrides.customData;
            }
        }
        return this.factory.getDeployTransaction(`;

  content = content.replace(pattern, replacement);
  fs.writeFileSync(filePath, content, 'utf8');
  console.log('✓ Successfully applied hardhat-deploy compatibility patch');
} else {
  console.error('❌ Could not find insertion point. File structure may have changed.');
  process.exit(1);
}

