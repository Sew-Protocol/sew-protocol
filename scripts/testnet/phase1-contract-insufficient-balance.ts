import hre from 'hardhat';
import { ethers } from 'ethers';

import { basescanAddressLink, envBool, envFirst, requireAddress, assert, retry, sleep } from './_journeyHelpers';

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

  const tokenForFees = requireAddress('ESCROW_TOKEN', process.env.TEST_ESCROW_TOKEN || process.env.ESCROW_TOKEN || sewTokenAddr);

  const SEND_REVERT_TXS = envBool('TEST_SEND_REVERT_TXS', envBool('SEND_REVERT_TXS', false));
  const POLL_SECONDS = Number(process.env.TEST_POLL_SECONDS || process.env.POLL_SECONDS || '2');

  const buyerPk = envFirst('TEST_BUYER_PRIVATE_KEY', 'BUYER_PRIVATE_KEY');
  const sellerPk = envFirst('TEST_SELLER_PRIVATE_KEY', 'SELLER_PRIVATE_KEY');
  const feeWithdrawerPk = envFirst('TEST_FEE_WITHDRAWER_PRIVATE_KEY', 'FEE_WITHDRAWER_PRIVATE_KEY', 'TEST_BUYER_PRIVATE_KEY', 'BUYER_PRIVATE_KEY');
  assert(buyerPk, 'Missing env var: TEST_BUYER_PRIVATE_KEY (or BUYER_PRIVATE_KEY)');
  assert(sellerPk, 'Missing env var: TEST_SELLER_PRIVATE_KEY (or SELLER_PRIVATE_KEY)');
  assert(feeWithdrawerPk, 'Missing env var: TEST_FEE_WITHDRAWER_PRIVATE_KEY (or FEE_WITHDRAWER_PRIVATE_KEY)');

  const buyer = new ethers.Wallet(buyerPk, provider);
  const seller = new ethers.Wallet(sellerPk, provider);
  const feeWithdrawer = new ethers.Wallet(feeWithdrawerPk, provider);

  const buyerAddr = await buyer.getAddress();
  const sellerAddr = await seller.getAddress();
  const feeWithdrawerAddr = await feeWithdrawer.getAddress();

  console.log(`\n🧪 Contract insufficient balance behaviors (Base Sepolia)`);
  console.log(`- EscrowVault: ${escrowVaultAddr}`);
  console.log(`  - ${basescanAddressLink(escrowVaultAddr)}`);
  console.log(`- tokenForFees: ${tokenForFees}`);
  console.log(`  - ${basescanAddressLink(tokenForFees)}`);
  console.log(`- buyer: ${buyerAddr}`);
  console.log(`- seller: ${sellerAddr}`);
  console.log(`- feeWithdrawer: ${feeWithdrawerAddr}`);
  console.log(`- SEND_REVERT_TXS=${SEND_REVERT_TXS}`);

  const escrow: any = await hre.ethers.getContractAt('EscrowVault', escrowVaultAddr);
  const escrowIface = escrow.interface;

  const token = await hre.ethers.getContractAt(
    [
      'function balanceOf(address) view returns (uint256)',
      'function symbol() view returns (string)',
    ],
    tokenForFees
  );
  const tokenAny: any = token;

  const sym = await tokenAny.symbol().catch(() => '');
  const feeAddr: string = await escrow.escrowFeeAddress();
  const feeBps: bigint = await escrow.escrowFee();

  console.log(`- EscrowVault.escrowFeeAddress: ${feeAddr}`);
  console.log(`- EscrowVault.escrowFee (bps): ${feeBps.toString()}`);
  console.log(`- Token symbol: ${sym}`);

  // ============
  // 1) Start with attempt to withdraw fees
  // ============
  console.log(`\n### 1) withdrawFees(${tokenForFees}) preflight + expected behavior`);
  {
    // totalFeesPerToken is public mapping on EscrowVault.
    const feeAmount: bigint = await retry('totalFeesPerToken', async () => escrow.totalFeesPerToken(tokenForFees));
    const vaultBal: bigint = await retry('token.balanceOf(vault)', async () => tokenAny.balanceOf(escrowVaultAddr));

    console.log(`- totalFeesPerToken: ${feeAmount.toString()}`);
    console.log(`- token.balanceOf(vault): ${vaultBal.toString()}`);

    // Determine expected result:
    // - feeAmount == 0 => revert NoFeesToWithdraw
    // - feeAmount > 0 and vaultBal < feeAmount => revert InsufficientContractBalance(token, required, available)
    // - feeAmount > 0 and vaultBal >= feeAmount => success (requires ROLE_FEE_RECIPIENT)

    try {
      await escrow.connect(feeWithdrawer).withdrawFees.staticCall(tokenForFees);
      console.log(`- staticCall: success (no revert)`);
      if (feeAmount === 0n) {
        console.log(`WARN: expected NoFeesToWithdraw but staticCall succeeded; check tokenForFees selection.`);
      }
    } catch (e: any) {
      const msg = e?.shortMessage || e?.reason || e?.message || String(e);
      console.log(`- staticCall reverted as expected: ${msg}`);
    }

    if (SEND_REVERT_TXS) {
      console.log(`- sending tx (may revert; costs gas)`);
      await escrow
        .connect(feeWithdrawer)
        .withdrawFees(tokenForFees)
        .then((tx: any) => tx.wait())
        .then((rcpt: any) => {
          console.log(`  tx mined: ${rcpt?.hash || '(unknown)'}`);
        })
        .catch((e: any) => {
          const msg = e?.shortMessage || e?.reason || e?.message || String(e);
          console.log(`  tx reverted (expected in some cases): ${msg}`);
        });
    }

    if (feeBps === 0n) {
      console.log(
        `NOTE: EscrowVault.escrowFee is 0 bps on this deployment, so new escrows won't accrue fees. ` +
          `WithdrawFees deficit scenarios are unlikely unless fees were created historically for this token.`
      );
    }
  }

  // ============
  // 2) Reproduce a real balance deficit using a fee-on-transfer token
  //    This makes EscrowVault receive less than requested on createEscrow, but it still
  //    records amountAfterFee based on the requested amount. On release, token.transfer
  //    reverts due to insufficient balance, so EscrowVault falls back to claimable.
  // ============
  console.log(`\n### 2) Fee-on-transfer token deficit: release falls back to claimable, withdraw may revert`);
  {
    const factory = await hre.ethers.getContractFactory('FeeOnTransferERC20Mock', buyer);
    const t = await factory.deploy('FeeOnTransfer Mock', 'FOT', 500); // 5% burn on transfer
    console.log(`- deploy token tx: ${t.deploymentTransaction()?.hash || '(unknown)'}`);
    const tokenContract = await t.waitForDeployment();
    const fotAddr = await tokenContract.getAddress();
    console.log(`- FeeOnTransfer token: ${fotAddr}`);
    console.log(`  - ${basescanAddressLink(fotAddr)}`);

    // Base Sepolia RPC endpoints are often load-balanced; immediately after deployment, a read
    // can hit a node that doesn't have the new bytecode yet (returns "0x").
    // Wait until getCode is non-empty before calling ERC20 view functions.
    await retry('FeeOnTransfer token code present', async () => {
      const code = await provider.getCode(fotAddr);
      if (!code || code === '0x') throw new Error('no code yet');
      return true;
    });

    const fot: any = await hre.ethers.getContractAt(
      [
        'function decimals() view returns (uint8)',
        'function balanceOf(address) view returns (uint256)',
        'function approve(address,uint256) returns (bool)',
        'function mint(address,uint256)',
      ],
      fotAddr
    );

    const decimals = await retry('fot.decimals()', async () => Number(await fot.decimals())).catch(() => 18);
    const amount = ethers.parseUnits('100', decimals);

    await fot.connect(buyer).mint(buyerAddr, amount * 2n);
    const buyerBal: bigint = await retry('fot.balanceOf(buyer)', async () => fot.balanceOf(buyerAddr));
    console.log(`- buyer FOT balance: ${buyerBal.toString()}`);

    const approveTx = await fot.connect(buyer).approve(escrowVaultAddr, ethers.MaxUint256);
    await approveTx.wait();

    const settings: EscrowSettings = {
      customResolver: ethers.ZeroAddress,
      yieldPreset: 0,
      autoReleaseTime: 0n,
      autoCancelTime: 0n,
    };

    const createTx = await escrow.connect(buyer).createEscrow(fotAddr, sellerAddr, amount, settings);
    console.log(`- createEscrow tx: ${createTx.hash}`);
    const createRcpt = await createTx.wait();
    assert(createRcpt, 'Missing receipt for createEscrow');
    assert(Number(createRcpt.status || 0) === 1, 'createEscrow reverted unexpectedly');

    const created = (createRcpt.logs as any[])
      .filter((l: any) => (l.address || '').toLowerCase() === escrowVaultAddr.toLowerCase())
      .map((l: any) => {
        try {
          return escrowIface.parseLog(l);
        } catch {
          return null;
        }
      })
      .find((p: any) => p?.name === 'EscrowCreated');
    assert(created, 'Could not find EscrowCreated');

    const workflowId = created.args.workflowId as bigint;
    const amountAfterFee = created.args.amountAfterFee as bigint;

    console.log(`- workflowId: ${workflowId.toString()}`);
    console.log(`- amountAfterFee (recorded): ${amountAfterFee.toString()}`);

    const vaultBalAfterCreate: bigint = await fot.balanceOf(escrowVaultAddr);
    console.log(`- vault FOT balance after create: ${vaultBalAfterCreate.toString()}`);
    if (vaultBalAfterCreate < amountAfterFee) {
      console.log(`- as expected: vault balance < amountAfterFee (deficit introduced by fee-on-transfer)`);
    } else {
      console.log(`WARN: vault balance >= amountAfterFee; deficit may not reproduce as expected`);
    }

    const releaseTx = await escrow.connect(buyer).releaseEscrowTransfer(workflowId);
    console.log(`- releaseEscrowTransfer tx: ${releaseTx.hash}`);
    const releaseRcpt = await releaseTx.wait();
    assert(releaseRcpt, 'Missing receipt for releaseEscrowTransfer');
    assert(Number(releaseRcpt.status || 0) === 1, 'releaseEscrowTransfer reverted unexpectedly');

    // Give RPC a moment; Base Sepolia nodes can be inconsistent immediately after txs.
    await sleep(POLL_SECONDS * 1000);

    const claimable: bigint = await retry('claimableBalances', async () => escrow.claimableBalances(workflowId, sellerAddr));
    console.log(`- claimableBalances[seller]: ${claimable.toString()}`);
    assert(claimable === amountAfterFee, 'expected claimable == amountAfterFee (push transfer should have failed)');

    // Withdraw attempt should revert because vault truly does not hold enough token to pay.
    // (This is an important edge-case to observe with fee-on-transfer / deflationary tokens.)
    try {
      await escrow.connect(seller).withdrawEscrow.staticCall(workflowId);
      console.log(`WARN: withdrawEscrow.staticCall unexpectedly succeeded; deficit may not exist on this run.`);
    } catch (e: any) {
      const msg = e?.shortMessage || e?.reason || e?.message || String(e);
      console.log(`- withdrawEscrow.staticCall reverted (expected under deficit): ${msg}`);
    }

    if (SEND_REVERT_TXS) {
      console.log(`- sending withdrawEscrow tx (expected revert; costs gas)`);
      await escrow
        .connect(seller)
        .withdrawEscrow(workflowId)
        .then((tx: any) => tx.wait())
        .then(() => {
          console.log(`WARN: withdrawEscrow tx succeeded unexpectedly`);
        })
        .catch((e: any) => {
          const msg = e?.shortMessage || e?.reason || e?.message || String(e);
          console.log(`  withdrawEscrow tx reverted (expected): ${msg}`);
        });
    }
  }

  console.log(`\n✅ Insufficient-balance behavior checks completed.`);
}

main().catch((err) => {
  console.error(`\n❌ Insufficient-balance test failed:\n${err?.stack || err?.message || err}`);
  process.exitCode = 1;
});

