import { run, network } from 'hardhat';
import { requireConfirmForMainnetLike } from '../hardhat.config';

async function main() {
  requireConfirmForMainnetLike(network.name);

  const addr = process.env.ADDR_UPGRADEABLE_BOX;
  if (!addr) throw new Error('Missing ADDR_UPGRADEABLE_BOX env var');

  await run('verify:verify', {
    address: addr,
    constructorArguments: [],
  });

  console.log('Verified contract at', addr, 'on', network.name);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
