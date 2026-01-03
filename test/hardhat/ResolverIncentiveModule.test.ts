/**
 * ResolverIncentiveModule Tests
 * 
 * Tests for resolver payment tracking and distribution:
 * - Resolver recording
 * - Fee recording (escrow and escalation)
 * - Payment calculation and distribution
 * - Governance functions (library upgrades, share percentage, weights)
 * - Library swapping functionality
 */

import { expect } from "chai";
import { ethers } from "hardhat";
import { time } from "@nomicfoundation/hardhat-network-helpers";
import { 
  ResolverIncentiveModule,
  PaymentCalculationLibraryV1
} from "../../typechain-types";
import { ERC20Mock } from "../../typechain-types";
import { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";

describe("ResolverIncentiveModule", function () {
  let incentiveModule: ResolverIncentiveModule;
  let paymentLibV1: PaymentCalculationLibraryV1;
  let deployer: SignerWithAddress;
  let timelock: SignerWithAddress;
  let resolver1: SignerWithAddress;
  let resolver2: SignerWithAddress;
  let resolver3: SignerWithAddress;
  let escrowContract: SignerWithAddress;
  let token: any; // Mock ERC20

  const RESOLVER_SHARE_PERCENTAGE = 5000; // 50%
  const SLOW_DELAY = 7 * 24 * 60 * 60; // 7 days

  beforeEach(async function () {
    [deployer, timelock, resolver1, resolver2, resolver3, escrowContract] = await ethers.getSigners();

    // Deploy PaymentCalculationLibraryV1
    const PaymentLibFactory = await ethers.getContractFactory("PaymentCalculationLibraryV1");
    paymentLibV1 = await PaymentLibFactory.deploy();
    await paymentLibV1.waitForDeployment();

    // Deploy ResolverIncentiveModule
    const IncentiveModuleFactory = await ethers.getContractFactory("ResolverIncentiveModule");
    incentiveModule = await IncentiveModuleFactory.deploy(
      deployer.address,
      await paymentLibV1.getAddress()
    );
    await incentiveModule.waitForDeployment();

    // Grant ROLE_TIMELOCK to timelock
    const ROLE_TIMELOCK = await incentiveModule.ROLE_TIMELOCK();
    await incentiveModule.grantRole(ROLE_TIMELOCK, timelock.address);

    // Register escrow contract
    await incentiveModule.registerEscrowContract(escrowContract.address);

    // Deploy mock ERC20 token
    const ERC20Factory = await ethers.getContractFactory("ERC20Mock");
    token = await ERC20Factory.deploy("Test Token", "TEST", deployer.address, ethers.parseEther("1000000"));
    await token.waitForDeployment();
    
    // Transfer tokens to escrow contract for payments
    await token.transfer(escrowContract.address, ethers.parseEther("10000"));
  });

  describe("Initialization", function () {
    it("Should initialize with correct library", async function () {
      expect(await incentiveModule.currentPaymentLibrary()).to.equal(await paymentLibV1.getAddress());
    });

    it("Should initialize with correct resolver share percentage", async function () {
      expect(await incentiveModule.resolverSharePercentage()).to.equal(RESOLVER_SHARE_PERCENTAGE);
    });

    it("Should initialize with correct weights", async function () {
      const weights = await incentiveModule.weights();
      expect(weights.level0).to.equal(10000);
      expect(weights.level1).to.equal(15000);
      expect(weights.level2).to.equal(20000);
    });
  });

  describe("Resolver Recording", function () {
    it("Should record resolver for dispute", async function () {
      const workflowId = 1;
      
      await expect(
        incentiveModule.connect(escrowContract).recordResolver(workflowId, resolver1.address, 0)
      ).to.emit(incentiveModule, "ResolverRecorded")
        .withArgs(workflowId, resolver1.address, 0, anyValue);

      const resolvers = await incentiveModule.getDisputeResolvers(workflowId);
      expect(resolvers.length).to.equal(1);
      expect(resolvers[0].resolver).to.equal(resolver1.address);
      expect(resolvers[0].level).to.equal(0);
    });

    it("Should record multiple resolvers for same dispute", async function () {
      const workflowId = 1;
      
      await incentiveModule.connect(escrowContract).recordResolver(workflowId, resolver1.address, 0);
      await incentiveModule.connect(escrowContract).recordResolver(workflowId, resolver2.address, 1);
      
      const resolvers = await incentiveModule.getDisputeResolvers(workflowId);
      expect(resolvers.length).to.equal(2);
      expect(resolvers[0].resolver).to.equal(resolver1.address);
      expect(resolvers[1].resolver).to.equal(resolver2.address);
    });

    it("Should not duplicate resolver records", async function () {
      const workflowId = 1;
      
      await incentiveModule.connect(escrowContract).recordResolver(workflowId, resolver1.address, 0);
      await incentiveModule.connect(escrowContract).recordResolver(workflowId, resolver1.address, 0);
      
      const resolvers = await incentiveModule.getDisputeResolvers(workflowId);
      expect(resolvers.length).to.equal(1);
    });

    it("Should reject recording from non-escrow contract", async function () {
      await expect(
        incentiveModule.recordResolver(1, resolver1.address, 0)
      ).to.be.revertedWith("Not registered escrow contract");
    });
  });

  describe("Fee Recording", function () {
    it("Should record escrow fee", async function () {
      const workflowId = 1;
      const fee = ethers.parseEther("100");
      
      await expect(
        incentiveModule.connect(escrowContract).recordEscrowFee(workflowId, await token.getAddress(), fee)
      ).to.emit(incentiveModule, "EscrowFeeRecorded")
        .withArgs(workflowId, await token.getAddress(), fee);

      const [escrowFee, escalationFees] = await incentiveModule.getDisputeFees(workflowId);
      expect(escrowFee).to.equal(fee);
      expect(escalationFees).to.equal(0);
    });

    it("Should record escalation fees", async function () {
      const workflowId = 1;
      const fee1 = ethers.parseEther("50");
      const fee2 = ethers.parseEther("30");
      
      await incentiveModule.connect(escrowContract).recordEscalationFee(workflowId, await token.getAddress(), fee1);
      await incentiveModule.connect(escrowContract).recordEscalationFee(workflowId, await token.getAddress(), fee2);
      
      const [escrowFee, escalationFees] = await incentiveModule.getDisputeFees(workflowId);
      expect(escrowFee).to.equal(0);
      expect(escalationFees).to.equal(fee1 + fee2);
    });
  });

  describe("Payment Distribution", function () {
    beforeEach(async function () {
      // Setup dispute with resolvers and fees
      const workflowId = 1;
      await incentiveModule.connect(escrowContract).recordResolver(workflowId, resolver1.address, 0);
      await incentiveModule.connect(escrowContract).recordResolver(workflowId, resolver2.address, 1);
      await incentiveModule.connect(escrowContract).recordEscrowFee(workflowId, await token.getAddress(), ethers.parseEther("100"));
      await incentiveModule.connect(escrowContract).recordEscalationFee(workflowId, await token.getAddress(), ethers.parseEther("50"));
      
      // Transfer tokens to incentive module (it will distribute from its own balance)
      await token.connect(escrowContract).transfer(await incentiveModule.getAddress(), ethers.parseEther("100"));
    });

    it("Should calculate and distribute payments", async function () {
      const workflowId = 1;
      
      const balance1Before = await token.balanceOf(resolver1.address);
      const balance2Before = await token.balanceOf(resolver2.address);
      
      await expect(
        incentiveModule.connect(escrowContract).onDisputeResolved(workflowId, await token.getAddress())
      ).to.emit(incentiveModule, "PaymentsDistributed");

      const balance1After = await token.balanceOf(resolver1.address);
      const balance2After = await token.balanceOf(resolver2.address);
      
      // Total fees: 100 + 50 = 150
      // Resolver share: 150 * 50% = 75
      // Resolver1 (level 0, weight 1.0): 75 * 10000 / (10000 + 15000) = 30
      // Resolver2 (level 1, weight 1.5): 75 * 15000 / (10000 + 15000) = 45
      expect(balance1After - balance1Before).to.equal(ethers.parseEther("30"));
      expect(balance2After - balance2Before).to.equal(ethers.parseEther("45"));
    });

    it("Should mark payments as distributed", async function () {
      const workflowId = 1;
      
      expect(await incentiveModule.arePaymentsDistributed(workflowId)).to.be.false;
      
      await incentiveModule.connect(escrowContract).onDisputeResolved(workflowId, await token.getAddress());
      
      expect(await incentiveModule.arePaymentsDistributed(workflowId)).to.be.true;
    });

    it("Should not distribute payments twice", async function () {
      const workflowId = 1;
      
      await incentiveModule.connect(escrowContract).onDisputeResolved(workflowId, await token.getAddress());
      
      await expect(
        incentiveModule.connect(escrowContract).onDisputeResolved(workflowId, await token.getAddress())
      ).to.be.revertedWith("Payments already distributed");
    });
  });

  describe("Library Swapping", function () {
    it("Should queue new payment library", async function () {
      // Deploy V2 library (using V1 as V2 for testing - same interface)
      const PaymentLibV2Factory = await ethers.getContractFactory("PaymentCalculationLibraryV1");
      const paymentLibV2 = await PaymentLibV2Factory.deploy();
      await paymentLibV2.waitForDeployment();

      await expect(
        incentiveModule.connect(timelock).queuePaymentCalculationLibrary(await paymentLibV2.getAddress())
      ).to.emit(incentiveModule, "PaymentLibraryQueued")
        .withArgs(await paymentLibV1.getAddress(), await paymentLibV2.getAddress(), anyValue);

      const [newLib, eta, exists] = await incentiveModule.getPendingPaymentLibrary();
      expect(newLib).to.equal(await paymentLibV2.getAddress());
      expect(exists).to.be.true;
      expect(eta).to.be.greaterThan(await time.latest());
    });

    it("Should not activate library before delay", async function () {
      const PaymentLibV2Factory = await ethers.getContractFactory("PaymentCalculationLibraryV1");
      const paymentLibV2 = await PaymentLibV2Factory.deploy();
      await paymentLibV2.waitForDeployment();

      await incentiveModule.connect(timelock).queuePaymentCalculationLibrary(await paymentLibV2.getAddress());

      await expect(
        incentiveModule.connect(timelock).activatePaymentCalculationLibrary()
      ).to.be.reverted;
    });

    it("Should activate library after delay", async function () {
      const PaymentLibV2Factory = await ethers.getContractFactory("PaymentCalculationLibraryV1");
      const paymentLibV2 = await PaymentLibV2Factory.deploy();
      await paymentLibV2.waitForDeployment();

      await incentiveModule.connect(timelock).queuePaymentCalculationLibrary(await paymentLibV2.getAddress());
      
      // Fast forward time
      await time.increase(SLOW_DELAY + 1);

      await expect(
        incentiveModule.connect(timelock).activatePaymentCalculationLibrary()
      ).to.emit(incentiveModule, "PaymentLibraryActivated")
        .withArgs(await paymentLibV1.getAddress(), await paymentLibV2.getAddress());

      expect(await incentiveModule.currentPaymentLibrary()).to.equal(await paymentLibV2.getAddress());
    });

    it("Should validate library before queueing", async function () {
      await expect(
        incentiveModule.connect(timelock).queuePaymentCalculationLibrary(ethers.ZeroAddress)
      ).to.be.revertedWith("Zero address");

      await expect(
        incentiveModule.connect(timelock).queuePaymentCalculationLibrary(deployer.address)
      ).to.be.revertedWith("Invalid library");
    });

    it("Should allow rollback to previous library", async function () {
      const PaymentLibV2Factory = await ethers.getContractFactory("PaymentCalculationLibraryV1");
      const paymentLibV2 = await PaymentLibV2Factory.deploy();
      await paymentLibV2.waitForDeployment();

      await incentiveModule.connect(timelock).queuePaymentCalculationLibrary(await paymentLibV2.getAddress());
      await time.increase(SLOW_DELAY + 1);
      await incentiveModule.connect(timelock).activatePaymentCalculationLibrary();

      await expect(
        incentiveModule.connect(timelock).rollbackToPreviousLibrary(await paymentLibV1.getAddress())
      ).to.emit(incentiveModule, "PaymentLibraryRolledBack")
        .withArgs(await paymentLibV1.getAddress());

      expect(await incentiveModule.currentPaymentLibrary()).to.equal(await paymentLibV1.getAddress());
    });
  });

  describe("Governance Functions", function () {
    it("Should queue resolver share percentage change", async function () {
      const newPercentage = 6000; // 60%
      
      await expect(
        incentiveModule.connect(timelock).queueResolverSharePercentage(newPercentage)
      ).to.emit(incentiveModule, "ResolverSharePercentageQueued")
        .withArgs(RESOLVER_SHARE_PERCENTAGE, newPercentage, anyValue);
    });

    it("Should activate resolver share percentage after delay", async function () {
      const newPercentage = 6000;
      
      await incentiveModule.connect(timelock).queueResolverSharePercentage(newPercentage);
      await time.increase(SLOW_DELAY + 1);

      await expect(
        incentiveModule.connect(timelock).activateResolverSharePercentage()
      ).to.emit(incentiveModule, "ResolverSharePercentageActivated")
        .withArgs(RESOLVER_SHARE_PERCENTAGE, newPercentage);

      expect(await incentiveModule.resolverSharePercentage()).to.equal(newPercentage);
    });

    it("Should queue weights change", async function () {
      const newWeights = {
        level0: 12000,
        level1: 18000,
        level2: 25000
      };
      
      await expect(
        incentiveModule.connect(timelock).queueWeights(newWeights)
      ).to.emit(incentiveModule, "WeightsQueued");
    });

    it("Should activate weights after delay", async function () {
      const newWeights = {
        level0: 12000,
        level1: 18000,
        level2: 25000
      };
      
      await incentiveModule.connect(timelock).queueWeights(newWeights);
      await time.increase(SLOW_DELAY + 1);

      await expect(
        incentiveModule.connect(timelock).activateWeights()
      ).to.emit(incentiveModule, "WeightsActivated");

      const weights = await incentiveModule.weights();
      expect(weights.level0).to.equal(12000);
      expect(weights.level1).to.equal(18000);
      expect(weights.level2).to.equal(25000);
    });
  });

  // Helper for matching any value in events
  const anyValue = (value: any) => true;
});

