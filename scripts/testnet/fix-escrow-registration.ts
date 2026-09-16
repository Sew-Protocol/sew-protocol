/**
 * Fix: Grant EscrowVault ROLE_ESCROW_CONTRACT on EscrowCreationPolicy
 *
 * Usage:
 *   pnpm hardhat run --network baseSepolia scripts/testnet/fix-escrow-registration.ts
 */

import hre from 'hardhat';
import * as fs from 'fs';

async function main() {
  if (hre.network.name !== 'baseSepolia') throw new Error('Run with baseSepolia');

  const [deployer] = await hre.ethers.getSigners();
  const registry = JSON.parse(
    fs.readFileSync('./deploy-registry/base-sepolia-v1-testnet.json', 'utf-8'),
  );

  const escrowVaultAddr = registry.contracts.EscrowVault.address;
  const creationPolicyAddr = registry.contracts.EscrowCreationPolicy.address;

  const creationPolicy = await hre.ethers.getContractAt('EscrowCreationPolicy', creationPolicyAddr);
  const ROLE_ESCROW_CONTRACT = await creationPolicy.ROLE_ESCROW_CONTRACT();

  console.log('\n=== Grant EscrowVault ROLE_ESCROW_CONTRACT ===');
  console.log('EscrowVault:', escrowVaultAddr);
  console.log('EscrowCreationPolicy:', creationPolicyAddr);

  // Check current state
  const hasRole = await creationPolicy.hasRole(ROLE_ESCROW_CONTRACT, escrowVaultAddr);
  console.log('Has role?', hasRole);

  if (!hasRole) {
    console.log('\nGranting ROLE_ESCROW_CONTRACT...');
    try {
      const tx = await creationPolicy.grantRole(ROLE_ESCROW_CONTRACT, escrowVaultAddr);
      const rcpt = await tx.wait();
      console.log('✅ Granted (tx:', rcpt?.transactionHash, ')');
    } catch (err: any) {
      console.log('❌ Failed:', err.message);
    }
  } else {
    console.log('✅ Already has role');
  }
}

main().catch(console.error);
