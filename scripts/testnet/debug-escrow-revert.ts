import hre from 'hardhat';
import deployments from '../../deploy-registry/base-sepolia-v1-testnet.json';

async function main() {
  const [signer] = await hre.ethers.getSigners();
  const signerAddr = await signer.getAddress();
  
  console.log('Debug: EscrowVault createEscrow revert');
  console.log(`Signer: ${signerAddr}`);
  
  // Load contracts
  const escrowVaultAddr = '0x13b8b7572c72b46879662BFEA53851cBeD3bC47a';
  const sewTokenAddr = '0x62BD47154D0b5Fe435F220E1294405040102b2ba';
  
  const erc20ABI = ['function approve(address spender, uint256 amount) returns (bool)'];
  const token = new hre.ethers.Contract(sewTokenAddr, erc20ABI, signer);
  
  // Try minimal createEscrow call
  const createOpsAddr = '0xBC60481020457CAC819B6938396a1002B0518f34';
  
  console.log(`\nAttempting to check what happens with createEscrow...`);
  console.log(`EscrowVault: ${escrowVaultAddr}`);
  console.log(`Token: ${sewTokenAddr}`);
  console.log(`CreateOps: ${createOpsAddr}`);
  
  // First, try to call at a low level to see the actual error
  try {
    // Get the function signature for createEscrow
    const escrowVaultABI = require('../../deployments/baseSepolia/EscrowVault.json').abi;
    const escrowVault = new hre.ethers.Contract(escrowVaultAddr, escrowVaultABI, signer);
    
    // Approve first
    const amount = hre.ethers.parseEther('100');
    console.log(`\nApproving ${hre.ethers.formatEther(amount)} tokens...`);
    const approveTx = await token.approve(escrowVaultAddr, amount);
    console.log(`Approve tx: ${approveTx.hash}`);
    await approveTx.wait();
    console.log(`✅ Approval confirmed`);
    
    // Now try createEscrow with minimal settings
    // NOTE: recipient must be different from sender - that's a validation rule
    const recipient = '0x' + 'd'.repeat(40);  // Different address (0xdddd...dddd)
    const settings = {
      customResolver: hre.ethers.ZeroAddress,
      releaseAddress: hre.ethers.ZeroAddress,
      yieldPreset: 0, // OFF
      autoReleaseTime: 0,
      autoCancelTime: 0
    };
    
    console.log(`\nAttempting createEscrow with settings:`, settings);
    console.log(`Sender: ${signerAddr}`);
    console.log(`Recipient: ${recipient}`);
    const createTx = await escrowVault.createEscrow(
      sewTokenAddr,
      recipient,
      amount,
      settings
    );
    console.log(`createEscrow tx: ${createTx.hash}`);
    await createTx.wait();
    console.log(`✅ createEscrow succeeded!`);
  } catch (error: any) {
    console.error(`\n❌ Error:`, error.message);
    if (error.data) {
      console.error(`Error data:`, error.data);
    }
    if (error.transaction) {
      console.error(`Transaction data:`, error.transaction);
    }
  }
}

main().catch(console.error);
