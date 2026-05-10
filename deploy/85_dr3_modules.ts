/**
 * Deploy DR v3 Capital Modules
 *
 * Deploys the supporting contracts for DR v3 (Decentralise Capital):
 *   - InsurancePoolVault       — holds insurance funds funded by slash proceeds + protocol fees
 *   - ResolverStakingModuleV1  — manages resolver bond deposits, tiers, and delegation
 *   - ResolverSlashingModuleV1 — calculates and executes slash penalties
 *   - BondTokenRegistry        — allowlist of accepted appeal-bond tokens
 *   - DRMAdminFacet            — governance admin surface delegated from DecentralizedResolutionModule
 *   - PaymentCalculationLibraryV1 — pure payment-distribution library for incentive module
 *   - ResolverIncentiveModuleV2   — DR v2 appeal-bond incentive module
 *
 * Must run before 86_decentralized_resolution_module.ts.
 * Depends on: TimelockController (30_timelock), SewToken (20_gov_token).
 */

import { HardhatRuntimeEnvironment } from 'hardhat/types';
import { DeployFunction } from 'hardhat-deploy/types';
import { validateNetworkForDeployment } from '../scripts/_lib/network-validation';
import { getChainConfig, getBlockExplorerUrl } from '../config/chains.config';
import { registerDeployment } from '../config/deployments.registry';

