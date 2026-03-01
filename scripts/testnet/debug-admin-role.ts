/**
 * Debug: Who has admin role on contracts?
 */

import hre from 'hardhat';
import { ethers } from 'ethers';
import * as fs from 'fs';

async function main() {
  if (hre.network.name !== 'baseSepolia') throw new Error('Run with baseSepolia');

  const [deployer] = await hre.ethers.getSigners();
  const deployerAddr = await deployer.getAddress();

  const registry = JSON.parse(
    fs.readFileSync('./deploy-registry/base-sepolia-v1-testnet.json', 'utf-8'),
  );

  console.log('Deployer:', deployerAddr);
  console.log();

  const contracts = [
    { name: 'EscrowVault', address: registry.contracts.EscrowVault.address },
    { name: 'CreateOps', address: registry.contracts.CreateOps.address },
    { name: 'YieldOps', address: registry.contracts.YieldOps.address },
  ];

  for (const c of contracts) {
    console.log(`=== ${c.name} (${c.address}) ===`);
    const contract = await hre.ethers.getContractAt(c.name, c.address);
    const adminRole = await contract.DEFAULT_ADMIN_ROLE();
    console.log('Admin role:', adminRole);
    console.log('Deployer has admin?', await contract.hasRole(adminRole, deployerAddr));

    // Try to get role member count
    try {
      const memberCount = await contract.getRoleMemberCount(adminRole);
      console.log('Role member count:', memberCount.toString());
      if (memberCount > 0n) {
        for (let i = 0; i < Math.min(Number(memberCount), 3); i++) {
          const member = await contract.getRoleMember(adminRole, i);
          console.log(`  Member ${i}:`, member);
        }
      }
    } catch (e: any) {
      console.log('  Error getting members:', e.message);
    }
    console.log();
  }
}

main().catch(console.error);
