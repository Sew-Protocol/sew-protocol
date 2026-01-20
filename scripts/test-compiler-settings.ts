import { ethers } from 'hardhat';
import * as fs from 'fs';
import * as path from 'path';

interface CompilerTestResult {
  config: string;
  solidityVersion: string;
  optimizerRuns: number;
  viaIR: boolean;
  contracts: {
    name: string;
    size: number;
    sizeKB: string;
  }[];
}

const SIZE_LIMIT_BYTES = 24 * 1024; // 24 KB

async function testCompilerSettings() {
  const contractNames = ['EscrowVault', 'EscrowableERC20', 'DecentralizedResolutionModule'];
  const testConfigs = [
    { version: '0.8.28', runs: 50000, viaIR: true, name: 'Current (0.8.28, 50k runs, viaIR)' },
    { version: '0.8.31', runs: 50000, viaIR: true, name: 'Upgrade (0.8.31, 50k runs, viaIR)' },
    { version: '0.8.31', runs: 100000, viaIR: true, name: 'Upgrade (0.8.31, 100k runs, viaIR)' },
    { version: '0.8.31', runs: 50000, viaIR: false, name: 'Upgrade (0.8.31, 50k runs, no viaIR)' },
    {
      version: '0.8.31',
      runs: 100000,
      viaIR: false,
      name: 'Upgrade (0.8.31, 100k runs, no viaIR)',
    },
  ];

  const results: CompilerTestResult[] = [];

  console.log('\n🔧 Testing Compiler Settings\n');
  console.log('════════════════════════════════════════════════════════════════════════════════\n');

  for (const config of testConfigs) {
    console.log(`Testing: ${config.name}`);
    console.log(`  Solidity: ${config.version}, Runs: ${config.runs}, viaIR: ${config.viaIR}`);

    // Update hardhat.config.ts temporarily
    const configPath = path.join(__dirname, '../hardhat.config.ts');
    const originalConfig = fs.readFileSync(configPath, 'utf8');

    // Create modified config
    const modifiedConfig = originalConfig
      .replace(/version: "0\.8\.\d+"/, `version: "${config.version}"`)
      .replace(/runs: \d+/, `runs: ${config.runs}`)
      .replace(/viaIR: (true|false)/, `viaIR: ${config.viaIR}`);

    fs.writeFileSync(configPath, modifiedConfig);

    try {
      // Compile
      const { execSync } = require('child_process');
      execSync('npx hardhat compile', { stdio: 'pipe' });

      // Measure sizes
      const contractSizes: { name: string; size: number; sizeKB: string }[] = [];
      for (const name of contractNames) {
        const artifactPath = path.join(
          __dirname,
          `../artifacts/contracts/${name}.sol/${name}.json`,
        );
        if (fs.existsSync(artifactPath)) {
          const artifact = JSON.parse(fs.readFileSync(artifactPath, 'utf8'));
          const deployedBytecode = artifact.deployedBytecode;
          const size = deployedBytecode ? (deployedBytecode.length - 2) / 2 : 0;
          const sizeKB = (size / 1024).toFixed(2);
          contractSizes.push({ name, size, sizeKB });
        }
      }

      results.push({
        config: config.name,
        solidityVersion: config.version,
        optimizerRuns: config.runs,
        viaIR: config.viaIR,
        contracts: contractSizes,
      });

      console.log(`  ✅ Compiled successfully`);
    } catch (error) {
      console.log(`  ❌ Compilation failed: ${error}`);
    } finally {
      // Restore original config
      fs.writeFileSync(configPath, originalConfig);
    }
  }

  // Print comparison table
  console.log('\n════════════════════════════════════════════════════════════════════════════════');
  console.log('📊 Size Comparison Results\n');

  // Header
  console.log(
    'Configuration'.padEnd(50) +
      'EscrowVault'.padStart(12) +
      'EscrowableERC20'.padStart(15) +
      'DecentralizedResolution'.padStart(25),
  );
  console.log('─'.repeat(102));

  // Results
  const baseline = results[0];
  for (const result of results) {
    const vault = result.contracts.find((c) => c.name === 'EscrowVault');
    const erc20 = result.contracts.find((c) => c.name === 'EscrowableERC20');
    const drm = result.contracts.find((c) => c.name === 'DecentralizedResolutionModule');

    const vaultSize = vault ? `${vault.sizeKB} KB` : 'N/A';
    const erc20Size = erc20 ? `${erc20.sizeKB} KB` : 'N/A';
    const drmSize = drm ? `${drm.sizeKB} KB` : 'N/A';

    // Calculate difference from baseline
    const baselineVault = baseline.contracts.find((c) => c.name === 'EscrowVault');
    const baselineErc20 = baseline.contracts.find((c) => c.name === 'EscrowableERC20');
    const baselineDrm = baseline.contracts.find((c) => c.name === 'DecentralizedResolutionModule');

    let vaultDiff = '';
    let erc20Diff = '';
    let drmDiff = '';

    if (vault && baselineVault) {
      const diff = vault.size - baselineVault.size;
      const diffKB = (diff / 1024).toFixed(2);
      vaultDiff = diff > 0 ? ` (+${diffKB} KB)` : diff < 0 ? ` (${diffKB} KB)` : ' (0 KB)';
    }

    if (erc20 && baselineErc20) {
      const diff = erc20.size - baselineErc20.size;
      const diffKB = (diff / 1024).toFixed(2);
      erc20Diff = diff > 0 ? ` (+${diffKB} KB)` : diff < 0 ? ` (${diffKB} KB)` : ' (0 KB)';
    }

    if (drm && baselineDrm) {
      const diff = drm.size - baselineDrm.size;
      const diffKB = (diff / 1024).toFixed(2);
      drmDiff = diff > 0 ? ` (+${diffKB} KB)` : diff < 0 ? ` (${diffKB} KB)` : ' (0 KB)';
    }

    console.log(
      result.config.padEnd(50) +
        (vaultSize + vaultDiff).padStart(12 + vaultDiff.length) +
        (erc20Size + erc20Diff).padStart(15 + erc20Diff.length) +
        (drmSize + drmDiff).padStart(25 + drmDiff.length),
    );
  }

  console.log('\n════════════════════════════════════════════════════════════════════════════════');

  // Find best configuration
  const bestConfig = results.reduce((best, current) => {
    const currentTotal = current.contracts.reduce((sum, c) => sum + c.size, 0);
    const bestTotal = best.contracts.reduce((sum, c) => sum + c.size, 0);
    return currentTotal < bestTotal ? current : best;
  });

  console.log(`\n🏆 Best Configuration: ${bestConfig.config}`);
  console.log(
    `   Total size: ${(bestConfig.contracts.reduce((sum, c) => sum + c.size, 0) / 1024).toFixed(2)} KB\n`,
  );

  // Save results to file
  const resultsPath = path.join(__dirname, '../docs/COMPILER_TEST_RESULTS.json');
  fs.writeFileSync(resultsPath, JSON.stringify(results, null, 2));
  console.log(`📄 Results saved to: ${resultsPath}\n`);
}

testCompilerSettings()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
