import { HardhatRuntimeEnvironment } from 'hardhat/types';
import { DeployFunction } from 'hardhat-deploy/types';
import { getGovConfig, validateGovConfig } from './_config';
import { registerDeployment } from '../config/deployments.registry';

/**
 * Deploy TimelockController
 *
 * This script deploys OpenZeppelin's TimelockController with:
 * - 48h minimum delay (configurable)
 * - Empty proposers initially (will be granted to Governor)
 * - Open executor (address(0) = anyone can execute)
 * - Deployer as temporary admin (will be revoked later)
 */
const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { deployments, getNamedAccounts, ethers } = hre;
  const { deploy } = deployments;
  const { deployer } = await getNamedAccounts();

  const config = getGovConfig(hre);
  validateGovConfig(config, hre);

  console.log(`\n📦 Deploying TimelockController...`);
  console.log(
    `   Min Delay: ${config.timelock.minDelaySec}s (${config.timelock.minDelaySec / 3600}h)`,
  );
  console.log(`   Proposers: [] (empty, will be granted to Governor)`);
  console.log(`   Executors: [address(0)] (open - anyone can execute)`);
  console.log(`   Admin: ${deployer} (temporary, will be revoked)`);

  // TimelockController constructor:
  // constructor(uint256 minDelay, address[] memory proposers, address[] memory executors, address admin)
  const timelockDeployment = await deploy('TimelockController', {
    contract: 'TimelockController',
    from: deployer,
    args: [
      config.timelock.minDelaySec, // minDelay in seconds
      [], // proposers (empty, will be granted to Governor later)
      [ethers.ZeroAddress], // executors (address(0) = open execution)
      deployer, // admin (temporary, will be revoked)
    ],
    log: true,
  });

  if (timelockDeployment.newlyDeployed) {
    console.log(`✅ TimelockController deployed at: ${timelockDeployment.address}`);

    // Verify deployment
    const timelock = await ethers.getContractAt('TimelockController', timelockDeployment.address);
    const minDelay = await timelock.getMinDelay();
    console.log(`   Verified min delay: ${minDelay.toString()}s`);

    // Register deployment
    if (timelockDeployment.receipt) {
      await registerDeployment(hre, 'TimelockController', {
        address: timelockDeployment.address,
        txHash: timelockDeployment.receipt.hash,
        blockNumber: timelockDeployment.receipt.blockNumber,
        constructorArgs: [
          config.timelock.minDelaySec,
          [],
          [ethers.ZeroAddress],
          deployer,
        ],
        tags: ['timelock', 'governance'],
      });
    }
  } else {
    console.log(`✅ TimelockController already deployed at: ${timelockDeployment.address}`);
  }
};

export default func;
func.tags = ['timelock', 'governance'];
func.dependencies = [];
