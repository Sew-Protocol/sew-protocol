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

  // Admin who can grant roles on EscrowVault (must have DEFAULT_ADMIN_ROLE or role admin for ROLE_ADMIN_CONTRACT)
  const adminPk = process.env.TEST_ADMIN_PRIVATE_KEY || process.env.ADMIN_PRIVATE_KEY || requireEnv('ADMIN_PRIVATE_KEY');
  // EOA we want to grant ROLE_ADMIN_CONTRACT and use for setResolutionModule
  const eoaPk = process.env.TEST_EOA_PRIVATE_KEY || process.env.EOA_PRIVATE_KEY || requireEnv('EOA_PRIVATE_KEY');
  const initialResolver = requireAddress(
    'INITIAL_RESOLVER',
    process.env.TEST_INITIAL_RESOLVER || process.env.INITIAL_RESOLVER || requireEnv('INITIAL_RESOLVER')
  );

  const admin = new ethers.Wallet(adminPk, provider);
  const eoa = new ethers.Wallet(eoaPk, provider);
  const adminAddr = await admin.getAddress();
  const eoaAddr = await eoa.getAddress();

  const escrowVaultAddr = (await deployments.get('EscrowVault')).address;
  const escrowAdminAddr = (await deployments.get('EscrowAdminContract')).address;
  const timelockAddr = (await deployments.get('TimelockController')).address;

  console.log(`\n🧷 Grant EOA + swap in DefaultResolutionModule (Base Sepolia)`);
  console.log(`- EscrowVault: ${escrowVaultAddr}`);
  console.log(`  - ${basescanAddressLink(escrowVaultAddr)}`);
  console.log(`- EscrowAdminContract: ${escrowAdminAddr}`);
  console.log(`- TimelockController: ${timelockAddr}`);
  console.log(`- ADMIN (role granter): ${adminAddr}`);
  console.log(`- EOA (module setter):  ${eoaAddr}`);
  console.log(`- INITIAL_RESOLVER:     ${initialResolver}`);
  console.log(
    `\nWARNING: This is a testnet convenience path. It bypasses slow-lane governance by granting an EOA direct module-set capability.`
  );

  const escrowAsAdmin: any = await hre.ethers.getContractAt('EscrowVault', escrowVaultAddr, admin);
  const escrowAsEoa: any = await hre.ethers.getContractAt('EscrowVault', escrowVaultAddr, eoa);

  // Deploy DefaultResolutionModule
  console.log(`\nDeploying DefaultResolutionModule...`);
  const factory = await hre.ethers.getContractFactory('DefaultResolutionModule', admin);
  const module = await factory.deploy(adminAddr, initialResolver);
  const depTx = module.deploymentTransaction();
  if (depTx) console.log(`  deploy tx: ${depTx.hash}`);
  await module.waitForDeployment();
  const moduleAddr = await module.getAddress();
  console.log(`✅ DefaultResolutionModule deployed: ${moduleAddr}`);
  console.log(`  - ${basescanAddressLink(moduleAddr)}`);

  // Grant module ROLE_TIMELOCK to EscrowAdminContract + TimelockController (so resolver can be rotated later)
  console.log(`\nGranting DefaultResolutionModule.ROLE_TIMELOCK to EscrowAdminContract and TimelockController...`);
  const ROLE_TIMELOCK = ethers.keccak256(ethers.toUtf8Bytes('ROLE_TIMELOCK'));
  await (await module.grantRole(ROLE_TIMELOCK, escrowAdminAddr)).wait();
  await (await module.grantRole(ROLE_TIMELOCK, timelockAddr)).wait();

  // Grant EOA EscrowVault.ROLE_ADMIN_CONTRACT
  const ROLE_ADMIN_CONTRACT = await escrowAsAdmin.ROLE_ADMIN_CONTRACT();
  const has = await escrowAsAdmin.hasRole(ROLE_ADMIN_CONTRACT, eoaAddr);
  if (!has) {
    console.log(`\nGranting EscrowVault.ROLE_ADMIN_CONTRACT to EOA...`);
    const tx = await escrowAsAdmin.grantRole(ROLE_ADMIN_CONTRACT, eoaAddr);
    console.log(`  grantRole tx: ${tx.hash}`);
    await tx.wait();
  } else {
    console.log(`\nEOA already has EscrowVault.ROLE_ADMIN_CONTRACT`);
  }

  // Swap in module immediately
  const current = await escrowAsEoa.disputeResolutionModule();
  console.log(`\nCurrent EscrowVault.disputeResolutionModule: ${current}`);
  console.log(`Setting EscrowVault.disputeResolutionModule -> ${moduleAddr} ...`);
  const setTx = await escrowAsEoa.setResolutionModule(moduleAddr);
  console.log(`  setResolutionModule tx: ${setTx.hash}`);
  await setTx.wait();

  const nowSet = await escrowAsEoa.disputeResolutionModule();
  console.log(`\n✅ EscrowVault.disputeResolutionModule is now: ${nowSet}`);
  console.log(`  - ${basescanAddressLink(nowSet)}`);
}

main().catch((err) => {
  console.error(`\n❌ Grant+swap failed:\n${err?.stack || err?.message || err}`);
  process.exitCode = 1;
});

