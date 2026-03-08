/**
 * Phase 4: Check Yield Generated After 7 Days
 *
 * Run this script 7 days after escrow creation to verify yield has been generated
 * and test the withdrawal mechanism.
 *
 * IMPORTANT: This test requires a USDC escrow (or other Aave-supported token)
 * since SEW has no Aave market and cannot generate yield.
 */

import hre from 'hardhat';

async function main() {
  console.log(`\n${'='.repeat(80)}`);
  console.log(`  PHASE 4: YIELD VERIFICATION (7 Days Later)`);
  console.log(`  Checking yield generated on USDC escrow`);
  console.log(`${'='.repeat(80)}\n`);

  const [signer] = await hre.ethers.getSigners();

  const record = require('./.yield-test-record.json');

  const USDC_DECIMALS = 6;
  const isUSDC = record.tokenSymbol === 'USDC';
  const decimals = isUSDC ? USDC_DECIMALS : 18;

  console.log(`📋 Test Details:`);
  console.log(`   Created: ${record.startDate}`);
  console.log(`   Today (Check): ${new Date().toISOString()}`);
  console.log(`   Workflow ID: ${record.workflowId}`);
  console.log(`   Token: ${record.tokenSymbol}`);
  console.log(`   Initial Amount: ${record.initialAmount} ${record.tokenSymbol}`);
  console.log(`   Recipient: ${record.recipientAddress}\n`);

  try {
    const ESCROW_VAULT = record.escrowVaultAddress;
    const TOKEN_ADDR = record.tokenAddress;
    const AAVE_YIELD_MODULE = record.aaveYieldModule;

    const token = await hre.ethers.getContractAt(
      [
        'function balanceOf(address) view returns (uint256)',
        'function name() view returns (string)',
      ],
      TOKEN_ADDR,
      signer,
    );

    const escrowVault = await hre.ethers.getContractAt(
      require('../../deployments/baseSepolia/EscrowVault.json').abi,
      ESCROW_VAULT,
      signer,
    );

    let aTokenAddress = '0x';
    try {
      const aaveYieldModuleABI = [
        'function getATokenAddress(address token) external view returns (address)',
      ];
      const aaveModule = await hre.ethers.getContractAt(
        aaveYieldModuleABI,
        AAVE_YIELD_MODULE,
        signer,
      );
      aTokenAddress = await aaveModule.getATokenAddress(TOKEN_ADDR);
    } catch (e) {
      console.log(`   ⚠️  Could not get aToken address - checking token directly`);
    }

    if (aTokenAddress === '0x0000000000000000000000000000000000000000' || aTokenAddress === '0x') {
      console.log(`   ❌ Token ${record.tokenSymbol} is NOT configured in AaveYieldModule!`);
      console.log(`   This token cannot generate yield on Aave.`);
      console.log(`   Expected: USDC, USDT, DAI, WETH, WBTC etc.\n`);

      console.log(`   Checking underlying token balance in escrow...`);
      const escrowBalance = await token.balanceOf(ESCROW_VAULT);
      console.log(
        `   Balance: ${hre.ethers.formatUnits(escrowBalance, decimals)} ${record.tokenSymbol}\n`,
      );

      console.log(
        `   ℹ️  NOTE: If balance increased from initial, it may be from other transactions, not yield.`,
      );
      console.log(
        `   The original test used SEW which has NO Aave market - yield test was invalid.\n`,
      );
      return;
    }

    console.log(`   ✅ Token configured: aToken = ${aTokenAddress}\n`);

    console.log(`2️⃣  Checking aToken balance (principal + yield in Aave)...`);
    const aToken = await hre.ethers.getContractAt(
      ['function balanceOf(address) view returns (uint256)'],
      aTokenAddress,
      signer,
    );

    const aTokenBalance = await aToken.balanceOf(ESCROW_VAULT);
    const formattedATokenBalance = hre.ethers.formatUnits(aTokenBalance, decimals);
    console.log(`   aToken Balance: ${formattedATokenBalance} a${record.tokenSymbol}\n`);

    console.log(`3️⃣  Checking underlying token balance in EscrowVault...`);
    const escrowBalance = await token.balanceOf(ESCROW_VAULT);
    const formattedBalance = hre.ethers.formatUnits(escrowBalance, decimals);
    console.log(`   Balance: ${formattedBalance} ${record.tokenSymbol}\n`);

    const initialAmount = parseFloat(record.initialAmount);

    if (parseFloat(formattedATokenBalance) > initialAmount) {
      const yieldGenerated = parseFloat(formattedATokenBalance) - initialAmount;
      const yieldPercent = ((yieldGenerated / initialAmount) * 100).toFixed(4);

      console.log(`   🎉 YIELD GENERATED!`);
      console.log(`   Initial Amount: ${initialAmount} ${record.tokenSymbol}`);
      console.log(`   Current (aToken): ${formattedATokenBalance} a${record.tokenSymbol}`);
      console.log(`   Yield Generated: ${yieldGenerated.toFixed(6)} ${record.tokenSymbol}`);
      console.log(`   Return Rate: ${yieldPercent}% over period\n`);
    } else {
      console.log(`   ℹ️  No yield detected yet (or funds not in Aave)`);
      console.log(`   Initial: ${initialAmount} ${record.tokenSymbol}`);
      console.log(`   Current: ${formattedATokenBalance} a${record.tokenSymbol}\n`);
    }

    console.log(`4️⃣  Checking escrow state...`);
    const workflowId = BigInt(record.workflowId);
    const escrowData = await escrowVault.escrowTransfers(workflowId);
    const state = escrowData[7];
    const stateNames = ['NONE', 'PENDING', 'RELEASED', 'REFUNDED', 'DISPUTED', 'RESOLVED'];
    console.log(`   State: ${stateNames[state]} (code: ${state})`);

    if (state === 1n) {
      console.log(`   ✅ Still PENDING - ready for release\n`);

      console.log(`5️⃣  Testing release/withdrawal mechanism...`);
      try {
        const recipientBalBefore = await token.balanceOf(record.recipientAddress);
        console.log(
          `   Recipient balance before: ${hre.ethers.formatUnits(recipientBalBefore, decimals)} ${record.tokenSymbol}`,
        );

        const releaseTx = await escrowVault.releaseEscrowTransfer(workflowId);
        const releaseRcpt = await releaseTx.wait();

        console.log(`   ✅ Release executed successfully`);
        console.log(`   TX: ${releaseTx.hash}\n`);

        const recipientBalAfter = await token.balanceOf(record.recipientAddress);
        const balanceDiff = recipientBalAfter - recipientBalBefore;

        console.log(`6️⃣  Verifying recipient received funds:`);
        console.log(
          `   Recipient balance before: ${hre.ethers.formatUnits(recipientBalBefore, decimals)} ${record.tokenSymbol}`,
        );
        console.log(
          `   Recipient balance after: ${hre.ethers.formatUnits(recipientBalAfter, decimals)} ${record.tokenSymbol}`,
        );
        console.log(
          `   Received: ${hre.ethers.formatUnits(balanceDiff, decimals)} ${record.tokenSymbol}`,
        );

        if (balanceDiff > 0n) {
          console.log(`   ✅ WITHDRAWAL SUCCESSFUL\n`);
        }
      } catch (error: any) {
        console.log(`   ⚠️  Release failed`);
        console.log(`   Error: ${error.message}\n`);
      }
    } else {
      console.log(`   ℹ️  Escrow already ${stateNames[state]}`);
    }

    console.log(`\n${'='.repeat(80)}`);
    console.log(`  ✅ YIELD VERIFICATION COMPLETE`);
    console.log(`${'='.repeat(80)}\n`);

    console.log(`📊 FINAL SUMMARY:`);
    console.log(`   Escrow ID: ${record.workflowId}`);
    console.log(`   Token: ${record.tokenSymbol}`);
    console.log(`   Initial: ${record.initialAmount} ${record.tokenSymbol}`);
    console.log(`   aToken Balance: ${formattedATokenBalance} a${record.tokenSymbol}`);
    if (parseFloat(formattedATokenBalance) > initialAmount) {
      const yieldGenerated = parseFloat(formattedATokenBalance) - initialAmount;
      const yieldPercent = ((yieldGenerated / initialAmount) * 100).toFixed(4);
      console.log(
        `   Yield: ${yieldGenerated.toFixed(6)} ${record.tokenSymbol} (${yieldPercent}%)`,
      );
    }
    console.log(`   Status: ✅ Test Complete\n`);
  } catch (error: any) {
    console.error(`\n❌ Verification failed:`);
    console.error(`Error: ${error.message}`);
  }
}

main().catch(console.error);
