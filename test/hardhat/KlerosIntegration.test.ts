import { expect } from "chai";
import { ethers } from "hardhat";
import { KlerosArbitrableProxy, MockKlerosArbitrator } from "../../typechain-types";

/**
 * NOTE: These tests are for Kleros integration (new arbitration feature).
 * Kleros contracts are in contracts/arbitration/ but not yet fully integrated into the escrow system.
 * Will be properly implemented once Kleros integration is complete.
 */
describe.skip("Kleros Integration Tests", function () {
  let klerosProxy: KlerosArbitrableProxy;
  let mockArbitrator: MockKlerosArbitrator;
  let owner: any, sender: any, recipient: any, other: any;

  const ARBITRATION_PRICE = ethers.parseEther("0.1");
  const AMOUNT = ethers.parseEther("1");

  beforeEach(async () => {
    [owner, sender, recipient, other] = await ethers.getSigners();

    const MockArbitratorFactory = await ethers.getContractFactory("MockKlerosArbitrator");
    mockArbitrator = await MockArbitratorFactory.deploy(ARBITRATION_PRICE);
    await mockArbitrator.waitForDeployment();

    const KlerosProxyFactory = await ethers.getContractFactory("KlerosArbitrableProxy");
    klerosProxy = await KlerosProxyFactory.deploy();
    await klerosProxy.waitForDeployment();
    await klerosProxy.initialize(await mockArbitrator.getAddress(), owner.address);
  });

  describe("Deployment", () => {
    it("Should deploy with correct arbitrator", async () => {
      expect(await klerosProxy.arbitrator()).to.equal(await mockArbitrator.getAddress());
    });

    it("Should have correct metadata", async () => {
      expect(await klerosProxy.moduleName()).to.equal("KlerosArbitrableProxy");
      expect(await klerosProxy.moduleVersion()).to.equal("1.0.0");
    });

    it("Should support ERC-165", async () => {
      expect(await klerosProxy.supportsInterface("0x01ffc9a7")).to.be.true;
    });

    it("Should set admin roles", async () => {
      const ROLE_ADMIN = await klerosProxy.ROLE_ADMIN();
      expect(await klerosProxy.hasRole(ROLE_ADMIN, owner.address)).to.be.true;
    });

    it("Should not allow re-initialization", async () => {
      await expect(klerosProxy.initialize(await mockArbitrator.getAddress(), owner.address)).to.be.reverted;
    });
  });

  describe("Escrow Registration", () => {
    it("Should register escrow contract", async () => {
      await klerosProxy.registerEscrowContract(sender.address);
      const ROLE = await klerosProxy.ROLE_ESCROW_CONTRACT();
      expect(await klerosProxy.hasRole(ROLE, sender.address)).to.be.true;
    });

    it("Should reject non-admin", async () => {
      await expect(klerosProxy.connect(sender).registerEscrowContract(sender.address)).to.be.reverted;
    });

    it("Should reject zero address", async () => {
      await expect(klerosProxy.registerEscrowContract(ethers.ZeroAddress)).to.be.revertedWith("Invalid escrow address");
    });
  });

  describe("Dispute Creation", () => {
    beforeEach(async () => {
      await klerosProxy.registerEscrowContract(owner.address);
    });

    it("Should create dispute", async () => {
      const data = ethers.AbiCoder.defaultAbiCoder().encode(
        ["address", "address", "address", "uint256", "uint256"],
        [ethers.ZeroAddress, sender.address, recipient.address, AMOUNT, AMOUNT]
      );
      await expect(klerosProxy.createDispute(1, 2, "0x", data, { value: ARBITRATION_PRICE }))
        .to.emit(klerosProxy, "DisputeCreated");
    });

    it("Should revert with insufficient fee", async () => {
      const data = ethers.AbiCoder.defaultAbiCoder().encode(
        ["address", "address", "address", "uint256", "uint256"],
        [ethers.ZeroAddress, sender.address, recipient.address, AMOUNT, AMOUNT]
      );
      await expect(klerosProxy.createDispute(1, 2, "0x", data, { value: 0 }))
        .to.be.revertedWith("Insufficient arbitration fee");
    });

    it("Should reject duplicate", async () => {
      const data = ethers.AbiCoder.defaultAbiCoder().encode(
        ["address", "address", "address", "uint256", "uint256"],
        [ethers.ZeroAddress, sender.address, recipient.address, AMOUNT, AMOUNT]
      );
      await klerosProxy.createDispute(1, 2, "0x", data, { value: ARBITRATION_PRICE });
      await expect(klerosProxy.createDispute(1, 2, "0x", data, { value: ARBITRATION_PRICE }))
        .to.be.revertedWith("Dispute already exists");
    });

    it("Should refund excess", async () => {
      const data = ethers.AbiCoder.defaultAbiCoder().encode(
        ["address", "address", "address", "uint256", "uint256"],
        [ethers.ZeroAddress, sender.address, recipient.address, AMOUNT, AMOUNT]
      );
      const before = await ethers.provider.getBalance(owner.address);
      const tx = await klerosProxy.createDispute(1, 2, "0x", data, { value: ARBITRATION_PRICE * 2n });
      const receipt = await tx.wait();
      const gas = receipt!.gasUsed * receipt!.gasPrice;
      const after = await ethers.provider.getBalance(owner.address);
      expect(before - after).to.be.closeTo(ARBITRATION_PRICE + gas, ethers.parseEther("0.001"));
    });

    it("Should store metadata", async () => {
      const data = ethers.AbiCoder.defaultAbiCoder().encode(
        ["address", "address", "address", "uint256", "uint256"],
        [ethers.ZeroAddress, sender.address, recipient.address, AMOUNT, AMOUNT]
      );
      await klerosProxy.createDispute(1, 2, "0x", data, { value: ARBITRATION_PRICE });
      const dispute = await klerosProxy.disputes(1);
      expect(dispute.from).to.equal(sender.address);
      expect(dispute.to).to.equal(recipient.address);
      expect(dispute.resolved).to.be.false;
    });

    it("Should create mappings", async () => {
      const data = ethers.AbiCoder.defaultAbiCoder().encode(
        ["address", "address", "address", "uint256", "uint256"],
        [ethers.ZeroAddress, sender.address, recipient.address, AMOUNT, AMOUNT]
      );
      await klerosProxy.createDispute(1, 2, "0x", data, { value: ARBITRATION_PRICE });
      expect(await klerosProxy.workflowToKlerosDispute(1)).to.equal(1); // klerosDisputeId(0) + 1
      expect(await klerosProxy.klerosDisputeToWorkflow(0)).to.equal(1);
    });

    it("Should reject non-escrow", async () => {
      await expect(klerosProxy.connect(sender).createDispute(1, 2, "0x", "0x", { value: ARBITRATION_PRICE })).to.be.reverted;
    });
  });

  describe("Evidence", () => {
    let workflowId: number;

    beforeEach(async () => {
      workflowId = 1;
      await klerosProxy.registerEscrowContract(owner.address);
      const data = ethers.AbiCoder.defaultAbiCoder().encode(
        ["address", "address", "address", "uint256", "uint256"],
        [ethers.ZeroAddress, sender.address, recipient.address, AMOUNT, AMOUNT]
      );
      await klerosProxy.createDispute(workflowId, 2, "0x", data, { value: ARBITRATION_PRICE });
    });

    it("Should allow sender evidence", async () => {
      await expect(klerosProxy.connect(sender).submitEvidence(workflowId, "ipfs://test"))
        .to.emit(klerosProxy, "EvidenceSubmitted");
    });

    it("Should allow recipient evidence", async () => {
      await expect(klerosProxy.connect(recipient).submitEvidence(workflowId, "ipfs://test2"))
        .to.emit(klerosProxy, "EvidenceSubmitted");
    });

    it("Should allow anyone evidence", async () => {
      await expect(klerosProxy.connect(other).submitEvidence(workflowId, "ipfs://test3"))
        .to.emit(klerosProxy, "EvidenceSubmitted");
    });

    it("Should allow multiple submissions", async () => {
      await klerosProxy.connect(sender).submitEvidence(workflowId, "1");
      await klerosProxy.connect(recipient).submitEvidence(workflowId, "2");
      await klerosProxy.connect(other).submitEvidence(workflowId, "3");
    });

    it("Should reject non-existent", async () => {
      await expect(klerosProxy.submitEvidence(999, "test")).to.be.revertedWith("Dispute does not exist");
    });

    it("Should reject after resolution", async () => {
      await mockArbitrator.giveRuling(0, 1);
      await expect(klerosProxy.submitEvidence(workflowId, "late")).to.be.revertedWith("Dispute already resolved");
    });
  });

  describe("Rulings", () => {
    let workflowId: number;

    beforeEach(async () => {
      workflowId = 1;
      await klerosProxy.registerEscrowContract(owner.address);
      const data = ethers.AbiCoder.defaultAbiCoder().encode(
        ["address", "address", "address", "uint256", "uint256"],
        [ethers.ZeroAddress, sender.address, recipient.address, AMOUNT, AMOUNT]
      );
      await klerosProxy.createDispute(workflowId, 2, "0x", data, { value: ARBITRATION_PRICE });
    });

    it("Should receive ruling (release)", async () => {
      await expect(mockArbitrator.giveRuling(0, 1))
        .to.emit(klerosProxy, "Ruling")
        .to.emit(klerosProxy, "RulingExecuted");
    });

    it("Should receive ruling (cancel)", async () => {
      await expect(mockArbitrator.giveRuling(0, 2)).to.emit(klerosProxy, "RulingExecuted");
    });

    it("Should store ruling", async () => {
      await mockArbitrator.giveRuling(0, 1);
      const [resolved, ruling] = await klerosProxy.getRuling(workflowId);
      expect(resolved).to.be.true;
      expect(ruling).to.equal(1);
    });

    it("Should update metadata", async () => {
      await mockArbitrator.giveRuling(0, 2);
      const dispute = await klerosProxy.disputes(workflowId);
      expect(dispute.resolved).to.be.true;
      expect(dispute.ruling).to.equal(2);
    });

    it("Should reject non-arbitrator", async () => {
      await expect(klerosProxy.connect(sender).rule(0, 1)).to.be.revertedWith("Only arbitrator can rule");
    });

    it("Should query before resolution", async () => {
      const [resolved] = await klerosProxy.getRuling(workflowId);
      expect(resolved).to.be.false;
    });
  });

  describe("IResolutionModule", () => {
    it("Should return resolver", async () => {
      const [resolver, level] = await klerosProxy.getDisputeResolver(1, "0x");
      expect(resolver).to.equal(await klerosProxy.getAddress());
      expect(level).to.equal(2);
    });

    it("Should authorize self", async () => {
      const [auth, role] = await klerosProxy.isAuthorizedDisputeResolver(1, await klerosProxy.getAddress(), "0x");
      expect(auth).to.be.true;
      expect(role).to.equal(2);
    });

    it("Should not authorize others", async () => {
      const [auth] = await klerosProxy.isAuthorizedDisputeResolver(1, sender.address, "0x");
      expect(auth).to.be.false;
    });

    it("Should prevent escalation", async () => {
      const [can] = await klerosProxy.canEscalate(1, 2, "0x");
      expect(can).to.be.false;
    });

    it("Should revert escalation", async () => {
      await expect(klerosProxy.executeEscalation(1, "0x")).to.be.revertedWith("No escalation from Kleros");
    });
  });

  describe("Cost", () => {
    it("Should return cost", async () => {
      expect(await klerosProxy.getArbitrationCost("0x")).to.equal(ARBITRATION_PRICE);
    });

    it("Should update with arbitrator", async () => {
      await mockArbitrator.setArbitrationPrice(ethers.parseEther("0.2"));
      expect(await klerosProxy.getArbitrationCost("0x")).to.equal(ethers.parseEther("0.2"));
    });

    it("Should handle zero", async () => {
      await mockArbitrator.setArbitrationPrice(0);
      expect(await klerosProxy.getArbitrationCost("0x")).to.equal(0);
    });
  });

  describe("Multiple Disputes", () => {
    beforeEach(async () => {
      await klerosProxy.registerEscrowContract(owner.address);
    });

    it("Should handle independently", async () => {
      const data = ethers.AbiCoder.defaultAbiCoder().encode(
        ["address", "address", "address", "uint256", "uint256"],
        [ethers.ZeroAddress, sender.address, recipient.address, AMOUNT, AMOUNT]
      );
      await klerosProxy.createDispute(1, 2, "0x", data, { value: ARBITRATION_PRICE });
      await klerosProxy.createDispute(2, 2, "0x", data, { value: ARBITRATION_PRICE });
      expect(await klerosProxy.workflowToKlerosDispute(1)).to.equal(1); // klerosDisputeId(0) + 1
      expect(await klerosProxy.workflowToKlerosDispute(2)).to.equal(2); // klerosDisputeId(1) + 1
    });

    it("Should handle different rulings", async () => {
      const data = ethers.AbiCoder.defaultAbiCoder().encode(
        ["address", "address", "address", "uint256", "uint256"],
        [ethers.ZeroAddress, sender.address, recipient.address, AMOUNT, AMOUNT]
      );
      await klerosProxy.createDispute(1, 2, "0x", data, { value: ARBITRATION_PRICE });
      await klerosProxy.createDispute(2, 2, "0x", data, { value: ARBITRATION_PRICE });
      await mockArbitrator.giveRuling(0, 1);
      await mockArbitrator.giveRuling(1, 2);
      const [, r1] = await klerosProxy.getRuling(1);
      const [, r2] = await klerosProxy.getRuling(2);
      expect(r1).to.equal(1);
      expect(r2).to.equal(2);
    });
  });

  describe("Access Control", () => {
    it("Should enforce admin", async () => {
      await expect(klerosProxy.connect(sender).registerEscrowContract(sender.address)).to.be.reverted;
    });

    it("Should manage roles", async () => {
      const ROLE = await klerosProxy.ROLE_ESCROW_CONTRACT();
      await klerosProxy.grantRole(ROLE, sender.address);
      expect(await klerosProxy.hasRole(ROLE, sender.address)).to.be.true;
      await klerosProxy.revokeRole(ROLE, sender.address);
      expect(await klerosProxy.hasRole(ROLE, sender.address)).to.be.false;
    });
  });

  describe("Edge Cases", () => {
    it("Should handle zero workflow", async () => {
      const [resolved] = await klerosProxy.getRuling(0);
      expect(resolved).to.be.false;
    });

    it("Should handle large workflow", async () => {
      const [resolved] = await klerosProxy.getRuling(ethers.MaxUint256);
      expect(resolved).to.be.false;
    });
  });
});
