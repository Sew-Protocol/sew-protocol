import { expect } from "chai";
import { ethers } from "hardhat";
import { BalanceAggregator, MultiL2EscrowAggregator, MulticallFallbackHandler } from "../typechain-types";

describe("Phase 3: Balance Aggregator Contracts", () => {
  let balanceAggregator: BalanceAggregator;
  let escrowAggregator: MultiL2EscrowAggregator;
  let fallbackHandler: MulticallFallbackHandler;
  let owner: any;
  let user: any;
  let multicall3Mock: any;
  let usdcMock: any;

  beforeEach(async () => {
    [owner, user] = await ethers.getSigners();

    // Mock Multicall3
    const Multicall3Mock = await ethers.getContractFactory("MockMulticall3");
    multicall3Mock = await Multicall3Mock.deploy();
    await multicall3Mock.waitForDeployment();

    // Mock USDC
    const MockERC20 = await ethers.getContractFactory("MockERC20");
    usdcMock = await MockERC20.deploy("USDC", "USDC");
    await usdcMock.waitForDeployment();

    // Deploy contracts
    const BalanceAggregator = await ethers.getContractFactory("BalanceAggregator");
    balanceAggregator = await BalanceAggregator.deploy(await multicall3Mock.getAddress());
    await balanceAggregator.waitForDeployment();

    const MultiL2EscrowAggregator = await ethers.getContractFactory("MultiL2EscrowAggregator");
    escrowAggregator = await MultiL2EscrowAggregator.deploy(
      await multicall3Mock.getAddress(),
      await usdcMock.getAddress()
    );
    await escrowAggregator.waitForDeployment();

    const MulticallFallbackHandler = await ethers.getContractFactory("MulticallFallbackHandler");
    fallbackHandler = await MulticallFallbackHandler.deploy(
      await multicall3Mock.getAddress(),
      await escrowAggregator.getAddress(),
      3600
    );
    await fallbackHandler.waitForDeployment();
  });

  describe("BalanceAggregator", () => {
    it("should deploy with valid multicall3 address", async () => {
      expect(await balanceAggregator.multicall3()).to.equal(await multicall3Mock.getAddress());
    });

    it("should reject zero address multicall3", async () => {
      const BalanceAggregator = await ethers.getContractFactory("BalanceAggregator");
      await expect(
        BalanceAggregator.deploy(ethers.ZeroAddress)
      ).to.be.revertedWithCustomError(BalanceAggregator, "InvalidMulticall3Address");
    });

    it("should update multicall3 address by owner", async () => {
      const MockMulticall3 = await ethers.getContractFactory("MockMulticall3");
      const newMulticall = await MockMulticall3.deploy();
      await newMulticall.waitForDeployment();

      await balanceAggregator.setMulticall3(await newMulticall.getAddress());
      expect(await balanceAggregator.multicall3()).to.equal(await newMulticall.getAddress());
    });

    it("should reject zero address when updating multicall3", async () => {
      await expect(
        balanceAggregator.setMulticall3(ethers.ZeroAddress)
      ).to.be.revertedWithCustomError(balanceAggregator, "InvalidMulticall3Address");
    });

    it("should encode balance call correctly", async () => {
      const encoded = await balanceAggregator.encodeBalanceCall(
        await usdcMock.getAddress(),
        user.address
      );
      expect(encoded.length).to.be.greaterThan(10);
      expect(encoded.substring(0, 10)).to.equal("0x70a08231"); // balanceOf selector
    });

    it("should decode balance result correctly", async () => {
      const balance = ethers.parseEther("100");
      const encoded = ethers.AbiCoder.defaultAbiCoder().encode(["uint256"], [balance]);
      const decoded = await balanceAggregator.decodeBalanceResult(encoded);
      expect(decoded).to.equal(balance);
    });

    it("should reject empty calls array", async () => {
      await expect(
        balanceAggregator.aggregateBalances(user.address, [], [])
      ).to.be.revertedWithCustomError(balanceAggregator, "NoResults");
    });

    it("should emit event on successful multicall", async () => {
      const tokenAddresses = [await usdcMock.getAddress()];
      const calls = [await balanceAggregator.encodeBalanceCall(tokenAddresses[0], user.address)];

      // Setup mock response
      const returnData = [
        { success: true, returnData: ethers.AbiCoder.defaultAbiCoder().encode(["uint256"], [ethers.parseEther("100")]) }
      ];
      await multicall3Mock.setReturnData(returnData);

      // Expect event emission
      await expect(balanceAggregator.aggregateBalances(user.address, tokenAddresses, calls))
        .to.emit(balanceAggregator, "BalanceQueried")
        .withArgs(user.address, 1);
    });
  });

  describe("MultiL2EscrowAggregator", () => {
    it("should deploy with valid addresses", async () => {
      expect(await escrowAggregator.multicall3()).to.equal(await multicall3Mock.getAddress());
      expect(await escrowAggregator.usdcAddress()).to.equal(await usdcMock.getAddress());
    });

    it("should reject zero address for multicall3", async () => {
      const MultiL2EscrowAggregator = await ethers.getContractFactory("MultiL2EscrowAggregator");
      await expect(
        MultiL2EscrowAggregator.deploy(ethers.ZeroAddress, await usdcMock.getAddress())
      ).to.be.revertedWithCustomError(MultiL2EscrowAggregator, "InvalidMulticallAddress");
    });

    it("should reject zero address for USDC", async () => {
      const MultiL2EscrowAggregator = await ethers.getContractFactory("MultiL2EscrowAggregator");
      await expect(
        MultiL2EscrowAggregator.deploy(await multicall3Mock.getAddress(), ethers.ZeroAddress)
      ).to.be.revertedWithCustomError(MultiL2EscrowAggregator, "InvalidUSDCAddress");
    });

    it("should update multicall3 address", async () => {
      const MockMulticall3 = await ethers.getContractFactory("MockMulticall3");
      const newMulticall = await MockMulticall3.deploy();
      await newMulticall.waitForDeployment();

      await escrowAggregator.setMulticall3(await newMulticall.getAddress());
      expect(await escrowAggregator.multicall3()).to.equal(await newMulticall.getAddress());
    });

    it("should update USDC address", async () => {
      const MockERC20 = await ethers.getContractFactory("MockERC20");
      const newUSDC = await MockERC20.deploy("USDC", "USDC");
      await newUSDC.waitForDeployment();

      await escrowAggregator.setUSDCAddress(await newUSDC.getAddress());
      expect(await escrowAggregator.usdcAddress()).to.equal(await newUSDC.getAddress());
    });

    it("should reject empty escrow list", async () => {
      await expect(
        escrowAggregator.queryEscrows(user.address, [])
      ).to.be.revertedWithCustomError(escrowAggregator, "EmptyEscrowList");
    });

    it("should emit QueryExecuted event on successful query", async () => {
      const MockEscrow = await ethers.getContractFactory("MockEscrow");
      const escrow = await MockEscrow.deploy();
      await escrow.waitForDeployment();

      const queries = [
        { chainId: 1, escrowAddress: await escrow.getAddress() }
      ];

      const returnData = [
        { success: true, returnData: ethers.AbiCoder.defaultAbiCoder().encode(["uint256"], [ethers.parseEther("50")]) },
        { success: true, returnData: ethers.AbiCoder.defaultAbiCoder().encode(["bool"], [true]) }
      ];
      await multicall3Mock.setReturnData(returnData);

      await expect(escrowAggregator.queryEscrows(user.address, queries))
        .to.emit(escrowAggregator, "QueryExecuted")
        .withArgs(user.address, 1);
    });
  });

  describe("MulticallFallbackHandler", () => {
    it("should deploy with valid configuration", async () => {
      expect(await fallbackHandler.primaryMulticall()).to.equal(await multicall3Mock.getAddress());
      const config = await fallbackHandler.fallbackConfig();
      expect(config.fallbackAggregator).to.equal(await escrowAggregator.getAddress());
      expect(config.fallbackTimeout).to.equal(3600);
    });

    it("should reject zero address primary multicall", async () => {
      const MulticallFallbackHandler = await ethers.getContractFactory("MulticallFallbackHandler");
      await expect(
        MulticallFallbackHandler.deploy(
          ethers.ZeroAddress,
          await escrowAggregator.getAddress(),
          3600
        )
      ).to.be.revertedWithCustomError(MulticallFallbackHandler, "InvalidPrimaryMulticall");
    });

    it("should add endpoint", async () => {
      await fallbackHandler.addEndpoint(1, "https://eth-mainnet.g.alchemy.com/v2/demo", 1);
      const endpoint = await fallbackHandler.getEndpoint(1);

      expect(endpoint.chainId).to.equal(1);
      expect(endpoint.priority).to.equal(1);
      expect(endpoint.enabled).to.equal(true);
    });

    it("should disable endpoint", async () => {
      await fallbackHandler.addEndpoint(1, "https://eth-mainnet.g.alchemy.com/v2/demo", 1);
      await fallbackHandler.disableEndpoint(1);

      await expect(fallbackHandler.getEndpoint(1))
        .to.be.revertedWithCustomError(fallbackHandler, "EndpointDisabled");
    });

    it("should enable endpoint", async () => {
      await fallbackHandler.addEndpoint(1, "https://eth-mainnet.g.alchemy.com/v2/demo", 1);
      await fallbackHandler.disableEndpoint(1);
      await fallbackHandler.enableEndpoint(1);

      const endpoint = await fallbackHandler.getEndpoint(1);
      expect(endpoint.enabled).to.equal(true);
    });

    it("should check endpoint health", async () => {
      await fallbackHandler.addEndpoint(1, "https://eth-mainnet.g.alchemy.com/v2/demo", 1);
      const isHealthy = await fallbackHandler.isEndpointHealthy(1);
      expect(isHealthy).to.equal(true);
    });

    it("should reject queries on disabled endpoint", async () => {
      await fallbackHandler.addEndpoint(1, "https://eth-mainnet.g.alchemy.com/v2/demo", 1);
      await fallbackHandler.disableEndpoint(1);

      const calls: any[] = [];
      await expect(
        fallbackHandler.executeWithFallback(calls, 1)
      ).to.be.revertedWithCustomError(fallbackHandler, "EndpointDisabled");
    });

    it("should update fallback configuration", async () => {
      const MockEscrow = await ethers.getContractFactory("MockEscrow");
      const newEscrow = await MockEscrow.deploy();
      await newEscrow.waitForDeployment();

      await fallbackHandler.setFallbackConfig(await newEscrow.getAddress(), 7200);
      const config = await fallbackHandler.fallbackConfig();

      expect(config.fallbackAggregator).to.equal(await newEscrow.getAddress());
      expect(config.fallbackTimeout).to.equal(7200);
    });

    it("should emit event when endpoint is added", async () => {
      await expect(fallbackHandler.addEndpoint(1, "https://eth-mainnet.g.alchemy.com/v2/demo", 1))
        .to.emit(fallbackHandler, "EndpointUpdated")
        .withArgs(1, "https://eth-mainnet.g.alchemy.com/v2/demo");
    });

    it("should emit event when fallback config is updated", async () => {
      const MockEscrow = await ethers.getContractFactory("MockEscrow");
      const newEscrow = await MockEscrow.deploy();
      await newEscrow.waitForDeployment();

      await expect(fallbackHandler.setFallbackConfig(await newEscrow.getAddress(), 7200))
        .to.emit(fallbackHandler, "FallbackConfigUpdated")
        .withArgs(await newEscrow.getAddress(), 7200);
    });
  });

  describe("Integration", () => {
    it("should support multi-chain endpoint management", async () => {
      const chains = [1, 8453, 42161, 10]; // Ethereum, Base, Arbitrum, Optimism

      for (const chainId of chains) {
        await fallbackHandler.addEndpoint(
          chainId,
          `https://rpc-${chainId}.example.com`,
          1
        );
      }

      for (const chainId of chains) {
        const endpoint = await fallbackHandler.getEndpoint(chainId);
        expect(endpoint.chainId).to.equal(chainId);
        expect(endpoint.enabled).to.equal(true);
      }
    });

    it("should handle endpoint health checks", async () => {
      await fallbackHandler.addEndpoint(1, "https://eth.example.com", 1);
      
      expect(await fallbackHandler.isEndpointHealthy(1)).to.equal(true);
      
      await fallbackHandler.disableEndpoint(1);
      expect(await fallbackHandler.isEndpointHealthy(1)).to.equal(false);
      
      await fallbackHandler.enableEndpoint(1);
      expect(await fallbackHandler.isEndpointHealthy(1)).to.equal(true);
    });

    it("should allow ownership transfer for aggregators", async () => {
      await balanceAggregator.transferOwnership(user.address);
      expect(await balanceAggregator.owner()).to.equal(user.address);
    });
  });
});
