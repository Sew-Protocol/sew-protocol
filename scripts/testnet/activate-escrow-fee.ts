/* eslint-disable no-console */
/**
 * Activate queued escrow fee for EscrowVault via EscrowAdminContract (slow lane).
 *
 * Run:
 *   pnpm hardhat run --network baseSepolia scripts/testnet/activate-escrow-fee.ts
 */

import hre from 'hardhat';

async function main() {
  if (hre.network.name !== 'baseSepolia') {
    throw new Error(`Run with --network baseSepolia (got: ${hre.network.name})`);
  }

  const { deployments, getNamedAccounts } = hre;
  const { deployer } = await getNamedAccounts();
  const signer = await hre.ethers.getSigner(deployer);

  const vaultAddr = (await deployments.get('EscrowVault')).address;
  const adminAddr = (await deployments.get('EscrowAdminContract')).address;

  const vault = await hre.ethers.getContractAt('EscrowVault', vaultAddr, signer);
  const admin = await hre.ethers.getContractAt('EscrowAdminContract', adminAddr, signer);

  const pending = await admin.getPendingEscrowFee(vaultAddr);
  const value = pending[0] as bigint;
  const eta = pending[1] as bigint;
  const exists = pending[2] as boolean;

  console.log(`EscrowVault: ${vaultAddr}`);
  console.log(`EscrowAdminContract: ${adminAddr}`);
  console.log(`Pending escrow fee: value=${value.toString()} eta=${eta.toString()} exists=${exists}`);

  if (!exists) {
    console.log(`⚠️  No pending escrow fee to activate.`);
    return;
  }

  const tx = await admin.activateEscrowFee(vaultAddr);
  console.log(`activate tx: ${tx.hash}`);
  await tx.wait();

  console.log(`✅ escrowFee (bps) is now: ${(await vault.escrowFee()).toString()}`);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});

