/**
 * Deploy the full DR v3 suite and immediately swap DecentralizedResolutionModule
 * into EscrowVault (bypasses the slow-lane governance delay).
 *
 * Use this for testnet convenience or for a fresh testnet deploy where you want
 * to land everything in one shot without waiting for timelock delays.
 *
 * Required env vars:
 *   DEPLOYER_PRIVATE_KEY  — must have EscrowVault.DEFAULT_ADMIN_ROLE or ROLE_ADMIN_CONTRACT
 *   STABLE_TOKEN_ADDRESS  — USDC (or mock stable) on the target chain
 *                           (defaults to Base Sepolia USDC if not set)
 *
 * Deployments are read from hardhat-deploy artefacts so you can also call this
 * after running `pnpm hardhat deploy --tags dr3` to just do the swap step.
 */

import hre from 'hardhat';
import { ethers } from 'ethers';

const BASE_SEPOLIA_USDC = '0x4cCa3115a7c13F68Cb2e1dF1c2c2dB87e15C9d2';
const BASE_MAINNET_USDC = '0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913';

function requireEnv(name: string): string {
  const v = process.env[name];
  if (!v) throw new Error(`Missing env var: ${name}`);
  return v;
}

function basescanLink(address: string, chainId: number): string {
  const base = chainId === 8453 ? 'https://basescan.org' : 'https://sepolia.basescan.org';
  return `${base}/address/${address}`;
}

