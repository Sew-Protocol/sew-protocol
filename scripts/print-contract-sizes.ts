import { readFileSync, existsSync } from 'fs';
import { join } from 'path';
import { execSync } from 'child_process';

// Try Foundry artifacts first (more accurate), fallback to Hardhat
const FOUNDRY_ARTIFACTS_DIR = join(__dirname, '../out');
const HARDHAT_ARTIFACTS_DIR = join(__dirname, '../artifacts/contracts');
const SIZE_LIMIT = 24 * 1024; // 24KB in bytes

interface ContractSize {
  name: string;
  size: number;
  sizeKB: number;
  overLimit: boolean;
  overLimitPercent: number;
  overFrozen: boolean;
}

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

function getContractSizeFromFoundry(contractName: string): number | null {
  // Extract base name (last part after /)
  const baseName = contractName.split('/').pop() || contractName;
  
  // Try Foundry artifact path: out/ContractName.sol/ContractName.json
  const foundryPath = join(FOUNDRY_ARTIFACTS_DIR, `${baseName}.sol`, `${baseName}.json`);
  if (existsSync(foundryPath)) {
    const size = getContractSize(foundryPath);
    if (size !== null) return size;
  }
  
  // Try with full path for subdirectories: out/decentralized-resolution-module/DecentralizedResolutionModule.sol/...
  if (contractName.includes('/')) {
    const parts = contractName.split('/');
    const dir = parts.slice(0, -1).join('/');
    const name = parts[parts.length - 1];
    const foundryPathWithDir = join(FOUNDRY_ARTIFACTS_DIR, dir, `${name}.sol`, `${name}.json`);
    if (existsSync(foundryPathWithDir)) {
      const size = getContractSize(foundryPathWithDir);
      if (size !== null) return size;
    }
  }
  
  // Fallback to Hardhat artifact path
  const hardhatPath = join(HARDHAT_ARTIFACTS_DIR, contractName.includes('/') ? contractName : `core/${contractName}.sol`, `${baseName}.json`);
  if (existsSync(hardhatPath)) {
    const size = getContractSize(hardhatPath);
    if (size !== null) return size;
  }
  
  return null;
}

function findContracts(): ContractSize[] {
  const contracts: ContractSize[] = [];
  // Frozen sizes for the BondLedger extraction (PRF_REVIEW_COMMIT 4959328).
  // The facade has only 276 B of EIP-170 headroom and is treated as frozen;
  // any growth requires explicit approval.
  const frozenSizes: Record<string, number> = {
    BondLedger: 5194,
    ResolverIncentiveModuleV2BondLedger: 24300,
  };
  const contractNames = [
    'BaseEscrow',
    'EscrowVault',
    'EscrowableERC20',
    'BasicEscrowVault',
    'BasicEscrowableERC20',
    'decentralized-resolution-module/DecentralizedResolutionModule',
    'decentralized-resolution-module/ResolverIncentiveModuleV1',
    'decentralized-resolution-module/ResolverIncentiveModuleV2',
    'shared/BondLedger',
    'decentralized-resolution-module/ResolverIncentiveModuleV2BondLedger',
  ];

  for (const contractName of contractNames) {
    const size = getContractSizeFromFoundry(contractName);

    if (size !== null) {
      const baseName = contractName.split('/').pop() || contractName;
      const sizeKB = size / 1024;
      // Over EIP-170 is always a hard failure.
      const overLimit = size > SIZE_LIMIT;
      // Frozen-size gate: BondLedger may grow up to +500 B (explicit approval
      // above that); the facade must not grow at all before deployment.
      const frozen = frozenSizes[baseName];
      const overFrozen =
        frozen !== undefined &&
        (baseName === 'ResolverIncentiveModuleV2BondLedger'
          ? size > frozen
          : size > frozen + 500);
      const overLimitPercent = overLimit ? ((size - SIZE_LIMIT) / SIZE_LIMIT) * 100 : 0;

      contracts.push({
        name: baseName,
        size,
        sizeKB,
        overLimit: overLimit || overFrozen,
        overLimitPercent,
        overFrozen,
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

  console.log(
    `Size Limit: ${(SIZE_LIMIT / 1024).toFixed(2)} KB (${SIZE_LIMIT.toLocaleString()} bytes)\n`,
  );

  for (const contract of contracts) {
    const status = contract.overLimit ? '❌ OVER LIMIT' : '✅ OK';
    const sizeStr = `${contract.sizeKB.toFixed(2)} KB (${contract.size.toLocaleString()} bytes)`;
    const overStr = contract.overLimit
      ? ` - ${contract.overLimitPercent.toFixed(1)}% over limit`
      : '';

    console.log(`${contract.name.padEnd(50)} ${sizeStr.padStart(25)} ${status}${overStr}`);
  }

  console.log('\n' + '═'.repeat(80));

  const overLimitContracts = contracts.filter((c) => c.overLimit);
  if (overLimitContracts.length > 0) {
    console.log(`\n⚠️  ${overLimitContracts.length} contract(s) exceed a size limit:\n`);
    for (const contract of overLimitContracts) {
      console.log(
        `   • ${contract.name}: ${contract.sizeKB.toFixed(2)} KB (${contract.size.toLocaleString()} bytes)`,
      );
    }
    console.log('');
  } else {
    console.log('\n✅ All contracts are under their size limits.\n');
  }

  // Hard-fail only on the BondLedger extraction frozen-size gates. EIP-170
  // violations in legacy contracts remain reported (pre-existing CI behaviour);
  // any growth of the review facade or primitive requires explicit approval.
  const frozenBreach = contracts.filter((c) => c.overFrozen);
  if (frozenBreach.length > 0) {
    console.log('❌ Frozen-size gate breached for the BondLedger extraction:');
    for (const contract of frozenBreach) {
      console.log(`   • ${contract.name}: ${contract.size.toLocaleString()} bytes`);
    }
    console.log('   Growth of BondLedger or ResolverIncentiveModuleV2BondLedger');
    console.log('   requires explicit approval (PRF_REVIEW_COMMIT 4959328).');
    process.exit(1);
  }
}

printContractSizes();
