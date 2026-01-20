import hre from 'hardhat';
import { ethers } from 'ethers';

function requireEnv(name: string): string {
  const v = process.env[name];
  if (!v) throw new Error(`Missing env var: ${name}`);
  return v;
}

function normalizeAddressLike(input: string): string {
  const withoutComments = input.split('//')[0].split('#')[0].trim();
  return withoutComments.split(/\s+/)[0] ?? '';
}

function requireAddress(name: string, value: string): string {
  const normalized = normalizeAddressLike(value);
  if (!ethers.isAddress(normalized)) {
    throw new Error(`Invalid ${name}: "${value}" (parsed as "${normalized}")`);
  }
  return ethers.getAddress(normalized);
}

function basescanAddressLink(address: string): string {
  return `https://sepolia.basescan.org/address/${address}`;
}

async function main() {
  const provider = hre.ethers.provider;
  const { deployments } = hre;

  const deployerPk = requireEnv('DEPLOYER_PRIVATE_KEY');
  const initialResolver = requireAddress('INITIAL_RESOLVER', requireEnv('INITIAL_RESOLVER'));

  const deployer = new ethers.Wallet(deployerPk, provider);
  const deployerAddr = await deployer.getAddress();

  const escrowVaultAddr = (await deployments.get('EscrowVault')).address;
  const escrowAdminAddr = (await deployments.get('EscrowAdminContract')).address;
  const timelockAddr = (await deployments.get('TimelockController')).address;

  console.log(`\n🚀 Deploy + queue DefaultResolutionModule (Base Sepolia)`);
  console.log(`- deployer: ${deployerAddr}`);
  console.log(`- EscrowVault: ${escrowVaultAddr}`);
  console.log(`  - ${basescanAddressLink(escrowVaultAddr)}`);
  console.log(`- EscrowAdminContract: ${escrowAdminAddr}`);
  console.log(`  - ${basescanAddressLink(escrowAdminAddr)}`);
  console.log(`- TimelockController: ${timelockAddr}`);
  console.log(`- INITIAL_RESOLVER: ${initialResolver}`);

  const escrow: any = await hre.ethers.getContractAt('EscrowVault', escrowVaultAddr);
  const current = await escrow.disputeResolutionModule();
  if (current && current !== ethers.ZeroAddress) {
    console.log(`\nℹ️  EscrowVault already has disputeResolutionModule set: ${current}`);
  }

  // Deploy DefaultResolutionModule
  const factory = await hre.ethers.getContractFactory('DefaultResolutionModule', deployer);
  console.log(`\nDeploying DefaultResolutionModule...`);
  const module = await factory.deploy(deployerAddr, initialResolver);
  const depTx = module.deploymentTransaction();
  if (depTx) console.log(`  tx: ${depTx.hash}`);
  await module.waitForDeployment();
  const moduleAddr = await module.getAddress();
  console.log(`✅ DefaultResolutionModule deployed: ${moduleAddr}`);
  console.log(`  - ${basescanAddressLink(moduleAddr)}`);

  // Grant ROLE_TIMELOCK on the module so governance/admin can rotate resolver later.
  const ROLE_TIMELOCK = ethers.keccak256(ethers.toUtf8Bytes('ROLE_TIMELOCK'));
  console.log(`\nGranting DefaultResolutionModule.ROLE_TIMELOCK to EscrowAdminContract and TimelockController...`);
  const grant1 = await module.grantRole(ROLE_TIMELOCK, escrowAdminAddr);
  console.log(`  grant EscrowAdminContract tx: ${grant1.hash}`);
  await grant1.wait();
  const grant2 = await module.grantRole(ROLE_TIMELOCK, timelockAddr);
  console.log(`  grant TimelockController tx: ${grant2.hash}`);
  await grant2.wait();

  // Queue the new module in EscrowAdminContract (slow lane). Activation requires waiting SLOW_DELAY (~7 days).
  const admin: any = await hre.ethers.getContractAt('EscrowAdminContract', escrowAdminAddr, deployer);
  console.log(`\nQueueing resolution module on EscrowVault (slow lane)...`);
  const q = await admin.queueResolutionModule(escrowVaultAddr, moduleAddr);
  console.log(`  queue tx: ${q.hash}`);
  await q.wait();

  const pending = await admin.getPendingResolutionModule(escrowVaultAddr);
  console.log(`\nPending resolution module:`, pending);
  console.log(
    `\nNext step (after ETA):\n` +
      `DEPLOYER_PRIVATE_KEY=... ./scripts/testnet/activate-resolution-module.sh`
  );
}

main().catch((err) => {
  console.error(`\n❌ Deploy+queue failed:\n${err?.stack || err?.message || err}`);
  process.exitCode = 1;
});

