import { ethers } from 'hardhat';
import * as fs from 'fs';

async function main() {
  const registryPath = './deploy-registry/base-sepolia-v1-testnet.json';
  const registry = JSON.parse(fs.readFileSync(registryPath, 'utf-8'));
  const escrowVaultAddr = registry.contracts.EscrowVault.address;

  const escrowVault = await ethers.getContractAt('EscrowVault', escrowVaultAddr);

  console.log('\n📊 Checking last escrows...\n');
  
  const totalEscrows = await escrowVault.getEscrowCount?.();
  console.log(`Total escrows: ${totalEscrows}`);

  // Check the last few escrows
  if (totalEscrows > 0) {
    for (let i = Math.max(0, Number(totalEscrows) - 3); i < totalEscrows; i++) {
      try {
        const info = await escrowVault.getEscrowInfo(i);
        const block = await ethers.provider.getBlock(info.createdAt || 'latest');
        console.log(`\nEscrow ${i}:`);
        console.log(`  Buyer: ${info.buyer}`);
        console.log(`  Seller: ${info.seller}`);
        console.log(`  Amount: ${ethers.formatEther(info.amount)} SEW`);
        console.log(`  Status: ${info.status}`);
        console.log(`  Created at block: ${info.createdAt}`);
      } catch (e) {
        console.log(`\nEscrow ${i}: Error reading - ${(e as any).message}`);
      }
    }
  }

  console.log('\n');
}

main().catch(console.error);