// USDC addresses by chain
const USDC: Record<number, string> = {
  8453: '0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913', // Base Mainnet
  84532: '0x4cCa3115a7c13F68Cb2e1dF1c2c2dB87e15C9d2', // Base Sepolia
};

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  await validateNetworkForDeployment(hre);

  const { deployments, getNamedAccounts, ethers } = hre;
  const { deploy, get } = deployments;
  const { deployer } = await getNamedAccounts();
  const chainConfig = getChainConfig(hre);

  const stableToken = USDC[chainConfig.chainId] ?? process.env.STABLE_TOKEN_ADDRESS;
  if (!stableToken) {
    throw new Error(
      `No USDC address configured for chainId ${chainConfig.chainId}. Set STABLE_TOKEN_ADDRESS env var.`,
    );
  }

  let timelockAddr: string;
  try {
    timelockAddr = (await get('TimelockController')).address;
  } catch {
    throw new Error('TimelockController not deployed — run 30_timelock.ts first');
  }

  let sewTokenAddr: string;
  try {
    sewTokenAddr = (await get('SewToken')).address;
  } catch {
    throw new Error('SewToken not deployed — run 20_gov_token.ts first');
  }

  console.log(`\n🔧 Deploying DR v3 Capital Modules`);
  console.log(`   chainId:         ${chainConfig.chainId}`);
  console.log(`   deployer:        ${deployer}`);
  console.log(`   TimelockController: ${timelockAddr}`);
  console.log(`   stableToken:     ${stableToken}`);
  console.log(`   sewToken:        ${sewTokenAddr}`);

  // ── 1. InsurancePoolVault ─────────────────────────────────────────────────

  console.log(`\n📦 Deploying InsurancePoolVault...`);
  const insuranceDeploy = await deploy('InsurancePoolVault', {
    contract: 'InsurancePoolVault',
    from: deployer,
    args: [deployer, stableToken],
    log: true,
  });

  if (insuranceDeploy.newlyDeployed) {
    const url = getBlockExplorerUrl(hre, insuranceDeploy.address);
    console.log(`   ✅ InsurancePoolVault: ${insuranceDeploy.address}`);
    if (url) console.log(`      ${url}`);
    if (insuranceDeploy.receipt) {
      await registerDeployment(hre, 'InsurancePoolVault', {
        address: insuranceDeploy.address,
        txHash: insuranceDeploy.receipt.hash,
        blockNumber: insuranceDeploy.receipt.blockNumber,
        constructorArgs: [deployer, stableToken],
        tags: ['dr3', 'insurance'],
      });
    }
  } else {
    console.log(`   ✅ InsurancePoolVault already deployed: ${insuranceDeploy.address}`);
  }

  // ── 2. ResolverStakingModuleV1 ────────────────────────────────────────────

  console.log(`\n📦 Deploying ResolverStakingModuleV1...`);
  const stakingDeploy = await deploy('ResolverStakingModuleV1', {
    contract: 'ResolverStakingModuleV1',
    from: deployer,
    args: [deployer, stableToken, sewTokenAddr],
    log: true,
  });

  if (stakingDeploy.newlyDeployed) {
    const url = getBlockExplorerUrl(hre, stakingDeploy.address);
    console.log(`   ✅ ResolverStakingModuleV1: ${stakingDeploy.address}`);
    if (url) console.log(`      ${url}`);
    if (stakingDeploy.receipt) {
      await registerDeployment(hre, 'ResolverStakingModuleV1', {
        address: stakingDeploy.address,
        txHash: stakingDeploy.receipt.hash,
        blockNumber: stakingDeploy.receipt.blockNumber,
        constructorArgs: [deployer, stableToken, sewTokenAddr],
        tags: ['dr3', 'staking'],
      });
    }
  } else {
    console.log(`   ✅ ResolverStakingModuleV1 already deployed: ${stakingDeploy.address}`);
  }

  // ── 3. ResolverSlashingModuleV1 ───────────────────────────────────────────

  console.log(`\n📦 Deploying ResolverSlashingModuleV1...`);
  const slashingDeploy = await deploy('ResolverSlashingModuleV1', {
    contract: 'ResolverSlashingModuleV1',
    from: deployer,
    args: [deployer, stakingDeploy.address, insuranceDeploy.address, stableToken],
    log: true,
  });

  if (slashingDeploy.newlyDeployed) {
    const url = getBlockExplorerUrl(hre, slashingDeploy.address);
    console.log(`   ✅ ResolverSlashingModuleV1: ${slashingDeploy.address}`);
    if (url) console.log(`      ${url}`);
    if (slashingDeploy.receipt) {
      await registerDeployment(hre, 'ResolverSlashingModuleV1', {
        address: slashingDeploy.address,
        txHash: slashingDeploy.receipt.hash,
        blockNumber: slashingDeploy.receipt.blockNumber,
        constructorArgs: [deployer, stakingDeploy.address, insuranceDeploy.address, stableToken],
        tags: ['dr3', 'slashing'],
      });
    }
  } else {
    console.log(`   ✅ ResolverSlashingModuleV1 already deployed: ${slashingDeploy.address}`);
  }

  // ── 4. BondTokenRegistry ──────────────────────────────────────────────────

  console.log(`\n📦 Deploying BondTokenRegistry...`);
  const bondRegistryDeploy = await deploy('BondTokenRegistry', {
    contract: 'BondTokenRegistry',
    from: deployer,
    args: [timelockAddr, stableToken],
    log: true,
  });

  if (bondRegistryDeploy.newlyDeployed) {
    const url = getBlockExplorerUrl(hre, bondRegistryDeploy.address);
    console.log(`   ✅ BondTokenRegistry: ${bondRegistryDeploy.address}`);
    if (url) console.log(`      ${url}`);
    if (bondRegistryDeploy.receipt) {
      await registerDeployment(hre, 'BondTokenRegistry', {
        address: bondRegistryDeploy.address,
        txHash: bondRegistryDeploy.receipt.hash,
        blockNumber: bondRegistryDeploy.receipt.blockNumber,
        constructorArgs: [timelockAddr, stableToken],
        tags: ['dr3', 'bond-registry'],
      });
    }
  } else {
    console.log(`   ✅ BondTokenRegistry already deployed: ${bondRegistryDeploy.address}`);
  }

  // ── 5. DRMAdminFacet ──────────────────────────────────────────────────────

  console.log(`\n📦 Deploying DRMAdminFacet...`);
  const adminFacetDeploy = await deploy('DRMAdminFacet', {
    contract: 'DRMAdminFacet',
    from: deployer,
    args: [timelockAddr, stableToken],
    log: true,
  });

  if (adminFacetDeploy.newlyDeployed) {
    const url = getBlockExplorerUrl(hre, adminFacetDeploy.address);
    console.log(`   ✅ DRMAdminFacet: ${adminFacetDeploy.address}`);
    if (url) console.log(`      ${url}`);
    if (adminFacetDeploy.receipt) {
      await registerDeployment(hre, 'DRMAdminFacet', {
        address: adminFacetDeploy.address,
        txHash: adminFacetDeploy.receipt.hash,
        blockNumber: adminFacetDeploy.receipt.blockNumber,
        constructorArgs: [timelockAddr, stableToken],
        tags: ['dr3', 'drm-admin'],
      });
    }
  } else {
    console.log(`   ✅ DRMAdminFacet already deployed: ${adminFacetDeploy.address}`);
  }

  // ── 6. PaymentCalculationLibraryV1 ───────────────────────────────────────

  console.log(`\n📦 Deploying PaymentCalculationLibraryV1...`);
  const paymentLibDeploy = await deploy('PaymentCalculationLibraryV1', {
    contract: 'PaymentCalculationLibraryV1',
    from: deployer,
    args: [],
    log: true,
  });

  if (paymentLibDeploy.newlyDeployed) {
    const url = getBlockExplorerUrl(hre, paymentLibDeploy.address);
    console.log(`   ✅ PaymentCalculationLibraryV1: ${paymentLibDeploy.address}`);
    if (url) console.log(`      ${url}`);
    if (paymentLibDeploy.receipt) {
      await registerDeployment(hre, 'PaymentCalculationLibraryV1', {
        address: paymentLibDeploy.address,
        txHash: paymentLibDeploy.receipt.hash,
        blockNumber: paymentLibDeploy.receipt.blockNumber,
        constructorArgs: [],
        tags: ['dr3', 'payment-lib'],
      });
    }
  } else {
    console.log(`   ✅ PaymentCalculationLibraryV1 already deployed: ${paymentLibDeploy.address}`);
  }

  // ── 7. ResolverIncentiveModuleV2 ─────────────────────────────────────────

  console.log(`\n📦 Deploying ResolverIncentiveModuleV2...`);
  const incentiveDeploy = await deploy('ResolverIncentiveModuleV2', {
    contract: 'ResolverIncentiveModuleV2',
    from: deployer,
    args: [deployer, paymentLibDeploy.address],
    log: true,
  });

  if (incentiveDeploy.newlyDeployed) {
    const url = getBlockExplorerUrl(hre, incentiveDeploy.address);
    console.log(`   ✅ ResolverIncentiveModuleV2: ${incentiveDeploy.address}`);
    if (url) console.log(`      ${url}`);
    if (incentiveDeploy.receipt) {
      await registerDeployment(hre, 'ResolverIncentiveModuleV2', {
        address: incentiveDeploy.address,
        txHash: incentiveDeploy.receipt.hash,
        blockNumber: incentiveDeploy.receipt.blockNumber,
        constructorArgs: [deployer, paymentLibDeploy.address],
        tags: ['dr3', 'incentive'],
      });
    }
  } else {
    console.log(
      `   ✅ ResolverIncentiveModuleV2 already deployed: ${incentiveDeploy.address}`,
    );
  }

  // ── 8. Cross-wire staking ↔ slashing ─────────────────────────────────────

  console.log(`\n🔗 Wiring staking ↔ slashing modules...`);
  const staking = await ethers.getContractAt(
    'ResolverStakingModuleV1',
    stakingDeploy.address,
    await ethers.getSigner(deployer),
  );

  const ROLE_TIMELOCK = ethers.keccak256(ethers.toUtf8Bytes('ROLE_TIMELOCK'));

  // Grant deployer ROLE_TIMELOCK on staking module so we can call setSlashingModule
  const deployerHasTimelockOnStaking = await staking.hasRole(ROLE_TIMELOCK, deployer);
  if (!deployerHasTimelockOnStaking) {
    console.log(`   Granting ROLE_TIMELOCK on ResolverStakingModuleV1 to deployer...`);
    await (await staking.grantRole(ROLE_TIMELOCK, deployer)).wait();
  }

  const currentSlashingModule = await staking.slashingModule();
  if (currentSlashingModule.toLowerCase() !== slashingDeploy.address.toLowerCase()) {
    console.log(`   Setting slashingModule on ResolverStakingModuleV1...`);
    await (await staking.setSlashingModule(slashingDeploy.address)).wait();
    console.log(`   ✅ slashingModule set to ${slashingDeploy.address}`);
  } else {
    console.log(`   ✅ slashingModule already set`);
  }

  // Grant TimelockController ROLE_TIMELOCK on staking module
  const timelockHasTimelockOnStaking = await staking.hasRole(ROLE_TIMELOCK, timelockAddr);
  if (!timelockHasTimelockOnStaking) {
    console.log(`   Granting ROLE_TIMELOCK on ResolverStakingModuleV1 to TimelockController...`);
    await (await staking.grantRole(ROLE_TIMELOCK, timelockAddr)).wait();
    console.log(`   ✅ Done`);
  }

  // ── 9. Wire slashing module → insurance pool ─────────────────────────────

  console.log(`\n🔗 Wiring slashing module → InsurancePoolVault...`);
  const insurance = await ethers.getContractAt(
    'InsurancePoolVault',
    insuranceDeploy.address,
    await ethers.getSigner(deployer),
  );

  const ROLE_SLASHING_MODULE = ethers.keccak256(ethers.toUtf8Bytes('ROLE_SLASHING_MODULE'));

  const slashingHasRole = await insurance.hasRole(ROLE_SLASHING_MODULE, slashingDeploy.address);
  if (!slashingHasRole) {
    console.log(`   Granting ROLE_SLASHING_MODULE on InsurancePoolVault to slashing module...`);
    await (await insurance.grantRole(ROLE_SLASHING_MODULE, slashingDeploy.address)).wait();
    console.log(`   ✅ Done`);
  } else {
    console.log(`   ✅ ROLE_SLASHING_MODULE already granted`);
  }

  // Grant TimelockController ROLE_TIMELOCK on insurance pool
  const insTimelockGranted = await insurance.hasRole(ROLE_TIMELOCK, timelockAddr);
  if (!insTimelockGranted) {
    console.log(`   Granting ROLE_TIMELOCK on InsurancePoolVault to TimelockController...`);
    await (await insurance.grantRole(ROLE_TIMELOCK, timelockAddr)).wait();
    console.log(`   ✅ Done`);
  }

  // ── 10. Wire incentive module ROLE_TIMELOCK ───────────────────────────────

  console.log(`\n🔗 Granting ROLE_TIMELOCK on ResolverIncentiveModuleV2 to TimelockController...`);
  const incentive = await ethers.getContractAt(
    'ResolverIncentiveModuleV2',
    incentiveDeploy.address,
    await ethers.getSigner(deployer),
  );

  const incTimelockGranted = await incentive.hasRole(ROLE_TIMELOCK, timelockAddr);
  if (!incTimelockGranted) {
    await (await incentive.grantRole(ROLE_TIMELOCK, timelockAddr)).wait();
    console.log(`   ✅ Done`);
  } else {
    console.log(`   ✅ Already granted`);
  }

  console.log(`\n✅ DR v3 module deployment complete`);
  console.log(`\n   InsurancePoolVault:        ${insuranceDeploy.address}`);
  console.log(`   ResolverStakingModuleV1:   ${stakingDeploy.address}`);
  console.log(`   ResolverSlashingModuleV1:  ${slashingDeploy.address}`);
  console.log(`   BondTokenRegistry:         ${bondRegistryDeploy.address}`);
  console.log(`   DRMAdminFacet:             ${adminFacetDeploy.address}`);
  console.log(`   PaymentCalculationLibraryV1: ${paymentLibDeploy.address}`);
  console.log(`   ResolverIncentiveModuleV2: ${incentiveDeploy.address}`);
  console.log(`\n   ➡ Next step: run 86_decentralized_resolution_module.ts`);
};

export default func;
func.tags = ['dr3', 'dr3-modules'];
func.dependencies = ['core', 'module-management', 'governance'];
