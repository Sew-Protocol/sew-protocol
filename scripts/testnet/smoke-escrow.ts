import hre from 'hardhat';
import { ethers } from 'ethers';

type EscrowSettings = {
  customResolver: string;
  yieldPreset: number; // YieldPreset enum (0=OFF, 1=TO_SENDER)
  autoReleaseTime: bigint;
  autoCancelTime: bigint;
};

function requireEnv(name: string): string {
  const v = process.env[name];
  if (!v) throw new Error(`Missing env var: ${name}`);
  return v;
}

function basescanAddressLink(address: string): string {
  return `https://sepolia.basescan.org/address/${address}`;
}

async function getWalletOrDefaultSigner(
  provider: ethers.Provider,
  maybePkEnv: string | undefined
): Promise<ethers.Signer> {
  if (maybePkEnv && maybePkEnv.trim().length > 0) return new ethers.Wallet(maybePkEnv, provider);
  const [defaultSigner] = await hre.ethers.getSigners();
  return defaultSigner;
}

async function main() {
  const { deployments } = hre;
  const provider = hre.ethers.provider;

  // Canonical deployed addresses (from hardhat-deploy)
  const escrowVaultAddr = (await deployments.get('EscrowVault')).address;
  const sewTokenAddr = (await deployments.get('SewToken')).address;

  const buyerPk = process.env.BUYER_PRIVATE_KEY; // optional
  const sellerPk = process.env.SELLER_PRIVATE_KEY; // optional (recommended for true 2-party cancel)

  const buyer = await getWalletOrDefaultSigner(provider, buyerPk);
  const buyerAddr = await buyer.getAddress();

  const seller =
    sellerPk && sellerPk.trim().length > 0 ? new ethers.Wallet(sellerPk, provider) : buyer;
  const sellerAddr = await seller.getAddress();

  const tokenAddr = process.env.ESCROW_TOKEN || sewTokenAddr;
  const amountHuman = process.env.ESCROW_AMOUNT || '1';

  console.log(`\n🧪 EscrowVault smoke test (Base Sepolia)`);
  console.log(`- EscrowVault: ${escrowVaultAddr}`);
  console.log(`  - ${basescanAddressLink(escrowVaultAddr)}`);
  console.log(`- Token: ${tokenAddr} ${tokenAddr.toLowerCase() === sewTokenAddr.toLowerCase() ? '(SewToken)' : ''}`);
  console.log(`  - ${basescanAddressLink(tokenAddr)}`);
  console.log(`- Buyer: ${buyerAddr}`);
  console.log(`- Seller: ${sellerAddr}${sellerAddr.toLowerCase() === buyerAddr.toLowerCase() ? ' (same as buyer)' : ''}`);

  if (sellerAddr.toLowerCase() === buyerAddr.toLowerCase()) {
    console.log(
      `\nℹ️  SELLER_PRIVATE_KEY not set; cancel test will use buyer as both parties. ` +
        `Set SELLER_PRIVATE_KEY (funded with some Base Sepolia ETH) to test true 2-party cancel.`
    );
  }

  const token = await hre.ethers.getContractAt(
    [
      'function name() view returns (string)',
      'function symbol() view returns (string)',
      'function decimals() view returns (uint8)',
      'function balanceOf(address) view returns (uint256)',
      'function allowance(address,address) view returns (uint256)',
      'function approve(address spender, uint256 amount) returns (bool)',
      'function transfer(address to, uint256 amount) returns (bool)',
    ],
    tokenAddr
  );

  const escrow = await hre.ethers.getContractAt('EscrowVault', escrowVaultAddr);

  const tokenName = await token.name().catch(() => '');
  const tokenSymbol = await token.symbol().catch(() => '');
  const tokenDecimals = Number(await token.decimals());
  const amount = ethers.parseUnits(amountHuman, tokenDecimals);

  console.log(`\nToken: ${tokenName} (${tokenSymbol}), decimals=${tokenDecimals}`);
  console.log(`Amount: ${amountHuman} (${amount.toString()} base units)`);

  // Ensure buyer has enough tokens (if not, try to transfer from buyer->seller isn't possible; we just fail fast)
  const buyerBal0: bigint = await token.balanceOf(buyerAddr);
  if (buyerBal0 < amount) {
    throw new Error(
      `Buyer token balance too low. balance=${buyerBal0.toString()} need=${amount.toString()}`
    );
  }

  // Ensure escrow can pull tokens
  const allowance0: bigint = await token.allowance(buyerAddr, escrowVaultAddr);
  if (allowance0 < amount) {
    console.log(`\n🔏 Approving EscrowVault to spend buyer tokens...`);
    const approveTx = await token.connect(buyer).approve(escrowVaultAddr, amount);
    console.log(`  tx: ${approveTx.hash}`);
    await approveTx.wait();
  } else {
    console.log(`\n🔏 Allowance OK (>= amount).`);
  }

  const settings: EscrowSettings = {
    customResolver: ethers.ZeroAddress,
    yieldPreset: 0, // OFF
    autoReleaseTime: 0n,
    autoCancelTime: 0n,
  };

  // ========= Test 1: create escrow → release =========
  console.log(`\n1) Create escrow → Release`);
  const sellerBalBeforeRelease: bigint = await token.balanceOf(sellerAddr);

  const createTx1 = await escrow
    .connect(buyer)
    .createEscrow(tokenAddr, sellerAddr, amount, settings);
  console.log(`  create tx: ${createTx1.hash}`);
  const rcpt1 = await createTx1.wait();
  if (!rcpt1) throw new Error('Missing receipt for create escrow (1)');

  const created1 = rcpt1.logs
    .filter((l) => (l as any).address?.toLowerCase?.() === escrowVaultAddr.toLowerCase())
    .map((l) => {
      try {
        return escrow.interface.parseLog(l as any);
      } catch {
        return null;
      }
    })
    .find((p) => p?.name === 'EscrowCreated');

  if (!created1) throw new Error('Could not find EscrowCreated event (1)');
  const workflowId1 = created1.args.workflowId as bigint;
  const amountAfterFee1 = created1.args.amountAfterFee as bigint;
  const fee1 = created1.args.fee as bigint;

  console.log(`  workflowId: ${workflowId1.toString()}`);
  console.log(`  fee: ${fee1.toString()}, amountAfterFee: ${amountAfterFee1.toString()}`);

  const releaseTx = await escrow.connect(buyer).releaseEscrowTransfer(workflowId1);
  console.log(`  release tx: ${releaseTx.hash}`);
  await releaseTx.wait();

  const sellerBalAfterRelease: bigint = await token.balanceOf(sellerAddr);
  const sellerDeltaRelease = sellerBalAfterRelease - sellerBalBeforeRelease;
  console.log(`  seller balance delta: ${sellerDeltaRelease.toString()}`);

  if (sellerDeltaRelease !== amountAfterFee1) {
    throw new Error(
      `Release balance mismatch. expected=${amountAfterFee1.toString()} got=${sellerDeltaRelease.toString()}`
    );
  }
  console.log(`  ✅ Release flow OK`);

  // ========= Test 2: create escrow → cancel (seller + buyer) → refund =========
  console.log(`\n2) Create escrow → Cancel (seller + buyer) → Refund to buyer`);

  // Re-approve if allowance was exactly amount and got consumed
  const allowance1: bigint = await token.allowance(buyerAddr, escrowVaultAddr);
  if (allowance1 < amount) {
    console.log(`  🔏 Re-approving EscrowVault to spend buyer tokens...`);
    const approveTx2 = await token.connect(buyer).approve(escrowVaultAddr, amount);
    console.log(`    tx: ${approveTx2.hash}`);
    await approveTx2.wait();
  }

  const buyerBalBeforeCancelFlow: bigint = await token.balanceOf(buyerAddr);

  const createTx2 = await escrow
    .connect(buyer)
    .createEscrow(tokenAddr, sellerAddr, amount, settings);
  console.log(`  create tx: ${createTx2.hash}`);
  const rcpt2 = await createTx2.wait();
  if (!rcpt2) throw new Error('Missing receipt for create escrow (2)');

  const created2 = rcpt2.logs
    .filter((l) => (l as any).address?.toLowerCase?.() === escrowVaultAddr.toLowerCase())
    .map((l) => {
      try {
        return escrow.interface.parseLog(l as any);
      } catch {
        return null;
      }
    })
    .find((p) => p?.name === 'EscrowCreated');

  if (!created2) throw new Error('Could not find EscrowCreated event (2)');
  const workflowId2 = created2.args.workflowId as bigint;
  const amountAfterFee2 = created2.args.amountAfterFee as bigint;

  console.log(`  workflowId: ${workflowId2.toString()}`);

  // Seller requests/approves cancel
  const sellerCancelTx = await escrow.connect(seller).recipientCancel(workflowId2);
  console.log(`  seller cancel tx: ${sellerCancelTx.hash}`);
  await sellerCancelTx.wait();

  // Buyer requests/approves cancel (this should finalize + refund if seller already agreed)
  const buyerCancelTx = await escrow.connect(buyer).senderCancel(workflowId2);
  console.log(`  buyer cancel tx: ${buyerCancelTx.hash}`);
  await buyerCancelTx.wait();

  const buyerBalAfterCancelFlow: bigint = await token.balanceOf(buyerAddr);
  const buyerDeltaRefund = buyerBalAfterCancelFlow - buyerBalBeforeCancelFlow;
  console.log(`  buyer balance delta: ${buyerDeltaRefund.toString()}`);

  if (buyerDeltaRefund !== amountAfterFee2) {
    throw new Error(
      `Refund balance mismatch. expected=${amountAfterFee2.toString()} got=${buyerDeltaRefund.toString()}`
    );
  }
  console.log(`  ✅ Cancel+refund flow OK`);

  console.log(`\n✅ Smoke tests completed successfully.`);
}

main().catch((err) => {
  console.error(`\n❌ Smoke test failed:\n${err?.stack || err?.message || err}`);
  process.exitCode = 1;
});

