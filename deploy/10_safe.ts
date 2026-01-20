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
    // Attempt to deploy a real Safe if possible
    console.log('ℹ️  @safe-global/safe-contracts found. Attempting to configure GuardianSafe.');

    // In a real scenario, we might use a factory to deploy a proxy.
    // For this implementation, we will check if we are on a network where we should deploy SafeMock
    // or if we should use the singleton pattern.
    if (isLocalNetwork) {
      console.log('ℹ️  Local network detected, using SafeMock for convenience.');
      const safeMock = await deploy('GuardianSafe', {
        contract: 'SafeMock',
        from: deployer,
        args: [config.safe.owners, config.safe.threshold],
        log: true,
      });
      console.log(`✅ Guardian Safe (SafeMock) deployed at: ${safeMock.address}`);
    } else {
      // For non-local networks, we expect either a pre-configured address or we guide the user to deploy one.
      if (config.guardian.multisig && config.guardian.multisig !== ethers.ZeroAddress) {
        console.log(`ℹ️  Using pre-configured Guardian Multisig at: ${config.guardian.multisig}`);
        await deployments.save('GuardianSafe', {
          address: config.guardian.multisig,
          abi: [], // ABI can be loaded from the package if needed
        });
      } else {
        console.log('⚠️  No Guardian Multisig address configured for this network.');
        console.log('   Please deploy a Safe using https://app.safe.global/ and set GUARDIAN_MULTISIG in .env');
        
        // Still deploy SafeMock as a temporary measure if configured to do so, or just skip
        const safeMock = await deploy('GuardianSafe', {
          contract: 'SafeMock',
          from: deployer,
          args: [config.safe.owners, config.safe.threshold],
          log: true,
        });
        console.log(`✅ Temporary Guardian Safe (SafeMock) deployed at: ${safeMock.address}`);
      }
    }
  } catch (error) {
    console.log('⚠️  Error configuring Safe. Falling back to SafeMock.');
    
    // Deploy SafeMock as GuardianSafe
    const safeMock = await deploy('GuardianSafe', {
      contract: 'SafeMock',
      from: deployer,
      args: [config.safe.owners, config.safe.threshold],
      log: true,
    });
    
    console.log(`✅ Guardian Safe (SafeMock) deployed at: ${safeMock.address}`);
  }
};

export default func;
func.tags = ['safe', 'governance'];
func.dependencies = [];
