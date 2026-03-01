/**
 * Execute proper Timelock proposal - with correct id calculation
 */

import hre from 'hardhat';
import { ethers } from 'ethers';
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

  // Check if already registered
  const ROLE_ESCROW_CONTRACT = await createOps.ROLE_ESCROW_CONTRACT();
  const alreadyRegistered = await createOps.hasRole(ROLE_ESCROW_CONTRACT, escrowVaultAddr);
  
  if (alreadyRegistered) {
    console.log('✅ Already registered');
    return;
  }

  console.log('\n=== Build Operation ===');
  
  // Call data
  const callData = createOps.interface.encodeFunctionData('registerEscrowContract', [escrowVaultAddr]);
  const value = 0;
  const predecessor = ethers.ZeroHash;
  const salt = ethers.id('register-escrow-vault'); // deterministic salt
  
  // Calculate ID (this is what schedule uses)
  const id = await timelock.hashOperation(createOpsAddr, value, callData, predecessor, salt);
  console.log('Operation ID:', id);

  // Get min delay
  const minDelay = await timelock.getMinDelay();
  console.log('Min delay:', minDelay.toString(), 'seconds (', Number(minDelay) / 3600, 'hours)');

  console.log('\n=== Schedule ===');
  try {
    const scheduleTx = await timelock.schedule(createOpsAddr, value, callData, predecessor, salt, minDelay);
    const rcpt = await scheduleTx.wait();
    console.log('✅ Scheduled (tx:', rcpt?.transactionHash, ')');
    console.log('   Operation ready at:', new Date(Date.now() + Number(minDelay) * 1000).toISOString());
  } catch (err: any) {
    if (err.message.includes('Already scheduled')) {
      console.log('⏭️  Already scheduled');
    } else {
      console.log('❌ Schedule error:', err.message);
    }
  }

  // Check if ready
  console.log('\n=== Check Status ===');
  const timestamp = await timelock.getTimestamp(id);
  console.log('Operation timestamp:', timestamp.toString());
  
  if (timestamp > 0) {
    console.log('\n=== Execute ===');
    try {
      const execTx = await timelock.execute(createOpsAddr, value, callData, predecessor, salt);
      const execRcpt = await execTx.wait();
      console.log('✅ Executed (tx:', execRcpt?.transactionHash, ')');
    } catch (err: any) {
      console.log('❌ Execute error:', err.message);
    }
  } else {
    console.log('⏳ Need to wait for delay period');
    console.log('   Wait:', Number(minDelay) / 3600, 'hours before executing');
  }

  // Verify
  const isRegistered = await createOps.hasRole(ROLE_ESCROW_CONTRACT, escrowVaultAddr);
  console.log('\n📊 Result:', isRegistered ? 'SUCCESS ✅' : 'FAILED ❌');
}

main().catch(console.error);
