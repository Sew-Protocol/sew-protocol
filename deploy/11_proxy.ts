import { HardhatRuntimeEnvironment } from 'hardhat/types';
import { DeployFunction } from 'hardhat-deploy/types';

function proxyKind() {
  const k = (process.env.PROXY_KIND || 'transparent').toLowerCase();
  if (k !== 'transparent' && k !== 'uups') throw new Error('PROXY_KIND must be transparent|uups');
  return k;
}

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { deployments, getNamedAccounts, ethers } = hre;
  const { deploy } = deployments;
  const { deployer } = await getNamedAccounts();

  const kind = proxyKind();
  const proxyContract = kind === 'transparent' ? 'OpenZeppelinTransparentProxy' : 'ERC1967Proxy';

  await deploy('UpgradeableBox', {
    from: deployer,
    contract: 'UpgradeableBox',
    log: true,
    proxy: {
      proxyContract,
      execute: { methodName: 'initialize', args: [deployer, 123] },
    },
  });

  const box = await ethers.getContract('UpgradeableBox', deployer);
  console.log(`[deploy] UpgradeableBox via ${kind} proxy at ${await box.getAddress()}`);
};

export default func;
func.tags = ['proxy'];
func.dependencies = ['impl'];
