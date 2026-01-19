import hre from 'hardhat';
import { ethers } from 'ethers';

import { basescanAddressLink, envBool, envFirst, envNumber, requireAddress, sleep, assert, retry, ESCROW_STATE } from './_journeyHelpers';

type EscrowSettings = {
  customResolver: string;
  yieldPreset: number; // YieldPreset enum (0=OFF, 1=TO_SENDER)
  autoReleaseTime: bigint;
  autoCancelTime: bigint;
};

async function main() {
  const { deployments } = hre;
  const provider = hre.ethers.provider;

  const escrowVaultAddr = (await deployments.get('EscrowVault')).address;
  const sewTokenAddr = (await deployments.get('SewToken')).address;

  const tokenAddr = requireAddress('ESCROW_TOKEN', process.env.TEST_ESCROW_TOKEN || process.env.ESCROW_TOKEN || sewTokenAddr);
  const amountHuman = process.env.TEST_ESCROW_AMOUNT || process.env.ESCROW_AMOUNT || '100';

  const RUN_NEGATIVE_TXS = envBool('TEST_RUN_NEGATIVE_TXS', envBool('RUN_NEGATIVE_TXS', false));
  const INCLUDE_DEFAULT_RESOLVER = envBool('TEST_INCLUDE_DEFAULT_RESOLVER', envBool('INCLUDE_DEFAULT_RESOLVER', false));
  const AUTO_SCALE_AMOUNT = envBool('TEST_AUTO_SCALE_AMOUNT', envBool('AUTO_SCALE_AMOUNT', false));
  const POLL_SECONDS = envNumber('TEST_POLL_SECONDS', envNumber('POLL_SECONDS', 2));

  const buyerPk = envFirst('TEST_BUYER_PRIVATE_KEY', 'BUYER_PRIVATE_KEY');
  const sellerPk = envFirst('TEST_SELLER_PRIVATE_KEY', 'SELLER_PRIVATE_KEY');
  const resolverPk = envFirst('TEST_RESOLVER_PRIVATE_KEY', 'RESOLVER_PRIVATE_KEY');
  assert(buyerPk, 'Missing env var: TEST_BUYER_PRIVATE_KEY (or BUYER_PRIVATE_KEY)');
  assert(sellerPk, 'Missing env var: TEST_SELLER_PRIVATE_KEY (or SELLER_PRIVATE_KEY)');
  assert(resolverPk, 'Missing env var: TEST_RESOLVER_PRIVATE_KEY (or RESOLVER_PRIVATE_KEY)');

  const buyer = new ethers.Wallet(buyerPk, provider);
  const seller = new ethers.Wallet(sellerPk, provider);
  const resolverOwner = new ethers.Wallet(resolverPk, provider);

  const buyerAddr = await buyer.getAddress();
  const sellerAddr = await seller.getAddress();
  const resolverOwnerAddr = await resolverOwner.getAddress();

  const resolverContractOverride = envFirst('TEST_CUSTOM_RESOLVER_CONTRACT', 'CUSTOM_RESOLVER_CONTRACT');

  console.log(`\n🧪 Phase 1 CreateOps parameter matrix (Base Sepolia)`);
  console.log(`- EscrowVault: ${escrowVaultAddr}`);
  console.log(`  - ${basescanAddressLink(escrowVaultAddr)}`);
  console.log(`- Token: ${tokenAddr}`);
  console.log(`  - ${basescanAddressLink(tokenAddr)}`);
  console.log(`- Buyer:  ${buyerAddr}`);
  console.log(`- Seller: ${sellerAddr}`);
  console.log(`- Resolver owner EOA: ${resolverOwnerAddr}`);
  console.log(`- RUN_NEGATIVE_TXS=${RUN_NEGATIVE_TXS}`);
  console.log(`- INCLUDE_DEFAULT_RESOLVER=${INCLUDE_DEFAULT_RESOLVER}`);

  const token = await hre.ethers.getContractAt(
    [
      'function name() view returns (string)',
      'function symbol() view returns (string)',
      'function decimals() view returns (uint8)',
      'function balanceOf(address) view returns (uint256)',
      'function allowance(address,address) view returns (uint256)',
      'function approve(address spender, uint256 amount) returns (bool)',
    ],
    tokenAddr
  );
  const tokenAny: any = token;

  const tokenName = await tokenAny.name().catch(() => '');
  const tokenSymbol = await tokenAny.symbol().catch(() => '');
  const tokenDecimals = Number(await tokenAny.decimals());
  const amount = ethers.parseUnits(amountHuman, tokenDecimals);

  console.log(`Token: ${tokenName} (${tokenSymbol}), decimals=${tokenDecimals}`);
  console.log(`Amount: ${amountHuman} (${amount.toString()} base units)`);
  console.log(`AUTO_SCALE_AMOUNT=${AUTO_SCALE_AMOUNT} (if buyer balance < amount, downscale to available)`);

  const escrow: any = await hre.ethers.getContractAt('EscrowVault', escrowVaultAddr);
  const escrowIface = escrow.interface;
  const erc20TransferIface = new ethers.Interface(['event Transfer(address indexed from, address indexed to, uint256 value)']);

  async function parseEscrowEvent(rcpt: any, name: string): Promise<any | null> {
    const parsed = (rcpt.logs as any[])
      .filter((l: any) => (l.address || '').toLowerCase() === escrowVaultAddr.toLowerCase())
      .map((l: any) => {
        try {
          return escrowIface.parseLog(l);
        } catch {
          return null;
        }
      })
      .find((p: any) => p?.name === name);
    return parsed || null;
  }

  function sumVaultTo(rcpt: any, to: string): bigint {
    let sum = 0n;
    const logs: any[] = rcpt.logs || [];
    for (const l of logs) {
      if ((l.address || '').toLowerCase() !== tokenAddr.toLowerCase()) continue;
      let p: any = null;
      try {
        p = erc20TransferIface.parseLog(l);
      } catch {
        continue;
      }
      const from = String(p.args.from).toLowerCase();
      const dest = String(p.args.to).toLowerCase();
      if (from === escrowVaultAddr.toLowerCase() && dest === to.toLowerCase()) {
        sum += BigInt(p.args.value.toString());
      }
    }
    return sum;
  }

  async function waitForBlockAtLeast(targetBlock: number, label: string, opts?: { timeoutMs?: number }) {
    const timeoutMs = opts?.timeoutMs ?? 60_000;
    const started = Date.now();
    let consecutive = 0;
    while (true) {
      const bn = await provider.getBlockNumber();
      if (bn >= targetBlock) consecutive++;
      else consecutive = 0;
      if (consecutive >= 2) return;
      if (Date.now() - started > timeoutMs) throw new Error(`Timed out waiting for chain to reach block ${targetBlock} (${label}). latest=${bn}`);
      await sleep(1500);
    }
  }

  async function waitForEscrowMatch(
    workflowId: bigint,
    expected: { escrowState: number },
    minBlock: number,
    label: string,
    opts?: { timeoutMs?: number }
  ) {
    const timeoutMs = opts?.timeoutMs ?? 90_000;
    const started = Date.now();
    await waitForBlockAtLeast(minBlock, `${label} (minBlock)`);
    while (true) {
      try {
        const et = await escrow.escrowTransfers(workflowId);
        const st = Number(et.escrowState);
        if (st === expected.escrowState) return;
      } catch {
        // ignore transient RPC mismatches
      }
      if (Date.now() - started > timeoutMs) {
        const et = await retry(`escrowTransfers(${workflowId.toString()}) ${label} (final read)`, async () => escrow.escrowTransfers(workflowId));
        throw new Error(`${label}: escrow did not converge. expectedState=${expected.escrowState} got=${Number(et.escrowState)}`);
      }
      await sleep(POLL_SECONDS * 1000);
    }
  }

  async function ensureDelivered(workflowId: bigint, recipient: ethers.Signer, recipientAddr: string, expectedAmount: bigint, rcptMaybe?: any) {
    if (rcptMaybe) {
      const pushed = sumVaultTo(rcptMaybe, recipientAddr);
      if (pushed !== 0n) {
        assert(pushed === expectedAmount, `push transfer amount mismatch. expected=${expectedAmount.toString()} got=${pushed.toString()}`);
        return;
      }
    }
    const claimable: bigint = await retry(`claimableBalances(${workflowId.toString()})`, async () =>
      escrow.claimableBalances(workflowId, recipientAddr)
    );
    assert(claimable === expectedAmount, `claimable amount mismatch. expected=${expectedAmount.toString()} got=${claimable.toString()}`);
    const wdTx = await escrow.connect(recipient).withdrawEscrow(workflowId);
    console.log(`  withdraw tx: ${wdTx.hash}`);
    await wdTx.wait();
  }

  // Approve tokens for createEscrow
  const allowance0: bigint = await tokenAny.allowance(buyerAddr, escrowVaultAddr);
  if (allowance0 < amount) {
    console.log(`\n🔏 Approving EscrowVault to spend buyer tokens (max uint256)...`);
    const approveTx = await tokenAny.connect(buyer).approve(escrowVaultAddr, ethers.MaxUint256);
    console.log(`  tx: ${approveTx.hash}`);
    await approveTx.wait();
  }

  const buyerBal0: bigint = await tokenAny.balanceOf(buyerAddr);
  if (buyerBal0 < amount) {
    const msg =
      `Buyer has insufficient token balance for createEscrow.\n` +
      `- token=${tokenSymbol || tokenAddr}\n` +
      `- buyer=${buyerAddr}\n` +
      `- balance=${buyerBal0.toString()} base units\n` +
      `- required=${amount.toString()} base units\n` +
      `Fix: fund the buyer address with ${amountHuman} ${tokenSymbol || ''} (or lower TEST_ESCROW_AMOUNT).`;
    if (!AUTO_SCALE_AMOUNT) {
      throw new Error(msg);
    }
    console.log(`WARN: ${msg}`);
    console.log(`WARN: AUTO_SCALE_AMOUNT enabled; scenarios will use the buyer's available balance instead.`);
  }

  // Deploy / load forwarding resolver contract to satisfy customResolver contract requirement.
  let resolverContractAddr: string;
  if (resolverContractOverride) {
    resolverContractAddr = requireAddress('CUSTOM_RESOLVER_CONTRACT', resolverContractOverride);
    console.log(`- customResolver contract: ${resolverContractAddr} (override)`);
  } else {
    console.log(`\n📦 Deploying TestnetForwardingResolver (customResolver contract)...`);
    const factory = await hre.ethers.getContractFactory('TestnetForwardingResolver', buyer);
    const deployed = await factory.deploy(resolverOwnerAddr);
    console.log(`  deploy tx: ${deployed.deploymentTransaction()?.hash || '(unknown)'}`);
    const c = await deployed.waitForDeployment();
    resolverContractAddr = await c.getAddress();
    console.log(`- customResolver contract: ${resolverContractAddr}`);
  }
  console.log(`  - ${basescanAddressLink(resolverContractAddr)}`);

  // Helper: create + assert fields, then release for cleanup.
  async function createAssertAndRelease(label: string, settings: EscrowSettings) {
    console.log(`\n### ${label}`);
    const bal: bigint = await tokenAny.balanceOf(buyerAddr);
    let amt: bigint = amount;
    if (bal < amt) {
      if (!AUTO_SCALE_AMOUNT) {
        throw new Error(
          `Buyer has insufficient token balance for scenario "${label}". balance=${bal.toString()} required=${amt.toString()}`
        );
      }
      if (bal === 0n) {
        throw new Error(`Buyer has zero token balance for scenario "${label}". Fund buyer=${buyerAddr} first.`);
      }
      amt = bal;
      console.log(`  WARN: downscaling amount to buyer balance: ${amt.toString()} base units`);
    }

    const tx = await escrow.connect(buyer).createEscrow(tokenAddr, sellerAddr, amt, settings);
    console.log(`  create tx: ${tx.hash}`);
    const rcpt = await tx.wait();
    assert(rcpt, 'Missing receipt for createEscrow');
    const created = await parseEscrowEvent(rcpt, 'EscrowCreated');
    assert(created, 'Could not find EscrowCreated');
    const workflowId = created.args.workflowId as bigint;
    const amountAfterFee = created.args.amountAfterFee as bigint;
    const feeAmount = created.args.fee as bigint;
    const blockNumber = Number(rcpt.blockNumber || 0);
    console.log(`  workflowId: ${workflowId.toString()}`);
    console.log(`  amountAfterFee: ${amountAfterFee.toString()} feeAmount: ${feeAmount.toString()}`);

    // Wait for PENDING on this block.
    if (blockNumber > 0) await waitForEscrowMatch(workflowId, { escrowState: ESCROW_STATE.PENDING }, blockNumber, 'after create (wait)');

    const et = await retry(`escrowTransfers(${workflowId.toString()})`, async () => escrow.escrowTransfers(workflowId));
    assert(String(et.token).toLowerCase() === tokenAddr.toLowerCase(), 'token mismatch');
    assert(String(et.to).toLowerCase() === sellerAddr.toLowerCase(), 'recipient mismatch');
    assert(String(et.from).toLowerCase() === buyerAddr.toLowerCase(), 'sender mismatch');
    assert(BigInt(et.amountAfterFee.toString()) === amountAfterFee, 'amountAfterFee mismatch');

    // Settings mapping should match what we passed in (times are absolute timestamps).
    const s = await retry(`escrowSettings(${workflowId.toString()})`, async () => escrow.escrowSettings(workflowId));
    assert(String(s.customResolver).toLowerCase() === settings.customResolver.toLowerCase(), 'settings.customResolver mismatch');
    assert(Number(s.yieldPreset) === settings.yieldPreset, `settings.yieldPreset mismatch. expected=${settings.yieldPreset} got=${Number(s.yieldPreset)}`);
    assert(BigInt(s.autoReleaseTime.toString()) === settings.autoReleaseTime, 'settings.autoReleaseTime mismatch');
    assert(BigInt(s.autoCancelTime.toString()) === settings.autoCancelTime, 'settings.autoCancelTime mismatch');

    // Dispute resolver rules:
    // - If customResolver is set, it must become the disputeResolver.
    // - If customResolver is 0, CreateOps/module decides (assert non-zero when enabled).
    if (settings.customResolver !== ethers.ZeroAddress) {
      assert(String(et.disputeResolver).toLowerCase() === settings.customResolver.toLowerCase(), 'disputeResolver != customResolver');
    } else if (INCLUDE_DEFAULT_RESOLVER) {
      assert(String(et.disputeResolver).toLowerCase() !== ethers.ZeroAddress.toLowerCase(), 'default disputeResolver returned zero address');
    }

    // Cleanup: release so funds are not stuck.
    const relTx = await escrow.connect(buyer).releaseEscrowTransfer(workflowId);
    console.log(`  release tx: ${relTx.hash}`);
    const relRcpt = await relTx.wait();
    assert(relRcpt, 'Missing receipt for releaseEscrowTransfer');
    assert(Number(relRcpt.status || 0) === 1, 'releaseEscrowTransfer transaction reverted');

    const relBlock = Number(relRcpt.blockNumber || 0);
    if (relBlock > 0) {
      await waitForEscrowMatch(workflowId, { escrowState: ESCROW_STATE.RELEASED }, relBlock, 'after release (wait)');
    }

    const after = await retry(`escrowTransfers(${workflowId.toString()}) after release`, async () =>
      escrow.escrowTransfers(workflowId)
    );
    assert(Number(after.escrowState) === ESCROW_STATE.RELEASED, `expected RELEASED after release, got=${Number(after.escrowState)}`);

    // Delivery to seller is push-or-pull. Ensure it landed.
    await ensureDelivered(workflowId, seller, sellerAddr, amountAfterFee, relRcpt);
    console.log(`  ✅ ${label} OK`);
  }

  const now = BigInt(Math.floor(Date.now() / 1000));
  const t1h = now + 3600n;

  // Matrix entries (CreateOps + BaseEscrow settings application)
  await createAssertAndRelease('A) customResolver=forwarding, yieldPreset=OFF, no auto times', {
    customResolver: resolverContractAddr,
    yieldPreset: 0,
    autoReleaseTime: 0n,
    autoCancelTime: 0n,
  });

  await createAssertAndRelease('B) customResolver=forwarding, yieldPreset=OFF, autoReleaseTime=+1h', {
    customResolver: resolverContractAddr,
    yieldPreset: 0,
    autoReleaseTime: t1h,
    autoCancelTime: 0n,
  });

  await createAssertAndRelease('C) customResolver=forwarding, yieldPreset=OFF, autoCancelTime=+1h', {
    customResolver: resolverContractAddr,
    yieldPreset: 0,
    autoReleaseTime: 0n,
    autoCancelTime: t1h,
  });

  await createAssertAndRelease('D) customResolver=forwarding, yieldPreset=TO_SENDER, no auto times', {
    customResolver: resolverContractAddr,
    yieldPreset: 1,
    autoReleaseTime: 0n,
    autoCancelTime: 0n,
  });

  if (INCLUDE_DEFAULT_RESOLVER) {
    await createAssertAndRelease('E) customResolver=0 (default resolver path), yieldPreset=OFF, no auto times', {
      customResolver: ethers.ZeroAddress,
      yieldPreset: 0,
      autoReleaseTime: 0n,
      autoCancelTime: 0n,
    });
  }

  if (RUN_NEGATIVE_TXS) {
    console.log(`\n### Negative (expected revert): both autoReleaseTime and autoCancelTime set`);
    const badSettings: EscrowSettings = {
      customResolver: resolverContractAddr,
      yieldPreset: 0,
      autoReleaseTime: t1h,
      autoCancelTime: t1h,
    };
    await escrow
      .connect(buyer)
      .createEscrow(tokenAddr, sellerAddr, amount, badSettings)
      .then((tx: any) => tx.wait())
      .then(() => {
        throw new Error('expected createEscrow to revert, but it succeeded');
      })
      .catch(() => {
        console.log(`  ✅ reverted as expected`);
      });
  }

  console.log(`\n✅ CreateOps parameter matrix completed.`);
}

main().catch((err) => {
  console.error(`\n❌ CreateOps parameter matrix failed:\n${err?.stack || err?.message || err}`);
  process.exitCode = 1;
});

