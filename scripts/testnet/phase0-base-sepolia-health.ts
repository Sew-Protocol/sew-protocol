import hre from 'hardhat';
import fs from 'fs';
import path from 'path';
import { ethers } from 'ethers';

type DeploymentJson = {
  address: string;
  abi?: any[];
};

type CheckResult = { ok: boolean; name: string; detail?: string };

function requireEnv(name: string): string {
  const v = process.env[name];
  if (!v || v.trim().length === 0) throw new Error(`Missing env var: ${name}`);
  return v.trim();
}

function optionalIntEnv(name: string): number | undefined {
  const v = process.env[name];
  if (!v || v.trim().length === 0) return undefined;
  const n = Number(v);
  if (!Number.isFinite(n) || n <= 0) throw new Error(`Invalid ${name}: ${v}`);
  return Math.floor(n);
}

function eqAddr(a: string, b: string): boolean {
  return a.toLowerCase() === b.toLowerCase();
}

async function forkBaseSepoliaIfHardhat(): Promise<void> {
  if (hre.network.name !== 'hardhat') return;

  const jsonRpcUrl = process.env.FORK_URL?.trim() || process.env.RPC_BASE_SEPOLIA?.trim();
  if (!jsonRpcUrl) {
    throw new Error('Set FORK_URL or RPC_BASE_SEPOLIA to fork Base Sepolia');
  }

  const blockNumber = optionalIntEnv('FORK_BLOCK_NUMBER');

  try {
    await hre.network.provider.request({
      method: 'hardhat_reset',
      params: [
        {
          forking: {
            jsonRpcUrl,
            ...(blockNumber ? { blockNumber } : {}),
          },
        },
      ],
    });
  } catch (err: any) {
    const msg = err?.message || String(err);
    // Work around current Hardhat/EDR limitation when forking at a pinned block.
    // If FORK_BLOCK_NUMBER is set and triggers this failure, retry without block pinning.
    if (blockNumber && msg.includes('Storage overrides are not supported for forked blocks yet')) {
      console.warn(
        `\n⚠️  Forking at FORK_BLOCK_NUMBER=${blockNumber} is not supported by the current Hardhat backend.`,
      );
      console.warn(`   Retrying fork without block pinning (latest head).`);
      await hre.network.provider.request({
        method: 'hardhat_reset',
        params: [
          {
            forking: {
              jsonRpcUrl,
            },
          },
        ],
      });
      return;
    }
    throw err;
  }
}

function loadBaseSepoliaDeployments(): Record<string, DeploymentJson> {
  const dir = path.resolve(__dirname, '../../deployments/baseSepolia');
  const entries = fs.readdirSync(dir, { withFileTypes: true });

  const out: Record<string, DeploymentJson> = {};
  for (const ent of entries) {
    if (!ent.isFile()) continue;
    if (!ent.name.endsWith('.json')) continue;
    if (ent.name.startsWith('solcInputs')) continue;

    const name = ent.name.replace(/\.json$/, '');
    const full = path.join(dir, ent.name);
    const parsed = JSON.parse(fs.readFileSync(full, 'utf8')) as DeploymentJson;
    out[name] = parsed;
  }

  return out;
}

async function checkHasCode(name: string, addr: string): Promise<CheckResult> {
  const code = await hre.ethers.provider.getCode(addr);
  if (code === '0x') return { ok: false, name, detail: `no bytecode at ${addr}` };
  return { ok: true, name };
}

