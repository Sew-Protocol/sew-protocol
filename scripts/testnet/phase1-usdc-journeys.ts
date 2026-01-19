import hre from 'hardhat';
import { ethers } from 'ethers';

import {
  ESCROW_STATE,
  SENDER_STATUS,
  RECIPIENT_STATUS,
  envNumber,
  envBool,
  envFirst,
  basescanAddressLink,
  sleep,
  requireAddress,
  assert,
  retry,
} from './_journeyHelpers';

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

  // Default to Base Sepolia USDC if provided; otherwise fall back to SewToken.
  const tokenAddr = requireAddress(
    'ESCROW_TOKEN',
    process.env.TEST_ESCROW_TOKEN || process.env.ESCROW_TOKEN || sewTokenAddr
  );
  const amountHuman = process.env.TEST_ESCROW_AMOUNT || process.env.ESCROW_AMOUNT || '100';

  const WAIT_FOR_APPEAL_WINDOW = envBool('TEST_WAIT_FOR_APPEAL_WINDOW', envBool('WAIT_FOR_APPEAL_WINDOW', false));
  const POLL_SECONDS = envNumber('TEST_POLL_SECONDS', envNumber('POLL_SECONDS', 30));
  const RUN_NEGATIVE_TXS = envBool('TEST_RUN_NEGATIVE_TXS', envBool('RUN_NEGATIVE_TXS', false));
  const CANCEL_ORDER = (envFirst('TEST_CANCEL_ORDER', 'CANCEL_ORDER') || 'buyer-first').toLowerCase(); // buyer-first | seller-first | both

  const buyerPk = envFirst('TEST_BUYER_PRIVATE_KEY', 'BUYER_PRIVATE_KEY');
  const sellerPk = envFirst('TEST_SELLER_PRIVATE_KEY', 'SELLER_PRIVATE_KEY');
  const resolverPk = envFirst('TEST_RESOLVER_PRIVATE_KEY', 'RESOLVER_PRIVATE_KEY');
  assert(buyerPk, 'Missing env var: TEST_BUYER_PRIVATE_KEY (or BUYER_PRIVATE_KEY)');
  assert(sellerPk, 'Missing env var: TEST_SELLER_PRIVATE_KEY (or SELLER_PRIVATE_KEY)');
  assert(resolverPk, 'Missing env var: TEST_RESOLVER_PRIVATE_KEY (or RESOLVER_PRIVATE_KEY)');

  const buyer = new ethers.Wallet(buyerPk, provider);
  const seller = new ethers.Wallet(sellerPk, provider);
  const resolver = new ethers.Wallet(resolverPk, provider);

  const buyerAddr = await buyer.getAddress();
  const sellerAddr = await seller.getAddress();
  const resolverAddr = await resolver.getAddress();

  // customResolver must be a contract. We'll use a forwarding resolver contract whose `owner` is the resolver EOA.
  // You can provide a pre-deployed instance to avoid deploying every run.
  const resolverContractOverride = envFirst('TEST_CUSTOM_RESOLVER_CONTRACT', 'CUSTOM_RESOLVER_CONTRACT');

  console.log(`\n🧪 Phase 1 testnet journeys (Base Sepolia)`);
  console.log(`- EscrowVault: ${escrowVaultAddr}`);
  console.log(`  - ${basescanAddressLink(escrowVaultAddr)}`);
  console.log(`- Token: ${tokenAddr} ${tokenAddr.toLowerCase() === sewTokenAddr.toLowerCase() ? '(SewToken)' : ''}`);
  console.log(`  - ${basescanAddressLink(tokenAddr)}`);
  console.log(`- Buyer:    ${buyerAddr}`);
  console.log(`- Seller:   ${sellerAddr}`);
  console.log(`- Resolver EOA (owner): ${resolverAddr}`);
  console.log(`- WAIT_FOR_APPEAL_WINDOW=${WAIT_FOR_APPEAL_WINDOW} (DefaultResolutionModule implies ~2 days)`);
  console.log(`- CANCEL_ORDER=${CANCEL_ORDER} (buyer-first | seller-first | both)`);
  console.log(`- RUN_NEGATIVE_TXS=${RUN_NEGATIVE_TXS} (expected-revert testnet txs; costs gas)`);

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

  const escrow: any = await hre.ethers.getContractAt('EscrowVault', escrowVaultAddr);

  const tokenName = await tokenAny.name().catch(() => '');
  const tokenSymbol = await tokenAny.symbol().catch(() => '');
  const tokenDecimals = Number(await tokenAny.decimals());
  const amount = ethers.parseUnits(amountHuman, tokenDecimals);

  console.log(`\nToken: ${tokenName} (${tokenSymbol}), decimals=${tokenDecimals}`);
  console.log(`Amount: ${amountHuman} (${amount.toString()} base units)`);

  // Deploy / load forwarding resolver contract (for dispute scenarios).
  let resolverContractAddr: string;
  if (resolverContractOverride) {
    resolverContractAddr = requireAddress('CUSTOM_RESOLVER_CONTRACT', resolverContractOverride);
    console.log(`- customResolver contract: ${resolverContractAddr} (override)`);
    console.log(`  - ${basescanAddressLink(resolverContractAddr)}`);
  } else {
    console.log(`\n📦 Deploying TestnetForwardingResolver (customResolver contract)...`);
    const factory = await hre.ethers.getContractFactory('TestnetForwardingResolver', buyer);
    const deployed = await factory.deploy(resolverAddr);
    console.log(`  deploy tx: ${deployed.deploymentTransaction()?.hash || '(unknown)'}`);
    const c = await deployed.waitForDeployment();
    resolverContractAddr = await c.getAddress();
    console.log(`- customResolver contract: ${resolverContractAddr}`);
    console.log(`  - ${basescanAddressLink(resolverContractAddr)}`);
  }

  const forwardingResolver: any = await hre.ethers.getContractAt(
    ['function cancelEscrow(address escrow,uint256 workflowId,bytes32 resolutionHash) returns (bool)',
     'function releaseEscrow(address escrow,uint256 workflowId,bytes32 resolutionHash) returns (bool)'],
    resolverContractAddr
  );

  // Approve enough for all operations (principal + potential bond collector paths)
  const allowance0: bigint = await tokenAny.allowance(buyerAddr, escrowVaultAddr);
  if (allowance0 < amount) {
    console.log(`\n🔏 Approving EscrowVault to spend buyer tokens (max uint256)...`);
    const approveTx = await tokenAny.connect(buyer).approve(escrowVaultAddr, ethers.MaxUint256);
    console.log(`  tx: ${approveTx.hash}`);
    await approveTx.wait();
  }

  const escrowIface = escrow.interface;
  const erc20TransferIface = new ethers.Interface([
    'event Transfer(address indexed from, address indexed to, uint256 value)',
  ]);

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

  async function latestChainTimestamp(): Promise<bigint> {
    const bn = await provider.getBlockNumber();
    const b = await provider.getBlock(bn);
    assert(b, 'Failed to load latest block');
    return BigInt(b.timestamp);
  }

  async function createEscrow(to: string, settings: EscrowSettings): Promise<{
    workflowId: bigint;
    amountAfterFee: bigint;
    feeAmount: bigint;
    blockNumber: number;
  }> {
    const tx = await escrow.connect(buyer).createEscrow(tokenAddr, to, amount, settings);
    console.log(`  create tx: ${tx.hash}`);
    const rcpt = await tx.wait();
    assert(rcpt, 'Missing receipt for createEscrow');
    const created = await parseEscrowEvent(rcpt, 'EscrowCreated');
    assert(created, 'Could not find EscrowCreated');
    const result = {
      workflowId: created.args.workflowId as bigint,
      amountAfterFee: created.args.amountAfterFee as bigint,
      feeAmount: created.args.fee as bigint,
      blockNumber: Number(rcpt.blockNumber || 0),
    };
    return result;
  }

  async function waitForBlockAtLeast(targetBlock: number, label: string, opts?: { timeoutMs?: number }) {
    const timeoutMs = opts?.timeoutMs ?? 60_000;
    const started = Date.now();
    let consecutive = 0;
    while (true) {
      const bn = await provider.getBlockNumber();
      if (bn >= targetBlock) consecutive++;
      else consecutive = 0;

      // Require a couple consecutive reads to reduce the chance we're bouncing between lagging nodes.
      if (consecutive >= 2) return;
      if (Date.now() - started > timeoutMs) {
        throw new Error(`Timed out waiting for chain to reach block ${targetBlock} (${label}). latest=${bn}`);
      }
      await sleep(1500);
    }
  }

  async function waitForEscrowState(
    workflowId: bigint,
    expectedState: number,
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
        if (st === expectedState) return;
      } catch {
        // keep retrying; can hit lagging nodes or transient issues
      }
      if (Date.now() - started > timeoutMs) {
        const et = await retry(`escrowTransfers(${workflowId.toString()}) ${label} (final read)`, async () =>
          escrow.escrowTransfers(workflowId)
        );
        throw new Error(
          `${label}: escrowState did not converge. expected=${expectedState} got=${Number(et.escrowState)}`
        );
      }
      await sleep(2000);
    }
  }

  async function waitForEscrowMatch(
    workflowId: bigint,
    expected: { escrowState: number; senderStatus?: number; recipientStatus?: number },
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
        const ss = Number(et.senderStatus);
        const rs = Number(et.recipientStatus);
        if (st !== expected.escrowState) throw new Error('state mismatch');
        if (expected.senderStatus !== undefined && ss !== expected.senderStatus) throw new Error('senderStatus mismatch');
        if (expected.recipientStatus !== undefined && rs !== expected.recipientStatus) throw new Error('recipientStatus mismatch');
        return;
      } catch {
        // keep retrying; can hit lagging nodes or transient issues
      }
      if (Date.now() - started > timeoutMs) {
        const et = await retry(`escrowTransfers(${workflowId.toString()}) ${label} (final read)`, async () =>
          escrow.escrowTransfers(workflowId)
        );
        throw new Error(
          `${label}: escrow did not converge. expectedState=${expected.escrowState} got=${Number(et.escrowState)} ` +
            `(senderStatus=${Number(et.senderStatus)}, recipientStatus=${Number(et.recipientStatus)})`
        );
      }
      await sleep(2000);
    }
  }

  async function expectEscrow(
    workflowId: bigint,
    expected: { escrowState: number; senderStatus?: number; recipientStatus?: number },
    label: string
  ) {
    const et = await retry(`escrowTransfers(${workflowId.toString()}) ${label}`, async () => escrow.escrowTransfers(workflowId));
    const st = Number(et.escrowState);
    if (st !== expected.escrowState) {
      const ss = Number(et.senderStatus);
      const rs = Number(et.recipientStatus);
      throw new Error(
        `${label}: escrowState mismatch. expected=${expected.escrowState} got=${st} (senderStatus=${ss}, recipientStatus=${rs})`
      );
    }
    if (expected.senderStatus !== undefined) {
      const ss = Number(et.senderStatus);
      assert(ss === expected.senderStatus, `${label}: senderStatus mismatch. expected=${expected.senderStatus} got=${ss}`);
    }
    if (expected.recipientStatus !== undefined) {
      const rs = Number(et.recipientStatus);
      assert(rs === expected.recipientStatus, `${label}: recipientStatus mismatch. expected=${expected.recipientStatus} got=${rs}`);
    }
  }

  async function ensurePullWithdrawIfAny(workflowId: bigint, recipient: ethers.Signer, recipientAddr: string) {
    const claimable: bigint = await retry(`claimableBalances(${workflowId.toString()})`, async () =>
      escrow.claimableBalances(workflowId, recipientAddr)
    );
    if (claimable > 0n) {
      const wdTx = await escrow.connect(recipient).withdrawEscrow(workflowId);
      console.log(`  withdraw tx: ${wdTx.hash}`);
      const wdRcpt = await wdTx.wait();
      assert(wdRcpt, 'Missing receipt for withdrawEscrow');
      const pushed = sumVaultTo(wdRcpt, recipientAddr);
      // Some ERC20s may not emit standard Transfer logs; the core invariant is claimable clearing.
      if (pushed !== 0n) {
        console.log(`  withdraw delivered via push: ${pushed.toString()}`);
      }
      const after: bigint = await retry(`claimableBalances(${workflowId.toString()}) after withdraw`, async () =>
        escrow.claimableBalances(workflowId, recipientAddr)
      );
      assert(after === 0n, `claimable not cleared after withdraw (still ${after.toString()})`);
    }
  }

  async function ensureDelivered(
    workflowId: bigint,
    recipient: ethers.Signer,
    recipientAddr: string,
    expectedAmount: bigint,
    rcptMaybe?: any
  ) {
    if (rcptMaybe) {
      const pushed = sumVaultTo(rcptMaybe, recipientAddr);
      if (pushed !== 0n) {
        assert(
          pushed === expectedAmount,
          `push transfer amount mismatch. expected=${expectedAmount.toString()} got=${pushed.toString()}`
        );
        return;
      }
    }

    const claimable: bigint = await escrow.claimableBalances(workflowId, recipientAddr);
    if (claimable === 0n) {
      // Not pushed and not claimable => something unexpected (or non-standard token events).
      throw new Error(
        `No delivery observed for workflowId=${workflowId.toString()} recipient=${recipientAddr}. ` +
          `Expected either Transfer log from EscrowVault or claimableBalances > 0.`
      );
    }
    assert(
      claimable === expectedAmount,
      `claimable amount mismatch. expected=${expectedAmount.toString()} got=${claimable.toString()}`
    );
    await ensurePullWithdrawIfAny(workflowId, recipient, recipientAddr);
  }

  // ======================
  // Test 1: create -> 2-party cancel -> refund + events + state
  // ======================
  console.log(`\n### 1) createEscrow -> both cancel -> buyer refund (and events/state)`);
  async function runMutualCancel(order: 'buyer-first' | 'seller-first') {
    const settings: EscrowSettings = {
      customResolver: ethers.ZeroAddress,
      yieldPreset: 0,
      autoReleaseTime: 0n,
      autoCancelTime: 0n,
    };

    const { workflowId, amountAfterFee, feeAmount, blockNumber: createBlock } = await createEscrow(sellerAddr, settings);
    console.log(`  workflowId: ${workflowId.toString()}`);
    console.log(`  amountAfterFee: ${amountAfterFee.toString()}`);
    console.log(`  feeAmount: ${feeAmount.toString()}`);

    if (createBlock > 0) {
      await waitForEscrowMatch(
        workflowId,
        { escrowState: ESCROW_STATE.PENDING, senderStatus: SENDER_STATUS.NONE, recipientStatus: RECIPIENT_STATUS.NONE },
        createBlock,
        'after create (wait)'
      );
    }
    await expectEscrow(
      workflowId,
      { escrowState: ESCROW_STATE.PENDING, senderStatus: SENDER_STATUS.NONE, recipientStatus: RECIPIENT_STATUS.NONE },
      'after create'
    );

    if (RUN_NEGATIVE_TXS) {
      // Optional expected-revert transactions (costs gas).
      // - Seller cannot senderCancel
      // - Buyer cannot recipientCancel
      console.log(`  (negative txs) seller attempts senderCancel (should revert)`);
      await escrow.connect(seller).senderCancel(workflowId).catch(() => null);
      console.log(`  (negative txs) buyer attempts recipientCancel (should revert)`);
      await escrow.connect(buyer).recipientCancel(workflowId).catch(() => null);
    }

    let confirmRcpt: any = null;
    let confirmBlock = 0;
    if (order === 'buyer-first') {
      const buyerCancelTx = await escrow.connect(buyer).senderCancel(workflowId);
      console.log(`  buyerCancel tx: ${buyerCancelTx.hash}`);
      const buyerCancelRcpt = await buyerCancelTx.wait();
      assert(buyerCancelRcpt, 'Missing receipt for buyerCancel');
      assert(await parseEscrowEvent(buyerCancelRcpt, 'CancelRequested'), 'CancelRequested not emitted (buyer)');
      await waitForEscrowMatch(
        workflowId,
        {
          escrowState: ESCROW_STATE.PENDING,
          senderStatus: SENDER_STATUS.AGREE_TO_CANCEL,
          recipientStatus: RECIPIENT_STATUS.NONE,
        },
        Number(buyerCancelRcpt.blockNumber || 0),
        'after buyer cancel request (wait)'
      );
      await expectEscrow(
        workflowId,
        {
          escrowState: ESCROW_STATE.PENDING,
          senderStatus: SENDER_STATUS.AGREE_TO_CANCEL,
          recipientStatus: RECIPIENT_STATUS.NONE,
        },
        'after buyer cancel request'
      );

      const sellerCancelTx = await escrow.connect(seller).recipientCancel(workflowId);
      console.log(`  sellerCancel tx: ${sellerCancelTx.hash}`);
      confirmRcpt = await sellerCancelTx.wait();
      assert(confirmRcpt, 'Missing receipt for sellerCancel');
      confirmBlock = Number(confirmRcpt.blockNumber || 0);
      assert(await parseEscrowEvent(confirmRcpt, 'CancelRequested'), 'CancelRequested not emitted (seller)');
      assert(await parseEscrowEvent(confirmRcpt, 'CancelConfirmed'), 'CancelConfirmed not emitted (seller confirm)');
    } else {
      const sellerCancelTx = await escrow.connect(seller).recipientCancel(workflowId);
      console.log(`  sellerCancel tx: ${sellerCancelTx.hash}`);
      const sellerCancelRcpt = await sellerCancelTx.wait();
      assert(sellerCancelRcpt, 'Missing receipt for sellerCancel');
      assert(await parseEscrowEvent(sellerCancelRcpt, 'CancelRequested'), 'CancelRequested not emitted (seller)');
      await waitForEscrowMatch(
        workflowId,
        {
          escrowState: ESCROW_STATE.PENDING,
          senderStatus: SENDER_STATUS.NONE,
          recipientStatus: RECIPIENT_STATUS.AGREE_TO_CANCEL,
        },
        Number(sellerCancelRcpt.blockNumber || 0),
        'after seller cancel request (wait)'
      );
      await expectEscrow(
        workflowId,
        {
          escrowState: ESCROW_STATE.PENDING,
          senderStatus: SENDER_STATUS.NONE,
          recipientStatus: RECIPIENT_STATUS.AGREE_TO_CANCEL,
        },
        'after seller cancel request'
      );

      const buyerCancelTx = await escrow.connect(buyer).senderCancel(workflowId);
      console.log(`  buyerCancel tx: ${buyerCancelTx.hash}`);
      confirmRcpt = await buyerCancelTx.wait();
      assert(confirmRcpt, 'Missing receipt for buyerCancel');
      confirmBlock = Number(confirmRcpt.blockNumber || 0);
      assert(await parseEscrowEvent(confirmRcpt, 'CancelRequested'), 'CancelRequested not emitted (buyer)');
      assert(await parseEscrowEvent(confirmRcpt, 'CancelConfirmed'), 'CancelConfirmed not emitted (buyer confirm)');
    }

    // Work around RPC load-balancer lag: wait until state reads reflect the confirm tx block.
    if (confirmBlock > 0) {
      await waitForEscrowMatch(
        workflowId,
        {
          escrowState: ESCROW_STATE.REFUNDED,
          senderStatus: SENDER_STATUS.AGREE_TO_CANCEL,
          recipientStatus: RECIPIENT_STATUS.AGREE_TO_CANCEL,
        },
        confirmBlock,
        'after mutual cancel (wait)'
      );
    }

    // State: should be finalized as REFUNDED
    await expectEscrow(
      workflowId,
      {
        escrowState: ESCROW_STATE.REFUNDED,
        senderStatus: SENDER_STATUS.AGREE_TO_CANCEL,
        recipientStatus: RECIPIENT_STATUS.AGREE_TO_CANCEL,
      },
      'after mutual cancel'
    );

    await ensureDelivered(workflowId, buyer, buyerAddr, amountAfterFee, confirmRcpt);
    console.log(`  ✅ mutual cancel+refund journey OK (${order})`);
  }

  if (CANCEL_ORDER === 'both') {
    await runMutualCancel('buyer-first');
    await runMutualCancel('seller-first');
  } else if (CANCEL_ORDER === 'seller-first') {
    await runMutualCancel('seller-first');
  } else {
    await runMutualCancel('buyer-first');
  }

  // Common settings for dispute tests: set customResolver to our resolver EOA.
  const disputeSettings: EscrowSettings = {
    customResolver: resolverContractAddr,
    yieldPreset: 0,
    autoReleaseTime: 0n,
    autoCancelTime: 0n,
  };

  async function settleIfPossible(workflowId: bigint, amountAfterFee: bigint, recipient: ethers.Signer, recipientAddr: string) {
    const pending = await retry(`pendingSettlements(${workflowId.toString()})`, async () => escrow.pendingSettlements(workflowId));
    const exists = Boolean(pending.exists);
    if (!exists) return;

    const appealDeadline = BigInt(pending.appealDeadline.toString());
    console.log(`  pending settlement exists, appealDeadline=${appealDeadline.toString()}`);

    if (!WAIT_FOR_APPEAL_WINDOW) {
      console.log(
        `  NOTE: dispute settlement is pending until appeal window expires. ` +
          `Set WAIT_FOR_APPEAL_WINDOW=1 to wait and executePendingSettlement().`
      );
      // Still validate the escrow state remains DISPUTED.
      await expectEscrow(workflowId, { escrowState: ESCROW_STATE.DISPUTED }, 'pending settlement');
      return;
    }

    // Poll until appealDeadline then execute.
    while ((await latestChainTimestamp()) < appealDeadline) {
      const now = await latestChainTimestamp();
      const remaining = appealDeadline > now ? appealDeadline - now : 0n;
      console.log(`  waiting for appeal window... remaining=${remaining.toString()}s`);
      await sleep(POLL_SECONDS * 1000);
    }

    const execTx = await escrow.executePendingSettlement(workflowId);
    console.log(`  executePendingSettlement tx: ${execTx.hash}`);
    const execRcpt = await execTx.wait();
    assert(execRcpt, 'Missing receipt for executePendingSettlement');

    await ensureDelivered(workflowId, recipient, recipientAddr, amountAfterFee, execRcpt);
    // Final state: terminal (RELEASED or REFUNDED)
    const et = await retry(`escrowTransfers(${workflowId.toString()}) after executePendingSettlement`, async () =>
      escrow.escrowTransfers(workflowId)
    );
    const st = Number(et.escrowState);
    assert(
      st === ESCROW_STATE.RELEASED || st === ESCROW_STATE.REFUNDED,
      `after executePendingSettlement: expected terminal state RELEASED/REFUNDED, got=${st}`
    );
  }

  // ======================
  // Test 2: buyer dispute -> resolverCancel -> buyer refund (amountAfterFee)
  // ======================
  console.log(`\n### 2) createEscrow -> buyer raises dispute -> resolverCancel -> buyer refund (amountAfterFee)`);
  {
    const { workflowId, amountAfterFee, blockNumber: createBlock } = await createEscrow(sellerAddr, disputeSettings);
    console.log(`  workflowId: ${workflowId.toString()}`);
    if (createBlock > 0) {
      await waitForEscrowMatch(
        workflowId,
        { escrowState: ESCROW_STATE.PENDING, senderStatus: SENDER_STATUS.NONE, recipientStatus: RECIPIENT_STATUS.NONE },
        createBlock,
        'after create (wait)'
      );
    }
    await expectEscrow(
      workflowId,
      { escrowState: ESCROW_STATE.PENDING, senderStatus: SENDER_STATUS.NONE, recipientStatus: RECIPIENT_STATUS.NONE },
      'after create'
    );

    const raiseTx = await escrow.connect(buyer).raiseDispute(workflowId);
    console.log(`  raiseDispute tx: ${raiseTx.hash}`);
    const raiseRcpt = await raiseTx.wait();
    assert(raiseRcpt, 'Missing receipt for raiseDispute');
    assert(await parseEscrowEvent(raiseRcpt, 'DisputeOpened'), 'DisputeOpened not emitted');
    await waitForEscrowMatch(
      workflowId,
      { escrowState: ESCROW_STATE.DISPUTED, senderStatus: SENDER_STATUS.RAISE_DISPUTE, recipientStatus: RECIPIENT_STATUS.NONE },
      Number(raiseRcpt.blockNumber || 0),
      'after raiseDispute (buyer) (wait)'
    );
    await expectEscrow(
      workflowId,
      { escrowState: ESCROW_STATE.DISPUTED, senderStatus: SENDER_STATUS.RAISE_DISPUTE, recipientStatus: RECIPIENT_STATUS.NONE },
      'after raiseDispute (buyer)'
    );

    const resTx = await forwardingResolver
      .connect(resolver)
      .cancelEscrow(escrowVaultAddr, workflowId, ethers.keccak256(ethers.toUtf8Bytes('phase1-cancel')));
    console.log(`  resolverCancel tx: ${resTx.hash}`);
    const resRcpt = await resTx.wait();
    assert(resRcpt, 'Missing receipt for resolverCancel');
    assert(await parseEscrowEvent(resRcpt, 'EscrowResolved'), 'EscrowResolved not emitted');
    const pendingSet = await parseEscrowEvent(resRcpt, 'PendingSettlementSet');
    if (pendingSet) {
      console.log(`  PendingSettlementSet emitted (appeal window enforced)`);
    }

    // Immediate case: terminal state + delivery on this tx
    const after = await retry(`escrowTransfers(${workflowId.toString()}) after resolverCancel`, async () =>
      escrow.escrowTransfers(workflowId)
    );
    const st = Number(after.escrowState);
    if (!pendingSet) {
      assert(st === ESCROW_STATE.REFUNDED, `expected REFUNDED on immediate resolverCancel, got=${st}`);
      await ensureDelivered(workflowId, buyer, buyerAddr, amountAfterFee, resRcpt);
    } else {
      await expectEscrow(workflowId, { escrowState: ESCROW_STATE.DISPUTED }, 'after resolverCancel (pending)');
    }

    await settleIfPossible(workflowId, amountAfterFee, buyer, buyerAddr);

    console.log(`  ✅ dispute cancel journey OK (pending settlement may require waiting)`);
  }

  // ======================
  // Test 3: seller dispute -> resolverRelease -> seller receives amountAfterFee
  // ======================
  console.log(`\n### 3) createEscrow -> seller raises dispute -> resolverRelease -> seller receives amountAfterFee`);
  {
    const { workflowId, amountAfterFee, blockNumber: createBlock } = await createEscrow(sellerAddr, disputeSettings);
    console.log(`  workflowId: ${workflowId.toString()}`);
    if (createBlock > 0) {
      await waitForEscrowMatch(
        workflowId,
        { escrowState: ESCROW_STATE.PENDING, senderStatus: SENDER_STATUS.NONE, recipientStatus: RECIPIENT_STATUS.NONE },
        createBlock,
        'after create (wait)'
      );
    }
    await expectEscrow(
      workflowId,
      { escrowState: ESCROW_STATE.PENDING, senderStatus: SENDER_STATUS.NONE, recipientStatus: RECIPIENT_STATUS.NONE },
      'after create'
    );

    const raiseTx = await escrow.connect(seller).raiseDispute(workflowId);
    console.log(`  raiseDispute tx: ${raiseTx.hash}`);
    const raiseRcpt = await raiseTx.wait();
    assert(raiseRcpt, 'Missing receipt for raiseDispute');
    assert(await parseEscrowEvent(raiseRcpt, 'DisputeOpened'), 'DisputeOpened not emitted');
    await waitForEscrowMatch(
      workflowId,
      { escrowState: ESCROW_STATE.DISPUTED, senderStatus: SENDER_STATUS.NONE, recipientStatus: RECIPIENT_STATUS.RAISE_DISPUTE },
      Number(raiseRcpt.blockNumber || 0),
      'after raiseDispute (seller) (wait)'
    );
    await expectEscrow(
      workflowId,
      { escrowState: ESCROW_STATE.DISPUTED, senderStatus: SENDER_STATUS.NONE, recipientStatus: RECIPIENT_STATUS.RAISE_DISPUTE },
      'after raiseDispute (seller)'
    );

    const resTx = await forwardingResolver
      .connect(resolver)
      .releaseEscrow(escrowVaultAddr, workflowId, ethers.keccak256(ethers.toUtf8Bytes('phase1-release')));
    console.log(`  resolverRelease tx: ${resTx.hash}`);
    const resRcpt = await resTx.wait();
    assert(resRcpt, 'Missing receipt for resolverRelease');
    assert(await parseEscrowEvent(resRcpt, 'EscrowResolved'), 'EscrowResolved not emitted');
    const pendingSet = await parseEscrowEvent(resRcpt, 'PendingSettlementSet');
    if (pendingSet) {
      console.log(`  PendingSettlementSet emitted (appeal window enforced)`);
    }

    // Immediate case: terminal state + delivery on this tx
    const after = await retry(`escrowTransfers(${workflowId.toString()}) after resolverRelease`, async () =>
      escrow.escrowTransfers(workflowId)
    );
    const st = Number(after.escrowState);
    if (!pendingSet) {
      assert(st === ESCROW_STATE.RELEASED, `expected RELEASED on immediate resolverRelease, got=${st}`);
      await ensureDelivered(workflowId, seller, sellerAddr, amountAfterFee, resRcpt);
    } else {
      await expectEscrow(workflowId, { escrowState: ESCROW_STATE.DISPUTED }, 'after resolverRelease (pending)');
    }

    await settleIfPossible(workflowId, amountAfterFee, seller, sellerAddr);

    console.log(`  ✅ dispute release journey OK (pending settlement may require waiting)`);
  }

  console.log(`\n✅ Phase 1 journeys script completed.`);
}

main().catch((err) => {
  console.error(`\n❌ Phase 1 journeys failed:\n${err?.stack || err?.message || err}`);
  process.exitCode = 1;
});

