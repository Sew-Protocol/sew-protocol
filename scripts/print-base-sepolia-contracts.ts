/**
 * Print a grouped Base Sepolia contracts table (markdown).
 *
 * Usage:
 *   pnpm hardhat run --network baseSepolia scripts/print-base-sepolia-contracts.ts
 */

import hre from 'hardhat';

type Row = {
  name: string;
  description: string;
  address: string;
  link: string;
  kind: 'contract' | 'eoa';
};

function basescanAddressLink(address: string): string {
  return `https://sepolia.basescan.org/address/${address}`;
}

async function rowForDeployment(
  name: string,
  description: string,
  address: string,
): Promise<Row> {
  const code = await hre.ethers.provider.getCode(address);
  const kind: Row['kind'] = code && code !== '0x' ? 'contract' : 'eoa';
  return {
    name,
    description,
    address,
    link: basescanAddressLink(address),
    kind,
  };
}

function printGroup(title: string, rows: Row[]) {
  if (rows.length === 0) return;
  console.log(`\n### ${title}\n`);
  console.log(`| Contract | Description | Address |`);
  console.log(`|---|---|---|`);
  for (const r of rows) {
    const displayName = r.kind === 'eoa' ? `${r.name} (EOA)` : r.name;
    const linkedAddress = `[\`${r.address}\`](${r.link})`;
    console.log(
      `| \`${displayName}\` | ${r.description} | ${linkedAddress} |`,
    );
  }
}

async function main() {
  if (hre.network.name !== 'baseSepolia') {
    throw new Error(`Run with --network baseSepolia (got: ${hre.network.name})`);
  }

  const deployments = await hre.deployments.all();

  const desc: Record<string, string> = {
    SewToken: 'Governance token used for voting',
    TimelockController: 'Governance timelock (executes queued proposals)',
    GovGovernor: 'On-chain Governor (absolute quorum)',
    Safe_Multisig: 'Safe multisig (testnet; may be same as guardian)',
    GuardianSafe: 'Guardian multisig (testnet; may be same as governance safe)',

    YieldOps: 'Yield ops router (yield deposit/withdraw orchestration)',
    DisputeOps: 'Dispute ops router (dispute flow orchestration)',
    SettlementOps: 'Settlement ops router (release/cancel/settlement orchestration)',
    CreateOps: 'Create ops router (escrow creation orchestration)',
    BondCollector: 'Bond/fee collector helper (as configured)',

    ModuleManagementContract: 'Slow-lane module default management',
    EscrowAdminContract: 'Slow-lane admin helper (holds minimal admin role)',

    EscrowVault: 'Core escrow contract (multi-token)',
    EscrowableERC20: 'Optional escrow-enabled ERC20 (single-token escrow)',

    DefaultResolutionModule: 'IEO/initial resolution module (single trusted resolver)',
    DefaultReleaseStrategy: 'Default release strategy module (if deployed)',
    AaveYieldGenerationModule: 'Aave yield generation module (optional)',
    DefaultYieldDistributionModule: 'Default yield distribution module (optional)',
  };

  const groups: Array<{ title: string; names: string[] }> = [
    {
      title: 'Governance infrastructure',
      names: ['SewToken', 'TimelockController', 'GovGovernor'],
    },
    {
      title: 'Testnet safes / operators',
      names: ['Safe_Multisig', 'GuardianSafe'],
    },
    {
      title: 'Ops contracts',
      names: ['CreateOps', 'SettlementOps', 'DisputeOps', 'YieldOps', 'BondCollector'],
    },
    {
      title: 'Core escrow',
      names: ['EscrowVault', 'EscrowableERC20'],
    },
    {
      title: 'Admin & module management',
      names: ['EscrowAdminContract', 'ModuleManagementContract'],
    },
    {
      title: 'IEO modules (optional)',
      names: [
        'DefaultResolutionModule',
        'DefaultReleaseStrategy',
        'AaveYieldGenerationModule',
        'DefaultYieldDistributionModule',
      ],
    },
  ];

  const used = new Set<string>();

  console.log(`\n## Base Sepolia deployed contracts\n`);
  console.log(`- **chainId**: 84532`);
  console.log(`- **Explorer**: \`https://sepolia.basescan.org\``);

  for (const g of groups) {
    const rows: Row[] = [];
    for (const name of g.names) {
      const dep = (deployments as any)[name] as { address: string } | undefined;
      if (!dep?.address) continue;
      used.add(name);
      rows.push(await rowForDeployment(name, desc[name] || '', dep.address));
    }
    printGroup(g.title, rows);
  }

  // Any remaining deployments not covered above.
  const remaining = Object.keys(deployments)
    .filter((n) => !used.has(n))
    .sort();

  if (remaining.length) {
    const rows: Row[] = [];
    for (const name of remaining) {
      const dep = (deployments as any)[name] as { address: string } | undefined;
      if (!dep?.address) continue;
      rows.push(await rowForDeployment(name, desc[name] || 'Deployed contract', dep.address));
    }
    printGroup('Other deployments', rows);
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});