async function run() {
  console.log(`\n🧪 Phase 0 — Base Sepolia deployment health check (fork)`);
  console.log(`- network: ${hre.network.name}`);

  await forkBaseSepoliaIfHardhat();

  const d = loadBaseSepoliaDeployments();
  const required = [
    'SewToken',
    'TimelockController',
    'GovGovernor',
    'Safe_Multisig',
    'GuardianSafe',
    'YieldOps',
    'DisputeOps',
    'SettlementOps',
    'CreateOps',
    'BondCollector',
    'ModuleSnapshotRegistry',
    'EscrowGovernanceTimelock',
    'EscrowVault',
  ] as const;

  for (const name of required) {
    if (!d[name]?.address) {
      throw new Error(`Missing deployment: deployments/baseSepolia/${name}.json`);
    }
  }

  const results: CheckResult[] = [];

  // 1) Bytecode presence
  console.log(`\n1) Bytecode presence`);
  for (const name of required) {
    results.push(await checkHasCode(name, d[name].address));
  }

  // 2) Core wiring checks (EscrowVault → ops + module mgmt)
  console.log(`\n2) Core wiring`);
  const escrowVault = await hre.ethers.getContractAt('EscrowVault', d.EscrowVault.address);

  const wiringPairs: Array<[string, () => Promise<string>, string]> = [
    ['EscrowVault.yieldOps', () => escrowVault.yieldOps(), d.YieldOps.address],
    ['EscrowVault.disputeOps', () => escrowVault.disputeOps(), d.DisputeOps.address],
    ['EscrowVault.createOps', () => escrowVault.createOps(), d.CreateOps.address],
    ['EscrowVault.settlementOps', () => escrowVault.settlementOps(), d.SettlementOps.address],
    ['EscrowVault.bondCollector', () => escrowVault.bondCollector(), d.BondCollector.address],
    ['EscrowVault.moduleManagement', () => escrowVault.moduleManagement(), d.ModuleSnapshotRegistry.address],
  ];

  for (const [label, getter, expected] of wiringPairs) {
    const actual = await getter();
    results.push({
      ok: eqAddr(actual, expected),
      name: label,
      detail: `expected=${expected} actual=${actual}`,
    });
  }

  const feeAddr = await escrowVault.escrowFeeAddress();
  results.push({
    ok: feeAddr !== ethers.ZeroAddress,
    name: 'EscrowVault.escrowFeeAddress != 0',
    detail: `actual=${feeAddr}`,
  });

  // 3) Ops registration: ROLE_ESCROW_CONTRACT granted to EscrowVault
  console.log(`\n3) Ops registration (ROLE_ESCROW_CONTRACT)`);
  const ROLE_ESCROW_CONTRACT = hre.ethers.keccak256(hre.ethers.toUtf8Bytes('ROLE_ESCROW_CONTRACT'));

  const accessControlAbi = [
    'function hasRole(bytes32 role, address account) view returns (bool)',
    'function DEFAULT_ADMIN_ROLE() view returns (bytes32)',
  ];

  for (const name of ['CreateOps', 'SettlementOps', 'DisputeOps', 'YieldOps', 'BondCollector'] as const) {
    const c = await hre.ethers.getContractAt(accessControlAbi, d[name].address);
    const ok = await c.hasRole(ROLE_ESCROW_CONTRACT, d.EscrowVault.address);
    results.push({
      ok,
      name: `${name}.hasRole(ROLE_ESCROW_CONTRACT, EscrowVault)`,
      detail: `escrow=${d.EscrowVault.address}`,
    });
  }

  // 4) EscrowGovernanceTimelock must be authorized on EscrowVault (ROLE_ADMIN_CONTRACT)
  console.log(`\n4) Slow-lane admin wiring (EscrowGovernanceTimelock)`);
  const ROLE_ADMIN_CONTRACT = await escrowVault.ROLE_ADMIN_CONTRACT();
  const adminOk = await escrowVault.hasRole(ROLE_ADMIN_CONTRACT, d.EscrowGovernanceTimelock.address);
  results.push({
    ok: adminOk,
    name: 'EscrowVault.hasRole(ROLE_ADMIN_CONTRACT, EscrowGovernanceTimelock)',
    detail: `admin=${d.EscrowGovernanceTimelock.address}`,
  });

  // 5) Timelock wiring (minimum): Governor proposer/canceller
  console.log(`\n5) Timelock wiring (minimum)`);
  const timelock = await hre.ethers.getContractAt('TimelockController', d.TimelockController.address);
  const PROPOSER_ROLE = await timelock.PROPOSER_ROLE();
  const CANCELLER_ROLE = await timelock.CANCELLER_ROLE();
  const governorIsProposer = await timelock.hasRole(PROPOSER_ROLE, d.GovGovernor.address);
  const governorIsCanceller = await timelock.hasRole(CANCELLER_ROLE, d.GovGovernor.address);
  results.push({
    ok: governorIsProposer,
    name: 'TimelockController: GovGovernor has PROPOSER_ROLE',
    detail: `governor=${d.GovGovernor.address}`,
  });
  results.push({
    ok: governorIsCanceller,
    name: 'TimelockController: GovGovernor has CANCELLER_ROLE',
    detail: `governor=${d.GovGovernor.address}`,
  });

  // 6) Minimal E2E on fork (no external keys)
  console.log(`\n6) Minimal E2E on fork (ERC20Mock)`);
  const [buyer, seller, resolver] = await hre.ethers.getSigners();
  const buyerAddr = await buyer.getAddress();
  const sellerAddr = await seller.getAddress();
  const resolverAddr = await resolver.getAddress();

  const tokenFactory = await hre.ethers.getContractFactory('ERC20Mock', buyer);
  const initialSupply = hre.ethers.parseUnits('1000000', 18);
  const token = await tokenFactory.deploy('Phase0 Mock Token', 'P0', buyerAddr, initialSupply);
  await token.waitForDeployment();
  const tokenAddr = await token.getAddress();

  const amount = hre.ethers.parseUnits('100', 18);
  const settings = {
    customResolver: resolverAddr,
    yieldPreset: 0, // OFF
    autoReleaseTime: 0n,
    autoCancelTime: 0n,
  };

  // create → release
  await (await token.connect(buyer).approve(d.EscrowVault.address, amount)).wait();
  const sellerBal0 = await token.balanceOf(sellerAddr);
  const createTx1 = await escrowVault.connect(buyer).createEscrow(tokenAddr, sellerAddr, amount, settings);
  const rcpt1 = await createTx1.wait();
  const created1 = rcpt1!.logs
    .map((l) => {
      try {
        return escrowVault.interface.parseLog(l as any);
      } catch {
        return null;
      }
    })
    .find((p) => p?.name === 'EscrowCreated');
  if (!created1) throw new Error('E2E: missing EscrowCreated (release flow)');
  const workflowId1 = created1.args.workflowId as bigint;
  const amountAfterFee1 = created1.args.amountAfterFee as bigint;
  await (await escrowVault.connect(buyer).releaseEscrowTransfer(workflowId1)).wait();
  const sellerBal1 = await token.balanceOf(sellerAddr);
  results.push({
    ok: sellerBal1 - sellerBal0 === amountAfterFee1,
    name: 'E2E: create → release transfers amountAfterFee to seller',
    detail: `delta=${(sellerBal1 - sellerBal0).toString()} expected=${amountAfterFee1.toString()}`,
  });

  // create → cancel (2-party) → refund
  await (await token.connect(buyer).approve(d.EscrowVault.address, amount)).wait();
  const buyerBal0 = await token.balanceOf(buyerAddr);
  const createTx2 = await escrowVault.connect(buyer).createEscrow(tokenAddr, sellerAddr, amount, settings);
  const rcpt2 = await createTx2.wait();
  const created2 = rcpt2!.logs
    .map((l) => {
      try {
        return escrowVault.interface.parseLog(l as any);
      } catch {
        return null;
      }
    })
    .find((p) => p?.name === 'EscrowCreated');
  if (!created2) throw new Error('E2E: missing EscrowCreated (cancel flow)');
  const workflowId2 = created2.args.workflowId as bigint;
  const amountAfterFee2 = created2.args.amountAfterFee as bigint;
  await (await escrowVault.connect(seller).recipientCancel(workflowId2)).wait();
  await (await escrowVault.connect(buyer).senderCancel(workflowId2)).wait();
  const buyerBal1 = await token.balanceOf(buyerAddr);
  results.push({
    ok: buyerBal1 - buyerBal0 === amountAfterFee2,
    name: 'E2E: create → 2-party cancel refunds amountAfterFee to buyer',
    detail: `delta=${(buyerBal1 - buyerBal0).toString()} expected=${amountAfterFee2.toString()}`,
  });

  // dispute → resolve → execute pending settlement after appeal window
  await (await token.connect(buyer).approve(d.EscrowVault.address, amount)).wait();
  const buyerBal2 = await token.balanceOf(buyerAddr);
  const createTx3 = await escrowVault.connect(buyer).createEscrow(tokenAddr, sellerAddr, amount, settings);
  const rcpt3 = await createTx3.wait();
  const created3 = rcpt3!.logs
    .map((l) => {
      try {
        return escrowVault.interface.parseLog(l as any);
      } catch {
        return null;
      }
    })
    .find((p) => p?.name === 'EscrowCreated');
  if (!created3) throw new Error('E2E: missing EscrowCreated (dispute flow)');
  const workflowId3 = created3.args.workflowId as bigint;
  const amountAfterFee3 = created3.args.amountAfterFee as bigint;

  await (await escrowVault.connect(buyer).raiseDispute(workflowId3)).wait();
  const resolutionHash = hre.ethers.keccak256(hre.ethers.toUtf8Bytes('phase0'));
  await (await escrowVault.connect(resolver).cancelAsDisputeResolver(workflowId3, resolutionHash)).wait();

  // advance time past appeal window (defaults to 2 days in EscrowVault constructor)
  await hre.network.provider.send('evm_increaseTime', [2 * 24 * 60 * 60 + 5]);
  await hre.network.provider.send('evm_mine');
  await (await escrowVault.executePendingSettlement(workflowId3)).wait();

  const buyerBal3 = await token.balanceOf(buyerAddr);
  results.push({
    ok: buyerBal3 - buyerBal2 === amountAfterFee3,
    name: 'E2E: dispute → resolver cancel → executePendingSettlement refunds buyer',
    detail: `delta=${(buyerBal3 - buyerBal2).toString()} expected=${amountAfterFee3.toString()}`,
  });

  // Summary
  const fails = results.filter((r) => !r.ok);
  const passes = results.length - fails.length;

  console.log(`\n📊 Phase 0 summary`);
  console.log(`- ✅ pass: ${passes}`);
  console.log(`- ❌ fail: ${fails.length}`);
  for (const f of fails) {
    console.log(`  - ❌ ${f.name}${f.detail ? ` (${f.detail})` : ''}`);
  }

  if (fails.length > 0) {
    process.exitCode = 1;
  } else {
    console.log(`\n✅ Phase 0 health check succeeded.`);
  }
}

run().catch((err) => {
  console.error(`\n❌ Phase 0 failed:\n${err?.stack || err?.message || err}`);
  process.exitCode = 1;
});

