/**
 * Phase 4: Yield Generation Test with SEW Token
 * 
 * This script creates a yield-enabled escrow with SEW (available testnet token)
 * and documents:
 * - Exact transaction details
 * - How to check yield in 7 days
 * - How to verify yield withdrawal
 */

import hre from 'hardhat';
import * as fs from 'fs';

interface YieldTestRecord {
  startDate: string;
  blockNumber: number;
  blockTimestamp: number;
  escrowCreationTx: string;
  workflowId: string;
  initialAmount: string;
  tokenSymbol: string;
  tokenAddress: string;
  escrowVaultAddress: string;
  aaveYieldModule: string;
  aavePool: string;
  buyerAddress: string;
  recipientAddress: string;
  yieldCheckDate7Days: string;
  instructions: string[];
  checkCommands: string[];
}

async function main() {
  console.log(`\n${'='.repeat(80)}`);
  console.log(`  PHASE 4: YIELD GENERATION TEST WITH SEW TOKEN`);
  console.log(`  Creating yield-enabled escrow and documenting verification process`);
  console.log(`${'='.repeat(80)}\n`);

  const [signer] = await hre.ethers.getSigners();
  const buyerAddr = await signer.getAddress();
  
  // Configuration
  const SEW_ADDR = '0x62BD47154D0b5Fe435F220E1294405040102b2ba'; // SEW on Base Sepolia
  const ESCROW_VAULT = '0x13b8b7572c72b46879662BFEA53851cBeD3bC47a';
  const AAVE_MODULE = '0x084DD3BA96B14Ce07746E7c6AF23454dcbB65C01';
  const AAVE_POOL = '0x8bAB6d1b75f19e9eD9fCe8b9BD338844fF79aE27';
  
  const recipientAddr = '0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee'; // Different address for recipient
  const amount = hre.ethers.parseEther('1000'); // 1000 SEW

  console.log(`📋 Configuration:`);
  console.log(`   Buyer: ${buyerAddr}`);
  console.log(`   Recipient: ${recipientAddr}`);
  console.log(`   Amount: 1000 SEW`);
  console.log(`   Token: SEW (testnet native token)`);
  console.log(`   Yield Enabled: YES (yieldPreset=1 = Aave)`);
  console.log(`   EscrowVault: ${ESCROW_VAULT}`);
  console.log(`   AaveYieldModule: ${AAVE_MODULE}`);
  console.log(`   Aave Pool: ${AAVE_POOL}\n`);

  try {
    // Get contract instances
    const sew = await hre.ethers.getContractAt(
      ['function approve(address,uint256) returns (bool)', 'function balanceOf(address) view returns (uint256)'],
      SEW_ADDR,
      signer
    );

    const escrowVault = await hre.ethers.getContractAt(
      require('../../deployments/baseSepolia/EscrowVault.json').abi,
      ESCROW_VAULT,
      signer
    );

    // Check SEW balance
    console.log(`1️⃣  Checking SEW balance...`);
    const balanceBefore = await sew.balanceOf(buyerAddr);
    console.log(`   Balance: ${hre.ethers.formatEther(balanceBefore)} SEW`);

    if (balanceBefore < amount) {
      throw new Error(`Insufficient balance. Have ${hre.ethers.formatEther(balanceBefore)}, need ${hre.ethers.formatEther(amount)}`);
    }
    console.log(`   ✅ Sufficient balance\n`);

    // Approve EscrowVault
    console.log(`2️⃣  Approving SEW for EscrowVault...`);
    const approveTx = await sew.approve(ESCROW_VAULT, amount);
    const approveRcpt = await approveTx.wait();
    console.log(`   ✅ Approved (TX: ${approveTx.hash})\n`);

    // Create yield-enabled escrow
    console.log(`3️⃣  Creating YIELD-ENABLED escrow with SEW...`);
    const settings = {
      customResolver: hre.ethers.ZeroAddress,
      releaseAddress: hre.ethers.ZeroAddress,
      yieldPreset: 1, // TO_SENDER = Aave yield to recipient
      autoReleaseTime: 0,
      autoCancelTime: 0
    };

    console.log(`   Settings: yieldPreset=1 (Aave yield will be generated)`);

    const createTx = await escrowVault.createEscrow(
      SEW_ADDR,
      recipientAddr,
      amount,
      settings
    );

    const createRcpt = await createTx.wait();
    console.log(`   ✅ Escrow created!\n`);

    // Parse logs to get workflowId
    const event = createRcpt?.logs
      .map(l => {
        try {
          return escrowVault.interface.parseLog(l as any);
        } catch {
          return null;
        }
      })
      .find(p => p?.name === 'EscrowCreated');

    if (!event) throw new Error('EscrowCreated event not found');

    const workflowId = event.args[0];
    const amountAfterFee = event.args[5];
    const createdBlock = createRcpt?.blockNumber;
    const blockData = await hre.ethers.provider.getBlock(createdBlock!);
    const createdTimestamp = blockData?.timestamp;

    console.log(`📊 Escrow Created:`);
    console.log(`   Transaction Hash: ${createTx.hash}`);
    console.log(`   Block Number: ${createdBlock}`);
    console.log(`   Timestamp: ${createdTimestamp} (${new Date(createdTimestamp! * 1000).toISOString()})`);
    console.log(`   Workflow ID: ${workflowId}`);
    console.log(`   Amount: ${hre.ethers.formatEther(amountAfterFee)} SEW`);
    console.log(`   Yield Preset: 1 (Aave - yields to recipient)\n`);

    // Calculate 7-day future date
    const startDate = new Date();
    const checkDate = new Date(startDate.getTime() + 7 * 24 * 60 * 60 * 1000);
    const checkDateISO = checkDate.toISOString().split('T')[0];

    // Build record
    const record: YieldTestRecord = {
      startDate: startDate.toISOString(),
      blockNumber: createdBlock!,
      blockTimestamp: createdTimestamp!,
      escrowCreationTx: createTx.hash,
      workflowId: workflowId.toString(),
      initialAmount: hre.ethers.formatEther(amountAfterFee),
      tokenSymbol: 'SEW',
      tokenAddress: SEW_ADDR,
      escrowVaultAddress: ESCROW_VAULT,
      aaveYieldModule: AAVE_MODULE,
      aavePool: AAVE_POOL,
      buyerAddress: buyerAddr,
      recipientAddress: recipientAddr,
      yieldCheckDate7Days: checkDateISO,
      instructions: [
        `1. Return on ${checkDateISO} (exactly 7 days from now)`,
        ``,
        `2. Run the yield check script:`,
        `   pnpm hardhat run scripts/testnet/phase4-check-yield-7days.ts --network baseSepolia`,
        ``,
        `3. The script will:`,
        `   - Check the SEW balance held by EscrowVault`,
        `   - Calculate yield generated (current - initial)`,
        `   - Show yield percentage return`,
        `   - Test release and withdrawal mechanisms`,
        `   - Verify funds reach recipient`,
      ],
      checkCommands: [
        `# Manual check: View escrow transaction on BaseScan`,
        `https://sepolia.basescan.org/tx/${createTx.hash}`,
        ``,
        `# Check SEW balance held by EscrowVault`,
        `cast call ${SEW_ADDR} "balanceOf(address)(uint256)" ${ESCROW_VAULT} --rpc-url https://sepolia.base.org`,
        ``,
        `# Check escrow state`,
        `cast call ${ESCROW_VAULT} "escrowStates(uint256)(uint8)" ${workflowId} --rpc-url https://sepolia.base.org`,
        `# Expected output: 0 = PENDING (escrow not yet released)`,
        ``,
        `# Check recipient balance`,
        `cast call ${SEW_ADDR} "balanceOf(address)(uint256)" ${recipientAddr} --rpc-url https://sepolia.base.org`,
      ],
    };

    // Save record
    const recordPath = 'scripts/testnet/.yield-test-record.json';
    fs.writeFileSync(recordPath, JSON.stringify(record, null, 2));
    console.log(`📝 Test record saved to: ${recordPath}\n`);

    // Display instructions
    console.log(`${'='.repeat(80)}`);
    console.log(`  HOW TO VERIFY YIELD IN 7 DAYS (${checkDateISO})`);
    console.log(`${'='.repeat(80)}\n`);

    console.log(`✅ TRANSACTION DETAILS (SAVE THESE):\n`);
    console.log(`   Start Date: ${record.startDate}`);
    console.log(`   Check Date: ${record.yieldCheckDate7Days} ← Return on this date!`);
    console.log(`   Creation TX: ${record.escrowCreationTx}`);
    console.log(`   Workflow ID: ${record.workflowId}`);
    console.log(`   Block: ${record.blockNumber}`);
    console.log(`   Initial Amount: ${record.initialAmount} SEW\n`);

    console.log(`📋 VERIFICATION PROCESS:\n`);
    record.instructions.forEach((instr) => {
      console.log(`${instr}`);
    });

    console.log(`\n\n🔍 MANUAL VERIFICATION COMMANDS:\n`);
    record.checkCommands.forEach((cmd) => {
      console.log(`${cmd}`);
    });

    // Create the follow-up script
    createFollowUpScript(record);
    console.log(`\n✅ Created follow-up script: scripts/testnet/phase4-check-yield-7days.ts\n`);

    console.log(`${'='.repeat(80)}`);
    console.log(`  ✅ PHASE 4 YIELD GENERATION TEST INITIATED`);
    console.log(`${'='.repeat(80)}\n`);

    console.log(`📌 IMPORTANT REMINDER:\n`);
    console.log(`   Date to Check Yield: ${checkDateISO}`);
    console.log(`   Command to Run:\n`);
    console.log(`   pnpm hardhat run scripts/testnet/phase4-check-yield-7days.ts --network baseSepolia\n`);
    console.log(`   Transaction: ${record.escrowCreationTx}\n`);

  } catch (error: any) {
    console.error(`\n❌ Test failed:`);
    console.error(`Error: ${error.message}`);
    if (error.data) {
      console.error(`Data: ${error.data}`);
    }
  }
}

