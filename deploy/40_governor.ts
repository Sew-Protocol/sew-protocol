import { HardhatRuntimeEnvironment } from 'hardhat/types';
import { DeployFunction } from 'hardhat-deploy/types';
import { getGovConfig, validateGovConfig } from './_config';

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
  const timelock = await ethers.getContractAt('TimelockController', timelockDeployment.address);

  console.log(`\n📦 Deploying GovGovernor...`);
  console.log(`   Name: Sew Protocol DAO`);
  console.log(`   Token: ${tokenDeployment.address}`);
  console.log(`   Timelock: ${timelockDeployment.address}`);
  console.log(`   Voting Delay: ${config.governor.votingDelayBlocks} blocks`);
  console.log(`   Voting Period: ${config.governor.votingPeriodBlocks} blocks`);
  const thresholdFormatted = (BigInt(config.governor.proposalThreshold) / BigInt(10 ** 18)).toString();
  console.log(`   Proposal Threshold: ${thresholdFormatted} tokens`);
  console.log(`   Quorum: ${config.governor.quorumBps / 100}% (${config.governor.quorumBps} bps)`);

  const governorDeployment = await deploy('GovGovernor', {
    contract: 'GovGovernor',
    from: deployer,
    args: [
      tokenDeployment.address, // token
      timelock, // timelock (contract instance, not address)
      config.governor.votingDelayBlocks, // votingDelay
      config.governor.votingPeriodBlocks, // votingPeriod
      config.governor.proposalThreshold, // proposalThreshold
      config.governor.quorumBps, // quorumBps
    ],
    log: true,
  });

  if (governorDeployment.newlyDeployed) {
    console.log(`✅ GovGovernor deployed at: ${governorDeployment.address}`);
    
    // Verify deployment
    const governor = await ethers.getContractAt('GovGovernor', governorDeployment.address);
    const votingDelay = await governor.votingDelay();
    const votingPeriod = await governor.votingPeriod();
    const proposalThreshold = await governor.proposalThreshold();
    const quorum = await governor.quorum(await ethers.provider.getBlockNumber());
    const timelockAddress = await governor.timelock();
    
    console.log(`\n📊 Governor Configuration:`);
    console.log(`   Voting Delay: ${votingDelay.toString()} blocks`);
    console.log(`   Voting Period: ${votingPeriod.toString()} blocks`);
    const thresholdFormatted = (proposalThreshold / BigInt(10 ** 18)).toString();
    const quorumFormatted = (quorum / BigInt(10 ** 18)).toString();
    console.log(`   Proposal Threshold: ${thresholdFormatted} tokens`);
    console.log(`   Quorum: ${quorumFormatted} tokens`);
    console.log(`   Timelock: ${timelockAddress}`);
  } else {
    console.log(`✅ GovGovernor already deployed at: ${governorDeployment.address}`);
  }
};

export default func;
func.tags = ['governor', 'governance'];
func.dependencies = ['token', 'timelock'];

