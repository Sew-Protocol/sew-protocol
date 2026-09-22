/**
 * Deploy DR v3 Capital Modules
 *
 * Deploys the supporting contracts for DR v3 (Decentralise Capital):
 *   - InsurancePoolVault       — holds insurance funds funded by slash proceeds + protocol fees
 *   - ResolverStakingModule  — manages resolver bond deposits, tiers, and delegation
 *   - ResolverSlashingModule — calculates and executes slash penalties
 *   - BondTokenRegistry        — allowlist of accepted appeal-bond tokens
 *   - DRMAdminFacet            — governance admin surface delegated from DecentralizedResolutionModule
 *   - PaymentCalculationLibrary — pure payment-distribution library for incentive module
 *   - ResolverIncentiveModule   — DR v2 appeal-bond incentive module
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
        txHash: insuranceDeploy.transactionHash,
        blockNumber: insuranceDeploy.receipt.blockNumber,
        constructorArgs: [deployer, stableToken],
        tags: ['dr3', 'insurance'],
      });
    }
  } else {
    console.log(`   ✅ InsurancePoolVault already deployed: ${insuranceDeploy.address}`);
  }

  // ── 2. ResolverStakingModule ────────────────────────────────────────────

  console.log(`\n📦 Deploying ResolverStakingModule...`);
  const stakingDeploy = await deploy('ResolverStakingModule', {
    contract: 'ResolverStakingModule',
    from: deployer,
    args: [deployer, stableToken, sewTokenAddr],
    log: true,
  });

  if (stakingDeploy.newlyDeployed) {
    const url = getBlockExplorerUrl(hre, stakingDeploy.address);
    console.log(`   ✅ ResolverStakingModule: ${stakingDeploy.address}`);
    if (url) console.log(`      ${url}`);
    if (stakingDeploy.receipt) {
      await registerDeployment(hre, 'ResolverStakingModule', {
        address: stakingDeploy.address,
        txHash: stakingDeploy.transactionHash,
        blockNumber: stakingDeploy.receipt.blockNumber,
        constructorArgs: [deployer, stableToken, sewTokenAddr],
        tags: ['dr3', 'staking'],
      });
    }
  } else {
    console.log(`   ✅ ResolverStakingModule already deployed: ${stakingDeploy.address}`);
  }

  // ── 3. ResolverSlashingModule ───────────────────────────────────────────

  console.log(`\n📦 Deploying ResolverSlashingModule...`);
  const slashingDeploy = await deploy('ResolverSlashingModule', {
    contract: 'ResolverSlashingModule',
    from: deployer,
    args: [deployer, stakingDeploy.address, insuranceDeploy.address, stableToken],
    log: true,
  });

  if (slashingDeploy.newlyDeployed) {
    const url = getBlockExplorerUrl(hre, slashingDeploy.address);
    console.log(`   ✅ ResolverSlashingModule: ${slashingDeploy.address}`);
    if (url) console.log(`      ${url}`);
    if (slashingDeploy.receipt) {
      await registerDeployment(hre, 'ResolverSlashingModule', {
        address: slashingDeploy.address,
        txHash: slashingDeploy.transactionHash,
        blockNumber: slashingDeploy.receipt.blockNumber,
        constructorArgs: [deployer, stakingDeploy.address, insuranceDeploy.address, stableToken],
        tags: ['dr3', 'slashing'],
      });
    }
  } else {
    console.log(`   ✅ ResolverSlashingModule already deployed: ${slashingDeploy.address}`);
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
        txHash: bondRegistryDeploy.transactionHash,
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
        txHash: adminFacetDeploy.transactionHash,
        blockNumber: adminFacetDeploy.receipt.blockNumber,
        constructorArgs: [timelockAddr, stableToken],
        tags: ['dr3', 'drm-admin'],
      });
    }
  } else {
    console.log(`   ✅ DRMAdminFacet already deployed: ${adminFacetDeploy.address}`);
  }

  // ── 6. PaymentCalculationLibrary ───────────────────────────────────────

  console.log(`\n📦 Deploying PaymentCalculationLibrary...`);
  const paymentLibDeploy = await deploy('PaymentCalculationLibrary', {
    contract: 'PaymentCalculationLibrary',
    from: deployer,
    args: [],
    log: true,
  });

  if (paymentLibDeploy.newlyDeployed) {
    const url = getBlockExplorerUrl(hre, paymentLibDeploy.address);
    console.log(`   ✅ PaymentCalculationLibrary: ${paymentLibDeploy.address}`);
    if (url) console.log(`      ${url}`);
    if (paymentLibDeploy.receipt) {
      await registerDeployment(hre, 'PaymentCalculationLibrary', {
        address: paymentLibDeploy.address,
        txHash: paymentLibDeploy.transactionHash,
        blockNumber: paymentLibDeploy.receipt.blockNumber,
        constructorArgs: [],
        tags: ['dr3', 'payment-lib'],
      });
    }
  } else {
    console.log(`   ✅ PaymentCalculationLibrary already deployed: ${paymentLibDeploy.address}`);
  }

  // ── 7. ResolverIncentiveModule ─────────────────────────────────────────

  console.log(`\n📦 Deploying ResolverIncentiveModule...`);
  const incentiveDeploy = await deploy('ResolverIncentiveModule', {
    contract: 'ResolverIncentiveModule',
    from: deployer,
    args: [deployer, paymentLibDeploy.address],
    log: true,
  });

  if (incentiveDeploy.newlyDeployed) {
    const url = getBlockExplorerUrl(hre, incentiveDeploy.address);
    console.log(`   ✅ ResolverIncentiveModule: ${incentiveDeploy.address}`);
    if (url) console.log(`      ${url}`);
    if (incentiveDeploy.receipt) {
      await registerDeployment(hre, 'ResolverIncentiveModule', {
        address: incentiveDeploy.address,
        txHash: incentiveDeploy.transactionHash,
        blockNumber: incentiveDeploy.receipt.blockNumber,
        constructorArgs: [deployer, paymentLibDeploy.address],
        tags: ['dr3', 'incentive'],
      });
    }
  } else {
    console.log(
      `   ✅ ResolverIncentiveModule already deployed: ${incentiveDeploy.address}`,
    );
  }

  // ── 8. Cross-wire staking ↔ slashing ─────────────────────────────────────

  console.log(`\n🔗 Wiring staking ↔ slashing modules...`);
  const staking = await ethers.getContractAt(
    'ResolverStakingModule',
    stakingDeploy.address,
    await ethers.getSigner(deployer),
  );

  const ROLE_TIMELOCK = ethers.keccak256(ethers.toUtf8Bytes('ROLE_TIMELOCK'));

  // Grant deployer ROLE_TIMELOCK on staking module so we can call setSlashingModule
  const deployerHasTimelockOnStaking = await staking.hasRole(ROLE_TIMELOCK, deployer);
  if (!deployerHasTimelockOnStaking) {
    console.log(`   Granting ROLE_TIMELOCK on ResolverStakingModule to deployer...`);
    await (await staking.grantRole(ROLE_TIMELOCK, deployer)).wait();
  }

  const currentSlashingModule = await staking.slashingModule();
  if (currentSlashingModule.toLowerCase() !== slashingDeploy.address.toLowerCase()) {
    console.log(`   Setting slashingModule on ResolverStakingModule...`);
    await (await staking.setSlashingModule(slashingDeploy.address)).wait();
    console.log(`   ✅ slashingModule set to ${slashingDeploy.address}`);
  } else {
    console.log(`   ✅ slashingModule already set`);
  }

  // Grant TimelockController ROLE_TIMELOCK on staking module
  const timelockHasTimelockOnStaking = await staking.hasRole(ROLE_TIMELOCK, timelockAddr);
  if (!timelockHasTimelockOnStaking) {
    console.log(`   Granting ROLE_TIMELOCK on ResolverStakingModule to TimelockController...`);
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

  console.log(`\n🔗 Granting ROLE_TIMELOCK on ResolverIncentiveModule to TimelockController...`);
  const incentive = await ethers.getContractAt(
    'ResolverIncentiveModule',
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
  console.log(`   ResolverStakingModule:   ${stakingDeploy.address}`);
  console.log(`   ResolverSlashingModule:  ${slashingDeploy.address}`);
  console.log(`   BondTokenRegistry:         ${bondRegistryDeploy.address}`);
  console.log(`   DRMAdminFacet:             ${adminFacetDeploy.address}`);
  console.log(`   PaymentCalculationLibrary: ${paymentLibDeploy.address}`);
  console.log(`   ResolverIncentiveModule: ${incentiveDeploy.address}`);
  console.log(`\n   ➡ Next step: run 86_decentralized_resolution_module.ts`);
};

export default func;
func.tags = ['dr3', 'dr3-modules'];
func.dependencies = ['core', 'module-management', 'governance'];
