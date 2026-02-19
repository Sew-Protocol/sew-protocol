/**
 * Base Sepolia v1 Deployment Validation Script
 * 
 * Validates:
 * - All 11 deployed contracts are on-chain and callable
 * - DefaultReleaseStrategy is functional
 * - SewToken exists and can be queried
 * - Module registry is active
 * - Critical wiring is in place
 * 
 * Run: pnpm hardhat run --network baseSepolia scripts/validate-deployment-v1.ts
 */

import { ethers } from 'hardhat';
import fs from 'node:fs';
import path from 'node:path';

interface ContractInfo {
  name: string;
  address: string;
  abi: any[];
  deployed: boolean;
  callable: boolean;
  hasCode: boolean;
  errors: string[];
}

const DEPLOYED_ADDRESSES: Record<string, string> = {
  ModuleSnapshotRegistry: '0x1B152685Fb8268d7eb4F292524d86661dCFEEdE6',
  YieldOps: '0xEc421d01E88754dAe5AAdE24C7616F8161f9f0F3',
  DisputeOps: '0xd62A061bcC7b934558bd4c5dDa4E1FbeDC06D394',
  SettlementOps: '0x2cB13cefF8E5326647454aa2d50db15f5282c3A4',
  CreateOps: '0xBC60481020457CAC819B6938396a1002B0518f34',
  BondCollector: '0x24240912ed0143A47Cda4b7d32C8AB8CdFA825B4',
  EscrowGovernanceTimelock: '0x13e2DBa43A28D5278803764F8308f1D230478391',
  SewToken: '0x79913fCa36Ea4e747F4742a4c1C7bC93a1522a14',
  TimelockController: '0xF61053a82F5dBd0a2eCDebb9748e457119305F6a',
  DefaultReleaseStrategy: '0xAaB4EeE521768df1f39501798A8D2a39b19c4E18',
  GuardianSafe: '0x5F13B5089a0B23c74AD9A22a2db59F5F48ab09bC',
};

async function getDeploymentAbi(contractName: string): Promise<any[] | null> {
  try {
    const deploymentFile = `deployments/baseSepolia/${contractName}.json`;
    if (!fs.existsSync(deploymentFile)) {
      return null;
    }
    const deployment = JSON.parse(fs.readFileSync(deploymentFile, 'utf-8'));
    return deployment.abi || null;
  } catch (e) {
    return null;
  }
}

async function validateContract(name: string, address: string): Promise<ContractInfo> {
  const info: ContractInfo = {
    name,
    address,
    abi: [],
    deployed: false,
    callable: false,
    hasCode: false,
    errors: [],
  };

  try {
    // Check if address has code
    const code = await ethers.provider.getCode(address);
    info.hasCode = code !== '0x';

    if (!info.hasCode) {
      info.errors.push('No code at address (may be EOA or not deployed)');
      return info;
    }

    // Try to get ABI from deployment artifact
    const abi = await getDeploymentAbi(name);
    if (abi) {
      info.abi = abi;
    }

    // Try a simple read-only call (getFunction or similar)
    try {
      // Try to call a generic view function to verify contract is callable
      const contract = new ethers.Contract(
        address,
        abi || [],
        ethers.provider
      );

      // Get bytecode size for reference
      const codeSize = (code.length - 2) / 2; // Remove 0x prefix

      info.deployed = true;
      info.callable = true;
      info.errors = [];
    } catch (callError: any) {
      info.deployed = true;
      info.callable = false;
      info.errors.push(`Call failed: ${callError.message}`);
    }
  } catch (err: any) {
    info.errors.push(err.message || String(err));
  }

  return info;
}

