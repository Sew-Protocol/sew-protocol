import path from 'node:path';
import { deployments } from 'hardhat';
import { addressesBundle, metaBundle, ledgerRoot, ensureDir, writeJson, snapshotAbi } from './_lib/ledger';

async function main() {
  const dir = ledgerRoot();
  ensureDir(dir);

  const meta = await metaBundle();
  writeJson(path.join(dir, 'meta.json'), meta);

  const addresses = await addressesBundle();
  writeJson(path.join(dir, 'addresses.json'), addresses);

  const abiDir = path.join(dir, 'abi');
  ensureDir(abiDir);
  await snapshotAbi('UpgradeableBox', abiDir);

  const dep = await deployments.get('UpgradeableBox');
  writeJson(path.join(dir, 'hardhat-deploy.json'), dep);

  console.log('Wrote deploy ledger:', dir);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
