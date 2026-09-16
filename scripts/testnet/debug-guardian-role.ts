/**
 * Debug Guardian Role Grant
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
  const guardianAddr = '0x5F13B5089a0B23c74AD9A22a2db59F5F48ab09bC';

  const ROLE_GUARDIAN = ethers.keccak256(ethers.toUtf8Bytes('ROLE_GUARDIAN'));

  const registry = JSON.parse(
    fs.readFileSync('./deploy-registry/base-sepolia-v1-testnet.json', 'utf-8'),
  );

  console.log('Deployer:', deployerAddr);
  console.log('Guardian:', guardianAddr);
  console.log();

  // Check EscrowCreationPolicy
  console.log('=== EscrowCreationPolicy ===');
  const creationPolicy = await hre.ethers.getContractAt(
    'EscrowCreationPolicy',
    registry.contracts.EscrowCreationPolicy.address,
  );
  const creationPolicyAdmin = await creationPolicy.DEFAULT_ADMIN_ROLE();
  console.log('DEFAULT_ADMIN_ROLE:', creationPolicyAdmin);
  console.log('Deployer has admin?', await creationPolicy.hasRole(creationPolicyAdmin, deployerAddr));
  console.log('Guardian has GUARDIAN?', await creationPolicy.hasRole(ROLE_GUARDIAN, guardianAddr));

  // Try grant with verbose error
  try {
    const tx = await creationPolicy.grantRole(ROLE_GUARDIAN, guardianAddr);
    console.log('Grant tx:', tx.hash);
    await tx.wait();
    console.log('SUCCESS');
  } catch (err: any) {
    console.log('Error:', err.message);
    if (err.message.includes('execution reverted')) {
      // Try to get revert reason
      console.log('Attempting to get revert reason...');
    }
  }

  // Check YieldOps
  console.log('\n=== YieldOps ===');
  const yieldOps = await hre.ethers.getContractAt('YieldOps', registry.contracts.YieldOps.address);
  const yieldOpsAdmin = await yieldOps.DEFAULT_ADMIN_ROLE();
  console.log('DEFAULT_ADMIN_ROLE:', yieldOpsAdmin);
  console.log('Deployer has admin?', await yieldOps.hasRole(yieldOpsAdmin, deployerAddr));
  console.log('Guardian has GUARDIAN?', await yieldOps.hasRole(ROLE_GUARDIAN, guardianAddr));

  try {
    const tx = await yieldOps.grantRole(ROLE_GUARDIAN, guardianAddr);
    console.log('Grant tx:', tx.hash);
    await tx.wait();
    console.log('SUCCESS');
  } catch (err: any) {
    console.log('Error:', err.message);
  }
}

main().catch(console.error);
