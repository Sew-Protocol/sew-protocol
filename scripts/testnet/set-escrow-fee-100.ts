/* eslint-disable no-console */
/**
 * Set EscrowVault escrow fee to 100 bps (1%) on Base Sepolia.
 *
 * Behavior:
 * - If caller has ROLE_ADMIN_CONTRACT on EscrowVault -> call setEscrowFeeBps(100) immediately.
 * - Else -> queue via EscrowGovernanceTimelock.queueEscrowFee(), then print ETA (7 days slow-lane).
 *
 * Run:
 *   pnpm hardhat run --network baseSepolia scripts/testnet/set-escrow-fee-100.ts
 */

import hre from 'hardhat';

const ESCROW_FEE_BPS = 100n;

async function main() {
  if (hre.network.name !== 'baseSepolia') {
    throw new Error(`Run with --network baseSepolia (got: ${hre.network.name})`);
  }

  const { deployments, getNamedAccounts } = hre;
  const { deployer } = await getNamedAccounts();
  const signer = await hre.ethers.getSigner(deployer);

  const vaultAddr = (await deployments.get('EscrowVault')).address;
  const adminAddr = (await deployments.get('EscrowGovernanceTimelock')).address;

  const vault = await hre.ethers.getContractAt('EscrowVault', vaultAddr, signer);
  const admin = await hre.ethers.getContractAt('EscrowGovernanceTimelock', adminAddr, signer);

  const currentFee: bigint = await vault.escrowFee();
  const roleAdminContract: string = await vault.ROLE_ADMIN_CONTRACT();
  const roleAdminTimelock: string = await admin.ROLE_TIMELOCK();

  console.log(`EscrowVault: ${vaultAddr}`);
  console.log(`EscrowGovernanceTimelock: ${adminAddr}`);
  console.log(`Caller: ${deployer}`);
  console.log(`Current escrowFee (bps): ${currentFee.toString()}`);

  if (currentFee === ESCROW_FEE_BPS) {
    console.log(`✅ escrowFee already set to ${ESCROW_FEE_BPS.toString()} bps`);
    return;
  }

  const hasAdminRole: boolean = await vault.hasRole(roleAdminContract, deployer);
  const hasAdminTimelockRole: boolean = await admin.hasRole(roleAdminTimelock, deployer);

  if (hasAdminRole) {
    console.log(`\n🔧 Caller has ROLE_ADMIN_CONTRACT; setting escrowFee immediately...`);
    const tx = await vault.setEscrowFeeBps(ESCROW_FEE_BPS);
    console.log(`  tx: ${tx.hash}`);
    const rcpt = await tx.wait();
    if (rcpt?.status !== 1n && rcpt?.status !== 1) {
      throw new Error(`setEscrowFeeBps tx reverted (status=${String((rcpt as any)?.status)})`);
    }
    const updated: bigint = await vault.escrowFee();
    console.log(`✅ Updated escrowFee (bps): ${updated.toString()}`);
    return;
  }

  if (!hasAdminTimelockRole) {
    throw new Error(
      `Caller ${deployer} does not have EscrowGovernanceTimelock.ROLE_TIMELOCK; cannot queueEscrowFee(). ` +
        `Use the original admin/timelock EOA (the one that deployed EscrowGovernanceTimelock) or grant ROLE_TIMELOCK to this EOA.`
    );
  }

  console.log(
    `\n⏳ Caller does NOT have ROLE_ADMIN_CONTRACT; queueing via EscrowGovernanceTimelock (slow lane)...`
  );
  const txQ = await admin.queueEscrowFee(vaultAddr, ESCROW_FEE_BPS);
  console.log(`  queue tx: ${txQ.hash}`);
  const rcptQ = await txQ.wait();
  if (rcptQ?.status !== 1n && rcptQ?.status !== 1) {
    throw new Error(`queueEscrowFee tx reverted (status=${String((rcptQ as any)?.status)})`);
  }

  const pending = await admin.getPendingEscrowFee(vaultAddr);
  // (value, eta, exists)
  const value = pending[0] as bigint;
  const eta = pending[1] as bigint;
  const exists = pending[2] as boolean;

  console.log(`✅ Queued escrowFee (bps): ${value.toString()}`);
  console.log(`   - exists: ${exists}`);
  console.log(`   - eta (unix): ${eta.toString()}`);
  console.log(`\nNext step (after ETA):`);
  console.log(`  pnpm hardhat run --network baseSepolia scripts/testnet/activate-escrow-fee.ts`);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});

