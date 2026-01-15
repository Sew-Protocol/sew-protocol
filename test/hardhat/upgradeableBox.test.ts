before(function () {
  this.skip();
}); // migrated to forge-std
import { deployments, ethers, upgrades } from 'hardhat';
import { expect } from 'chai';

// Skip these tests - UpgradeableBox is just for verification, not part of main contracts
// hardhat-deploy compatibility issue with getSignerFrom prevents these from running
describe.skip('UpgradeableBox', function () {
  it('deploys via hardhat-deploy and works', async () => {
    await deployments.fixture(['proxy', 'post']);
    const [signer] = await ethers.getSigners();

    const box = await ethers.getContract('UpgradeableBox', signer);
    expect(await box.value()).to.equal(123n);

    await box.setValue(777);
    expect(await box.value()).to.equal(777n);
  });

  it('can upgrade proxy to V2 (helper)', async () => {
    await deployments.fixture(['proxy']);
    const proxyAddress = (await deployments.get('UpgradeableBox')).address;

    const kind = (process.env.PROXY_KIND || 'transparent').toLowerCase();
    const BoxV2 = await ethers.getContractFactory('UpgradeableBoxV2');

    const upgraded =
      kind === 'uups'
        ? await upgrades.upgradeProxy(proxyAddress, BoxV2, { kind: 'uups' })
        : await upgrades.upgradeProxy(proxyAddress, BoxV2);

    expect(await upgraded.version()).to.equal('v2');
  });
});