function createFollowUpScript(record: YieldTestRecord) {
  const script = `/**
 * Phase 4: Check Yield Generated After 7 Days
 * 
 * Run this script 7 days after escrow creation to verify yield has been generated
 * and test the withdrawal mechanism.
 * 
 * Test Record:
 * - Created: ${record.startDate}
 * - Check Date: ${record.yieldCheckDate7Days}
 * - TX: ${record.escrowCreationTx}
 * - Workflow ID: ${record.workflowId}
 * - Initial Amount: ${record.initialAmount} ${record.tokenSymbol}
 */

import hre from 'hardhat';

async function main() {
  console.log(\`\\n\${'='.repeat(80)}\`);
  console.log(\`  PHASE 4: YIELD VERIFICATION (7 Days Later)\`);
  console.log(\`  Checking yield generated on ${record.tokenSymbol} escrow\`);
  console.log(\`\${'='.repeat(80)}\\n\`);

  const [signer] = await hre.ethers.getSigners();
  
  // Load test record
  const record = require('./.yield-test-record.json');
  
  console.log(\`📋 Test Details:\`);
  console.log(\`   Created: \${record.startDate}\`);
  console.log(\`   Today (Check): \${new Date().toISOString()}\`);
  console.log(\`   Workflow ID: \${record.workflowId}\`);
  console.log(\`   Initial Amount: \${record.initialAmount} ${record.tokenSymbol}\`);
  console.log(\`   Recipient: \${record.recipientAddress}\\n\`);

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
    console.log(\`1️⃣  Checking ${record.tokenSymbol} balance in EscrowVault...\`);
    const escrowBalance = await token.balanceOf(ESCROW_VAULT);
    const formattedBalance = hre.ethers.formatEther(escrowBalance);
    console.log(\`   Balance: \${formattedBalance} ${record.tokenSymbol}\\n\`);

    // Calculate yield
    const initialAmount = parseFloat(record.initialAmount);
    const currentAmount = parseFloat(formattedBalance);
    const yieldGenerated = currentAmount - initialAmount;
    const yieldPercent = (yieldGenerated / initialAmount * 100).toFixed(6);

    console.log(\`2️⃣  Yield Analysis:\`);
    if (yieldGenerated > 0) {
      console.log(\`   🎉 YIELD GENERATED!\`);
      console.log(\`   Initial Amount: \${initialAmount} ${record.tokenSymbol}\`);
      console.log(\`   Current Amount: \${currentAmount} ${record.tokenSymbol}\`);
      console.log(\`   Yield Generated: \${yieldGenerated.toFixed(6)} ${record.tokenSymbol}\`);
      console.log(\`   Return Rate: \${yieldPercent}% APY (annualized)\`);
    } else if (yieldGenerated === 0) {
      console.log(\`   ℹ️  No yield detected\`);
      console.log(\`   Initial: \${initialAmount} ${record.tokenSymbol}\`);
      console.log(\`   Current: \${currentAmount} ${record.tokenSymbol}\`);
      console.log(\`   Note: Aave yield may take longer to accrue on testnet\`);
    } else {
      console.log(\`   ⚠️  Unexpected: Balance decreased\`);
    }
    console.log();

    // Check escrow state
    console.log(\`3️⃣  Checking escrow state...\`);
    const workflowId = BigInt(record.workflowId);
    const state = await escrowVault.escrowStates(workflowId);
    const stateNames = ['PENDING', 'RELEASED', 'REFUNDED', 'DISPUTED', 'SETTLEMENT_PENDING'];
    console.log(\`   State: \${stateNames[state]} (code: \${state})\`);
    
    if (state === 0n) {
      console.log(\`   ✅ Still PENDING - ready for release\\n\`);
      
      // Test release
      console.log(\`4️⃣  Testing release/withdrawal mechanism...\`);
      try {
        const recipientBalBefore = await token.balanceOf(record.recipientAddress);
        console.log(\`   Recipient balance before: \${hre.ethers.formatEther(recipientBalBefore)} ${record.tokenSymbol}\`);
        
        const releaseTx = await escrowVault.releaseEscrowTransfer(workflowId);
        const releaseRcpt = await releaseTx.wait();
        
        console.log(\`   ✅ Release executed successfully\`);
        console.log(\`   TX: \${releaseTx.hash}\\n\`);
        
        // Check recipient balance after release
        const recipientBalAfter = await token.balanceOf(record.recipientAddress);
        const balanceDiff = recipientBalAfter - recipientBalBefore;
        
        console.log(\`5️⃣  Verifying recipient received funds:\`);
        console.log(\`   Recipient balance before: \${hre.ethers.formatEther(recipientBalBefore)} ${record.tokenSymbol}\`);
        console.log(\`   Recipient balance after: \${hre.ethers.formatEther(recipientBalAfter)} ${record.tokenSymbol}\`);
        console.log(\`   Received: \${hre.ethers.formatEther(balanceDiff)} ${record.tokenSymbol}\`);
        
        if (balanceDiff > 0n) {
          console.log(\`   ✅ WITHDRAWAL SUCCESSFUL\\n\`);
        }
      } catch (error: any) {
        console.log(\`   ⚠️  Release failed\`);
        console.log(\`   Error: \${error.message}\\n\`);
      }
    } else {
      console.log(\`   ℹ️  Escrow already \${stateNames[state]}\`);
    }

    console.log(\`\\n\${'='.repeat(80)}\`);
    console.log(\`  ✅ YIELD VERIFICATION COMPLETE\`);
    console.log(\`\${'='.repeat(80)}\\n\`);

    console.log(\`📊 FINAL SUMMARY:\`);
    console.log(\`   Escrow ID: \${record.workflowId}\`);
    console.log(\`   Token: ${record.tokenSymbol}\`);
    console.log(\`   Initial: \${record.initialAmount} ${record.tokenSymbol}\`);
    console.log(\`   Current: \${currentAmount} ${record.tokenSymbol}\`);
    if (yieldGenerated > 0) {
      console.log(\`   Yield: \${yieldGenerated.toFixed(6)} ${record.tokenSymbol} (\${yieldPercent}%)\`);
    }
    console.log(\`   Status: ✅ Test Complete\\n\`);

  } catch (error: any) {
    console.error(\`\\n❌ Verification failed:\`);
    console.error(\`Error: \${error.message}\`);
  }
}

main().catch(console.error);
`;

  fs.writeFileSync('scripts/testnet/phase4-check-yield-7days.ts', script);
}

main().catch(console.error);
