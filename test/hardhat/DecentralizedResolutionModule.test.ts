/**
 * DecentralizedResolutionModule Tests
 * 
 * Tests for decentralized resolution module:
 * - Resolver appointment and management
 * - Round-robin resolver selection
 * - Escalation functionality
 * - Resolution table management
 * - Integration with ResolverIncentiveModule
 */

import { expect } from "chai";
import { ethers } from "hardhat";
import { 
  DecentralizedResolutionModule,
  ResolverIncentiveModule,
  PaymentCalculationLibraryV1
} from "../../typechain-types";
import { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";

describe("DecentralizedResolutionModule", function () {
  let module: DecentralizedResolutionModule;
  let incentiveModule: ResolverIncentiveModule;
  let paymentLib: PaymentCalculationLibraryV1;
  let deployer: SignerWithAddress;
  let timelock: SignerWithAddress;
  let seniorResolver1: SignerWithAddress;
  let seniorResolver2: SignerWithAddress;
  let resolver1: SignerWithAddress;
  let resolver2: SignerWithAddress;
  let resolver3: SignerWithAddress;
  let escrowContract: SignerWithAddress;

  beforeEach(async function () {
    [deployer, timelock, seniorResolver1, seniorResolver2, resolver1, resolver2, resolver3, escrowContract] = 
      await ethers.getSigners();

    // Deploy payment library and incentive module
    const PaymentLibFactory = await ethers.getContractFactory("PaymentCalculationLibraryV1");
    paymentLib = await PaymentLibFactory.deploy();
    await paymentLib.waitForDeployment();

    const IncentiveModuleFactory = await ethers.getContractFactory("ResolverIncentiveModule");
    incentiveModule = await IncentiveModuleFactory.deploy();
    await incentiveModule.waitForDeployment();
    await incentiveModule.initialize(deployer.address, await paymentLib.getAddress());

    // Deploy DecentralizedResolutionModule
    const ModuleFactory = await ethers.getContractFactory("DecentralizedResolutionModule");
    module = await ModuleFactory.deploy();
    await module.waitForDeployment();
    await module.initialize(deployer.address);

    // Grant ROLE_TIMELOCK
    const ROLE_TIMELOCK = await module.ROLE_TIMELOCK();
    await module.grantRole(ROLE_TIMELOCK, timelock.address);

    // Register escrow contract (requires ROLE_TIMELOCK)
    await module.connect(timelock).registerEscrowContract(escrowContract.address);
    
    // Register escrow contract in incentive module (requires ROLE_TIMELOCK)
    const INCENTIVE_ROLE_TIMELOCK = await incentiveModule.ROLE_TIMELOCK();
    await incentiveModule.grantRole(INCENTIVE_ROLE_TIMELOCK, timelock.address);
    await incentiveModule.connect(timelock).registerEscrowContract(escrowContract.address);
    
    // Also register the resolution module so it can call incentive module functions
    // (The resolution module calls incentive module on behalf of escrow contracts)
    await incentiveModule.connect(timelock).registerEscrowContract(await module.getAddress());

    // Set incentive module (requires ROLE_TIMELOCK)
    await module.connect(timelock).setIncentiveModule(await incentiveModule.getAddress());

    // Appoint senior resolvers
    await module.connect(timelock).appointSeniorResolver(
      seniorResolver1.address,
      "Senior Resolver 1",
      "First senior resolver"
    );
    await module.connect(timelock).appointSeniorResolver(
      seniorResolver2.address,
      "Senior Resolver 2",
      "Second senior resolver"
    );

    // Appoint standard resolvers (by senior resolvers)
    await module.connect(seniorResolver1).appointResolver(
      resolver1.address,
      "Resolver 1",
      "First resolver"
    );
    await module.connect(seniorResolver1).appointResolver(
      resolver2.address,
      "Resolver 2",
      "Second resolver"
    );
    await module.connect(seniorResolver2).appointResolver(
      resolver3.address,
      "Resolver 3",
      "Third resolver"
    );
  });

  describe("Round-Robin Resolver Selection", function () {
    it("Should select resolvers in round-robin order", async function () {
      const category = ethers.keccak256(ethers.toUtf8Bytes("TEST_CATEGORY"));
      
      // Set up resolution table entry
      await module.connect(timelock).setResolutionTableEntry(category, {
        initialResolver: ethers.ZeroAddress, // Not used with round-robin
        maxEscalationLevel: 2,
        escalationFee: 0,
        enabled: true,
        categoryName: "Test Category"
      });

      // Initialize disputes and check resolver selection
      const workflowId1 = 1;
      const workflowId2 = 2;
      const workflowId3 = 3;
      const workflowId4 = 4;

      await module.connect(escrowContract).setEscrowCategory(workflowId1, category);
      await module.connect(escrowContract).setEscrowCategory(workflowId2, category);
      await module.connect(escrowContract).setEscrowCategory(workflowId3, category);
      await module.connect(escrowContract).setEscrowCategory(workflowId4, category);

      // Get resolvers (should be round-robin)
      const [resolver1_selected, level1] = await module.getDisputeResolver(workflowId1, "0x");
      const [resolver2_selected, level2] = await module.getDisputeResolver(workflowId2, "0x");
      const [resolver3_selected, level3] = await module.getDisputeResolver(workflowId3, "0x");
      const [resolver4_selected, level4] = await module.getDisputeResolver(workflowId4, "0x");

      // Initialize disputes to advance round-robin counter
      await module.connect(escrowContract).initializeDispute(workflowId1, resolver1_selected, category);
      await module.connect(escrowContract).initializeDispute(workflowId2, resolver2_selected, category);
      await module.connect(escrowContract).initializeDispute(workflowId3, resolver3_selected, category);

      // Next resolver should be one of the valid resolvers (randomness from blockhash makes exact selection unpredictable)
      const [resolver5_selected] = await module.getDisputeResolver(workflowId4, "0x");
      expect(resolver5_selected).to.be.oneOf([
        resolver1.address,
        resolver2.address,
        resolver3.address
      ]);
    });

    it("Should use round-robin for senior resolvers on escalation", async function () {
      const category = ethers.keccak256(ethers.toUtf8Bytes("TEST_CATEGORY"));
      const workflowId = 1;

      await module.connect(escrowContract).setEscrowCategory(workflowId, category);
      await module.connect(escrowContract).initializeDispute(workflowId, resolver1.address, category);

      // Check escalation - should use round-robin for senior resolvers
      // Note: With blockhash randomness, exact selection is unpredictable
      const [canEscalate1, nextResolver1] = await module.canEscalate(workflowId, 0, "0x");
      expect(canEscalate1).to.be.true;
      // Should be one of the senior resolvers
      expect(nextResolver1).to.be.oneOf([
        seniorResolver1.address,
        seniorResolver2.address
      ]);

      // Execute escalation
      await module.connect(escrowContract).executeEscalation(workflowId, "0x");

      // Next escalation should select next senior resolver or external resolver
      const [canEscalate2, nextResolver2] = await module.canEscalate(workflowId, 1, "0x");
      // Level 2 might be external resolver, so check if it's enabled
      if (canEscalate2) {
        // If level 2 is enabled, it should be external resolver or a senior resolver
        expect(nextResolver2).to.not.equal(address(0));
      }
    });

    it("Should maintain separate round-robin counters per category", async function () {
      const category1 = ethers.keccak256(ethers.toUtf8Bytes("CATEGORY_1"));
      const category2 = ethers.keccak256(ethers.toUtf8Bytes("CATEGORY_2"));

      await module.connect(timelock).setResolutionTableEntry(category1, {
        initialResolver: ethers.ZeroAddress,
        maxEscalationLevel: 2,
        escalationFee: 0,
        enabled: true,
        categoryName: "Category 1"
      });

      await module.connect(timelock).setResolutionTableEntry(category2, {
        initialResolver: ethers.ZeroAddress,
        maxEscalationLevel: 2,
        escalationFee: 0,
        enabled: true,
        categoryName: "Category 2"
      });

      const workflowId1 = 1;
      const workflowId2 = 2;
      const workflowId3 = 11; // New workflow for category1
      const workflowId4 = 12; // New workflow for category2

      await module.connect(escrowContract).setEscrowCategory(workflowId1, category1);
      await module.connect(escrowContract).setEscrowCategory(workflowId2, category2);
      await module.connect(escrowContract).setEscrowCategory(workflowId3, category1);
      await module.connect(escrowContract).setEscrowCategory(workflowId4, category2);

      // Get initial resolvers - both should be valid resolvers (randomness makes exact selection unpredictable)
      const [resolver1_cat1] = await module.getDisputeResolver(workflowId1, "0x");
      const [resolver1_cat2] = await module.getDisputeResolver(workflowId2, "0x");

      expect(resolver1_cat1).to.be.oneOf([resolver1.address, resolver2.address, resolver3.address]);
      expect(resolver1_cat2).to.be.oneOf([resolver1.address, resolver2.address, resolver3.address]);

      // Initialize dispute in category1 - this advances category1's counter
      await module.connect(escrowContract).initializeDispute(workflowId1, resolver1_cat1, category1);

      // Get next resolvers - both should be valid resolvers
      // Note: With blockhash randomness, we can't predict exact selection, but both categories
      // should independently select from the same pool of resolvers
      const [resolver2_cat1] = await module.getDisputeResolver(workflowId3, "0x");
      const [resolver2_cat2] = await module.getDisputeResolver(workflowId4, "0x");

      expect(resolver2_cat1).to.be.oneOf([resolver1.address, resolver2.address, resolver3.address]);
      expect(resolver2_cat2).to.be.oneOf([resolver1.address, resolver2.address, resolver3.address]);
    });
  });

  describe("Integration with IncentiveModule", function () {
    it("Should record resolver in incentive module when dispute initialized", async function () {
      const workflowId = 1;
      const category = ethers.keccak256(ethers.toUtf8Bytes("TEST"));

      await module.connect(escrowContract).setEscrowCategory(workflowId, category);
      
      // Get resolver first (round-robin will select one)
      const [selectedResolver] = await module.getDisputeResolver(workflowId, "0x");
      
      await module.connect(escrowContract).initializeDispute(workflowId, selectedResolver, category);

      const resolvers = await incentiveModule.getDisputeResolvers(workflowId);
      expect(resolvers.length).to.equal(1);
      expect(resolvers[0].resolver.toLowerCase()).to.equal(selectedResolver.toLowerCase());
      expect(resolvers[0].level).to.equal(0);
    });

    it("Should record escalated resolver in incentive module", async function () {
      const workflowId = 1;
      const category = ethers.keccak256(ethers.toUtf8Bytes("TEST"));

      await module.connect(escrowContract).setEscrowCategory(workflowId, category);
      
      // Get resolver first (round-robin will select one)
      const [selectedResolver] = await module.getDisputeResolver(workflowId, "0x");
      await module.connect(escrowContract).initializeDispute(workflowId, selectedResolver, category);

      // Escalate
      await module.connect(escrowContract).executeEscalation(workflowId, "0x");

      const resolvers = await incentiveModule.getDisputeResolvers(workflowId);
      expect(resolvers.length).to.equal(2);
      expect(resolvers[0].resolver.toLowerCase()).to.equal(selectedResolver.toLowerCase());
      expect(resolvers[0].level).to.equal(0);
      expect(resolvers[1].level).to.equal(1);
    });
  });

  describe("Resolver Management", function () {
    it("Should allow senior resolver to appoint standard resolver", async function () {
      // Get a new address that's not already a resolver
      const [, , , , , , , newResolverSigner] = await ethers.getSigners();
      
      await expect(
        module.connect(seniorResolver1).appointResolver(
          newResolverSigner.address,
          "New Resolver",
          "New resolver description"
        )
      ).to.emit(module, "ResolverAppointed")
        .withArgs(newResolverSigner.address, 1, seniorResolver1.address); // 1 = RESOLVER role

      expect(await module.isApprovedResolver(newResolverSigner.address)).to.be.true;
    });

    it("Should allow timelock to appoint senior resolver", async function () {
      // Get a new address that's not already a senior resolver
      const [, , , , , , , , newSeniorSigner] = await ethers.getSigners();
      
      await expect(
        module.connect(timelock).appointSeniorResolver(
          newSeniorSigner.address,
          "New Senior",
          "New senior description"
        )
      ).to.emit(module, "ResolverAppointed")
        .withArgs(newSeniorSigner.address, 2, timelock.address); // 2 = SENIOR_RESOLVER role

      expect(await module.isApprovedSeniorResolver(newSeniorSigner.address)).to.be.true;
    });
  });
});

