import { HardhatRuntimeEnvironment } from 'hardhat/types';
import { DeployFunction } from 'hardhat-deploy/types';
import { registerDeployment } from '../config/deployments.registry';

/**
 * Deploy EscrowGovernanceTimelock
 *
 * This contract holds slow-lane pending state for escrow configuration and is intended
 * to be called by the TimelockController (ROLE_TIMELOCK).
 */
const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { deployments, getNamedAccounts } = hre;
  const { deploy } = deployments;
  const { deployer } = await getNamedAccounts();

  console.log(`\n📦 Deploying EscrowGovernanceTimelock...`);

  const deployment = await deploy('EscrowGovernanceTimelock', {
    contract: 'EscrowGovernanceTimelock',
    from: deployer,
    args: [deployer],
    log: true,
  });

  if (deployment.newlyDeployed) {
    console.log(`✅ EscrowGovernanceTimelock deployed at: ${deployment.address}`);

    if (deployment.receipt) {
      await registerDeployment(hre, 'EscrowGovernanceTimelock', {
        address: deployment.address,
        txHash: deployment.receipt.hash,
        blockNumber: deployment.receipt.blockNumber,
        constructorArgs: [deployer],
        tags: ['escrow-admin', 'governance'],
      });
    }
  } else {
    console.log(`✅ EscrowGovernanceTimelock already deployed at: ${deployment.address}`);
  }
};

export default func;
func.tags = ['escrow-admin'];

