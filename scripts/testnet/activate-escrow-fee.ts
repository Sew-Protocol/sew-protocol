/* eslint-disable no-console */
/**
 * Activate queued escrow fee for EscrowVault via EscrowGovernanceTimelock (slow lane).
 *
 * Run:
 *   pnpm hardhat run --network baseSepolia scripts/testnet/activate-escrow-fee.ts
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

  const roleAdminContract: string = await vault.ROLE_ADMIN_CONTRACT();
  const roleAdminTimelock: string = await admin.ROLE_TIMELOCK();

  // Pre-flight: the EscrowGovernanceTimelock must hold ROLE_ADMIN_CONTRACT on the
  // target vault, otherwise activateEscrowFee() will revert with no diagnostic.
  const adminHoldsRole: boolean = await vault.hasRole(roleAdminContract, adminAddr);
  if (!adminHoldsRole) {
    throw new Error(
      `EscrowGovernanceTimelock ${adminAddr} does NOT hold ROLE_ADMIN_CONTRACT on ` +
        `EscrowVault ${vaultAddr}; activateEscrowFee() would revert. ` +
        `Ensure the grant from deploy/70_core_escrow.ts was applied.`
    );
  }

  const hasAdminTimelockRole: boolean = await admin.hasRole(roleAdminTimelock, deployer);
  if (!hasAdminTimelockRole) {
    throw new Error(
      `Caller ${deployer} does not have EscrowGovernanceTimelock.ROLE_TIMELOCK; cannot activateEscrowFee(). ` +
        `Use the original admin/timelock EOA (the one that deployed EscrowGovernanceTimelock) or grant ROLE_TIMELOCK to this EOA.`
    );
  }

  const pending = await admin.getPendingEscrowFee(vaultAddr);
  const value = pending[0] as bigint;
  const eta = pending[1] as bigint;
  const exists = pending[2] as boolean;

  console.log(`EscrowVault: ${vaultAddr}`);
  console.log(`EscrowGovernanceTimelock: ${adminAddr}`);
  console.log(`Pending escrow fee: value=${value.toString()} eta=${eta.toString()} exists=${exists}`);

  if (!exists) {
    console.log(`⚠️  No pending escrow fee to activate.`);
    return;
  }

  if (value !== ESCROW_FEE_BPS) {
    throw new Error(
      `Pending escrow fee is ${value.toString()} bps, expected ${ESCROW_FEE_BPS.toString()} bps. ` +
        `Refusing to activate a mismatched value.`
    );
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