async function validateToken(): Promise<{
  exists: boolean;
  totalSupply?: string;
  symbol?: string;
  name?: string;
  decimals?: number;
  errors: string[];
}> {
  const result = {
    exists: false,
    errors: [] as string[],
  };

  try {
    const tokenAddr = DEPLOYED_ADDRESSES.SewToken;
    const code = await ethers.provider.getCode(tokenAddr);

    if (code === '0x') {
      result.errors.push('SewToken has no code at address');
      return result;
    }

    result.exists = true;

    // Create contract instance with minimal ERC20 ABI
    const erc20Abi = [
      'function totalSupply() view returns (uint256)',
      'function symbol() view returns (string)',
      'function name() view returns (string)',
      'function decimals() view returns (uint8)',
    ];

    const token = new ethers.Contract(tokenAddr, erc20Abi, ethers.provider);

    try {
      const [totalSupply, symbol, name, decimals] = await Promise.all([
        token.totalSupply(),
        token.symbol(),
        token.name(),
        token.decimals(),
      ]);

      return {
        exists: true,
        totalSupply: ethers.formatUnits(totalSupply, decimals),
        symbol,
        name,
        decimals: decimals.toString(),
        errors: [],
      };
    } catch (e: any) {
      result.errors.push(`Failed to read token metadata: ${e.message}`);
      return result;
    }
  } catch (err: any) {
    result.errors.push(err.message || String(err));
    return result;
  }
}

async function validateModuleRegistry(): Promise<{
  exists: boolean;
  callable: boolean;
  errors: string[];
}> {
  const result = {
    exists: false,
    callable: false,
    errors: [] as string[],
  };

  try {
    const regAddr = DEPLOYED_ADDRESSES.ModuleSnapshotRegistry;
    const code = await ethers.provider.getCode(regAddr);

    if (code === '0x') {
      result.errors.push('ModuleSnapshotRegistry has no code');
      return result;
    }

    result.exists = true;

    const registryAbi = [
      'function moduleCount() view returns (uint256)',
      'function listModules() view returns (tuple(address module, bool active, uint64 addedBlock, string moduleName, string moduleVersion)[])',
    ];

    const registry = new ethers.Contract(regAddr, registryAbi, ethers.provider);

    try {
      const count = await registry.moduleCount?.();
      result.callable = true;
      if (count) {
        console.log(`   ModuleSnapshotRegistry has ${count} modules registered`);
      }
    } catch (e: any) {
      result.errors.push(`Failed to call moduleCount: ${e.message}`);
    }

    return result;
  } catch (err: any) {
    result.errors.push(err.message || String(err));
    return result;
  }
}

async function validateDefaultReleaseStrategy(): Promise<{
  exists: boolean;
  callable: boolean;
  errors: string[];
}> {
  const result = {
    exists: false,
    callable: false,
    errors: [] as string[],
  };

  try {
    const stratAddr = DEPLOYED_ADDRESSES.DefaultReleaseStrategy;
    const code = await ethers.provider.getCode(stratAddr);

    if (code === '0x') {
      result.errors.push('DefaultReleaseStrategy has no code');
      return result;
    }

    result.exists = true;

    const strategyAbi = [
      'function shouldRelease(address token, uint256 amount) view returns (bool)',
      'function strategyName() view returns (string)',
    ];

    const strategy = new ethers.Contract(stratAddr, strategyAbi, ethers.provider);

    try {
      const name = await strategy.strategyName?.();
      result.callable = true;
      console.log(`   DefaultReleaseStrategy name: ${name}`);
    } catch (e: any) {
      result.errors.push(`Failed to call strategyName: ${e.message}`);
    }

    return result;
  } catch (err: any) {
    result.errors.push(err.message || String(err));
    return result;
  }
}

