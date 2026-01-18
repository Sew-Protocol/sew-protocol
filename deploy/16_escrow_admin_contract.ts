import { HardhatRuntimeEnvironment } from 'hardhat/types';
import { DeployFunction } from 'hardhat-deploy/types';
import { registerDeployment } from '../config/deployments.registry';

/**
 * Deploy EscrowAdminContract
 *
 * This contract holds slow-lane pending state for escrow configuration and is intended
 * to be called by the TimelockController (ROLE_TIMELOCK).
 */
const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { deployments, getNamedAccounts } = hre;
  const { deploy } = deployments;
  const { deployer } = await getNamedAccounts();

  console.log(`\n📦 Deploying EscrowAdminContract...`);

  const deployment = await deploy('EscrowAdminContract', {
    contract: 'EscrowAdminContract',
    from: deployer,
    args: [deployer],
    log: true,
  });

  if (deployment.newlyDeployed) {
    console.log(`✅ EscrowAdminContract deployed at: ${deployment.address}`);

    if (deployment.receipt) {
      await registerDeployment(hre, 'EscrowAdminContract', {
        address: deployment.address,
        txHash: deployment.receipt.hash,
        blockNumber: deployment.receipt.blockNumber,
        constructorArgs: [deployer],
        tags: ['escrow-admin', 'governance'],
      });
    }
  } else {
    console.log(`✅ EscrowAdminContract already deployed at: ${deployment.address}`);
  }
};

export default func;
func.tags = ['escrow-admin'];

