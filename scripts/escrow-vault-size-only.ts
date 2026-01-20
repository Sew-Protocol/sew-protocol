import { readFileSync, existsSync } from 'fs';
import { join } from 'path';

// Try Foundry artifacts first (more accurate), fallback to Hardhat
const FOUNDRY_ARTIFACTS_DIR = join(__dirname, '../out');
const HARDHAT_ARTIFACTS_DIR = join(__dirname, '../artifacts/contracts');
const SIZE_LIMIT = 24 * 1024; // 24KB in bytes

function getContractSize(contractPath: string): number | null {
  if (!existsSync(contractPath)) {
    return null;
  }

  try {
    const artifact = JSON.parse(readFileSync(contractPath, 'utf-8'));
    let bytecode = artifact.deployedBytecode;

    // Handle Foundry artifacts which store bytecode as object with 'object' key
    if (typeof bytecode === 'object' && bytecode !== null && 'object' in bytecode) {
      bytecode = bytecode.object;
    }

    if (!bytecode || bytecode === '0x' || typeof bytecode !== 'string') {
      return null; // Abstract contract or no bytecode
    }

    // Remove '0x' prefix and calculate size (each byte is 2 hex chars)
    const size = (bytecode.length - 2) / 2;
    return isNaN(size) || size <= 0 ? null : size;
  } catch (error) {
    console.error(`Error reading ${contractPath}:`, error);
    return null;
  }
}

function getEscrowVaultSize(): number | null {
  // Try Foundry artifact path: out/EscrowVault.sol/EscrowVault.json
  const foundryPath = join(FOUNDRY_ARTIFACTS_DIR, 'EscrowVault.sol', 'EscrowVault.json');
  if (existsSync(foundryPath)) {
    const size = getContractSize(foundryPath);
    if (size !== null) return size;
  }
  
  // Fallback to Hardhat artifact path
  const hardhatPath = join(HARDHAT_ARTIFACTS_DIR, 'core/EscrowVault.sol', 'EscrowVault.json');
  if (existsSync(hardhatPath)) {
    const size = getContractSize(hardhatPath);
    if (size !== null) return size;
  }
  
  return null;
}

function printEscrowVaultSize() {
  console.log('\n📦 EscrowVault Contract Size\n');
  console.log('═'.repeat(60));

  const size = getEscrowVaultSize();

  if (size === null) {
    console.log('⚠️  EscrowVault artifact not found. Run "forge build" first.\n');
    return;
  }

  const sizeKB = size / 1024;
  const overLimit = size > SIZE_LIMIT;
  const overLimitPercent = overLimit ? ((size - SIZE_LIMIT) / SIZE_LIMIT) * 100 : 0;

  const status = overLimit ? '❌ OVER LIMIT' : '✅ OK';
  const sizeStr = `${sizeKB.toFixed(2)} KB (${size.toLocaleString()} bytes)`;
  const overStr = overLimit
    ? ` - ${overLimitPercent.toFixed(1)}% over limit`
    : '';

  console.log(`Size Limit: ${(SIZE_LIMIT / 1024).toFixed(2)} KB (${SIZE_LIMIT.toLocaleString()} bytes)\n`);
  console.log(`EscrowVault${' '.repeat(40)} ${sizeStr.padStart(25)} ${status}${overStr}`);
  console.log('\n' + '═'.repeat(60) + '\n');
}

printEscrowVaultSize();
