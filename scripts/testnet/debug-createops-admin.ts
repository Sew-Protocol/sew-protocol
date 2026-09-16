/**
 * Debug: Who has admin on EscrowCreationPolicy?
 */

import hre from 'hardhat';
import * as fs from 'fs';

async function main() {
  if (hre.network.name !== 'baseSepolia') throw new Error('Run with baseSepolia');

  const [deployer] = await hre.ethers.getSigners();
  const registry = JSON.parse(
    fs.readFileSync('./deploy-registry/base-sepolia-v1-testnet.json', 'utf-8'),
  );

  const creationPolicyAddr = registry.contracts.EscrowCreationPolicy.address;
  const creationPolicy = await hre.ethers.getContractAt('EscrowCreationPolicy', creationPolicyAddr);

  const adminRole = await creationPolicy.DEFAULT_ADMIN_ROLE();
  console.log('Admin role:', adminRole);
  console.log('Deployer has admin?', await creationPolicy.hasRole(adminRole, deployer.address));

  // Check timelock
  const timelock = registry.contracts.TimelockController.address;
  console.log('Timelock has admin?', await creationPolicy.hasRole(adminRole, timelock));
}

main().catch(console.error);
