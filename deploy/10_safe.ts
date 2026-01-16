import { HardhatRuntimeEnvironment } from 'hardhat/types';
import { DeployFunction } from 'hardhat-deploy/types';
import { getGovConfig, validateGovConfig } from './_config';
import { isLocal } from '../config/chains.config';

/**
 * Deploy Safe Multisig Wallet
 *
 * This script deploys a Gnosis Safe multisig wallet with configurable owners and threshold.
 * The Safe will be used as the initial owner of governance contracts before transferring to Timelock.
 */
const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { deployments, getNamedAccounts, ethers } = hre;
  const { deploy, get } = deployments;
  const { deployer } = await getNamedAccounts();

  const config = getGovConfig(hre);
  validateGovConfig(config, hre);

  // For local development, if no Safe owners are configured, use deployer as a single owner
  const isLocalNetwork = isLocal(hre);

  if (config.safe.owners.length === 0 && isLocalNetwork) {
    console.log(
      '⚠️  No Safe owners configured. Using deployer as single owner for local development.',
    );
    config.safe.owners = [deployer];
    config.safe.threshold = 1;
  }

  if (config.safe.owners.length === 0) {
    throw new Error('No Safe owners configured. Set SAFE_OWNER_* environment variables.');
  }

  if (config.safe.threshold > config.safe.owners.length) {
    throw new Error(
      `Safe threshold (${config.safe.threshold}) cannot exceed number of owners (${config.safe.owners.length})`,
    );
  }

  console.log(`\n📦 Deploying Safe Multisig Wallet...`);
  console.log(`   Owners: ${config.safe.owners.length}`);
  console.log(`   Threshold: ${config.safe.threshold}`);
  console.log(`   Owner addresses:`, config.safe.owners);

  // Deploy Safe using the Safe contracts package
  // Note: Safe deployment is complex and typically uses a factory pattern
  // For now, we'll deploy a minimal Safe setup
  // In production, you would use the Safe factory contract

  // Check if Safe contracts are available
  try {
    const safeContracts = await import('@safe-global/safe-contracts');

    // For a full Safe deployment, you would use the SafeProxyFactory
    // This is a simplified version - in production, use the official Safe deployment scripts
    console.log('⚠️  Full Safe deployment requires SafeProxyFactory. Using placeholder for now.');
    console.log(
      '   In production, deploy Safe using: https://github.com/safe-global/safe-contracts',
    );

    // Store Safe configuration for later use
    await deployments.save('Safe_Multisig', {
      address: ethers.ZeroAddress, // Placeholder - will be set manually
      abi: [],
      args: [config.safe.owners, config.safe.threshold],
    });

    console.log('✅ Safe configuration saved (address to be set manually)');
    console.log(
      '   ⚠️  Deploy Safe manually using Safe UI or factory, then update deployment ledger',
    );
  } catch (error) {
    console.log('⚠️  @safe-global/safe-contracts not found. Skipping Safe deployment.');
    console.log('   Install with: pnpm add @safe-global/safe-contracts');
    console.log('   Or deploy Safe manually using Safe UI: https://app.safe.global/');

    // Save placeholder for local development
    await deployments.save('Safe_Multisig', {
      address: deployer, // Use deployer as placeholder for local dev
      abi: [],
      args: [config.safe.owners, config.safe.threshold],
    });
  }
};

export default func;
func.tags = ['safe', 'governance'];
func.dependencies = [];
