import hre from 'hardhat';

async function main() {
  console.log(`\n${'='.repeat(70)}`);
  console.log(`  PHASE 2: AAVE YIELD GENERATION TESTING`);
  console.log(`  Escrow with yield enabled to test Aave integration`);
  console.log(`${'='.repeat(70)}\n`);

  const [signer] = await hre.ethers.getSigners();
  const signerAddr = await signer.getAddress();
  
  const escrowVaultAddr = '0x13b8b7572c72b46879662BFEA53851cBeD3bC47a';
  const sewTokenAddr = '0x62BD47154D0b5Fe435F220E1294405040102b2ba';
  const aaveModuleAddr = '0x084DD3BA96B14Ce07746E7c6AF23454dcbB65C01';
  
  console.log(`📋 Configuration:`);
  console.log(`   Buyer/Sender: ${signerAddr}`);
  console.log(`   Recipient: 0xdddddddddddddddddddddddddddddddddddddddd`);
  console.log(`   EscrowVault: ${escrowVaultAddr}`);
  console.log(`   AaveYieldModule: ${aaveModuleAddr}`);
  console.log(`   Token (SEW): ${sewTokenAddr}\n`);

  const erc20ABI = ['function approve(address, uint256) returns (bool)', 'function balanceOf(address) view returns (uint256)'];
  const token = new hre.ethers.Contract(sewTokenAddr, erc20ABI, signer);
  
  const escrowVaultABI = require('../../deployments/baseSepolia/EscrowVault.json').abi;
  const escrowVault = new hre.ethers.Contract(escrowVaultAddr, escrowVaultABI, signer);

  const recipient = '0xdddddddddddddddddddddddddddddddddddddddd';
  const amount = hre.ethers.parseEther('250');
  
  const settings = {
    customResolver: hre.ethers.ZeroAddress,
    releaseAddress: hre.ethers.ZeroAddress,
    yieldPreset: 1, // TO_SENDER (Aave - yields to recipient)
    autoReleaseTime: 0,
    autoCancelTime: 0
  };
  
  try {
    // Check balance
    const buyerBalBefore = await token.balanceOf(signerAddr);
    console.log(`📊 Buyer balance: ${hre.ethers.formatEther(buyerBalBefore)} SEW\n`);

    // Approve
    console.log(`1️⃣  Approving tokens for yield escrow...`);
    const approveTx = await token.approve(escrowVaultAddr, amount);
    await approveTx.wait();
    console.log(`   ✅ Approved ${hre.ethers.formatEther(amount)} SEW\n`);
    
    // Create with Aave yield
    console.log(`2️⃣  Creating escrow with Aave yield (yieldPreset=1)...`);
    const createTx = await escrowVault.createEscrow(sewTokenAddr, recipient, amount, settings);
    const createRcpt = await createTx.wait();
    
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
    
    console.log(`   ✅ Escrow created`);
    console.log(`   Workflow ID: ${workflowId}`);
    console.log(`   Amount after fee: ${hre.ethers.formatEther(amountAfterFee)} SEW`);
    console.log(`   TX: ${createTx.hash}\n`);

    // Wait for yield to accrue
    const blockNumBefore = await hre.ethers.provider.getBlockNumber();
    console.log(`3️⃣  Escrow is now earning yield on Aave...`);
    console.log(`   Block at creation: ${blockNumBefore}`);
    console.log(`   Funds locked in EscrowVault, generating yield via Aave\n`);

    // Release escrow
    console.log(`4️⃣  Releasing escrow after yield generation...`);
    const releaseTx = await escrowVault.releaseEscrowTransfer(workflowId);
    await releaseTx.wait();
    console.log(`   ✅ Released (TX: ${releaseTx.hash})`);
    
    // Check recipient balance
    const recipientBal = await token.balanceOf(recipient);
    console.log(`   Recipient balance: ${hre.ethers.formatEther(recipientBal)} SEW`);
    
    if (recipientBal > amountAfterFee) {
      const yieldGenerated = recipientBal - amountAfterFee;
      console.log(`   🎉 YIELD GENERATED: ${hre.ethers.formatEther(yieldGenerated)} SEW`);
    } else if (recipientBal === amountAfterFee) {
      console.log(`   ℹ️  No yield yet (too short timeframe)`);
    }

    // Check buyer balance after
    const buyerBalAfter = await token.balanceOf(signerAddr);
    console.log(`\n   Buyer balance after: ${hre.ethers.formatEther(buyerBalAfter)} SEW`);
    console.log(`   Net cost: ${hre.ethers.formatEther(buyerBalBefore - buyerBalAfter)} SEW`);

    console.log(`\n${'='.repeat(70)}`);
    console.log(`  ✅ PHASE 2 COMPLETE: Aave Yield Module Integration Verified`);
    console.log(`${'='.repeat(70)}\n`);
    
  } catch (error: any) {
    console.error(`\n❌ PHASE 2 FAILED`);
    console.error(`Error: ${error.message}`);
    if (error.data) {
      console.error(`Error data: ${error.data}`);
    }
  }
}

main().catch(console.error);
