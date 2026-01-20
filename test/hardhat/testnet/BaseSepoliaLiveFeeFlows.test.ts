import { expect } from 'chai';
import hre from 'hardhat';
import { ethers } from 'ethers';

type EscrowSettings = {
  customResolver: string;
  yieldPreset: number;
  autoReleaseTime: bigint;
  autoCancelTime: bigint;
};

function requireEnv(name: string): string {
  const v = process.env[name];
  if (!v) throw new Error(`Missing env var: ${name}`);
  return v;
}

function optionalWallet(pkEnv: string | undefined, provider: ethers.Provider): ethers.Wallet | null {
  if (!pkEnv || pkEnv.trim().length === 0) return null;
  return new ethers.Wallet(pkEnv, provider);
}

async function ensureAllowance(
  token: any,
  owner: string,
  spender: string,
  amount: bigint,
  signer: ethers.Signer
) {
  const allowance: bigint = await token.allowance(owner, spender);
  if (allowance >= amount) return;
  const tx = await token.connect(signer).approve(spender, amount);
  await tx.wait();
}

function defaultSettings(): EscrowSettings {
  return {
    customResolver: ethers.ZeroAddress,
    yieldPreset: 0, // OFF
    autoReleaseTime: 0n,
    autoCancelTime: 0n,
  };
}

