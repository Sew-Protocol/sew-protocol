import hre from 'hardhat';

async function main() {
  const [signer] = await hre.ethers.getSigners();
  const signerAddr = await signer.getAddress();
  
  const escrowVaultAddr = '0x13b8b7572c72b46879662BFEA53851cBeD3bC47a';
  const sewTokenAddr = '0x62BD47154D0b5Fe435F220E1294405040102b2ba';
  const aaveModuleAddr = '0x084DD3BA96B14Ce07746E7c6AF23454dcbB65C01';
  
  console.log(`\nTesting Aave yield module availability...`);
  
  const erc20ABI = ['function approve(address, uint256) returns (bool)'];
  const token = new hre.ethers.Contract(sewTokenAddr, erc20ABI, signer);
  
  const escrowVaultABI = require('../../deployments/baseSepolia/EscrowVault.json').abi;
  const escrowVault = new hre.ethers.Contract(escrowVaultAddr, escrowVaultABI, signer);
  
  const seller = '0xcccccccccccccccccccccccccccccccccccccccc';
  const amount = hre.ethers.parseEther('50');
  
  const settings = {
    customResolver: hre.ethers.ZeroAddress,
    releaseAddress: hre.ethers.ZeroAddress,
    yieldPreset: 1, // TO_SENDER (Aave yield) 
    autoReleaseTime: 0,
    autoCancelTime: 0
  };
  
  try {
    console.log(`Creating escrow with yieldPreset=1 (Aave)...`);
    const approveTx = await token.approve(escrowVaultAddr, amount);
    await approveTx.wait();
    
    const createTx = await escrowVault.createEscrow(sewTokenAddr, seller, amount, settings);
    console.log(`✅ Created escrow with Aave yield`);
    console.log(`   TX: ${createTx.hash}`);
    
    const rcpt = await createTx.wait();
    console.log(`✅ Confirmed - Aave yield module is available!`);
  } catch (error: any) {
    console.error(`❌ Aave yield not available: ${error.message}`);
    if (error.data) {
      console.error(`   Error code: ${error.data.slice(0, 10)}`);
    }
  }
}

main();
