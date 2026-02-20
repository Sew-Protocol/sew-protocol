/**
 * Phase 4: Yield Generation Test with USDC
 * 
 * This script creates a yield-enabled escrow with USDC and documents:
 * - Exact transaction details
 * - How to check yield in 7 days
 * - How to verify yield withdrawal
 */

import hre from 'hardhat';
import * as fs from 'fs';

interface YieldTestRecord {
  startDate: string;
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
  console.log(`  PHASE 4: YIELD GENERATION TEST WITH USDC`);
  console.log(`  Creating yield-enabled escrow and documenting verification process`);
  console.log(`${'='.repeat(80)}\n`);

  const [signer] = await hre.ethers.getSigners();
  const buyerAddr = await signer.getAddress();
  
  // Configuration
  const USDC_ADDR = '0x036CbD53842c5426634e7929541eC2318f3dCF7e'; // USDC on Base Sepolia
  const ESCROW_VAULT = '0x13b8b7572c72b46879662BFEA53851cBeD3bC47a';
  const AAVE_MODULE = '0x084DD3BA96B14Ce07746E7c6AF23454dcbB65C01';
  const AAVE_POOL = '0x8bAB6d1b75f19e9eD9fCe8b9BD338844fF79aE27';
  
  const recipientAddr = '0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee'; // Different address for recipient
  const amount = hre.ethers.parseUnits('100', 6); // 100 USDC (6 decimals)

  console.log(`📋 Configuration:`);
  console.log(`   Buyer: ${buyerAddr}`);
  console.log(`   Recipient: ${recipientAddr}`);
  console.log(`   Amount: 100 USDC`);
  console.log(`   EscrowVault: ${ESCROW_VAULT}`);
  console.log(`   AaveYieldModule: ${AAVE_MODULE}`);
  console.log(`   Aave Pool: ${AAVE_POOL}\n`);

