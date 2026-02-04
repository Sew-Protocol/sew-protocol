import { ethers } from "hardhat";
import * as fs from "fs";
import * as path from "path";

interface DeploymentConfig {
  chainId: number;
  multicall3Address: string;
  usdcAddress: string;
  rpcEndpoints: {
    primary: string;
    backups: string[];
  };
  governorAddress: string;
}

const CHAIN_CONFIGS: Record<number, DeploymentConfig> = {
  1: {
    chainId: 1,
    multicall3Address: "0xcA11bde05977b3631167028862bE2a173976CA11",
    usdcAddress: "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
    rpcEndpoints: {
      primary: "https://eth-mainnet.g.alchemy.com/v2/${ALCHEMY_KEY}",
      backups: [
        "https://eth-mainnet.infura.io/v3/${INFURA_KEY}",
        "https://eth.public-rpc.com",
      ],
    },
    governorAddress: "", // Set via environment
  },
  11155111: {
    chainId: 11155111,
    multicall3Address: "0xcA11bde05977b3631167028862bE2a173976CA11",
    usdcAddress: "0xda9d4f9b69ac6C22e444eD9aF0DfF72693DDA42A",
    rpcEndpoints: {
      primary: "https://sepolia.g.alchemy.com/v2/${ALCHEMY_KEY}",
      backups: [
        "https://sepolia.infura.io/v3/${INFURA_KEY}",
        "https://sepolia.drpc.org",
      ],
    },
    governorAddress: "",
  },
  8453: {
    chainId: 8453,
    multicall3Address: "0xcA11bde05977b3631167028862bE2a173976CA11",
    usdcAddress: "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913",
    rpcEndpoints: {
      primary: "https://base-mainnet.g.alchemy.com/v2/${ALCHEMY_KEY}",
      backups: [
        "https://base.infura.io/v3/${INFURA_KEY}",
        "https://base.publicrpc.com",
      ],
    },
    governorAddress: "",
  },
  84532: {
    chainId: 84532,
    multicall3Address: "0xcA11bde05977b3631167028862bE2a173976CA11",
    usdcAddress: "0x036CbD53842c5426634e7929541eC2318f3dCF7e",
    rpcEndpoints: {
      primary: "https://sepolia.base.org",
      backups: ["https://base-sepolia-rpc.publicnode.com"],
    },
    governorAddress: "",
  },
  42161: {
    chainId: 42161,
    multicall3Address: "0xcA11bde05977b3631167028862bE2a173976CA11",
    usdcAddress: "0xaf88d065e77c8cC2239327C5EDb3A432268e5831",
    rpcEndpoints: {
      primary: "https://arbitrum-mainnet.infura.io/v3/${INFURA_KEY}",
      backups: [
        "https://arb1.arbitrum.io/rpc",
        "https://arbitrum.publicrpc.com",
      ],
    },
    governorAddress: "",
  },
  421614: {
    chainId: 421614,
    multicall3Address: "0xcA11bde05977b3631167028862bE2a173976CA11",
    usdcAddress: "0x2c44b726c0991588f38461803f3a06d45b66bff5",
    rpcEndpoints: {
      primary: "https://sepolia-rollup.arbitrum.io/rpc",
      backups: ["https://arbitrum-sepolia-rpc.publicnode.com"],
    },
    governorAddress: "",
  },
  10: {
    chainId: 10,
    multicall3Address: "0xcA11bde05977b3631167028862bE2a173976CA11",
    usdcAddress: "0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85",
    rpcEndpoints: {
      primary: "https://optimism-mainnet.infura.io/v3/${INFURA_KEY}",
      backups: ["https://mainnet.optimism.io", "https://optimism.publicrpc.com"],
    },
    governorAddress: "",
  },
  11155420: {
    chainId: 11155420,
    multicall3Address: "0xcA11bde05977b3631167028862bE2a173976CA11",
    usdcAddress: "0x5fd84259d66Cd46628e51781750FEaF79e4663F6",
    rpcEndpoints: {
      primary: "https://sepolia.optimism.io",
      backups: ["https://optimism-sepolia-rpc.publicnode.com"],
    },
    governorAddress: "",
  },
};

