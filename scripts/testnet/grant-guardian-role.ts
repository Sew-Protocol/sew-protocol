/**
 * Grant Guardian Role
 *
 * Grants ROLE_GUARDIAN to the guardian multisig on all contracts
 *
 * Usage:
 *   pnpm hardhat run --network baseSepolia scripts/testnet/grant-guardian-role.ts
 *
 * Requires DEPLOYER_PRIVATE_KEY (or SEPOLIA_DEPLOY_KEY)
 */

import hre from 'hardhat';
import { ethers } from 'ethers';
import * as fs from 'fs';

async function main() {
  if (hre.network.name !== 'baseSepolia') {
    throw new Error(`Run with --network baseSepolia`);
  }

  const [deployer] = await hre.ethers.getSigners();
  const deployerAddr = await deployer.getAddress();

  // Guardian address from env
  const guardianAddr =
    process.env.GUARDIAN_MULTISIG || '0x5F13B5089a0B23c74AD9A22a2db59F5F48ab09bC';

  const ROLE_GUARDIAN = ethers.keccak256(ethers.toUtf8Bytes('ROLE_GUARDIAN'));

  console.log('\n════════════════════════════════════════════════════════════════');
  console.log('       GRANT GUARDIAN ROLE');
  console.log('════════════════════════════════════════════════════════════════\n');
  console.log(`Deployer: ${deployerAddr}`);
  console.log(`Guardian: ${guardianAddr}\n`);

  // Load contracts
  const registryPath = './deploy-registry/base-sepolia-v1-testnet.json';
  const registry = JSON.parse(fs.readFileSync(registryPath, 'utf-8'));

  const contracts = [
    { name: 'EscrowVault', address: registry.contracts.EscrowVault.address },
    { name: 'CreateOps', address: registry.contracts.CreateOps.address },
    { name: 'YieldOps', address: registry.contracts.YieldOps.address },
    { name: 'SettlementOps', address: registry.contracts.SettlementOps.address },
    { name: 'DisputeOps', address: registry.contracts.DisputeOps.address },
  ];

  let granted = 0;
  let skipped = 0;
  let failed = 0;

  for (const c of contracts) {
    try {
      const contract = await hre.ethers.getContractAt(c.name, c.address);

      // Check if contract supports ROLE_GUARDIAN
      let hasGuardianSupport = false;
      try {
        await contract.ROLE_GUARDIAN();
        hasGuardianSupport = true;
      } catch {
        console.log(`⏭️  ${c.name}: Does not support ROLE_GUARDIAN`);
        skipped++;
        continue;
      }

      // Check if already has role
      const hasRole = await contract.hasRole(ROLE_GUARDIAN, guardianAddr);
      if (hasRole) {
        console.log(`✅ ${c.name}: Guardian already has ROLE_GUARDIAN`);
        skipped++;
        continue;
      }

      // Grant role
      console.log(`🔐 Granting ROLE_GUARDIAN to ${c.name}...`);
      const tx = await contract.grantRole(ROLE_GUARDIAN, guardianAddr);
      const rcpt = await tx.wait();
      console.log(`   ✅ Granted (tx: ${rcpt?.transactionHash})`);
      granted++;
    } catch (err: any) {
      console.log(`❌ ${c.name}: ${err.message}`);
      failed++;
    }
  }

  console.log('\n════════════════════════════════════════════════════════════════');
  console.log('                     SUMMARY');
  console.log('════════════════════════════════════════════════════════════════\n');
  console.log(`Granted: ${granted}`);
  console.log(`Skipped: ${skipped}`);
  console.log(`Failed: ${failed}\n`);

  if (failed > 0) {
    console.log('⚠️  Some roles failed to grant. Check errors above.\n');
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