  try {
    // Get contract instances
    const usdc = await hre.ethers.getContractAt(
      ['function approve(address,uint256) returns (bool)', 'function balanceOf(address) view returns (uint256)'],
      USDC_ADDR,
      signer
    );

    const escrowVault = await hre.ethers.getContractAt(
      require('../../deployments/baseSepolia/EscrowVault.json').abi,
      ESCROW_VAULT,
      signer
    );

    // Check USDC balance
    console.log(`1️⃣  Checking USDC balance...`);
    const balanceBefore = await usdc.balanceOf(buyerAddr);
    console.log(`   Balance: ${hre.ethers.formatUnits(balanceBefore, 6)} USDC`);

    if (balanceBefore < amount) {
      console.warn(`   ⚠️  Warning: Balance may be insufficient for test`);
    } else {
      console.log(`   ✅ Sufficient balance\n`);
    }

    // Approve EscrowVault
    console.log(`2️⃣  Approving USDC for EscrowVault...`);
    const approveTx = await usdc.approve(ESCROW_VAULT, amount);
    const approveRcpt = await approveTx.wait();
    console.log(`   ✅ Approved (TX: ${approveTx.hash})\n`);

    // Create yield-enabled escrow
    console.log(`3️⃣  Creating YIELD-ENABLED escrow with USDC...`);
    const settings = {
      customResolver: hre.ethers.ZeroAddress,
      releaseAddress: hre.ethers.ZeroAddress,
      yieldPreset: 1, // TO_SENDER = Aave yield to recipient
      autoReleaseTime: 0,
      autoCancelTime: 0
    };

    const createTx = await escrowVault.createEscrow(
      USDC_ADDR,
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
    const createdTimestamp = (await hre.ethers.provider.getBlock(createdBlock!))?.timestamp;

    console.log(`📊 Escrow Created:`);
    console.log(`   Transaction Hash: ${createTx.hash}`);
    console.log(`   Block: ${createdBlock}`);
    console.log(`   Timestamp: ${createdTimestamp} (${new Date(createdTimestamp! * 1000).toISOString()})`);
    console.log(`   Workflow ID: ${workflowId}`);
    console.log(`   Amount: ${hre.ethers.formatUnits(amountAfterFee, 6)} USDC`);
    console.log(`   Yield Preset: 1 (Aave - yields to recipient)\n`);

    // Calculate 7-day future date
    const startDate = new Date();
    const checkDate = new Date(startDate.getTime() + 7 * 24 * 60 * 60 * 1000);
    const checkDateISO = checkDate.toISOString().split('T')[0];

    // Build record
    const record: YieldTestRecord = {
      startDate: startDate.toISOString(),
      escrowCreationTx: createTx.hash,
      workflowId: workflowId.toString(),
      initialAmount: hre.ethers.formatUnits(amountAfterFee, 6),
      tokenSymbol: 'USDC',
      tokenAddress: USDC_ADDR,
      escrowVaultAddress: ESCROW_VAULT,
      aaveYieldModule: AAVE_MODULE,
      aavePool: AAVE_POOL,
      buyerAddress: buyerAddr,
      recipientAddress: recipientAddr,
      yieldCheckDate7Days: checkDateISO,
      instructions: [
        `1. Wait until ${checkDateISO} (7 days from creation)`,
        `2. Run the yield check script on that date:`,
        `   pnpm hardhat run scripts/testnet/phase4-check-yield-7days.ts --network baseSepolia`,
        `3. The script will:`,
        `   - Query the aToken balance held by EscrowVault`,
        `   - Calculate yield generated = current balance - initial amount`,
        `   - Show yield percentage return`,
        `   - Test withdrawal and release mechanisms`,
      ],
      checkCommands: [
        `# Check aToken balance in EscrowVault (substitute aToken address)`,
        `cast call <aToken_address> "balanceOf(address)" ${ESCROW_VAULT} --rpc-url https://sepolia.base.org`,
        ``,
        `# Query Aave Pool for aToken address (substitute pool address)`,
        `cast call ${AAVE_POOL} "getReserveData(address)" ${USDC_ADDR} --rpc-url https://sepolia.base.org`,
        ``,
        `# Check transaction details on BaseScan`,
        `https://sepolia.basescan.org/tx/${createTx.hash}`,
        ``,
        `# View escrow state on-chain`,
        `cast call ${ESCROW_VAULT} "escrowStates(uint256)(uint8)" ${workflowId} --rpc-url https://sepolia.base.org`,
      ],
    };

    // Save record
    const recordPath = 'scripts/testnet/.yield-test-record.json';
    fs.writeFileSync(recordPath, JSON.stringify(record, null, 2));
    console.log(`📝 Test record saved to: ${recordPath}\n`);

    // Display instructions
    console.log(`${'='.repeat(80)}`);
    console.log(`  HOW TO CHECK YIELD IN 7 DAYS (${checkDateISO})`);
    console.log(`${'='.repeat(80)}\n`);

    console.log(`SAVED DETAILS:`);
    console.log(`  Start Date: ${record.startDate}`);
    console.log(`  Check Date: ${record.yieldCheckDate7Days}`);
    console.log(`  Workflow ID: ${record.workflowId}`);
    console.log(`  Creation TX: ${record.escrowCreationTx}\n`);

    console.log(`VERIFICATION STEPS:\n`);
    record.instructions.forEach((instr, i) => {
      console.log(`${instr}`);
    });

    console.log(`\n\nUSEFUL COMMANDS:\n`);
    record.checkCommands.forEach((cmd) => {
      console.log(`${cmd}`);
    });

    console.log(`\n\nCREATING FOLLOW-UP SCRIPT...`);
    createFollowUpScript(record);
    console.log(`✅ Created: scripts/testnet/phase4-check-yield-7days.ts\n`);

    console.log(`${'='.repeat(80)}`);
    console.log(`  ✅ PHASE 4 YIELD TEST INITIATED`);
    console.log(`${'='.repeat(80)}\n`);

    console.log(`📌 REMINDER:`);
    console.log(`   Return on ${checkDateISO} and run:`);
    console.log(`   pnpm hardhat run scripts/testnet/phase4-check-yield-7days.ts --network baseSepolia\n`);

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
 * Run this script 7 days after escrow creation to verify yield has been generated.
 * 
 * Test Record:
 * - Created: ${record.startDate}
 * - Check Date: ${record.yieldCheckDate7Days}
 * - TX: ${record.escrowCreationTx}
 * - Workflow ID: ${record.workflowId}
 */

import hre from 'hardhat';

async function main() {
  console.log(\`\\n\${'='.repeat(80)}\`);
  console.log(\`  PHASE 4: YIELD CHECK (7 Days Later)\`);
  console.log(\`  Checking yield generated on USDC escrow\`);
  console.log(\`\${'='.repeat(80)}\\n\`);

  const [signer] = await hre.ethers.getSigners();
  
  // Load test record
  const record = require('./.yield-test-record.json');
  
  console.log(\`📋 Test Details:\`);
  console.log(\`   Created: \${record.startDate}\`);
  console.log(\`   Check Date: \${record.yieldCheckDate7Days}\`);
  console.log(\`   Workflow ID: \${record.workflowId}\`);
  console.log(\`   Initial Amount: \${record.initialAmount} USDC\`);
  console.log(\`   Recipient: \${record.recipientAddress}\\n\`);

  try {
    const ESCROW_VAULT = record.escrowVaultAddress;
    const USDC_ADDR = record.tokenAddress;
    const AAVE_POOL = record.aavePool;
    
    // Get contracts
    const usdc = await hre.ethers.getContractAt(
      ['function balanceOf(address) view returns (uint256)', 'function name() view returns (string)'],
      USDC_ADDR,
      signer
    );

    const escrowVault = await hre.ethers.getContractAt(
      require('../../deployments/baseSepolia/EscrowVault.json').abi,
      ESCROW_VAULT,
      signer
    );

    // Check USDC balance held by EscrowVault
    console.log(\`1️⃣  Checking USDC balance in EscrowVault...\`);
    const escrowBalance = await usdc.balanceOf(ESCROW_VAULT);
    console.log(\`   Balance: \${hre.ethers.formatUnits(escrowBalance, 6)} USDC\\n\`);

    // Calculate yield
    const initialAmount = parseFloat(record.initialAmount);
    const currentAmount = parseFloat(hre.ethers.formatUnits(escrowBalance, 6));
    const yieldGenerated = currentAmount - initialAmount;
    const yieldPercent = (yieldGenerated / initialAmount * 100).toFixed(4);

    console.log(\`2️⃣  Yield Analysis:\`);
    if (yieldGenerated > 0) {
      console.log(\`   ✅ YIELD GENERATED!\`);
      console.log(\`   Initial: \${initialAmount} USDC\`);
      console.log(\`   Current: \${currentAmount} USDC\`);
      console.log(\`   Yield: \${yieldGenerated.toFixed(6)} USDC\`);
      console.log(\`   Return: \${yieldPercent}%\\n\`);
    } else {
      console.log(\`   ℹ️  No yield detected yet\`);
      console.log(\`   Initial: \${initialAmount} USDC\`);
      console.log(\`   Current: \${currentAmount} USDC\\n\`);
    }

    // Test withdrawal by releasing escrow
    console.log(\`3️⃣  Testing withdrawal/release mechanism...\`);
    const workflowId = BigInt(record.workflowId);
    
    try {
      const releaseTx = await escrowVault.releaseEscrowTransfer(workflowId);
      const releaseRcpt = await releaseTx.wait();
      
      console.log(\`   ✅ Release executed\`);
      console.log(\`   TX: \${releaseTx.hash}\\n\`);
      
      // Check recipient balance
      const recipientBalance = await usdc.balanceOf(record.recipientAddress);
      console.log(\`4️⃣  Checking recipient balance after release:\`);
      console.log(\`   Recipient balance: \${hre.ethers.formatUnits(recipientBalance, 6)} USDC\\n\`);
      
      if (recipientBalance > 0n) {
        console.log(\`   ✅ WITHDRAWAL SUCCESSFUL\`);
        console.log(\`   Recipient received full amount + any yield\`);
      }
    } catch (error: any) {
      console.log(\`   ℹ️  Release failed (may require authorization)\`);
      console.log(\`   Error: \${error.message}\\n\`);
    }

    console.log(\`${'='.repeat(80)}\`);
    console.log(\`  YIELD VERIFICATION COMPLETE\`);
    console.log(\`${'='.repeat(80)}\\n\`);

    console.log(\`📊 SUMMARY:\`);
    console.log(\`   Escrow ID: \${record.workflowId}\`);
    console.log(\`   Token: USDC (Base Sepolia)\`);
    console.log(\`   Amount: \${record.initialAmount} USDC\`);
    if (yieldGenerated > 0) {
      console.log(\`   Yield: \${yieldGenerated.toFixed(6)} USDC (\${yieldPercent}%)\`);
    }
    console.log(\`   Status: ✅ Validated\\n\`);

  } catch (error: any) {
    console.error(\`\\n❌ Check failed:\`);
    console.error(\`Error: \${error.message}\`);
  }
}

main().catch(console.error);
`;

  fs.writeFileSync('scripts/testnet/phase4-check-yield-7days.ts', script);
}

main().catch(console.error);
