/* eslint-disable no-console */
/**
 * Verify Base Sepolia deployed contract sources on Basescan.
 *
 * This uses Hardhat's `verify:verify` task (etherscan/sourcify plugin) and reads
 * constructor arguments from hardhat-deploy deployment artifacts.
 *
 * Run:
 *   pnpm hardhat run --network baseSepolia scripts/verify-base-sepolia-sources.ts
 */

import hre from 'hardhat';

type Failure = { name: string; address: string; error: string };
type Skip = { name: string; address?: string; reason: string };

async function main() {
  if (hre.network.name !== 'baseSepolia') {
    throw new Error(`Run with --network baseSepolia (got: ${hre.network.name})`);
  }

  const deployments = await hre.deployments.all();
  const names = Object.keys(deployments).sort();

  const failures: Failure[] = [];
  const skipped: Skip[] = [];

  for (const name of names) {
    // Skip non-deployment folders or accidental JSON entries.
    if (name === 'reports' || name === 'solcInputs' || name === 'version-report') continue;

    const dep: any = (deployments as any)[name];
    const address: string | undefined = dep?.address;
    if (!address) {
      skipped.push({ name, reason: 'missing address in deployment artifact' });
      continue;
    }

    const code = await hre.ethers.provider.getCode(address);
    if (!code || code === '0x') {
      skipped.push({ name, address, reason: 'EOA / no runtime code' });
      continue;
    }

    const args: any[] = Array.isArray(dep?.args) ? dep.args : [];

    process.stdout.write(`Verifying ${name} (${address})... `);
    try {
      await hre.run('verify:verify', {
        address,
        constructorArguments: args
      });
      process.stdout.write('OK\n');
    } catch (e: any) {
      process.stdout.write('FAILED\n');
      const msg = typeof e?.message === 'string' ? e.message : String(e);
      failures.push({ name, address, error: msg });
    }
  }

  console.log(`\n## Verification summary (baseSepolia)`);
  console.log(`- **failed**: ${failures.length}`);
  console.log(`- **skipped**: ${skipped.length}`);

  if (failures.length) {
    console.log(`\n### Unverified (verification failed)`);
    for (const f of failures) {
      const firstLine = f.error.split('\n')[0] || f.error;
      console.log(`- **${f.name}**: \`${f.address}\``);
      console.log(`  - error: ${firstLine}`);
    }
  } else {
    console.log(`\n### Unverified (verification failed)`);
    console.log(`- none`);
  }

  if (skipped.length) {
    console.log(`\n### Skipped`);
    for (const s of skipped) {
      console.log(`- **${s.name}**${s.address ? `: \`${s.address}\`` : ''} — ${s.reason}`);
    }
  }

  if (failures.length) process.exitCode = 1;
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});

