/**
 * Debug: Check TimelockController has admin on Ops contracts
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
  console.log('TimelockController:', timelockAddr);
  console.log();

  const contracts = [
    { name: 'CreateOps', address: registry.contracts.CreateOps.address },
    { name: 'YieldOps', address: registry.contracts.YieldOps.address },
  ];

  for (const c of contracts) {
    console.log(`=== ${c.name} ===`);
    const contract = await hre.ethers.getContractAt(c.name, c.address);
    const adminRole = await contract.DEFAULT_ADMIN_ROLE();

    const hasTimelock = await contract.hasRole(adminRole, timelockAddr);
    console.log('Timelock has admin?', hasTimelock);
    console.log();
  }

  console.log('The deployer cannot grant roles because TimelockController has admin.');
  console.log('Need to grant ROLE_GUARDIAN via Timelock (requires timelock execution).');
}

main().catch(console.error);
