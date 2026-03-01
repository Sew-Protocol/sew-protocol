/**
 * Debug: Who has admin on CreateOps?
 */

import hre from 'hardhat';
import * as fs from 'fs';

async function main() {
  if (hre.network.name !== 'baseSepolia') throw new Error('Run with baseSepolia');

  const [deployer] = await hre.ethers.getSigners();
  const registry = JSON.parse(
    fs.readFileSync('./deploy-registry/base-sepolia-v1-testnet.json', 'utf-8'),
  );

  const createOpsAddr = registry.contracts.CreateOps.address;
  const createOps = await hre.ethers.getContractAt('CreateOps', createOpsAddr);

  const adminRole = await createOps.DEFAULT_ADMIN_ROLE();
  console.log('Admin role:', adminRole);
  console.log('Deployer has admin?', await createOps.hasRole(adminRole, deployer.address));

  // Check timelock
  const timelock = registry.contracts.TimelockController.address;
  console.log('Timelock has admin?', await createOps.hasRole(adminRole, timelock));
}

main().catch(console.error);