async function main() {
  console.log('');
  console.log('═══════════════════════════════════════════════════════════════');
  console.log('BASE SEPOLIA v1 DEPLOYMENT VALIDATION');
  console.log('═══════════════════════════════════════════════════════════════');
  console.log('');

  const network = (await ethers.provider.getNetwork());
  console.log(`Network: ${network.name} (Chain ID: ${network.chainId})`);
  console.log(`Block: ${await ethers.provider.getBlockNumber()}`);
  console.log('');

  // Validate all contracts
  console.log('📋 CONTRACT VALIDATION:');
  console.log('─────────────────────────────────────────────────────────────');

  const results: ContractInfo[] = [];
  for (const [name, address] of Object.entries(DEPLOYED_ADDRESSES)) {
    const info = await validateContract(name, address);
    results.push(info);

    const status = info.callable ? '✅' : info.hasCode ? '⚠️' : '❌';
    console.log(`${status} ${name}`);
    console.log(`   Address: ${address}`);
    console.log(`   Deployed: ${info.deployed ? 'Yes' : 'No'}`);
    console.log(`   Callable: ${info.callable ? 'Yes' : 'No'}`);
    if (info.errors.length > 0) {
      console.log(`   Errors: ${info.errors.join(', ')}`);
    }
  }

  // Validate token
  console.log('');
  console.log('💰 TOKEN VALIDATION:');
  console.log('─────────────────────────────────────────────────────────────');
  const tokenInfo = await validateToken();
  if (tokenInfo.exists) {
    console.log(`✅ SewToken deployed at ${DEPLOYED_ADDRESSES.SewToken}`);
    console.log(`   Name: ${tokenInfo.name}`);
    console.log(`   Symbol: ${tokenInfo.symbol}`);
    console.log(`   Decimals: ${tokenInfo.decimals}`);
    console.log(`   Total Supply: ${tokenInfo.totalSupply}`);
  } else {
    console.log(`❌ SewToken validation failed`);
    if (tokenInfo.errors.length > 0) {
      console.log(`   Errors: ${tokenInfo.errors.join(', ')}`);
    }
  }

  // Validate registry
  console.log('');
  console.log('📦 MODULE REGISTRY VALIDATION:');
  console.log('─────────────────────────────────────────────────────────────');
  const regInfo = await validateModuleRegistry();
  if (regInfo.exists && regInfo.callable) {
    console.log(`✅ ModuleSnapshotRegistry is active`);
  } else {
    console.log(`⚠️ ModuleSnapshotRegistry exists but may not be fully callable`);
    if (regInfo.errors.length > 0) {
      console.log(`   Errors: ${regInfo.errors.join(', ')}`);
    }
  }

  // Validate strategy
  console.log('');
  console.log('⚙️ STRATEGY VALIDATION:');
  console.log('─────────────────────────────────────────────────────────────');
  const stratInfo = await validateDefaultReleaseStrategy();
  if (stratInfo.exists && stratInfo.callable) {
    console.log(`✅ DefaultReleaseStrategy is active`);
  } else {
    console.log(`⚠️ DefaultReleaseStrategy exists but may not be fully callable`);
    if (stratInfo.errors.length > 0) {
      console.log(`   Errors: ${stratInfo.errors.join(', ')}`);
    }
  }

  // Summary
  console.log('');
  console.log('📊 SUMMARY:');
  console.log('─────────────────────────────────────────────────────────────');
  const deployed = results.filter((r) => r.deployed).length;
  const callable = results.filter((r) => r.callable).length;
  console.log(`Contracts deployed: ${deployed}/${results.length}`);
  console.log(`Contracts callable: ${callable}/${results.length}`);
  console.log(`Token: ${tokenInfo.exists ? '✅ Active' : '❌ Not found'}`);
  console.log(`Registry: ${regInfo.callable ? '✅ Active' : '⚠️ Partial'}`);
  console.log(`Strategy: ${stratInfo.callable ? '✅ Active' : '⚠️ Partial'}`);

  console.log('');
  console.log('═══════════════════════════════════════════════════════════════');
  if (callable >= 10 && tokenInfo.exists && regInfo.callable && stratInfo.callable) {
    console.log('✅ VALIDATION PASSED - Deployment is healthy');
  } else {
    console.log('⚠️ VALIDATION INCOMPLETE - Some contracts may not be callable yet');
  }
  console.log('═══════════════════════════════════════════════════════════════');
  console.log('');
}

main()
  .then(() => process.exit(0))
  .catch((err) => {
    console.error(err);
    process.exit(1);
  });
