import hre from 'hardhat';
import { ethers } from 'ethers';

function requireEnv(name: string): string {
  const v = process.env[name];
  if (!v) throw new Error(`Missing env var: ${name}`);
  return v;
}

function basescanAddressLink(address: string): string {
  return `https://sepolia.basescan.org/address/${address}`;
}

async function main() {
  const provider = hre.ethers.provider;
  const { deployments } = hre;

  const deployerPk = requireEnv('DEPLOYER_PRIVATE_KEY');
  const deployer = new ethers.Wallet(deployerPk, provider);

  const escrowVaultAddr = (await deployments.get('EscrowVault')).address;
  const escrowAdminAddr = (await deployments.get('EscrowAdminContract')).address;

  const admin: any = await hre.ethers.getContractAt('EscrowAdminContract', escrowAdminAddr, deployer);
  const escrow: any = await hre.ethers.getContractAt('EscrowVault', escrowVaultAddr);

  console.log(`\n⏳ Activate queued resolution module (Base Sepolia)`);
  console.log(`- EscrowVault: ${escrowVaultAddr}`);
  console.log(`  - ${basescanAddressLink(escrowVaultAddr)}`);
  console.log(`- EscrowAdminContract: ${escrowAdminAddr}`);
  console.log(`  - ${basescanAddressLink(escrowAdminAddr)}`);

  const pending = await admin.getPendingResolutionModule(escrowVaultAddr);
  console.log(`\nPending:`, pending);

  console.log(`\nActivating...`);
  const tx = await admin.activateResolutionModule(escrowVaultAddr);
  console.log(`  tx: ${tx.hash}`);
  await tx.wait();

  const nowSet = await escrow.disputeResolutionModule();
  console.log(`\n✅ EscrowVault.disputeResolutionModule is now: ${nowSet}`);
  console.log(`  - ${basescanAddressLink(nowSet)}`);
}

main().catch((err) => {
  console.error(`\n❌ Activate failed:\n${err?.stack || err?.message || err}`);
  process.exitCode = 1;
});