async function deployPhase3(chainId: number = 11155111) {
  console.log(`\n📋 Phase 3: Balance Aggregator - Deployment Script`);
  console.log(`=====================================`);
  console.log(`Chain ID: ${chainId}`);

  const config = CHAIN_CONFIGS[chainId];
  if (!config) {
    throw new Error(`Unsupported chain ID: ${chainId}`);
  }

  const [deployer] = await ethers.getSigners();
  console.log(`Deployer: ${deployer.address}`);

  // Deploy BalanceAggregator
  console.log(`\n1️⃣  Deploying BalanceAggregator...`);
  const BalanceAggregator = await ethers.getContractFactory("BalanceAggregator");
  const balanceAggregator = await BalanceAggregator.deploy(config.multicall3Address);
  await balanceAggregator.waitForDeployment();
  const balanceAggregatorAddr = await balanceAggregator.getAddress();
  console.log(`   ✅ BalanceAggregator: ${balanceAggregatorAddr}`);

  // Deploy MultiL2EscrowAggregator
  console.log(`\n2️⃣  Deploying MultiL2EscrowAggregator...`);
  const MultiL2EscrowAggregator = await ethers.getContractFactory("MultiL2EscrowAggregator");
  const escrowAggregator = await MultiL2EscrowAggregator.deploy(
    config.multicall3Address,
    config.usdcAddress
  );
  await escrowAggregator.waitForDeployment();
  const escrowAggregatorAddr = await escrowAggregator.getAddress();
  console.log(`   ✅ MultiL2EscrowAggregator: ${escrowAggregatorAddr}`);

  // Deploy MulticallFallbackHandler
  console.log(`\n3️⃣  Deploying MulticallFallbackHandler...`);
  const MulticallFallbackHandler = await ethers.getContractFactory(
    "MulticallFallbackHandler"
  );
  const fallbackHandler = await MulticallFallbackHandler.deploy(
    config.multicall3Address,
    escrowAggregatorAddr,
    3600
  );
  await fallbackHandler.waitForDeployment();
  const fallbackHandlerAddr = await fallbackHandler.getAddress();
  console.log(`   ✅ MulticallFallbackHandler: ${fallbackHandlerAddr}`);

  // Configure endpoints on fallback handler
  console.log(`\n4️⃣  Configuring RPC endpoints...`);
  for (const [chain, cfg] of Object.entries(CHAIN_CONFIGS)) {
    const cid = parseInt(chain);
    const tx = await fallbackHandler.addEndpoint(
      cid,
      cfg.rpcEndpoints.primary,
      1
    );
    await tx.wait();
    console.log(`   ✅ Added endpoint for chain ${cid}`);
  }

  // Save deployment record
  const deployment = {
    chain: chainId,
    timestamp: new Date().toISOString(),
    deployer: deployer.address,
    contracts: {
      balanceAggregator: balanceAggregatorAddr,
      multiL2EscrowAggregator: escrowAggregatorAddr,
      multicallFallbackHandler: fallbackHandlerAddr,
    },
    config: {
      multicall3: config.multicall3Address,
      usdc: config.usdcAddress,
    },
  };

  const deployDir = path.join(__dirname, "../deployments/phase3");
  if (!fs.existsSync(deployDir)) {
    fs.mkdirSync(deployDir, { recursive: true });
  }

  const filename = path.join(deployDir, `${chainId}-deployment.json`);
  fs.writeFileSync(filename, JSON.stringify(deployment, null, 2));
  console.log(`\n📄 Deployment saved to ${filename}`);

  console.log(`\n✅ Phase 3 Deployment Complete`);
  console.log(`=====================================`);
  console.log(`
  ⚠️  NEXT STEPS:
  
  1. Add to contract registry:
     - Update L2AddressRegistry with new contract addresses
     - Set version tags and audit trail
  
  2. Configure RPC endpoints:
     - Update environment variables with real RPC URLs
     - Test health checks on all endpoints
  
  3. Set up monitoring:
     - Deploy keeper bot for health monitoring
     - Configure alert thresholds
     - Set fallback trigger conditions
  
  4. Frontend integration:
     - Import BalanceAggregator ABI
     - Implement multicall encoding helpers
     - Build balance display component
     - Add fallback UI for degraded mode
  
  5. Testing on testnet:
     - Deploy on Sepolia first
     - Verify multicall efficiency (should see 66-90% RPC reduction)
     - Test failover mechanisms
     - Validate balance aggregation across L2s
  `);

  return deployment;
}

if (require.main === module) {
  const chainId = parseInt(process.env.CHAIN_ID || "11155111");
  deployPhase3(chainId).catch((error) => {
    console.error("Deployment failed:", error);
    process.exitCode = 1;
  });
}

export { deployPhase3, CHAIN_CONFIGS };
