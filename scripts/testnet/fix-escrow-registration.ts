/**
 * Fix: Grant EscrowVault ROLE_ESCROW_CONTRACT on CreateOps
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
  const createOpsAddr = registry.contracts.CreateOps.address;

  const createOps = await hre.ethers.getContractAt('CreateOps', createOpsAddr);
  const ROLE_ESCROW_CONTRACT = await createOps.ROLE_ESCROW_CONTRACT();

  console.log('\n=== Grant EscrowVault ROLE_ESCROW_CONTRACT ===');
  console.log('EscrowVault:', escrowVaultAddr);
  console.log('CreateOps:', createOpsAddr);

  // Check current state
  const hasRole = await createOps.hasRole(ROLE_ESCROW_CONTRACT, escrowVaultAddr);
  console.log('Has role?', hasRole);

  if (!hasRole) {
    console.log('\nGranting ROLE_ESCROW_CONTRACT...');
    try {
      const tx = await createOps.grantRole(ROLE_ESCROW_CONTRACT, escrowVaultAddr);
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