describe('Base Sepolia (live) — escrow fee scenarios', function () {
  before(function () {
    // Safety: prevent accidental mainnet/testnet sends during normal `pnpm test`.
    // To run this file:
    //   LIVE_TESTS=YES RPC_BASE_SEPOLIA=... TEST_BUYER_PRIVATE_KEY=... TEST_SELLER_PRIVATE_KEY=... pnpm hardhat test --network baseSepolia --grep "Base Sepolia (live)"
    if ((process.env.LIVE_TESTS || '').toUpperCase() !== 'YES') this.skip();
    if (hre.network.name !== 'baseSepolia') this.skip();
  });

  it('purchase + refund: fee tracking at each stage', async function () {
    this.timeout(15 * 60_000);

    const provider = hre.ethers.provider;
    const deployments = hre.deployments;

    const escrowVaultAddr = (await deployments.get('EscrowVault')).address;
    const sewTokenAddr = (await deployments.get('SewToken')).address;
    const tokenAddr = process.env.ESCROW_TOKEN || sewTokenAddr;

    const buyerPk = requireEnv('TEST_BUYER_PRIVATE_KEY');
    const sellerPk = requireEnv('TEST_SELLER_PRIVATE_KEY');
    const buyer = new ethers.Wallet(buyerPk, provider);
    const seller = new ethers.Wallet(sellerPk, provider);

    const buyerAddr = await buyer.getAddress();
    const sellerAddr = await seller.getAddress();

    const vault = await hre.ethers.getContractAt('EscrowVault', escrowVaultAddr);
    const token = await hre.ethers.getContractAt(
      [
        'function name() view returns (string)',
        'function symbol() view returns (string)',
        'function decimals() view returns (uint8)',
        'function balanceOf(address) view returns (uint256)',
        'function allowance(address,address) view returns (uint256)',
        'function approve(address,uint256) returns (bool)',
      ],
      tokenAddr
    );

    const feeBps: bigint = await vault.escrowFee();
    // This test assumes the deployed EscrowVault is configured at 1% (100 bps).
    // If it is not, the fee assertions will fail and you should update the deployed parameter.
    expect(feeBps).to.equal(100n);

    const decimals = Number(await token.decimals());
    const amountHuman = process.env.ESCROW_AMOUNT || '10';
    const amount = ethers.parseUnits(amountHuman, decimals);

    const expectedFee = (amount * feeBps) / 10_000n;
    const expectedAmountAfterFee = amount - expectedFee;

    const buyerBal0: bigint = await token.balanceOf(buyerAddr);
    if (buyerBal0 < amount) {
      throw new Error(
        `Buyer token balance too low: have=${buyerBal0.toString()} need=${amount.toString()} token=${tokenAddr}`
      );
    }

    await ensureAllowance(token, buyerAddr, escrowVaultAddr, amount, buyer);

    // ===== purchase flow =====
    const feesBeforePurchase: bigint = await vault.totalFeesPerToken(tokenAddr);
    const heldBeforePurchase: bigint = await vault.totalHeldInEscrowPerToken(tokenAddr);
    const sellerBalBefore: bigint = await token.balanceOf(sellerAddr);

    const txCreate1 = await vault.connect(buyer).createEscrow(tokenAddr, sellerAddr, amount, defaultSettings());
    const rcpt1 = await txCreate1.wait();
    if (!rcpt1) throw new Error('Missing receipt for createEscrow (purchase)');

    const created1 = rcpt1.logs
      .filter((l) => (l as any).address?.toLowerCase?.() === escrowVaultAddr.toLowerCase())
      .map((l) => {
        try {
          return vault.interface.parseLog(l as any);
        } catch {
          return null;
        }
      })
      .find((p) => p?.name === 'EscrowCreated');
    if (!created1) throw new Error('Missing EscrowCreated event (purchase)');

    const workflowId1 = created1.args.workflowId as bigint;
    const fee1 = created1.args.fee as bigint;
    const amountAfterFee1 = created1.args.amountAfterFee as bigint;

    expect(fee1).to.equal(expectedFee);
    expect(amountAfterFee1).to.equal(expectedAmountAfterFee);

    expect(await vault.totalFeesPerToken(tokenAddr)).to.equal(feesBeforePurchase + fee1);
    expect(await vault.totalHeldInEscrowPerToken(tokenAddr)).to.equal(heldBeforePurchase + amountAfterFee1);

    const txRelease = await vault.connect(buyer).releaseEscrowTransfer(workflowId1);
    await txRelease.wait();

    // If auto-transfer fails, seller may need to pull.
    const claimable: bigint = await vault.claimableBalances(workflowId1, sellerAddr);
    if (claimable > 0n) {
      const txWithdraw = await vault.connect(seller).withdrawEscrow(workflowId1);
      await txWithdraw.wait();
    }

    const sellerBalAfter: bigint = await token.balanceOf(sellerAddr);
    expect(sellerBalAfter - sellerBalBefore).to.equal(amountAfterFee1);

    // After release: held should be reduced back, fees remain.
    expect(await vault.totalHeldInEscrowPerToken(tokenAddr)).to.equal(heldBeforePurchase);
    expect(await vault.totalFeesPerToken(tokenAddr)).to.equal(feesBeforePurchase + fee1);

    // ===== refund flow =====
    await ensureAllowance(token, buyerAddr, escrowVaultAddr, amount, buyer);

    const feesBeforeRefund: bigint = await vault.totalFeesPerToken(tokenAddr);
    const heldBeforeRefund: bigint = await vault.totalHeldInEscrowPerToken(tokenAddr);
    const buyerBalBeforeRefund: bigint = await token.balanceOf(buyerAddr);

    const txCreate2 = await vault.connect(buyer).createEscrow(tokenAddr, sellerAddr, amount, defaultSettings());
    const rcpt2 = await txCreate2.wait();
    if (!rcpt2) throw new Error('Missing receipt for createEscrow (refund)');

    const created2 = rcpt2.logs
      .filter((l) => (l as any).address?.toLowerCase?.() === escrowVaultAddr.toLowerCase())
      .map((l) => {
        try {
          return vault.interface.parseLog(l as any);
        } catch {
          return null;
        }
      })
      .find((p) => p?.name === 'EscrowCreated');
    if (!created2) throw new Error('Missing EscrowCreated event (refund)');

    const workflowId2 = created2.args.workflowId as bigint;
    const fee2 = created2.args.fee as bigint;
    const amountAfterFee2 = created2.args.amountAfterFee as bigint;

    expect(fee2).to.equal(expectedFee);
    expect(amountAfterFee2).to.equal(expectedAmountAfterFee);

    expect(await vault.totalFeesPerToken(tokenAddr)).to.equal(feesBeforeRefund + fee2);
    expect(await vault.totalHeldInEscrowPerToken(tokenAddr)).to.equal(heldBeforeRefund + amountAfterFee2);

    const txSellerCancel = await vault.connect(seller).recipientCancel(workflowId2);
    await txSellerCancel.wait();

    const txBuyerCancel = await vault.connect(buyer).senderCancel(workflowId2);
    await txBuyerCancel.wait();

    const buyerBalAfterRefund: bigint = await token.balanceOf(buyerAddr);
    expect(buyerBalAfterRefund - buyerBalBeforeRefund).to.equal(amountAfterFee2);

    expect(await vault.totalHeldInEscrowPerToken(tokenAddr)).to.equal(heldBeforeRefund);
    expect(await vault.totalFeesPerToken(tokenAddr)).to.equal(feesBeforeRefund + fee2);
  });

  it('DAO can withdraw fees (requires TEST_DAO_PRIVATE_KEY with ROLE_FEE_RECIPIENT)', async function () {
    this.timeout(10 * 60_000);

    const provider = hre.ethers.provider;
    const deployments = hre.deployments;

    const escrowVaultAddr = (await deployments.get('EscrowVault')).address;
    const sewTokenAddr = (await deployments.get('SewToken')).address;
    const tokenAddr = process.env.ESCROW_TOKEN || sewTokenAddr;

    const dao = optionalWallet(process.env.TEST_DAO_PRIVATE_KEY, provider);
    if (!dao) this.skip();

    const vault = await hre.ethers.getContractAt('EscrowVault', escrowVaultAddr);
    const token = await hre.ethers.getContractAt(
      [
        'function balanceOf(address) view returns (uint256)',
      ],
      tokenAddr
    );

    const roleFeeRecipient: string = await vault.ROLE_FEE_RECIPIENT();
    const daoAddr = await dao.getAddress();
    const hasRole: boolean = await vault.hasRole(roleFeeRecipient, daoAddr);
    if (!hasRole) {
      throw new Error(`TEST_DAO_PRIVATE_KEY address ${daoAddr} does not have ROLE_FEE_RECIPIENT on EscrowVault`);
    }

    const treasuryAddr: string = await vault.escrowFeeAddress();

    const totalFeesBefore: bigint = await vault.totalFeesPerToken(tokenAddr);
    if (totalFeesBefore === 0n) {
      throw new Error('No fees accrued yet. Run the purchase/refund test first to accrue fees.');
    }

    const treasuryBal0: bigint = await token.balanceOf(treasuryAddr);

    const tx = await vault.connect(dao).withdrawFees(tokenAddr);
    const rcpt = await tx.wait();
    if (!rcpt) throw new Error('Missing receipt for withdrawFees');

    // Event check
    const feesWithdrawn = rcpt.logs
      .filter((l) => (l as any).address?.toLowerCase?.() === escrowVaultAddr.toLowerCase())
      .map((l) => {
        try {
          return vault.interface.parseLog(l as any);
        } catch {
          return null;
        }
      })
      .find((p) => p?.name === 'FeesWithdrawn');

    expect(feesWithdrawn, 'FeesWithdrawn event').to.not.equal(undefined);

    expect(await vault.totalFeesPerToken(tokenAddr)).to.equal(0n);
    const treasuryBal1: bigint = await token.balanceOf(treasuryAddr);
    expect(treasuryBal1 - treasuryBal0).to.equal(totalFeesBefore);
  });
});

