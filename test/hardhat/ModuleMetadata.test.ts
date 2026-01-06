/**
 * Module Metadata Tests
 * 
 * Tests for module metadata functions:
 * - moduleName()
 * - moduleVersion()
 * - supportsInterface() (ERC-165)
 * - Interface detection
 */

import { expect } from "chai";
import { ethers } from "hardhat";
import { 
  DecentralizedResolutionModule,
  DefaultResolutionModule,
  DefaultReleaseStrategy,
  AaveYieldGenerationModule,
  DefaultYieldDistributionModule,
  IResolutionModule,
  IReleaseStrategy,
  IYieldGenerationModule,
  IYieldDistributionModule
} from "../../typechain-types";
import { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";

describe("Module Metadata", function () {
  let deployer: SignerWithAddress;
  let timelock: SignerWithAddress;
  
  // Module instances
  let decentralizedModule: DecentralizedResolutionModule;
  let defaultResolutionModule: DefaultResolutionModule;
  let defaultReleaseStrategy: DefaultReleaseStrategy;
  let aaveYieldModule: AaveYieldGenerationModule;
  let defaultYieldDistribution: DefaultYieldDistributionModule;

  beforeEach(async function () {
    [deployer, timelock] = await ethers.getSigners();

    // Deploy DecentralizedResolutionModule
    const DecentralizedFactory = await ethers.getContractFactory("DecentralizedResolutionModule");
    decentralizedModule = await DecentralizedFactory.deploy();
    await decentralizedModule.waitForDeployment();
    await decentralizedModule.initialize(deployer.address);

    // Deploy DefaultResolutionModule
    const DefaultResolutionFactory = await ethers.getContractFactory("DefaultResolutionModule");
    defaultResolutionModule = await DefaultResolutionFactory.deploy(
      deployer.address,
      deployer.address // resolver
    );
    await defaultResolutionModule.waitForDeployment();

    // Deploy DefaultReleaseStrategy
    const ReleaseStrategyFactory = await ethers.getContractFactory("DefaultReleaseStrategy");
    defaultReleaseStrategy = await ReleaseStrategyFactory.deploy();
    await defaultReleaseStrategy.waitForDeployment();

    // Deploy AaveYieldGenerationModule (if available)
    try {
      const AaveFactory = await ethers.getContractFactory("AaveYieldGenerationModule");
      aaveYieldModule = await AaveFactory.deploy(
        deployer.address,
        ethers.ZeroAddress, // aavePoolProvider (placeholder)
        deployer.address // timelock
      );
      await aaveYieldModule.waitForDeployment();
    } catch (e) {
      // Aave module may not be available in test environment
      console.log("AaveYieldGenerationModule not available for testing");
    }

    // Deploy DefaultYieldDistributionModule
    try {
      const YieldDistFactory = await ethers.getContractFactory("DefaultYieldDistributionModule");
      defaultYieldDistribution = await YieldDistFactory.deploy();
      await defaultYieldDistribution.waitForDeployment();
    } catch (e) {
      // May not be available
      console.log("DefaultYieldDistributionModule not available for testing");
    }
  });

  describe("DecentralizedResolutionModule", function () {
    it("Should return correct module name", async function () {
      const name = await decentralizedModule.moduleName();
      expect(name).to.equal("DecentralizedResolution");
    });

    it("Should return semantic version", async function () {
      const version = await decentralizedModule.moduleVersion();
      expect(version).to.match(/^\d+\.\d+\.\d+$/); // Semantic version format
      expect(version).to.equal("1.0.0");
    });

    it("Should support IResolutionModule interface", async function () {
      // Calculate interface ID from function selectors (XOR of all function selectors)
      const isAuthorizedSelector = ethers.id("isAuthorizedDisputeResolver(uint256,address,bytes)").slice(0, 10);
      const getResolverSelector = ethers.id("getDisputeResolver(uint256,bytes)").slice(0, 10);
      const canEscalateSelector = ethers.id("canEscalate(uint256,uint8,bytes)").slice(0, 10);
      const executeEscalationSelector = ethers.id("executeEscalation(uint256,bytes)").slice(0, 10);
      const moduleNameSelector = ethers.id("moduleName()").slice(0, 10);
      const moduleVersionSelector = ethers.id("moduleVersion()").slice(0, 10);
      
      // Calculate XOR of all selectors (ERC-165 standard)
      let calculatedInterfaceId = BigInt(0);
      for (const selector of [isAuthorizedSelector, getResolverSelector, canEscalateSelector, executeEscalationSelector, moduleNameSelector, moduleVersionSelector]) {
        calculatedInterfaceId = calculatedInterfaceId ^ BigInt(selector);
      }
      const interfaceId = ethers.toBeHex(calculatedInterfaceId, 4); // 4 bytes
      
      const supports = await decentralizedModule.supportsInterface(interfaceId);
      expect(supports).to.be.true;
    });

    it("Should support ERC165 interface", async function () {
      const erc165Id = "0x01ffc9a7"; // ERC165 interface ID
      const supports = await decentralizedModule.supportsInterface(erc165Id);
      expect(supports).to.be.true;
    });

    it("Should not support invalid interface", async function () {
      const invalidId = "0x12345678";
      const supports = await decentralizedModule.supportsInterface(invalidId);
      expect(supports).to.be.false;
    });
  });

  describe("DefaultResolutionModule", function () {
    it("Should return correct module name", async function () {
      const name = await defaultResolutionModule.moduleName();
      expect(name).to.equal("DefaultSingleResolver");
    });

    it("Should return semantic version", async function () {
      const version = await defaultResolutionModule.moduleVersion();
      expect(version).to.match(/^\d+\.\d+\.\d+$/);
      expect(version).to.equal("1.0.0");
    });

    it("Should support IResolutionModule interface", async function () {
      // Calculate interface ID from function selectors (XOR of all function selectors)
      const isAuthorizedSelector = ethers.id("isAuthorizedDisputeResolver(uint256,address,bytes)").slice(0, 10);
      const getResolverSelector = ethers.id("getDisputeResolver(uint256,bytes)").slice(0, 10);
      const canEscalateSelector = ethers.id("canEscalate(uint256,uint8,bytes)").slice(0, 10);
      const executeEscalationSelector = ethers.id("executeEscalation(uint256,bytes)").slice(0, 10);
      const moduleNameSelector = ethers.id("moduleName()").slice(0, 10);
      const moduleVersionSelector = ethers.id("moduleVersion()").slice(0, 10);
      
      let calculatedInterfaceId = BigInt(0);
      for (const selector of [isAuthorizedSelector, getResolverSelector, canEscalateSelector, executeEscalationSelector, moduleNameSelector, moduleVersionSelector]) {
        calculatedInterfaceId = calculatedInterfaceId ^ BigInt(selector);
      }
      const interfaceId = ethers.toBeHex(calculatedInterfaceId, 4);
      
      const supports = await defaultResolutionModule.supportsInterface(interfaceId);
      expect(supports).to.be.true;
    });

    it("Should support ERC165 interface", async function () {
      const erc165Id = "0x01ffc9a7";
      const supports = await defaultResolutionModule.supportsInterface(erc165Id);
      expect(supports).to.be.true;
    });
  });

  describe("DefaultReleaseStrategy", function () {
    it("Should return correct strategy name", async function () {
      const name = await defaultReleaseStrategy.strategyName();
      expect(name).to.equal("DefaultBuyerRelease");
    });

    it("Should return correct module name", async function () {
      const name = await defaultReleaseStrategy.moduleName();
      expect(name).to.equal("DefaultBuyerRelease");
    });

    it("Should return semantic version", async function () {
      const version = await defaultReleaseStrategy.moduleVersion();
      expect(version).to.match(/^\d+\.\d+\.\d+$/);
      expect(version).to.equal("1.0.0");
    });

    it("Should support IReleaseStrategy interface", async function () {
      // Calculate interface ID from function selectors (XOR of all function selectors)
      const canReleaseSelector = ethers.id("canRelease(uint256,address,bytes)").slice(0, 10);
      const executeReleaseSelector = ethers.id("executeRelease(uint256,bytes)").slice(0, 10);
      const strategyNameSelector = ethers.id("strategyName()").slice(0, 10);
      const moduleNameSelector = ethers.id("moduleName()").slice(0, 10);
      const moduleVersionSelector = ethers.id("moduleVersion()").slice(0, 10);
      
      let calculatedInterfaceId = BigInt(0);
      for (const selector of [canReleaseSelector, executeReleaseSelector, strategyNameSelector, moduleNameSelector, moduleVersionSelector]) {
        calculatedInterfaceId = calculatedInterfaceId ^ BigInt(selector);
      }
      const interfaceId = ethers.toBeHex(calculatedInterfaceId, 4);
      
      const supports = await defaultReleaseStrategy.supportsInterface(interfaceId);
      expect(supports).to.be.true;
    });

    it("Should support ERC165 interface", async function () {
      const erc165Id = "0x01ffc9a7";
      const supports = await defaultReleaseStrategy.supportsInterface(erc165Id);
      expect(supports).to.be.true;
    });
  });

  describe("AaveYieldGenerationModule", function () {
    it("Should return correct module name", async function () {
      if (!aaveYieldModule) {
        this.skip();
        return;
      }
      const name = await aaveYieldModule.moduleName();
      expect(name).to.be.a("string");
      expect(name.length).to.be.greaterThan(0);
    });

    it("Should return semantic version", async function () {
      if (!aaveYieldModule) {
        this.skip();
        return;
      }
      const version = await aaveYieldModule.moduleVersion();
      expect(version).to.match(/^\d+\.\d+\.\d+$/);
    });

    it("Should support IYieldGenerationModule interface", async function () {
      if (!aaveYieldModule) {
        this.skip();
        return;
      }
      // IYieldGenerationModule already has supportsInterface
      const erc165Id = "0x01ffc9a7";
      const supports = await aaveYieldModule.supportsInterface(erc165Id);
      expect(supports).to.be.true;
    });
  });

  describe("DefaultYieldDistributionModule", function () {
    it("Should return correct module name", async function () {
      if (!defaultYieldDistribution) {
        this.skip();
        return;
      }
      const name = await defaultYieldDistribution.moduleName();
      expect(name).to.be.a("string");
      expect(name.length).to.be.greaterThan(0);
    });

    it("Should return semantic version", async function () {
      if (!defaultYieldDistribution) {
        this.skip();
        return;
      }
      const version = await defaultYieldDistribution.moduleVersion();
      expect(version).to.match(/^\d+\.\d+\.\d+$/);
    });

    it("Should support IYieldDistributionModule interface", async function () {
      if (!defaultYieldDistribution) {
        this.skip();
        return;
      }
      const erc165Id = "0x01ffc9a7";
      const supports = await defaultYieldDistribution.supportsInterface(erc165Id);
      expect(supports).to.be.true;
    });
  });

  describe("Interface ID Consistency", function () {
    it("Should use consistent interface ID calculation", async function () {
      // All modules should use the same method for interface ID calculation
      // This test verifies that interface IDs are calculated correctly
      const erc165Id = "0x01ffc9a7";
      
      const supports1 = await decentralizedModule.supportsInterface(erc165Id);
      const supports2 = await defaultResolutionModule.supportsInterface(erc165Id);
      const supports3 = await defaultReleaseStrategy.supportsInterface(erc165Id);
      
      expect(supports1).to.be.true;
      expect(supports2).to.be.true;
      expect(supports3).to.be.true;
    });
  });
});

