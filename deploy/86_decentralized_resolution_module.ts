/**
 * Deploy DecentralizedResolutionModule (DRM) and complete DR v3 wiring
 *
 * This script:
 *   1. Deploys DecentralizedResolutionModule
 *   2. Wires DRMAdminFacet as the admin surface (one-time bootstrap)
 *   3. Sets the BondTokenRegistry via the admin facet delegation
 *   4. Sets ResolverIncentiveModuleV2 as the incentive module
 *   5. Grants governance roles (ROLE_TIMELOCK) to TimelockController
 *   6. Registers EscrowVault as an allowed escrow contract on DRM
 *
 * Run scripts/testnet/deploy-drm-and-set-immediate.ts (or the queue variant) to
 * activate DRM as the live resolution module on EscrowVault.
 *
 * Depends on: 85_dr3_modules (InsurancePoolVault, StakingModule, SlashingModule,
 *             BondTokenRegistry, DRMAdminFacet, ResolverIncentiveModuleV2).
 */

import { HardhatRuntimeEnvironment } from 'hardhat/types';
import { DeployFunction } from 'hardhat-deploy/types';
import { validateNetworkForDeployment } from '../scripts/_lib/network-validation';
import { getBlockExplorerUrl } from '../config/chains.config';
import { registerDeployment } from '../config/deployments.registry';

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  await validateNetworkForDeployment(hre);

  const { deployments, getNamedAccounts, ethers } = hre;
  const { deploy, get } = deployments;
  const { deployer } = await getNamedAccounts();

  // Resolve dependencies
  const timelockAddr = (await get('TimelockController')).address;
  const bondRegistryAddr = (await get('BondTokenRegistry')).address;
  const adminFacetAddr = (await get('DRMAdminFacet')).address;
  const incentiveModuleAddr = (await get('ResolverIncentiveModuleV2')).address;

  let escrowVaultAddr: string | undefined;
  try {
    escrowVaultAddr = (await get('EscrowVault')).address;
  } catch {
    console.log(`   ⚠  EscrowVault not deployed — will skip escrow registration`);
  }

  let escrowAdminAddr: string | undefined;
  try {
    escrowAdminAddr = (await get('EscrowGovernanceTimelock')).address;
  } catch {
    // optional
  }

  console.log(`\n📦 Deploying DecentralizedResolutionModule...`);
  console.log(`   deployer:          ${deployer}`);
  console.log(`   TimelockController: ${timelockAddr}`);
  console.log(`   DRMAdminFacet:      ${adminFacetAddr}`);
  console.log(`   BondTokenRegistry:  ${bondRegistryAddr}`);
  console.log(`   IncentiveModule:    ${incentiveModuleAddr}`);

  // ── 1. Deploy DRM ─────────────────────────────────────────────────────────

  const drmDeploy = await deploy('DecentralizedResolutionModule', {
    contract: 'DecentralizedResolutionModule',
    from: deployer,
    args: [deployer],
    log: true,
  });

  if (drmDeploy.newlyDeployed) {
    const url = getBlockExplorerUrl(hre, drmDeploy.address);
    console.log(`   ✅ DecentralizedResolutionModule: ${drmDeploy.address}`);
    if (url) console.log(`      ${url}`);
    if (drmDeploy.receipt) {
      await registerDeployment(hre, 'DecentralizedResolutionModule', {
        address: drmDeploy.address,
        txHash: drmDeploy.receipt.hash,
        blockNumber: drmDeploy.receipt.blockNumber,
        constructorArgs: [deployer],
        tags: ['dr3', 'resolution-module'],
      });
    }
  } else {
    console.log(`   ✅ DecentralizedResolutionModule already deployed: ${drmDeploy.address}`);
  }

  const signer = await ethers.getSigner(deployer);
  const drm = await ethers.getContractAt('DecentralizedResolutionModule', drmDeploy.address, signer);

  const ROLE_TIMELOCK = ethers.keccak256(ethers.toUtf8Bytes('ROLE_TIMELOCK'));
  const ROLE_GUARDIAN = ethers.keccak256(ethers.toUtf8Bytes('ROLE_GUARDIAN'));

  // ── 2. Bootstrap admin facet (one-time, no role required on first call) ──

  console.log(`\n🔗 Bootstrapping DRMAdminFacet...`);
  const currentFacet = await drm.adminFacet();
  if (currentFacet === ethers.ZeroAddress) {
    console.log(`   Setting adminFacet to ${adminFacetAddr}...`);
    await (await drm.setAdminFacet(adminFacetAddr)).wait();
    console.log(`   ✅ adminFacet set`);
  } else if (currentFacet.toLowerCase() === adminFacetAddr.toLowerCase()) {
    console.log(`   ✅ adminFacet already set`);
  } else {
    console.log(`   ⚠  adminFacet already set to a different address: ${currentFacet}`);
    console.log(`      Update via governance (ROLE_TIMELOCK) if a rotation is needed.`);
  }

  // ── 3. Grant ROLE_TIMELOCK on DRM to TimelockController (+ EscrowAdmin) ──

  console.log(`\n🔗 Granting governance roles on DecentralizedResolutionModule...`);

  const timelockHasDRMTimelock = await drm.hasRole(ROLE_TIMELOCK, timelockAddr);
  if (!timelockHasDRMTimelock) {
    console.log(`   Granting ROLE_TIMELOCK to TimelockController...`);
    await (await drm.grantRole(ROLE_TIMELOCK, timelockAddr)).wait();
    console.log(`   ✅ Done`);
  } else {
    console.log(`   ✅ TimelockController already has ROLE_TIMELOCK on DRM`);
  }

  if (escrowAdminAddr) {
    const escrowAdminHasDRMTimelock = await drm.hasRole(ROLE_TIMELOCK, escrowAdminAddr);
    if (!escrowAdminHasDRMTimelock) {
      console.log(`   Granting ROLE_TIMELOCK to EscrowGovernanceTimelock...`);
      await (await drm.grantRole(ROLE_TIMELOCK, escrowAdminAddr)).wait();
      console.log(`   ✅ Done`);
    } else {
      console.log(`   ✅ EscrowGovernanceTimelock already has ROLE_TIMELOCK on DRM`);
    }
  }

  // ── 4. Set BondTokenRegistry via admin-facet delegation ──────────────────
  // DRM.setBondTokenRegistry delegates to DRMAdminFacet which requires ROLE_TIMELOCK.
  // Deployer must have ROLE_TIMELOCK on DRM (which DEFAULT_ADMIN_ROLE can grant).

  console.log(`\n🔗 Setting BondTokenRegistry...`);

  const deployerHasDRMTimelock = await drm.hasRole(ROLE_TIMELOCK, deployer);
  if (!deployerHasDRMTimelock) {
    console.log(`   Granting ROLE_TIMELOCK to deployer (temporary)...`);
    await (await drm.grantRole(ROLE_TIMELOCK, deployer)).wait();
  }

  const currentRegistry = await drm.bondTokenRegistry();
  if (currentRegistry === ethers.ZeroAddress || currentRegistry.toLowerCase() !== bondRegistryAddr.toLowerCase()) {
    console.log(`   Calling DRM.setBondTokenRegistry(${bondRegistryAddr})...`);
    await (await drm.setBondTokenRegistry(bondRegistryAddr)).wait();
    console.log(`   ✅ BondTokenRegistry set`);
  } else {
    console.log(`   ✅ BondTokenRegistry already set`);
  }

  // ── 5. Set incentive module ───────────────────────────────────────────────

  console.log(`\n🔗 Setting ResolverIncentiveModuleV2 as incentiveModule...`);

  const currentIncentive = await drm.incentiveModule();
  if (
    currentIncentive === ethers.ZeroAddress ||
    currentIncentive.toLowerCase() !== incentiveModuleAddr.toLowerCase()
  ) {
    console.log(`   Calling DRM.setIncentiveModule(${incentiveModuleAddr})...`);
    await (await drm.setIncentiveModule(incentiveModuleAddr)).wait();
    console.log(`   ✅ incentiveModule set`);
  } else {
    console.log(`   ✅ incentiveModule already set`);
  }

  // ── 6. Register EscrowVault as an allowed escrow on DRM ──────────────────

  if (escrowVaultAddr) {
    console.log(`\n🔗 Registering EscrowVault on DecentralizedResolutionModule...`);
    const isRegistered = await drm.registeredEscrowContracts(escrowVaultAddr);
    if (!isRegistered) {
      console.log(`   Calling DRM.registerEscrowContract(${escrowVaultAddr})...`);
      await (await drm.registerEscrowContract(escrowVaultAddr)).wait();
      console.log(`   ✅ EscrowVault registered`);
    } else {
      console.log(`   ✅ EscrowVault already registered`);
    }
  }

  // ── 7. Grant ROLE_TIMELOCK on DRMAdminFacet to TimelockController ─────────
  // DRMAdminFacet's own role registry must also have TimelockController as ROLE_TIMELOCK
  // so that direct calls to the facet (not via DRM delegation) are also authorized.

  console.log(`\n🔗 Granting governance roles on DRMAdminFacet...`);
  const adminFacet = await ethers.getContractAt('DRMAdminFacet', adminFacetAddr, signer);
  const facetTimelockGranted = await adminFacet.hasRole(ROLE_TIMELOCK, timelockAddr);
  if (!facetTimelockGranted) {
    console.log(`   Granting ROLE_TIMELOCK to TimelockController on DRMAdminFacet...`);
    await (await adminFacet.grantRole(ROLE_TIMELOCK, timelockAddr)).wait();
    console.log(`   ✅ Done`);
  } else {
    console.log(`   ✅ TimelockController already has ROLE_TIMELOCK on DRMAdminFacet`);
  }

  console.log(`\n✅ DecentralizedResolutionModule deployment and wiring complete`);
  console.log(`\n   DecentralizedResolutionModule: ${drmDeploy.address}`);
  console.log(`\n   Next steps:`);
  console.log(`   • To activate on testnet immediately:`);
  console.log(`     ./scripts/testnet/deploy-drm-and-set-immediate.sh`);
  console.log(`   • To activate via governance (production):`);
  console.log(`     ./scripts/testnet/activate-resolution-module.sh`);
};

export default func;
func.tags = ['dr3', 'decentralized-resolution-module'];
func.dependencies = ['dr3-modules'];
