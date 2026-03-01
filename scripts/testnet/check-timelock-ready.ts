/**
 * Check if timelock operation is ready and execute
 */

import hre from 'hardhat';
import { ethers } from 'ethers';
import * as fs from 'fs';

async function main() {
  if (hre.network.name !== 'baseSepolia') throw new Error('Run with baseSepolia');

  const registry = JSON.parse(
    fs.readFileSync('./deploy-registry/base-sepolia-v1-testnet.json', 'utf-8'),
  );

  const timelockAddr = registry.contracts.TimelockController.address;
  const createOpsAddr = registry.contracts.CreateOps.address;
  const escrowVaultAddr = registry.contracts.EscrowVault.address;

  const timelock = await hre.ethers.getContractAt('TimelockController', timelockAddr);
  const createOps = await hre.ethers.getContractAt('CreateOps', createOpsAddr);

  // Build same operation
  const callData = createOps.interface.encodeFunctionData('registerEscrowContract', [escrowVaultAddr]);
  const id = await timelock.hashOperation(createOpsAddr, 0, callData, ethers.ZeroHash, ethers.id('register-escrow-vault'));

  console.log('Operation ID:', id);

  // Check timestamp
  const timestamp = await timelock.getTimestamp(id);
  const block = await hre.ethers.provider.getBlock('latest');
  console.log('Operation ready at timestamp:', timestamp.toString());
  console.log('Current block timestamp:', block?.timestamp);
  console.log('Ready?', timestamp > 0 && timestamp <= block?.timestamp);

  // Try execute
  if (timestamp > 0 && timestamp <= (block?.timestamp || 0)) {
    console.log('\n=== Execute ===');
    try {
      const execTx = await timelock.execute(createOpsAddr, 0, callData, ethers.ZeroHash, ethers.id('register-escrow-vault'));
      const rcpt = await execTx.wait();
      console.log('✅ Executed (tx:', rcpt?.transactionHash, ')');
    } catch (err: any) {
      console.log('❌ Error:', err.message);
    }
  } else {
    const waitTime = Number(timestamp) - (block?.timestamp || 0);
    console.log('\n⏳ Need to wait:', waitTime, 'seconds', '(', waitTime / 3600, 'hours)');
    console.log('Ready at:', new Date(Number(timestamp) * 1000).toISOString());
  }

  // Verify
  const ROLE_ESCROW_CONTRACT = await createOps.ROLE_ESCROW_CONTRACT();
  const isRegistered = await createOps.hasRole(ROLE_ESCROW_CONTRACT, escrowVaultAddr);
  console.log('\n📊 Result:', isRegistered ? 'SUCCESS ✅' : 'FAILED ❌');
}

main().catch(console.error);
