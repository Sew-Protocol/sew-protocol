import { expect } from "chai";
import { ethers } from "hardhat";
import { EscrowableERC20 } from "../typechain-types";

describe("Error Handling", function () {
  let escrowableERC20: EscrowableERC20;
  let owner: any;
  let user1: any;
  let user2: any;
  let resolver: any;

  const ESCROW_FEE = 100;

  beforeEach(async function () {
    [owner, user1, user2, resolver] = await ethers.getSigners();

    // Deploy contract
    const EscrowableERC20Factory = await ethers.getContractFactory("EscrowableERC20");
    escrowableERC20 = await EscrowableERC20Factory.deploy("Test Token", "TEST", ESCROW_FEE, owner.address);
    await escrowableERC20.waitForDeployment();

    // Set resolver
    await escrowableERC20.setAuthorizedResolver(resolver.address);

    // Transfer some tokens to user1 for testing
    await escrowableERC20.transfer(user1.address, ethers.parseEther("100"));
  });

  describe("Insufficient Token Balance", function () {
    it("should provide user-friendly error for insufficient balance", async function () {
      const largeAmount = ethers.parseEther("1000"); // More than user1 has
      
      await expect(
        escrowableERC20.connect(user1).escrowTransfer(user2.address, largeAmount)
      ).to.be.revertedWithCustomError(escrowableERC20, "InsufficientTokenBalance")
        .withArgs(ethers.parseEther("100"), largeAmount);
    });

    it("should work with sufficient balance", async function () {
      const amount = ethers.parseEther("50");
      
      await expect(
        escrowableERC20.connect(user1).escrowTransfer(user2.address, amount)
      ).to.not.be.reverted;
    });
  });

  describe("Invalid Workflow ID", function () {
    it("should provide user-friendly error for invalid workflow ID", async function () {
      const invalidWorkflowId = 999;
      
      await expect(
        escrowableERC20.connect(user1).releaseEscrowTransfer(invalidWorkflowId)
      ).to.be.revertedWithCustomError(escrowableERC20, "InvalidWorkflowId")
        .withArgs(invalidWorkflowId, 0);
    });

    it("should provide user-friendly error for getAttachmentURIs", async function () {
      const invalidWorkflowId = 999;
      
      await expect(
        escrowableERC20.getAttachmentURIs(invalidWorkflowId)
      ).to.be.revertedWithCustomError(escrowableERC20, "InvalidWorkflowId")
        .withArgs(invalidWorkflowId, 0);
    });
  });

  describe("Transfer Not Pending", function () {
    it("should provide user-friendly error for non-pending transfer", async function () {
      // Create a transfer
      const amount = ethers.parseEther("10");
      const tx = await escrowableERC20.connect(user1).escrowTransfer(user2.address, amount);
      await tx.wait();
      const workflowId = Number(await escrowableERC20.nextWorkflowId()) - 1;
      
      // Release the transfer
      await escrowableERC20.connect(user1).releaseEscrowTransfer(workflowId);
      
      // Try to release again
      await expect(
        escrowableERC20.connect(user1).releaseEscrowTransfer(workflowId)
      ).to.be.revertedWithCustomError(escrowableERC20, "TransferNotPending")
        .withArgs(workflowId, 2); // 2 = RELEASED state
    });
  });

  describe("Not Authorized Resolver", function () {
    it("should provide user-friendly error for unauthorized resolver", async function () {
      // Create a transfer
      const amount = ethers.parseEther("10");
      const tx = await escrowableERC20.connect(user1).escrowTransfer(user2.address, amount);
      await tx.wait();
      const workflowId = Number(await escrowableERC20.nextWorkflowId()) - 1;
      
      // Raise a dispute
      await escrowableERC20.connect(user1).raiseDispute(workflowId);
      
      // Try to resolve as unauthorized user
      await expect(
        escrowableERC20.connect(user2).resolverCancel(workflowId)
      ).to.be.revertedWithCustomError(escrowableERC20, "NotAuthorizedResolver")
        .withArgs(user2.address, resolver.address); // resolver.address is the authorized resolver
    });
  });

  describe("Error Message Format", function () {
    it("should provide clear error information", async function () {
      const largeAmount = ethers.parseEther("1000");
      
      try {
        await escrowableERC20.connect(user1).escrowTransfer(user2.address, largeAmount);
      } catch (error: any) {
        // Check that the error contains useful information
        expect(error.message).to.include("InsufficientTokenBalance");
        expect(error.message).to.include("100000000000000000000"); // user1's balance
        expect(error.message).to.include("1000000000000000000000"); // required amount
      }
    });
  });
}); 