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

function envNumber(name: string, defaultValue: number): number {
  const v = process.env[name];
  if (!v) return defaultValue;
  const n = Number(v);
  if (!Number.isFinite(n) || n < 0) throw new Error(`Invalid ${name}: ${v}`);
  return n;
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function basescanAddressLink(address: string): string {
  return `https://sepolia.basescan.org/address/${address}`;
}

function normalizeAddressLike(input: string): string {
  // Allow users to paste addresses with comments like:
  // 0xabc...def  // USDC
  // or with extra whitespace/newlines.
  const withoutComments = input.split('//')[0].split('#')[0].trim();
  // If still contains whitespace, keep only the first token.
  return withoutComments.split(/\s+/)[0] ?? '';
}

function requireAddress(name: string, value: string): string {
  const normalized = normalizeAddressLike(value);
  if (!ethers.isAddress(normalized)) {
    throw new Error(`Invalid ${name}: "${value}" (parsed as "${normalized}")`);
  }
  return ethers.getAddress(normalized);
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

  // Env helpers for post-deploy scripts (TEST_* preferred, legacy supported).
  const env = {
    pk(name: string, legacy?: string): string | undefined {
      return process.env[`TEST_${name}`] || (legacy ? process.env[legacy] : undefined);
    },
    str(name: string, legacy?: string): string | undefined {
      return process.env[`TEST_${name}`] || (legacy ? process.env[legacy] : undefined);
    },
    num(name: string, fallback: number, legacy?: string): number {
      const v = process.env[`TEST_${name}`] || (legacy ? process.env[legacy] : undefined);
      if (!v) return fallback;
      const n = Number(v);
      if (!Number.isFinite(n) || n < 0) throw new Error(`Invalid TEST_${name}: ${v}`);
      return n;
    },
  };

  const escrowVaultAddr = (await deployments.get('EscrowVault')).address;
  const sewTokenAddr = (await deployments.get('SewToken')).address;

  // TEST_* env vars are preferred for post-deploy scripts; legacy env vars still work as fallback.
  const buyerPk = env.pk('BUYER_PRIVATE_KEY', 'BUYER_PRIVATE_KEY'); // optional
  const sellerPk = env.pk('SELLER_PRIVATE_KEY', 'SELLER_PRIVATE_KEY'); // optional
  const sellerAddressOverride = env.str('SELLER_ADDRESS', 'SELLER_ADDRESS'); // optional

  const buyer = await getWalletOrDefaultSigner(provider, buyerPk);
  const buyerAddr = await buyer.getAddress();

  const sellerSigner =
    sellerPk && sellerPk.trim().length > 0 ? new ethers.Wallet(sellerPk, provider) : undefined;
  const sellerAddr = sellerAddressOverride
    ? requireAddress('SELLER_ADDRESS', sellerAddressOverride)
    : sellerSigner
      ? await sellerSigner.getAddress()
      : buyerAddr;

  const tokenAddr = requireAddress('ESCROW_TOKEN', env.str('ESCROW_TOKEN', 'ESCROW_TOKEN') || sewTokenAddr);
  const amountHuman = env.str('ESCROW_AMOUNT', 'ESCROW_AMOUNT') || '1';

  const transfers = env.num('NUM_TRANSFERS', 25, 'NUM_TRANSFERS');
  const delaySeconds = env.num('DELAY_SECONDS', 15, 'DELAY_SECONDS');

  console.log(`\n🧪 Stress: many escrows with delayed release (Base Sepolia)`);
  console.log(`- EscrowVault: ${escrowVaultAddr}`);
  console.log(`  - ${basescanAddressLink(escrowVaultAddr)}`);
  console.log(
    `- Token: ${tokenAddr} ${tokenAddr.toLowerCase() === sewTokenAddr.toLowerCase() ? '(SewToken)' : ''}`
  );
  console.log(`  - ${basescanAddressLink(tokenAddr)}`);
  console.log(`- Buyer: ${buyerAddr}`);
  console.log(
    `- Seller: ${sellerAddr}${sellerAddr.toLowerCase() === buyerAddr.toLowerCase() ? ' (same as buyer)' : ''}`
  );
  console.log(`- NUM_TRANSFERS=${transfers}`);
  console.log(`- DELAY_SECONDS=${delaySeconds}`);

  if (sellerAddr.toLowerCase() === buyerAddr.toLowerCase()) {
    console.log(
      `\nℹ️  TEST_SELLER_PRIVATE_KEY/TEST_SELLER_ADDRESS not set; seller defaults to buyer. ` +
        `Set TEST_SELLER_ADDRESS (or TEST_SELLER_PRIVATE_KEY) to validate a distinct seller balance.`
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
    ],
    tokenAddr
  );

  // Hardhat's generic Contract typing is too loose for TS typecheck in this repo.
  // Use `any` to match other testnet scripts and keep runtime behavior correct.
  const tokenAny: any = token;
  const escrow: any = await hre.ethers.getContractAt('EscrowVault', escrowVaultAddr);

  // We can only execute `withdrawEscrow` if we have a signer for `sellerAddr`.
  const sellerTxSigner: ethers.Signer | undefined =
    sellerAddr.toLowerCase() === buyerAddr.toLowerCase()
      ? buyer
      : sellerSigner && (await sellerSigner.getAddress()).toLowerCase() === sellerAddr.toLowerCase()
        ? sellerSigner
        : undefined;

  const tokenName = await tokenAny.name().catch(() => '');
  const tokenSymbol = await tokenAny.symbol().catch(() => '');
  const tokenDecimals = Number(await tokenAny.decimals());
  const amount = ethers.parseUnits(amountHuman, tokenDecimals);

  console.log(`\nToken: ${tokenName} (${tokenSymbol}), decimals=${tokenDecimals}`);
  console.log(`Amount per escrow: ${amountHuman} (${amount.toString()} base units)`);

  const buyerBal0: bigint = await tokenAny.balanceOf(buyerAddr);
  const required: bigint = amount * BigInt(transfers);
  if (buyerBal0 < required) {
    throw new Error(
      `Buyer token balance too low for NUM_TRANSFERS. balance=${buyerBal0.toString()} need≈${required.toString()}`
    );
  }

  const allowance0: bigint = await tokenAny.allowance(buyerAddr, escrowVaultAddr);
  if (allowance0 < required) {
    console.log(`\n🔏 Approving EscrowVault to spend buyer tokens (max uint256)...`);
    const approveTx = await tokenAny.connect(buyer).approve(escrowVaultAddr, ethers.MaxUint256);
    console.log(`  tx: ${approveTx.hash}`);
    await approveTx.wait();
  } else {
    console.log(`\n🔏 Allowance OK (>= total required).`);
  }

  const settings: EscrowSettings = {
    customResolver: ethers.ZeroAddress,
    yieldPreset: 0, // OFF
    autoReleaseTime: 0n,
    autoCancelTime: 0n,
  };

  const sellerStart: bigint = await tokenAny.balanceOf(sellerAddr);
  let expectedTotal: bigint = 0n;
  let deliveredTotal: bigint = 0n;

  console.log(`\nRunning...`);
  for (let i = 0; i < transfers; i++) {
    const idx = i + 1;
    console.log(`\n[${idx}/${transfers}] createEscrow → wait → release`);

    const sellerBefore: bigint = await tokenAny.balanceOf(sellerAddr);

    const createTx = await escrow.connect(buyer).createEscrow(tokenAddr, sellerAddr, amount, settings);
    console.log(`  create tx: ${createTx.hash}`);
    const rcpt = await createTx.wait();
    if (!rcpt) throw new Error(`Missing receipt for create escrow (${idx})`);

    const created = (rcpt.logs as any[])
      .filter((l: any) => l.address?.toLowerCase?.() === escrowVaultAddr.toLowerCase())
      .map((l: any) => {
        try {
          return escrow.interface.parseLog(l as any);
        } catch {
          return null;
        }
      })
      .find((p) => p?.name === 'EscrowCreated');

    if (!created) throw new Error(`Could not find EscrowCreated event (${idx})`);
    const workflowId = created.args.workflowId as bigint;
    const amountAfterFee = created.args.amountAfterFee as bigint;
    expectedTotal += amountAfterFee;

    console.log(`  workflowId: ${workflowId.toString()}`);
    console.log(`  amountAfterFee: ${amountAfterFee.toString()}`);

    if (delaySeconds > 0) {
      console.log(`  waiting ${delaySeconds}s...`);
      await sleep(delaySeconds * 1000);
    }

    const releaseTx = await escrow.connect(buyer).releaseEscrowTransfer(workflowId);
    console.log(`  release tx: ${releaseTx.hash}`);
    const releaseRcpt = await releaseTx.wait();

    // Debug helpers for tokens that appear to "succeed" but don't move balances.
    const erc20EventIface = new ethers.Interface([
      'event Transfer(address indexed from, address indexed to, uint256 value)',
    ]);
    const escrowEventIface = escrow.interface;

    let pushedToSeller: bigint = 0n;
    if (releaseRcpt?.logs?.length) {
      const escrowAuto = releaseRcpt.logs
        .filter((l: any) => (l.address || '').toLowerCase() === escrowVaultAddr.toLowerCase())
        .map((l: any) => {
          try {
            return escrowEventIface.parseLog(l);
          } catch {
            return null;
          }
        })
        .find((p: any) => p?.name === 'EscrowTransferAutoResult');
      if (escrowAuto) {
        console.log(
          `  EscrowTransferAutoResult: recipient=${escrowAuto.args.recipient} amount=${escrowAuto.args.amount.toString()} success=${escrowAuto.args.success} code=${escrowAuto.args.reasonCode}`
        );
      }

      const tokenTransfers = releaseRcpt.logs
        .filter((l: any) => (l.address || '').toLowerCase() === tokenAddr.toLowerCase())
        .map((l: any) => {
          try {
            return erc20EventIface.parseLog(l);
          } catch {
            return null;
          }
        })
        .filter(Boolean) as any[];

      for (const t of tokenTransfers) {
        console.log(
          `  ERC20 Transfer: from=${t.args.from} to=${t.args.to} value=${t.args.value.toString()}`
        );
        // Track the specific escrow payout transfer for robust accounting even if the seller wallet
        // sweeps funds immediately after receiving them.
        if (
          String(t.args.from).toLowerCase() === escrowVaultAddr.toLowerCase() &&
          String(t.args.to).toLowerCase() === sellerAddr.toLowerCase()
        ) {
          pushedToSeller += BigInt(t.args.value.toString());
        }
      }
    }

    const sellerAfter: bigint = await tokenAny.balanceOf(sellerAddr);
    let delta = sellerAfter - sellerBefore;

    // Prefer event-based accounting (robust to seller wallet sweeping funds right after receipt).
    if (pushedToSeller === amountAfterFee) {
      deliveredTotal += amountAfterFee;
      console.log(`  ✅ delivered via push transfer (event observed)`);
      console.log(`  seller balance delta observed: ${delta.toString()}`);
      continue;
    }

    // EscrowVault uses "attempt push; fallback to pull". For pull, verify claimable + withdraw.
    if (pushedToSeller === 0n) {
      const claimable: bigint = await escrow.claimableBalances(workflowId, sellerAddr);
      const escrowBal: bigint = await tokenAny.balanceOf(escrowVaultAddr);
      console.log(`  push delta: ${delta.toString()}, claimable: ${claimable.toString()}`);
      console.log(`  EscrowVault token balance now: ${escrowBal.toString()}`);

      if (claimable > 0n) {
        if (!sellerTxSigner) {
          throw new Error(
            `Release fell back to pull (claimable=${claimable.toString()}) but no TEST_SELLER_PRIVATE_KEY provided for ${sellerAddr}. ` +
              `Provide TEST_SELLER_PRIVATE_KEY or set TEST_SELLER_ADDRESS to an account you control.`
          );
        }

        const wdTx = await escrow.connect(sellerTxSigner).withdrawEscrow(workflowId);
        console.log(`  withdraw tx: ${wdTx.hash}`);
        await wdTx.wait();

        const sellerAfterWithdraw: bigint = await tokenAny.balanceOf(sellerAddr);
        delta = sellerAfterWithdraw - sellerBefore;
        const claimableAfter: bigint = await escrow.claimableBalances(workflowId, sellerAddr);
        console.log(`  withdraw delta: ${(sellerAfterWithdraw - sellerAfter).toString()}`);
        console.log(`  claimable after: ${claimableAfter.toString()}`);

        deliveredTotal += claimable;
      }
    } else {
      // We saw token transfers, but not the expected vault->seller amount. Fail with diagnostics.
      throw new Error(
        `Unexpected token transfer pattern at ${idx}. expected vault->seller=${amountAfterFee.toString()} but saw=${pushedToSeller.toString()}`
      );
    }

    if (delta !== amountAfterFee) {
      throw new Error(
        `Seller delta mismatch at ${idx}. expected=${amountAfterFee.toString()} got=${delta.toString()}`
      );
    }
    console.log(`  ✅ delivered via pull-withdraw (delta OK after withdraw)`);
  }

  const sellerEnd: bigint = await tokenAny.balanceOf(sellerAddr);
  const sellerNet = sellerEnd - sellerStart;

  console.log(`\nSummary`);
  console.log(`- seller start: ${sellerStart.toString()}`);
  console.log(`- seller end:   ${sellerEnd.toString()}`);
  console.log(`- seller net:   ${sellerNet.toString()}`);
  console.log(`- expected:     ${expectedTotal.toString()}`);
  console.log(`- delivered:    ${deliveredTotal.toString()}`);

  if (sellerNet !== expectedTotal) {
    console.log(
      `WARN: seller net balance != expected. This can happen if the seller address ` +
        `spends/sweeps funds during the run. This script asserts delivery via events/withdrawals instead.`
    );
  }

  // Primary invariant: total amount released across all escrows equals sum(amountAfterFee),
  // independent of seller wallet sweeping funds.
  if (deliveredTotal !== expectedTotal) {
    throw new Error(
      `Final delivered total mismatch. expected=${expectedTotal.toString()} got=${deliveredTotal.toString()}`
    );
  }

  console.log(`\n✅ Stress test completed successfully.`);
}

main().catch((err) => {
  console.error(`\n❌ Stress test failed:\n${err?.stack || err?.message || err}`);
  process.exitCode = 1;
});

