/**
 * Debug: Check timelock delay and try direct access
 */

import hre from 'hardhat';
import * as fs from 'fs';

async function main() {
  if (hre.network.name !== 'baseSepolia') throw new Error('Run with baseSepolia');

  const [deployer] = await hre.ethers.getSigners();
  const registry = JSON.parse(
    fs.readFileSync('./deploy-registry/base-sepolia-v1-testnet.json', 'utf-8'),
  );

  const timelockAddr = registry.contracts.TimelockController.address;
  const createOpsAddr = registry.contracts.CreateOps.address;
  const escrowVaultAddr = registry.contracts.EscrowVault.address;

  const timelock = await hre.ethers.getContractAt('TimelockController', timelockAddr);
  const createOps = await hre.ethers.getContractAt('CreateOps', createOpsAddr);

  console.log('=== Timelock Config ===');
  const minDelay = await timelock.getMinDelay();
  console.log('Min delay:', minDelay.toString(), 'seconds');

  console.log('\n=== Deployer ===');
  const PROPOSER_ROLE = await timelock.PROPOSER_ROLE();
  console.log('Deployer is PROPOSER?', await timelock.hasRole(PROPOSER_ROLE, deployer.address));

  // Try direct grant from deployer (since deployer is admin on Timelock)
  console.log('\n=== Try direct grant on CreateOps ===');
  const ROLE_ESCROW_CONTRACT = await createOps.ROLE_ESCROW_CONTRACT();
  
  try {
    const tx = await createOps.grantRole(ROLE_ESCROW_CONTRACT, escrowVaultAddr);
    const rcpt = await tx.wait();
    console.log('✅ Granted directly (tx:', rcpt?.transactionHash, ')');
  } catch (err: any) {
    console.log('❌ Error:', err.message);
  }

  // Verify
  const isRegistered = await createOps.hasRole(ROLE_ESCROW_CONTRACT, escrowVaultAddr);
  console.log('\n📊 Result:', isRegistered ? 'SUCCESS' : 'FAILED');
}

main().catch(console.error);
