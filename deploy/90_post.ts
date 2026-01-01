import { HardhatRuntimeEnvironment } from 'hardhat/types';
import { DeployFunction } from 'hardhat-deploy/types';

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { ethers, getNamedAccounts, deployments } = hre;
  const { deployer } = await getNamedAccounts();
  const box = await ethers.getContract('UpgradeableBox', deployer);

  const v = await box.value();
  if (v.toString() !== '123') throw new Error(`Unexpected value: ${v.toString()}`);
  deployments.log(`[post] Sanity OK. value=${v.toString()}`);
};

export default func;
func.tags = ['post'];
func.dependencies = ['proxy'];
