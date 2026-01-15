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

  console.log(`\n📦 Deploying GovGovernor...`);
  console.log(`   Name: Sew Protocol DAO`);
  console.log(`   Token: ${tokenDeployment.address}`);
  console.log(`   Timelock: ${timelockDeployment.address}`);
  console.log(`   Voting Delay: ${config.governor.votingDelayBlocks} blocks`);
  console.log(`   Voting Period: ${config.governor.votingPeriodBlocks} blocks`);
  const thresholdFormatted = (
    BigInt(config.governor.proposalThreshold) / BigInt(10 ** 18)
  ).toString();
  console.log(`   Proposal Threshold: ${thresholdFormatted} tokens`);
  console.log(`   Quorum: ${config.governor.quorumBps / 100}% (${config.governor.quorumBps} bps)`);

  const governorDeployment = await deploy('GovGovernor', {
    contract: 'GovGovernor',
    from: deployer,
    args: [
      tokenDeployment.address, // token
      timelockDeployment.address, // timelock (address - will be cast to TimelockController in Solidity)
      config.governor.votingDelayBlocks, // votingDelay
      config.governor.votingPeriodBlocks, // votingPeriod
      config.governor.proposalThreshold, // proposalThreshold
      config.governor.quorumBps / 100, // quorumNumerator (convert from basis points to percentage: 400 bps = 4%)
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
    const timelockAddress = await governor.timelock();
    const quorumNumerator = await governor.quorumNumerator();

    console.log(`\n📊 Governor Configuration:`);
    console.log(`   Voting Delay: ${votingDelay.toString()} blocks`);
    console.log(`   Voting Period: ${votingPeriod.toString()} blocks`);
    const thresholdFormatted = (proposalThreshold / BigInt(10 ** 18)).toString();
    console.log(`   Proposal Threshold: ${thresholdFormatted} tokens`);
    console.log(`   Quorum Numerator: ${quorumNumerator.toString()}% (denominator: 100)`);
    console.log(`   Timelock: ${timelockAddress}`);

    // Note: quorum() requires checkpoints to exist, so we can't call it immediately after deployment
    // The quorum will be calculated as: totalSupply * quorumNumerator / 100
  } else {
    console.log(`✅ GovGovernor already deployed at: ${governorDeployment.address}`);
  }
};

export default func;
func.tags = ['governor', 'governance'];
func.dependencies = ['token', 'timelock'];
