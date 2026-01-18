import { HardhatRuntimeEnvironment } from 'hardhat/types';
import { DeployFunction } from 'hardhat-deploy/types';
import { getGovConfig, validateGovConfig } from './_config';
import { registerDeployment } from '../config/deployments.registry';

/**
 * Deploy GovGovernor
 *
 * This script deploys the GovGovernor contract with all extensions:
 * - GovernorSettings: voting delay, period, threshold
 * - GovernorCountingSimple: simple vote counting
 * - GovernorVotes: token-weighted voting
 * - GovernorVotesQuorumFraction: quorum based on token supply
 * - GovernorTimelockControl: execution via TimelockController
 */
const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { deployments, getNamedAccounts, ethers } = hre;
  const { deploy, get } = deployments;
  const { deployer } = await getNamedAccounts();

  const config = getGovConfig(hre);
  validateGovConfig(config, hre);

  // Get deployed contracts
  const tokenDeployment = await get('SewToken');
  const timelockDeployment = await get('TimelockController');

  const token = await ethers.getContractAt('SewToken', tokenDeployment.address);

  console.log(`\n📦 Deploying GovGovernor...`);
  console.log(`   Name: Sew Protocol DAO`);
  console.log(`   Token: ${tokenDeployment.address}`);
  console.log(`   Timelock: ${timelockDeployment.address}`);
  console.log(`   Voting Delay: ${config.governor.votingDelayBlocks} blocks`);
  console.log(`   Voting Period: ${config.governor.votingPeriodBlocks} blocks`);
  const thresholdFormatted = (
    BigInt(config.governor.proposalThreshold) / BigInt(10 ** 18)
  ).toString();
  const quorumFormatted = (
    BigInt(config.governor.absoluteQuorum) / BigInt(10 ** 18)
  ).toString();
  console.log(`   Proposal Threshold: ${thresholdFormatted} tokens`);
  console.log(`   Absolute Quorum: ${quorumFormatted} tokens`);
  
  // Get initial non-circulating addresses from config (e.g., vesting contracts, locked tokens)
  // These are tracked for transparency/APIs (CoinGecko, etc.) but NOT used for quorum calculation
  const initialNonCirculatingAddresses: string[] = config.governor.initialNonCirculatingAddresses || [];
  console.log(`   Initial Non-Circulating Addresses: ${initialNonCirculatingAddresses.length} (for transparency/APIs)`);

  const governorDeployment = await deploy('GovGovernor', {
    contract: 'GovGovernor',
    from: deployer,
    args: [
      tokenDeployment.address, // token
      timelockDeployment.address, // timelock (address - will be cast to TimelockController in Solidity)
      config.governor.votingDelayBlocks, // votingDelay
      config.governor.votingPeriodBlocks, // votingPeriod
      config.governor.proposalThreshold, // proposalThreshold
      config.governor.absoluteQuorum, // absoluteQuorumTokens (e.g., 4M tokens)
      initialNonCirculatingAddresses, // initialNonCirculatingAddresses (for transparency/APIs)
    ],
    log: true,
  });

  if (governorDeployment.newlyDeployed) {
    console.log(`✅ GovGovernor deployed at: ${governorDeployment.address}`);

    // Wait for transaction confirmation before verifying
    if (governorDeployment.receipt) {
      await governorDeployment.receipt.wait();
    }

    // Verify deployment (with retry for timing issues)
    const governor = await ethers.getContractAt('GovGovernor', governorDeployment.address);
    let votingDelay, votingPeriod, proposalThreshold, timelockAddress, absoluteQuorum;
    let retries = 3;
    
    while (retries > 0) {
      try {
        votingDelay = await governor.votingDelay();
        votingPeriod = await governor.votingPeriod();
        proposalThreshold = await governor.proposalThreshold();
        timelockAddress = await governor.timelock();
        absoluteQuorum = await governor.absoluteQuorum();
        break;
      } catch (error: any) {
        retries--;
        if (retries === 0) {
          console.log(`   ⚠️  Could not verify governor configuration (this is non-critical): ${error.message}`);
          console.log(`   ✅ Deployment succeeded at: ${governorDeployment.address}`);
          // Still register deployment even if verification fails
          if (governorDeployment.receipt) {
            await registerDeployment(hre, 'GovGovernor', {
              address: governorDeployment.address,
              txHash: governorDeployment.receipt.hash,
              blockNumber: governorDeployment.receipt.blockNumber,
              constructorArgs: [
                tokenDeployment.address,
                timelockDeployment.address,
                config.governor.votingDelayBlocks,
                config.governor.votingPeriodBlocks,
                config.governor.proposalThreshold,
                config.governor.absoluteQuorum,
                initialNonCirculatingAddresses,
              ],
              tags: ['governor', 'governance'],
            });
          }
          return; // Exit gracefully if verification fails
        }
        // Wait a bit before retry
        await new Promise((resolve) => setTimeout(resolve, 2000));
      }
    }

    if (votingDelay !== undefined) {
      console.log(`\n📊 Governor Configuration:`);
      console.log(`   Voting Delay: ${votingDelay.toString()} blocks`);
      console.log(`   Voting Period: ${votingPeriod.toString()} blocks`);
      const thresholdFormatted = (proposalThreshold / BigInt(10 ** 18)).toString();
      const quorumFormatted = (absoluteQuorum / BigInt(10 ** 18)).toString();
      console.log(`   Proposal Threshold: ${thresholdFormatted} tokens`);
      console.log(`   Absolute Quorum: ${quorumFormatted} tokens`);
      console.log(`   Timelock: ${timelockAddress}`);

      // Note: Quorum is an absolute amount (e.g., 4M tokens), not percentage-based
      // Non-circulating addresses are tracked for transparency/APIs but NOT used for quorum calculation
    }

    // Register deployment
    if (governorDeployment.receipt) {
      await registerDeployment(hre, 'GovGovernor', {
        address: governorDeployment.address,
        txHash: governorDeployment.receipt.hash,
        blockNumber: governorDeployment.receipt.blockNumber,
              constructorArgs: [
                tokenDeployment.address,
                timelockDeployment.address,
                config.governor.votingDelayBlocks,
                config.governor.votingPeriodBlocks,
                config.governor.proposalThreshold,
                config.governor.absoluteQuorum,
                initialNonCirculatingAddresses,
              ],
        tags: ['governor', 'governance'],
      });
    }
  } else {
    console.log(`✅ GovGovernor already deployed at: ${governorDeployment.address}`);
  }
};

export default func;
func.tags = ['governor', 'governance'];
func.dependencies = ['token', 'timelock'];
