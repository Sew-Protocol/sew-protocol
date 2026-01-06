import { readFileSync, existsSync } from 'fs';
import { join } from 'path';

const ARTIFACTS_DIR = join(__dirname, '../artifacts/contracts');
const SIZE_LIMIT = 24 * 1024; // 24KB in bytes

interface ContractSize {
  name: string;
  size: number;
  sizeKB: number;
  overLimit: boolean;
  overLimitPercent: number;
}

function getContractSize(contractPath: string): number | null {
  if (!existsSync(contractPath)) {
    return null;
  }
  
  try {
    const artifact = JSON.parse(readFileSync(contractPath, 'utf-8'));
    const bytecode = artifact.deployedBytecode;
    
    if (!bytecode || bytecode === '0x') {
      return null; // Abstract contract or no bytecode
    }
    
    // Remove '0x' prefix and calculate size (each byte is 2 hex chars)
    return (bytecode.length - 2) / 2;
  } catch (error) {
    console.error(`Error reading ${contractPath}:`, error);
    return null;
  }
}

function findContracts(): ContractSize[] {
  const contracts: ContractSize[] = [];
  const contractFiles = [
    'BaseEscrow.sol/BaseEscrow.json',
    'EscrowVault.sol/EscrowVault.json',
    'EscrowableERC20.sol/EscrowableERC20.json',
    'modules/DecentralizedResolutionModule.sol/DecentralizedResolutionModule.json',
    'modules/ResolverIncentiveModule.sol/ResolverIncentiveModule.json',
  ];
  
  for (const file of contractFiles) {
    const contractPath = join(ARTIFACTS_DIR, file);
    const size = getContractSize(contractPath);
    
    if (size !== null) {
      const sizeKB = size / 1024;
      const overLimit = size > SIZE_LIMIT;
      const overLimitPercent = overLimit ? ((size - SIZE_LIMIT) / SIZE_LIMIT) * 100 : 0;
      
      contracts.push({
        name: file.split('/').pop()?.replace('.json', '') || file,
        size,
        sizeKB,
        overLimit,
        overLimitPercent,
      });
    }
  }
  
  return contracts.sort((a, b) => b.size - a.size);
}

function printContractSizes() {
  console.log('\n📦 Contract Size Report\n');
  console.log('═'.repeat(80));
  
  const contracts = findContracts();
  
  if (contracts.length === 0) {
    console.log('⚠️  No contract artifacts found. Run "pnpm compile" first.\n');
    return;
  }
  
  console.log(`Size Limit: ${(SIZE_LIMIT / 1024).toFixed(2)} KB (${SIZE_LIMIT.toLocaleString()} bytes)\n`);
  
  for (const contract of contracts) {
    const status = contract.overLimit ? '❌ OVER LIMIT' : '✅ OK';
    const sizeStr = `${contract.sizeKB.toFixed(2)} KB (${contract.size.toLocaleString()} bytes)`;
    const overStr = contract.overLimit 
      ? ` - ${contract.overLimitPercent.toFixed(1)}% over limit`
      : '';
    
    console.log(`${contract.name.padEnd(50)} ${sizeStr.padStart(25)} ${status}${overStr}`);
  }
  
  console.log('\n' + '═'.repeat(80));
  
  const overLimitContracts = contracts.filter(c => c.overLimit);
  if (overLimitContracts.length > 0) {
    console.log(`\n⚠️  ${overLimitContracts.length} contract(s) exceed the 24KB limit:\n`);
    for (const contract of overLimitContracts) {
      console.log(`   • ${contract.name}: ${contract.sizeKB.toFixed(2)} KB (${contract.overLimitPercent.toFixed(1)}% over)`);
    }
    console.log('');
  } else {
    console.log('\n✅ All contracts are under the 24KB limit!\n');
  }
}

printContractSizes();


