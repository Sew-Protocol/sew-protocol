/**
 * CreateOps Diagnostic
 * Inspects CreateOps contract state to understand why escrow creation is failing
 */

import { ethers } from 'hardhat';
import * as fs from 'fs';

async function main() {
  console.log('\n════════════════════════════════════════════════════════════════');
  console.log('             CREATEOPS STATE DIAGNOSTIC');
  console.log('════════════════════════════════════════════════════════════════\n');

  // Load contracts
  const registryPath = './deploy-registry/base-sepolia-v1-testnet.json';
  const registry = JSON.parse(fs.readFileSync(registryPath, 'utf-8'));

  const createOpsAddr = registry.contracts.CreateOps.address;
  const escrowVaultAddr = registry.contracts.EscrowVault.address;
  const moduleRegistryAddr = registry.contracts.ModuleSnapshotRegistry.address;

  console.log('📍 Contract Addresses:');
  console.log(`   CreateOps: ${createOpsAddr}`);
  console.log(`   EscrowVault: ${escrowVaultAddr}`);
  console.log(`   ModuleRegistry: ${moduleRegistryAddr}\n`);

  // Load CreateOps contract
  const createOps = await ethers.getContractAt('CreateOps', createOpsAddr);
  const escrowVault = await ethers.getContractAt('EscrowVault', escrowVaultAddr);

  // Check basic properties
  console.log('🔍 CreateOps State:');
  
  try {
    // Try to get some state
    const code = await ethers.provider.getCode(createOpsAddr);
    console.log(`   Bytecode present: ${code !== '0x' ? '✅' : '❌'}`);

    // Check if contract is paused/locked
    try {
      const isPaused = await createOps.paused?.();
      if (typeof isPaused === 'boolean') {
        console.log(`   Paused: ${isPaused ? '⚠️  YES' : '✅ NO'}`);
      }
    } catch {}

    // Check owner
    try {
      const owner = await createOps.owner?.();
      if (owner) {
        console.log(`   Owner: ${owner}`);
      }
    } catch {}

    console.log('\n📋 EscrowVault State:');

    // Check how many escrows exist
    try {
      // Try to get escrow count
      const escrowCount = await escrowVault.getEscrowCount?.();
      if (escrowCount !== undefined) {
        console.log(`   Total escrows created: ${escrowCount}`);
      }
    } catch {}

    console.log('\n⚠️  DIAGNOSTIC LIMITATION:');
    console.log('   CreateOps contract does not expose public state inspection functions.');
    console.log('   To debug the actual issue, we need:');
    console.log('   1. Contract ABI with view functions');
    console.log('   2. Foundry trace of failed createEscrow transaction');
    console.log('   3. Contract source code inspection');

    console.log('\n📊 Known Issue: Escrow Creation Reverts');
    console.log('   All createEscrow() calls fail with "execution reverted"');
    console.log('   Symptoms:');
    console.log('   - Token approval works');
    console.log('   - Only createEscrow() fails');
    console.log('   - Affects all configurations (with/without yield)');

    console.log('\n💡 Recommended Next Steps:');
    console.log('   1. Check CreateOps has reference to generationModule:');
    console.log('      forge inspect 0xBC60481020457CAC819B6938396a1002B0518f34 storage');
    console.log('   2. Check deployer has required roles:');
    console.log('      forge call 0xBC60481020457CAC819B6938396a1002B0518f34 "hasRole(bytes32,address)"');
    console.log('   3. Get transaction trace:');
    console.log('      cast rpc trace_transaction <txHash>');
    
  } catch (error) {
    console.log(`❌ Error: ${error}`);
  }

  console.log('\n════════════════════════════════════════════════════════════════\n');
}

main().catch(error => {
  console.error('Error:', error);
  process.exit(1);
});
