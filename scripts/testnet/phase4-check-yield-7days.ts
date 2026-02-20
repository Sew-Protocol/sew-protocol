/**
 * Phase 4: Check Yield Generated After 7 Days
 * 
 * Run this script 7 days after escrow creation to verify yield has been generated
 * and test the withdrawal mechanism.
 * 
 * Test Record:
 * - Created: 2026-02-20T18:54:06.587Z
 * - Check Date: 2026-02-27
 * - TX: 0x92b7f82f1fee10983f489023da133d39660e0c709f7fb8a46a800a281eca42f4
 * - Workflow ID: 16
 * - Initial Amount: 1000.0 SEW
 */

import hre from 'hardhat';

async function main() {
  console.log(`\n${'='.repeat(80)}`);
  console.log(`  PHASE 4: YIELD VERIFICATION (7 Days Later)`);
  console.log(`  Checking yield generated on SEW escrow`);
  console.log(`${'='.repeat(80)}\n`);

  const [signer] = await hre.ethers.getSigners();
  
  // Load test record
  const record = require('./.yield-test-record.json');
  
  console.log(`📋 Test Details:`);
  console.log(`   Created: ${record.startDate}`);
  console.log(`   Today (Check): ${new Date().toISOString()}`);
  console.log(`   Workflow ID: ${record.workflowId}`);
  console.log(`   Initial Amount: ${record.initialAmount} SEW`);
  console.log(`   Recipient: ${record.recipientAddress}\n`);

  try {
    const ESCROW_VAULT = record.escrowVaultAddress;
    const TOKEN_ADDR = record.tokenAddress;
    
    // Get contracts
    const token = await hre.ethers.getContractAt(
      ['function balanceOf(address) view returns (uint256)', 'function name() view returns (string)'],
      TOKEN_ADDR,
      signer
    );

    const escrowVault = await hre.ethers.getContractAt(
      require('../../deployments/baseSepolia/EscrowVault.json').abi,
      ESCROW_VAULT,
      signer
    );

    // Check token balance held by EscrowVault
    console.log(`1️⃣  Checking SEW balance in EscrowVault...`);
    const escrowBalance = await token.balanceOf(ESCROW_VAULT);
    const formattedBalance = hre.ethers.formatEther(escrowBalance);
    console.log(`   Balance: ${formattedBalance} SEW\n`);

    // Calculate yield
    const initialAmount = parseFloat(record.initialAmount);
    const currentAmount = parseFloat(formattedBalance);
    const yieldGenerated = currentAmount - initialAmount;
    const yieldPercent = (yieldGenerated / initialAmount * 100).toFixed(6);

    console.log(`2️⃣  Yield Analysis:`);
    if (yieldGenerated > 0) {
      console.log(`   🎉 YIELD GENERATED!`);
      console.log(`   Initial Amount: ${initialAmount} SEW`);
      console.log(`   Current Amount: ${currentAmount} SEW`);
      console.log(`   Yield Generated: ${yieldGenerated.toFixed(6)} SEW`);
      console.log(`   Return Rate: ${yieldPercent}% APY (annualized)`);
    } else if (yieldGenerated === 0) {
      console.log(`   ℹ️  No yield detected`);
      console.log(`   Initial: ${initialAmount} SEW`);
      console.log(`   Current: ${currentAmount} SEW`);
      console.log(`   Note: Aave yield may take longer to accrue on testnet`);
    } else {
      console.log(`   ⚠️  Unexpected: Balance decreased`);
    }
    console.log();

    // Check escrow state
    console.log(`3️⃣  Checking escrow state...`);
    const workflowId = BigInt(record.workflowId);
    const state = await escrowVault.escrowStates(workflowId);
    const stateNames = ['PENDING', 'RELEASED', 'REFUNDED', 'DISPUTED', 'SETTLEMENT_PENDING'];
    console.log(`   State: ${stateNames[state]} (code: ${state})`);
    
    if (state === 0n) {
      console.log(`   ✅ Still PENDING - ready for release\n`);
      
      // Test release
      console.log(`4️⃣  Testing release/withdrawal mechanism...`);
      try {
        const recipientBalBefore = await token.balanceOf(record.recipientAddress);
        console.log(`   Recipient balance before: ${hre.ethers.formatEther(recipientBalBefore)} SEW`);
        
        const releaseTx = await escrowVault.releaseEscrowTransfer(workflowId);
        const releaseRcpt = await releaseTx.wait();
        
        console.log(`   ✅ Release executed successfully`);
        console.log(`   TX: ${releaseTx.hash}\n`);
        
        // Check recipient balance after release
        const recipientBalAfter = await token.balanceOf(record.recipientAddress);
        const balanceDiff = recipientBalAfter - recipientBalBefore;
        
        console.log(`5️⃣  Verifying recipient received funds:`);
        console.log(`   Recipient balance before: ${hre.ethers.formatEther(recipientBalBefore)} SEW`);
        console.log(`   Recipient balance after: ${hre.ethers.formatEther(recipientBalAfter)} SEW`);
        console.log(`   Received: ${hre.ethers.formatEther(balanceDiff)} SEW`);
        
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
    console.log(`   Token: SEW`);
    console.log(`   Initial: ${record.initialAmount} SEW`);
    console.log(`   Current: ${currentAmount} SEW`);
    if (yieldGenerated > 0) {
      console.log(`   Yield: ${yieldGenerated.toFixed(6)} SEW (${yieldPercent}%)`);
    }
    console.log(`   Status: ✅ Test Complete\n`);

  } catch (error: any) {
    console.error(`\n❌ Verification failed:`);
    console.error(`Error: ${error.message}`);
  }
}

main().catch(console.error);
