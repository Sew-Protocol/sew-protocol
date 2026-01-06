import { HardhatUserConfig } from 'hardhat/config';
import '@nomicfoundation/hardhat-ethers'; // Required by hardhat-deploy-ethers (v3.x)
import '@nomicfoundation/hardhat-verify';
import '@nomicfoundation/hardhat-chai-matchers'; // For testing with chai
import '@typechain/hardhat'; // For TypeScript type generation
import '@openzeppelin/hardhat-upgrades';
import 'hardhat-deploy';
import 'hardhat-deploy-ethers'; // Extends hardhat-deploy with ethers integration - MUST come after hardhat-deploy
import { extendEnvironment } from 'hardhat/config';
import * as dotenv from 'dotenv';

dotenv.config();

// Workaround for hardhat-deploy compatibility with @nomicfoundation/hardhat-ethers v3.x
// hardhat-deploy expects provider.getSignerFrom but it's not provided by default
extendEnvironment(async (hre) => {
  // Add getSignerFrom method to provider if it doesn't exist
  if (hre.network.provider && !(hre.network.provider as any).getSignerFrom) {
    const provider = hre.network.provider;
    (provider as any).getSignerFrom = function(address: string) {
      // Use ethers provider to get signer - hardhat-deploy expects this method to exist
      // The actual implementation will use provider.getSigner anyway, so this is just a stub
      return (hre.ethers.provider as any).getSigner(address);
    };
  }
});

const PRIVATE_KEY = process.env.PRIVATE_KEY || '';
const DEPLOY_CONFIRM = (process.env.DEPLOY_CONFIRM || 'NO').toUpperCase();

function rpc(envKey: string) {
  return process.env[envKey] || '';
}

function accountsOrThrow(networkName: string) {
  if (!PRIVATE_KEY) throw new Error(`Missing PRIVATE_KEY for network: ${networkName}`);
  return [PRIVATE_KEY];
}

const config: HardhatUserConfig = {
  solidity: {
    version: "0.8.28",
    settings: {
      optimizer: {
        enabled: true,
        // https://docs.soliditylang.org/en/latest/using-the-compiler.html#optimizer-options
        runs: 50000, // Higher runs = smaller code size (but higher gas cost)
      },
      viaIR: true, // Enable IR-based code generation to reduce contract size
      evmVersion: "cancun", // Use Cancun EVM version to support mcopy instruction
    },
  },
  paths: {
    sources: 'contracts',
    tests: 'test/hardhat',
    cache: 'cache',
    artifacts: 'artifacts',
  },
  namedAccounts: {
    deployer: { default: 0 },
  },
  networks: {
    hardhat: { 
      allowUnlimitedContractSize: true, // Allow large contracts in test environment only
      chainId: 31337
    },
    baseSepolia: { url: rpc('RPC_BASE_SEPOLIA'), accounts: accountsOrThrow('baseSepolia'), chainId: 84532 },
    base: { url: rpc('RPC_BASE_MAINNET'), accounts: accountsOrThrow('base'), chainId: 8453 },
    ethereum: { url: rpc('RPC_ETHEREUM'), accounts: accountsOrThrow('ethereum'), chainId: 1 },
  },
  etherscan: {
    apiKey: {
      baseSepolia: process.env.BASESCAN_API_KEY || process.env.ETHERSCAN_API_KEY || '',
      base: process.env.BASESCAN_API_KEY || process.env.ETHERSCAN_API_KEY || '',
      mainnet: process.env.ETHERSCAN_API_KEY || '',
    },
  },
};

export default config;

export function requireConfirmForMainnetLike(networkName: string) {
  const mainnetLike = ['ethereum', 'mainnet', 'base'].includes(networkName);
  if (mainnetLike && DEPLOY_CONFIRM !== 'YES') {
    throw new Error('Refusing mainnet-like action without DEPLOY_CONFIRM=YES');
  }
}
