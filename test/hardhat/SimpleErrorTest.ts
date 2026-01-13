import { expect } from "chai";
import { ethers } from "hardhat";
import { setupResolutionModule } from "../helpers/setupResolutionModule";

describe("Simple Error Test", function () {
  let escrowableERC20: any;
  let owner: any;
  let user1: any;
  let user2: any;
  let resolver: any;

  beforeEach(async function () {
    [owner, user1, user2, resolver] = await ethers.getSigners();

    const EscrowableERC20Factory = await ethers.getContractFactory("EscrowableERC20");
    escrowableERC20 = await EscrowableERC20Factory.deploy("Test Token", "TEST", 100, owner.address, ethers.ZeroAddress, ethers.ZeroAddress);
    await escrowableERC20.waitForDeployment();

    // Phase 7: Setup resolution module (required for escrow creation)
    await setupResolutionModule(escrowableERC20, owner, resolver.address);

    // Transfer some tokens to user1 for testing
    await escrowableERC20.transfer(user1.address, ethers.parseEther("100"));
  });

  it("should throw custom error for insufficient balance", async function () {
    const largeAmount = ethers.parseEther("1000"); // More than user1 has
    
    // Check user1's actual balance
    const balance = await escrowableERC20.balanceOf(user1.address);
    console.log("User1 balance:", ethers.formatEther(balance));
    console.log("Required amount:", ethers.formatEther(largeAmount));
    
    try {
      await escrowableERC20.connect(user1).createEscrow(user2.address, largeAmount);
      expect.fail("Expected transaction to revert");
    } catch (error: any) {
      console.log("Error caught:", error.message);
      // Check if it's our custom error or the OpenZeppelin error
      expect(error.message).to.include("InsufficientTokenBalance");
    }
  });

  it("should work with sufficient balance", async function () {
    const amount = ethers.parseEther("50");
    
    await expect(
      escrowableERC20.connect(user1).createEscrow(user2.address, amount)
    ).to.not.be.reverted;
  });

  it("should throw custom error for invalid workflow ID", async function () {
    const invalidWorkflowId = 999;
    
    try {
      await escrowableERC20.connect(user1).releaseEscrowTransfer(invalidWorkflowId);
      expect.fail("Expected transaction to revert");
    } catch (error: any) {
      console.log("Error caught:", error.message);
      expect(error.message).to.include("InvalidWorkflowId");
    }
  });
}); 