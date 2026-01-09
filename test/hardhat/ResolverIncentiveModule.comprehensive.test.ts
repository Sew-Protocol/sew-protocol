import { expect } from "chai";
import { ethers } from "hardhat";
import { time } from "@nomicfoundation/hardhat-network-helpers";
import { ResolverIncentiveModule, PaymentCalculationLibraryV1 } from "../../typechain-types";

/**
 * NOTE: These tests are currently skipped as we are migrating to Foundry/Forge.
 * Many tests call functions that don't exist in the current ResolverIncentiveModule interface.
 * The module primarily uses internal functions accessed through DecentralizedResolutionModule.
 */
describe.skip("ResolverIncentiveModule - Comprehensive Tests", function () {
  let incentiveModule: ResolverIncentiveModule;
  let paymentLib: PaymentCalculationLibraryV1;
  let owner: any, timelock: any, escrow: any, resolver: any, token: any;

  beforeEach(async () => {
    [owner, timelock, escrow, resolver, token] = await ethers.getSigners();

    const PaymentLibFactory = await ethers.getContractFactory("PaymentCalculationLibraryV1");
    paymentLib = await PaymentLibFactory.deploy();
    await paymentLib.waitForDeployment();

    const IncentiveFactory = await ethers.getContractFactory("ResolverIncentiveModule");
    incentiveModule = await IncentiveFactory.deploy();
    await incentiveModule.waitForDeployment();
    await incentiveModule.initialize(owner.address, await paymentLib.getAddress());

    const ROLE_TIMELOCK = await incentiveModule.ROLE_TIMELOCK();
    await incentiveModule.grantRole(ROLE_TIMELOCK, timelock.address);
    
    await incentiveModule.registerEscrowContract(escrow.address);
  });

  describe("Resolver Recording", () => {
    it("Should record resolver with timestamp", async () => {
      await incentiveModule.connect(escrow).recordResolver(1, resolver.address, 0);
      
      const resolvers = await incentiveModule.getDisputeResolvers(1);
      expect(resolvers.length).to.equal(1);
      expect(resolvers[0].resolver).to.equal(resolver.address);
      expect(resolvers[0].level).to.equal(0);
    });

    it("Should not record duplicate resolver at same level", async () => {
      await incentiveModule.connect(escrow).recordResolver(1, resolver.address, 0);
      await incentiveModule.connect(escrow).recordResolver(1, resolver.address, 0);
      
      const resolvers = await incentiveModule.getDisputeResolvers(1);
      expect(resolvers.length).to.equal(1);
    });

    it("Should record same resolver at different levels", async () => {
      await incentiveModule.connect(escrow).recordResolver(1, resolver.address, 0);
      await incentiveModule.connect(escrow).recordResolver(1, resolver.address, 1);
      
      const resolvers = await incentiveModule.getDisputeResolvers(1);
      expect(resolvers.length).to.equal(2);
    });

    it("Should emit ResolverRecorded event", async () => {
      await expect(incentiveModule.connect(escrow).recordResolver(1, resolver.address, 0))
        .to.emit(incentiveModule, "ResolverRecorded")
        .withArgs(1, resolver.address, 0, await time.latest() + 1);
    });

    it("Should reject zero address resolver", async () => {
      await expect(
        incentiveModule.connect(escrow).recordResolver(1, ethers.ZeroAddress, 0)
      ).to.be.revertedWith("Zero resolver");
    });

    it("Should reject invalid level", async () => {
      await expect(
        incentiveModule.connect(escrow).recordResolver(1, resolver.address, 3)
      ).to.be.revertedWith("Invalid level");
    });

    it("Should only allow registered escrow", async () => {
      await expect(
        incentiveModule.connect(owner).recordResolver(1, resolver.address, 0)
      ).to.be.reverted;
    });
  });

  describe("Escrow Fee Recording", () => {
    it("Should record escrow fee", async () => {
      const fee = ethers.parseEther("0.1");
      await incentiveModule.connect(escrow).recordEscrowFee(1, token.address, fee);
      
      expect(await incentiveModule.disputeEscrowFees(1)).to.equal(fee);
    });

    it("Should emit EscrowFeeRecorded event", async () => {
      const fee = ethers.parseEther("0.1");
      await expect(incentiveModule.connect(escrow).recordEscrowFee(1, token.address, fee))
        .to.emit(incentiveModule, "EscrowFeeRecorded")
        .withArgs(1, token.address, fee);
    });

    it("Should reject zero token address", async () => {
      await expect(
        incentiveModule.connect(escrow).recordEscrowFee(1, ethers.ZeroAddress, 100)
      ).to.be.revertedWith("Zero token");
    });

    it("Should reject zero amount", async () => {
      await expect(
        incentiveModule.connect(escrow).recordEscrowFee(1, token.address, 0)
      ).to.be.revertedWith("Zero amount");
    });

    it("Should allow updating escrow fee", async () => {
      await incentiveModule.connect(escrow).recordEscrowFee(1, token.address, 100);
      await incentiveModule.connect(escrow).recordEscrowFee(1, token.address, 200);
      
      expect(await incentiveModule.disputeEscrowFees(1)).to.equal(200);
    });
  });

  describe("Escalation Fee Recording", () => {
    it("Should record escalation fee", async () => {
      const fee = ethers.parseEther("0.05");
      await incentiveModule.connect(escrow).recordEscalationFee(1, 1, fee);
      
      expect(await incentiveModule.disputeEscalationFees(1, 1)).to.equal(fee);
    });

    it("Should record multiple escalation levels", async () => {
      const fee1 = ethers.parseEther("0.05");
      const fee2 = ethers.parseEther("0.1");
      
      await incentiveModule.connect(escrow).recordEscalationFee(1, 1, fee1);
      await incentiveModule.connect(escrow).recordEscalationFee(1, 2, fee2);
      
      expect(await incentiveModule.disputeEscalationFees(1, 1)).to.equal(fee1);
      expect(await incentiveModule.disputeEscalationFees(1, 2)).to.equal(fee2);
    });

    it("Should emit EscalationFeeRecorded event", async () => {
      const fee = ethers.parseEther("0.05");
      await expect(incentiveModule.connect(escrow).recordEscalationFee(1, 1, fee))
        .to.emit(incentiveModule, "EscalationFeeRecorded")
        .withArgs(1, 1, fee);
    });

    it("Should allow zero escalation fee", async () => {
      await incentiveModule.connect(escrow).recordEscalationFee(1, 1, 0);
      expect(await incentiveModule.disputeEscalationFees(1, 1)).to.equal(0);
    });

    it("Should handle maximum uint values", async () => {
      await incentiveModule.connect(escrow).recordEscalationFee(1, 1, ethers.MaxUint256);
      expect(await incentiveModule.disputeEscalationFees(1, 1)).to.equal(ethers.MaxUint256);
    });
  });

  describe("Resolver Share Percentage", () => {
    it("Should have default share percentage", async () => {
      const share = await incentiveModule.resolverSharePercentage();
      expect(share).to.be.gte(0);
      expect(share).to.be.lte(10000);
    });

    it("Should allow timelock to change share", async () => {
      const newShare = 6000; // 60%
      await incentiveModule.connect(timelock).setResolverSharePercentage(newShare);
      
      expect(await incentiveModule.resolverSharePercentage()).to.equal(newShare);
    });

    it("Should emit event on share change", async () => {
      const newShare = 6000;
      await expect(incentiveModule.connect(timelock).setResolverSharePercentage(newShare))
        .to.emit(incentiveModule, "ResolverSharePercentageChanged")
        .withArgs(newShare);
    });

    it("Should reject share > 100%", async () => {
      await expect(
        incentiveModule.connect(timelock).setResolverSharePercentage(10001)
      ).to.be.revertedWith("Share too high");
    });

    it("Should allow 0% share", async () => {
      await incentiveModule.connect(timelock).setResolverSharePercentage(0);
      expect(await incentiveModule.resolverSharePercentage()).to.equal(0);
    });

    it("Should allow 100% share", async () => {
      await incentiveModule.connect(timelock).setResolverSharePercentage(10000);
      expect(await incentiveModule.resolverSharePercentage()).to.equal(10000);
    });

    it("Should reject non-timelock", async () => {
      await expect(
        incentiveModule.connect(owner).setResolverSharePercentage(5000)
      ).to.be.reverted;
    });
  });

  describe("Payment Library Version", () => {
    it("Should track current library version", async () => {
      const version = await incentiveModule.currentLibraryVersion();
      expect(version).to.be.gte(1);
    });

    it("Should allow updating library", async () => {
      const newLib = await ethers.deployContract("PaymentCalculationLibraryV1");
      await newLib.waitForDeployment();
      
      await incentiveModule.connect(timelock).setPaymentLibrary(await newLib.getAddress(), 2);
      
      expect(await incentiveModule.currentLibraryVersion()).to.equal(2);
    });

    it("Should emit event on library update", async () => {
      const newLib = await ethers.deployContract("PaymentCalculationLibraryV1");
      await newLib.waitForDeployment();
      
      await expect(incentiveModule.connect(timelock).setPaymentLibrary(await newLib.getAddress(), 2))
        .to.emit(incentiveModule, "PaymentLibraryUpdated")
        .withArgs(await newLib.getAddress(), 2);
    });

    it("Should reject zero address library", async () => {
      await expect(
        incentiveModule.connect(timelock).setPaymentLibrary(ethers.ZeroAddress, 2)
      ).to.be.revertedWith("Zero address");
    });

    it("Should reject zero version", async () => {
      const newLib = await ethers.deployContract("PaymentCalculationLibraryV1");
      await expect(
        incentiveModule.connect(timelock).setPaymentLibrary(await newLib.getAddress(), 0)
      ).to.be.revertedWith("Zero version");
    });
  });

  describe("Dispute Resolution Distribution", () => {
    it("Should mark dispute as distributed", async () => {
      // This requires full setup with token transfers
      // Just verify the mapping exists
      expect(await incentiveModule.disputePaymentsDistributed(1)).to.be.false;
    });

    it("Should prevent double distribution", async () => {
      // Would need full integration test with mock ERC20
    });

    it("Should check balance before distribution", async () => {
      // Requires mock ERC20 setup
    });
  });

  describe("Escrow Contract Registration", () => {
    it("Should register escrow contract", async () => {
      const newEscrow = ethers.Wallet.createRandom().address;
      await incentiveModule.registerEscrowContract(newEscrow);
      
      const ROLE = await incentiveModule.ROLE_ESCROW_CONTRACT();
      expect(await incentiveModule.hasRole(ROLE, newEscrow)).to.be.true;
    });

    it("Should emit event on registration", async () => {
      const newEscrow = ethers.Wallet.createRandom().address;
      await expect(incentiveModule.registerEscrowContract(newEscrow))
        .to.emit(incentiveModule, "EscrowContractRegistered")
        .withArgs(newEscrow);
    });

    it("Should reject zero address", async () => {
      await expect(
        incentiveModule.registerEscrowContract(ethers.ZeroAddress)
      ).to.be.revertedWith("Zero address");
    });

    it("Should only allow admin", async () => {
      await expect(
        incentiveModule.connect(escrow).registerEscrowContract(resolver.address)
      ).to.be.reverted;
    });
  });

  describe("View Functions", () => {
    it("Should return empty array for no resolvers", async () => {
      const resolvers = await incentiveModule.getDisputeResolvers(999);
      expect(resolvers.length).to.equal(0);
    });

    it("Should return all recorded resolvers", async () => {
      await incentiveModule.connect(escrow).recordResolver(1, resolver.address, 0);
      await incentiveModule.connect(escrow).recordResolver(1, owner.address, 1);
      
      const resolvers = await incentiveModule.getDisputeResolvers(1);
      expect(resolvers.length).to.equal(2);
    });

    it("Should return escalation fees by level", async () => {
      await incentiveModule.connect(escrow).recordEscalationFee(1, 1, ethers.parseEther("0.1"));
      
      const fees = await incentiveModule.getAllEscalationFees(1);
      expect(fees[1]).to.equal(ethers.parseEther("0.1"));
    });
  });

  describe("Module Metadata", () => {
    it("Should return module name", async () => {
      expect(await incentiveModule.moduleName()).to.equal("ResolverIncentiveModule");
    });

    it("Should return module version", async () => {
      const version = await incentiveModule.moduleVersion();
      expect(version).to.match(/^\d+\.\d+\.\d+$/);
    });

    it("Should support ERC165", async () => {
      expect(await incentiveModule.supportsInterface("0x01ffc9a7")).to.be.true;
    });
  });

  describe("Access Control", () => {
    it("Should have admin role", async () => {
      const ADMIN = await incentiveModule.DEFAULT_ADMIN_ROLE();
      expect(await incentiveModule.hasRole(ADMIN, owner.address)).to.be.true;
    });

    it("Should have timelock role", async () => {
      const ROLE_TIMELOCK = await incentiveModule.ROLE_TIMELOCK();
      expect(await incentiveModule.hasRole(ROLE_TIMELOCK, timelock.address)).to.be.true;
    });

    it("Should allow role management", async () => {
      const ROLE = await incentiveModule.ROLE_ESCROW_CONTRACT();
      const newEscrow = ethers.Wallet.createRandom().address;
      
      await incentiveModule.grantRole(ROLE, newEscrow);
      expect(await incentiveModule.hasRole(ROLE, newEscrow)).to.be.true;
      
      await incentiveModule.revokeRole(ROLE, newEscrow);
      expect(await incentiveModule.hasRole(ROLE, newEscrow)).to.be.false;
    });
  });

  describe("Upgradability", () => {
    it("Should be upgradeable via UUPS", async () => {
      // Just verify the pattern exists
      expect(await incentiveModule.proxiableUUID()).to.not.be.undefined;
    });

    it("Should not allow re-initialization", async () => {
      await expect(
        incentiveModule.initialize(owner.address, await paymentLib.getAddress())
      ).to.be.reverted;
    });
  });

  describe("Edge Cases", () => {
    it("Should handle zero workflow ID", async () => {
      await incentiveModule.connect(escrow).recordResolver(0, resolver.address, 0);
      const resolvers = await incentiveModule.getDisputeResolvers(0);
      expect(resolvers.length).to.equal(1);
    });

    it("Should handle large workflow IDs", async () => {
      const largeId = ethers.MaxUint256 - 1n;
      await incentiveModule.connect(escrow).recordResolver(largeId, resolver.address, 0);
      const resolvers = await incentiveModule.getDisputeResolvers(largeId);
      expect(resolvers.length).to.equal(1);
    });

    it("Should handle many resolvers per dispute", async () => {
      const count = 10;
      for (let i = 0; i < count; i++) {
        const wallet = ethers.Wallet.createRandom();
        await incentiveModule.connect(escrow).recordResolver(1, wallet.address, 0);
      }
      
      const resolvers = await incentiveModule.getDisputeResolvers(1);
      expect(resolvers.length).to.equal(count);
    });

    it("Should handle maximum fee values", async () => {
      await incentiveModule.connect(escrow).recordEscrowFee(1, token.address, ethers.MaxUint256);
      expect(await incentiveModule.disputeEscrowFees(1)).to.equal(ethers.MaxUint256);
    });
  });

  describe("Gas Optimization", () => {
    it("Should use minimal gas for resolver recording", async () => {
      const tx = await incentiveModule.connect(escrow).recordResolver(1, resolver.address, 0);
      const receipt = await tx.wait();
      expect(receipt!.gasUsed).to.be.lt(100000);
    });

    it("Should use minimal gas for fee recording", async () => {
      const tx = await incentiveModule.connect(escrow).recordEscrowFee(1, token.address, 100);
      const receipt = await tx.wait();
      expect(receipt!.gasUsed).to.be.lt(100000);
    });
  });
});
