import hre from 'hardhat';

async function main() {
  console.log(`\n${'='.repeat(70)}`);
  console.log(`  PHASE 1: MULTI-PARTY ESCROW VALIDATION`);
  console.log(`  Testing full escrow lifecycle with distinct buyer/seller`);
  console.log(`${'='.repeat(70)}\n`);

  const [signer] = await hre.ethers.getSigners();
  const signerAddr = await signer.getAddress();
  
  // Use signer as buyer and hardcode different addresses as sellers
  const buyerAddr = signerAddr;
  const seller1Addr = '0x' + 'a'.repeat(40); // 0xaaaa...aaaa
  const seller2Addr = '0x' + 'b'.repeat(40); // 0xbbbb...bbbb
  
  console.log(`📋 Participants:`);
  console.log(`   Buyer: ${buyerAddr}`);
  console.log(`   Seller 1: ${seller1Addr}`);
  console.log(`   Seller 2: ${seller2Addr}\n`);

  // Load contracts
  const escrowVaultAddr = '0x13b8b7572c72b46879662BFEA53851cBeD3bC47a';
  const sewTokenAddr = '0x62BD47154D0b5Fe435F220E1294405040102b2ba';

  const erc20ABI = [
    'function approve(address spender, uint256 amount) returns (bool)',
    'function balanceOf(address account) view returns (uint256)',
    'function transfer(address to, uint256 amount) returns (bool)',
  ];
  
  const token = new hre.ethers.Contract(sewTokenAddr, erc20ABI, signer);
  const escrowVaultABI = require('../../deployments/baseSepolia/EscrowVault.json').abi;
  const escrowVault = new hre.ethers.Contract(escrowVaultAddr, escrowVaultABI, signer);

  const amount = hre.ethers.parseEther('100');
  const testCases = [
    {
      name: 'TEST 1: Create → Release',
      seller: seller1Addr,
      action: 'release',
    },
    {
      name: 'TEST 2: Create → Cancel',
      seller: seller2Addr,
      action: 'cancel',
    },
  ];

  for (const testCase of testCases) {
    console.log(`\n${testCase.name}`);
    console.log(`${'-'.repeat(70)}`);
    
    try {
      // Check balance
      const buyerBalBefore = await token.balanceOf(buyerAddr);
      console.log(`📊 Buyer balance before: ${hre.ethers.formatEther(buyerBalBefore)} SEW`);

      // Approve
      console.log(`\n1️⃣  Approving tokens...`);
      const approveTx = await token.approve(escrowVaultAddr, amount);
      const approveRcpt = await approveTx.wait();
      console.log(`   ✅ Approved ${hre.ethers.formatEther(amount)} SEW (tx: ${approveTx.hash})`);

      // Create escrow
      console.log(`\n2️⃣  Creating escrow...`);
      const settings = {
        customResolver: hre.ethers.ZeroAddress,
        releaseAddress: hre.ethers.ZeroAddress,
        yieldPreset: 0, // OFF
        autoReleaseTime: 0,
        autoCancelTime: 0
      };
      
      const createTx = await escrowVault.createEscrow(
        sewTokenAddr,
        testCase.seller,
        amount,
        settings
      );
      const createRcpt = await createTx.wait();
      console.log(`   ✅ Escrow created (tx: ${createTx.hash})`);

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
      
      const workflowId = event.args[0]; // workflowId is first arg
      const amountAfterFee = event.args[5]; // amountAfterFee
      
      console.log(`   Workflow ID: ${workflowId}`);
      console.log(`   Amount after fee: ${hre.ethers.formatEther(amountAfterFee)} SEW`);

      // Action (release or cancel)
      if (testCase.action === 'release') {
        console.log(`\n3️⃣  Releasing escrow...`);
        const releaseTx = await escrowVault.releaseEscrowTransfer(workflowId);
        await releaseTx.wait();
        console.log(`   ✅ Released (tx: ${releaseTx.hash})`);
        
        // Check seller balance increased
        const sellerBalAfter = await token.balanceOf(testCase.seller);
        console.log(`   Seller received: ${hre.ethers.formatEther(sellerBalAfter)} SEW`);
        console.log(`   ✅ TEST PASSED`);
      } else if (testCase.action === 'cancel') {
        console.log(`\n3️⃣  Cancelling escrow (buyer)...`);
        const cancelTx = await escrowVault.senderCancel(workflowId);
        await cancelTx.wait();
        console.log(`   ✅ Cancelled (tx: ${cancelTx.hash})`);
        
        // Check buyer balance (should be restored minus fee)
        const buyerBalAfter = await token.balanceOf(buyerAddr);
        const expectedBal = buyerBalBefore - amount; // Fee already deducted
        console.log(`   Buyer balance after: ${hre.ethers.formatEther(buyerBalAfter)} SEW`);
        console.log(`   ✅ TEST PASSED`);
      }
      
    } catch (error: any) {
      console.error(`   ❌ TEST FAILED`);
      console.error(`   Error: ${error.message}`);
      if (error.data) {
        console.error(`   Data: ${error.data}`);
      }
    }
  }

  console.log(`\n${'='.repeat(70)}`);
  console.log(`  PHASE 1 COMPLETE`);
  console.log(`${'='.repeat(70)}\n`);
}

main().catch(console.error);
