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

  console.log(`\n⚡ Deploy + set DefaultResolutionModule immediately (Base Sepolia)`);
  console.log(`- deployer: ${deployerAddr}`);
  console.log(`- EscrowVault: ${escrowVaultAddr}`);
  console.log(`  - ${basescanAddressLink(escrowVaultAddr)}`);
  console.log(`- EscrowAdminContract: ${escrowAdminAddr}`);
  console.log(`- TimelockController: ${timelockAddr}`);
  console.log(`- INITIAL_RESOLVER: ${initialResolver}`);
  console.log(
    `\nWARNING: This bypasses the slow-lane delay by granting direct permission to set the module.` +
      ` Do this only for testnet convenience and consider revoking afterwards.`
  );

  const escrow: any = await hre.ethers.getContractAt('EscrowVault', escrowVaultAddr, deployer);
  const current = await escrow.disputeResolutionModule();
  console.log(`\nCurrent EscrowVault.disputeResolutionModule: ${current}`);

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
  await (await module.grantRole(ROLE_TIMELOCK, escrowAdminAddr)).wait();
  await (await module.grantRole(ROLE_TIMELOCK, timelockAddr)).wait();

  // Ensure deployer can call setResolutionModule.
  const ROLE_ADMIN_CONTRACT = await escrow.ROLE_ADMIN_CONTRACT();
  const DEFAULT_ADMIN_ROLE = await escrow.DEFAULT_ADMIN_ROLE();

  const hasAdminContract = await escrow.hasRole(ROLE_ADMIN_CONTRACT, deployerAddr);
  if (!hasAdminContract) {
    const hasDefaultAdmin = await escrow.hasRole(DEFAULT_ADMIN_ROLE, deployerAddr);
    if (!hasDefaultAdmin) {
      throw new Error(
        `Deployer ${deployerAddr} does not have EscrowVault.ROLE_ADMIN_CONTRACT and cannot grant it (no DEFAULT_ADMIN_ROLE). ` +
          `To bypass the slow lane, use an account that can grant roles on EscrowVault, or activate via slow lane after ETA.`
      );
    }

    console.log(`\nGranting EscrowVault.ROLE_ADMIN_CONTRACT to deployer for immediate swap...`);
    const g = await escrow.grantRole(ROLE_ADMIN_CONTRACT, deployerAddr);
    console.log(`  grant tx: ${g.hash}`);
    await g.wait();
  }

  // Immediate set
  console.log(`\nSetting EscrowVault.disputeResolutionModule immediately...`);
  const setTx = await escrow.setResolutionModule(moduleAddr);
  console.log(`  set tx: ${setTx.hash}`);
  await setTx.wait();

  const nowSet = await escrow.disputeResolutionModule();
  console.log(`\n✅ EscrowVault.disputeResolutionModule is now: ${nowSet}`);
  console.log(`  - ${basescanAddressLink(nowSet)}`);

  console.log(
    `\nOptional cleanup:\n` +
      `- If you granted ROLE_ADMIN_CONTRACT to deployer only for this, revoke it later via AccessControl.\n` +
      `- For production-like behavior, still prefer the slow-lane queue/activate path.`
  );
}

main().catch((err) => {
  console.error(`\n❌ Immediate deploy+set failed:\n${err?.stack || err?.message || err}`);
  process.exitCode = 1;
});