async function main() {
  const { deployments, ethers: hreEthers } = hre;
  const provider = hreEthers.provider;
  const network = await provider.getNetwork();
  const chainId = Number(network.chainId);

  const deployerPk = requireEnv('DEPLOYER_PRIVATE_KEY');
  const deployer = new ethers.Wallet(deployerPk, provider);
  const deployerAddr = await deployer.getAddress();

  const stableToken =
    process.env.STABLE_TOKEN_ADDRESS ??
    (chainId === 8453 ? BASE_MAINNET_USDC : BASE_SEPOLIA_USDC);

  console.log(`\n⚡ Deploy DR v3 + set DecentralizedResolutionModule immediately`);
  console.log(`   chainId:  ${chainId}`);
  console.log(`   deployer: ${deployerAddr}`);
  console.log(`   stable:   ${stableToken}`);

  // ── Resolve previously-deployed core contracts ────────────────────────────

  const timelockAddr = (await deployments.get('TimelockController')).address;
  const escrowVaultAddr = (await deployments.get('EscrowVault')).address;

  let escrowAdminAddr: string | undefined;
  try { escrowAdminAddr = (await deployments.get('EscrowGovernanceTimelock')).address; } catch {}

  let sewTokenAddr: string;
  try {
    sewTokenAddr = (await deployments.get('SewToken')).address;
  } catch {
    throw new Error('SewToken not deployed — run governance deploy scripts first');
  }

  console.log(`\n   TimelockController:       ${timelockAddr}`);
  console.log(`   EscrowVault:              ${escrowVaultAddr}`);
  if (escrowAdminAddr) console.log(`   EscrowGovernanceTimelock: ${escrowAdminAddr}`);

  // ── Helper: deploy or get ─────────────────────────────────────────────────

  async function deployOrGet(
    name: string,
    factory: ethers.ContractFactory,
    args: unknown[],
  ): Promise<string> {
    try {
      const existing = (await deployments.get(name)).address;
      console.log(`   ✅ ${name} already deployed: ${existing}`);
      return existing;
    } catch {
      console.log(`\n📦 Deploying ${name}...`);
      const contract = await factory.deploy(...args);
      const tx = contract.deploymentTransaction();
      if (tx) console.log(`   tx: ${tx.hash}`);
      await contract.waitForDeployment();
      const addr = await contract.getAddress();
      console.log(`   ✅ ${name}: ${addr}`);
      console.log(`      ${basescanLink(addr, chainId)}`);
      return addr;
    }
  }

  // ── 1. InsurancePoolVault ─────────────────────────────────────────────────
  const insuranceAddr = await deployOrGet(
    'InsurancePoolVault',
    await hreEthers.getContractFactory('InsurancePoolVault', deployer),
    [deployerAddr, stableToken],
  );

  // ── 2. ResolverStakingModuleV1 ────────────────────────────────────────────
  const stakingAddr = await deployOrGet(
    'ResolverStakingModuleV1',
    await hreEthers.getContractFactory('ResolverStakingModuleV1', deployer),
    [deployerAddr, stableToken, sewTokenAddr],
  );

  // ── 3. ResolverSlashingModuleV1 ───────────────────────────────────────────
  const slashingAddr = await deployOrGet(
    'ResolverSlashingModuleV1',
    await hreEthers.getContractFactory('ResolverSlashingModuleV1', deployer),
    [deployerAddr, stakingAddr, insuranceAddr, stableToken],
  );

  // ── 4. BondTokenRegistry ──────────────────────────────────────────────────
  const bondRegistryAddr = await deployOrGet(
    'BondTokenRegistry',
    await hreEthers.getContractFactory('BondTokenRegistry', deployer),
    [timelockAddr, stableToken],
  );

  // ── 5. DRMAdminFacet ──────────────────────────────────────────────────────
  const adminFacetAddr = await deployOrGet(
    'DRMAdminFacet',
    await hreEthers.getContractFactory('DRMAdminFacet', deployer),
    [timelockAddr, stableToken],
  );

  // ── 6. PaymentCalculationLibraryV1 ───────────────────────────────────────
  const paymentLibAddr = await deployOrGet(
    'PaymentCalculationLibraryV1',
    await hreEthers.getContractFactory('PaymentCalculationLibraryV1', deployer),
    [],
  );

  // ── 7. ResolverIncentiveModuleV2 ─────────────────────────────────────────
  const incentiveAddr = await deployOrGet(
    'ResolverIncentiveModuleV2',
    await hreEthers.getContractFactory('ResolverIncentiveModuleV2', deployer),
    [deployerAddr, paymentLibAddr],
  );

  // ── 8. DecentralizedResolutionModule ─────────────────────────────────────
  const drmAddr = await deployOrGet(
    'DecentralizedResolutionModule',
    await hreEthers.getContractFactory('DecentralizedResolutionModule', deployer),
    [deployerAddr],
  );

  const drm: any = await hreEthers.getContractAt('DecentralizedResolutionModule', drmAddr, deployer);
  const ROLE_TIMELOCK = ethers.keccak256(ethers.toUtf8Bytes('ROLE_TIMELOCK'));
  const ROLE_SLASHING_MODULE = ethers.keccak256(ethers.toUtf8Bytes('ROLE_SLASHING_MODULE'));

  // ── 9. Wire staking ↔ slashing ───────────────────────────────────────────
  console.log(`\n🔗 Wiring staking ↔ slashing...`);
  const staking: any = await hreEthers.getContractAt('ResolverStakingModuleV1', stakingAddr, deployer);

  if (!(await staking.hasRole(ROLE_TIMELOCK, deployerAddr))) {
    await (await staking.grantRole(ROLE_TIMELOCK, deployerAddr)).wait();
  }
  const currentSlashingOnStaking = await staking.slashingModule();
  if (currentSlashingOnStaking.toLowerCase() !== slashingAddr.toLowerCase()) {
    await (await staking.setSlashingModule(slashingAddr)).wait();
    console.log(`   ✅ staking.slashingModule → ${slashingAddr}`);
  } else {
    console.log(`   ✅ staking.slashingModule already set`);
  }
  if (!(await staking.hasRole(ROLE_TIMELOCK, timelockAddr))) {
    await (await staking.grantRole(ROLE_TIMELOCK, timelockAddr)).wait();
  }

  // ── 10. Insurance pool: grant slashing module ─────────────────────────────
  console.log(`\n🔗 Wiring slashing → InsurancePoolVault...`);
  const insurance: any = await hreEthers.getContractAt('InsurancePoolVault', insuranceAddr, deployer);
  if (!(await insurance.hasRole(ROLE_SLASHING_MODULE, slashingAddr))) {
    await (await insurance.grantRole(ROLE_SLASHING_MODULE, slashingAddr)).wait();
    console.log(`   ✅ insurance ROLE_SLASHING_MODULE → ${slashingAddr}`);
  }
  if (!(await insurance.hasRole(ROLE_TIMELOCK, timelockAddr))) {
    await (await insurance.grantRole(ROLE_TIMELOCK, timelockAddr)).wait();
  }

  // ── 11. Bootstrap admin facet on DRM ─────────────────────────────────────
  console.log(`\n🔗 Bootstrapping DRMAdminFacet on DRM...`);
  const currentFacet = await drm.adminFacet();
  if (currentFacet === ethers.ZeroAddress) {
    await (await drm.setAdminFacet(adminFacetAddr)).wait();
    console.log(`   ✅ adminFacet → ${adminFacetAddr}`);
  } else {
    console.log(`   ✅ adminFacet already set: ${currentFacet}`);
  }

  // ── 12. Grant governance roles on DRM ─────────────────────────────────────
  console.log(`\n🔗 Granting ROLE_TIMELOCK on DRM...`);
  if (!(await drm.hasRole(ROLE_TIMELOCK, timelockAddr))) {
    await (await drm.grantRole(ROLE_TIMELOCK, timelockAddr)).wait();
    console.log(`   ✅ ROLE_TIMELOCK → TimelockController`);
  }
  if (escrowAdminAddr && !(await drm.hasRole(ROLE_TIMELOCK, escrowAdminAddr))) {
    await (await drm.grantRole(ROLE_TIMELOCK, escrowAdminAddr)).wait();
    console.log(`   ✅ ROLE_TIMELOCK → EscrowGovernanceTimelock`);
  }

  // Grant deployer ROLE_TIMELOCK so it can call setBondTokenRegistry / setIncentiveModule
  if (!(await drm.hasRole(ROLE_TIMELOCK, deployerAddr))) {
    await (await drm.grantRole(ROLE_TIMELOCK, deployerAddr)).wait();
  }

  // ── 13. Set BondTokenRegistry ─────────────────────────────────────────────
  console.log(`\n🔗 Setting BondTokenRegistry...`);
  const currentRegistry = await drm.bondTokenRegistry();
  if (currentRegistry === ethers.ZeroAddress || currentRegistry.toLowerCase() !== bondRegistryAddr.toLowerCase()) {
    await (await drm.setBondTokenRegistry(bondRegistryAddr)).wait();
    console.log(`   ✅ bondTokenRegistry → ${bondRegistryAddr}`);
  } else {
    console.log(`   ✅ bondTokenRegistry already set`);
  }

  // ── 14. Set incentive module ──────────────────────────────────────────────
  console.log(`\n🔗 Setting incentiveModule...`);
  const currentIncentive = await drm.incentiveModule();
  if (currentIncentive === ethers.ZeroAddress || currentIncentive.toLowerCase() !== incentiveAddr.toLowerCase()) {
    await (await drm.setIncentiveModule(incentiveAddr)).wait();
    console.log(`   ✅ incentiveModule → ${incentiveAddr}`);
  } else {
    console.log(`   ✅ incentiveModule already set`);
  }

  // ── 15. Register EscrowVault on DRM ──────────────────────────────────────
  console.log(`\n🔗 Registering EscrowVault on DRM...`);
  if (!(await drm.registeredEscrowContracts(escrowVaultAddr))) {
    await (await drm.registerEscrowContract(escrowVaultAddr)).wait();
    console.log(`   ✅ EscrowVault registered`);
  } else {
    console.log(`   ✅ EscrowVault already registered`);
  }

  // ── 16. Swap DRM into EscrowVault (bypass slow lane) ────────────────────
  console.log(`\n🔗 Swapping DecentralizedResolutionModule into EscrowVault...`);
  const escrow: any = await hreEthers.getContractAt('EscrowVault', escrowVaultAddr, deployer);

  const current = await escrow.disputeResolutionModule();
  console.log(`   Current resolution module: ${current}`);

  if (current.toLowerCase() === drmAddr.toLowerCase()) {
    console.log(`   ✅ DRM already active on EscrowVault`);
  } else {
    // Ensure deployer can call setResolutionModule
    const ROLE_ADMIN_CONTRACT = await escrow.ROLE_ADMIN_CONTRACT();
    const DEFAULT_ADMIN_ROLE = await escrow.DEFAULT_ADMIN_ROLE();

    const hasAdminContract = await escrow.hasRole(ROLE_ADMIN_CONTRACT, deployerAddr);
    if (!hasAdminContract) {
      const hasDefaultAdmin = await escrow.hasRole(DEFAULT_ADMIN_ROLE, deployerAddr);
      if (!hasDefaultAdmin) {
        throw new Error(
          `Deployer ${deployerAddr} has neither ROLE_ADMIN_CONTRACT nor DEFAULT_ADMIN_ROLE ` +
            `on EscrowVault. Use a guardian/admin account or activate via slow lane.`,
        );
      }
      console.log(`   Granting ROLE_ADMIN_CONTRACT to deployer for immediate swap...`);
      await (await escrow.grantRole(ROLE_ADMIN_CONTRACT, deployerAddr)).wait();
    }

    const setTx = await escrow.setResolutionModule(drmAddr);
    console.log(`   set tx: ${setTx.hash}`);
    await setTx.wait();
  }

  const nowSet = await escrow.disputeResolutionModule();
  console.log(`\n✅ EscrowVault.disputeResolutionModule: ${nowSet}`);
  console.log(`   ${basescanLink(nowSet, chainId)}`);

  console.log(`\n📋 Deployed addresses:`);
  console.log(`   InsurancePoolVault:            ${insuranceAddr}`);
  console.log(`   ResolverStakingModuleV1:       ${stakingAddr}`);
  console.log(`   ResolverSlashingModuleV1:      ${slashingAddr}`);
  console.log(`   BondTokenRegistry:             ${bondRegistryAddr}`);
  console.log(`   DRMAdminFacet:                 ${adminFacetAddr}`);
  console.log(`   PaymentCalculationLibraryV1:   ${paymentLibAddr}`);
  console.log(`   ResolverIncentiveModuleV2:     ${incentiveAddr}`);
  console.log(`   DecentralizedResolutionModule: ${drmAddr}`);
}

main().catch((err) => {
  console.error(`\n❌ DR v3 deploy failed:\n${err?.stack ?? err?.message ?? err}`);
  process.exitCode = 1;
});
