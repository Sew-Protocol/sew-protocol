/**
 * Update TimelockController minimum delay (for testnet only)
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
  const timelock = await hre.ethers.getContractAt('TimelockController', timelockAddr);

  console.log('\n=== Current Config ===');
  const currentDelay = await timelock.getMinDelay();
  console.log('Current min delay:', currentDelay.toString(), 'seconds', '(', Number(currentDelay) / 3600, 'hours)');

  // Try to update delay
  const newDelay = 0; // immediate for testnet
  
  console.log('\n=== Updating to', newDelay, 'seconds ===');
  
  try {
    const tx = await timelock.updateDelay(newDelay);
    const rcpt = await tx.wait();
    console.log('✅ Updated (tx:', rcpt?.transactionHash, ')');
    
    const newDelayCheck = await timelock.getMinDelay();
    console.log('New min delay:', newDelayCheck.toString(), 'seconds');
  } catch (err: any) {
    console.log('❌ Error:', err.message);
  }
}

main().catch(console.error);
