import { expect } from "chai";
import { ethers } from "hardhat";
import { time } from "@nomicfoundation/hardhat-network-helpers";
import { EscrowVault } from "../typechain-types";
import { ERC20Mock } from "../typechain-types";
import { setupResolutionModule } from "../helpers/setupResolutionModule";

describe("EscrowVault", function () {
  let escrowVault: EscrowVault;
  let token1: ERC20Mock;
  let token2: ERC20Mock;
  let owner: any;
  let sender: any;
  let recipient: any;
  let resolver: any;
  let feeAddress: any;

  const ESCROW_FEE = 100;
  const ESCROW_FEE_DENOMINATOR = 10000;
  const INITIAL_TRANSFER_AMOUNT = ethers.parseEther("1");

  beforeEach(async () => {
    [owner, sender, recipient, resolver, feeAddress] = await ethers.getSigners();
    
    // Deploy EscrowVault
    const escrowVaultFactory = await ethers.getContractFactory("EscrowVault");
    escrowVault = (await escrowVaultFactory.deploy(ESCROW_FEE, feeAddress.address)) as EscrowVault;
    await escrowVault.waitForDeployment();
    
    // Deploy mock ERC20 tokens
    const tokenFactory = await ethers.getContractFactory("ERC20Mock");
    token1 = (await tokenFactory.deploy("Token 1", "TKN1", owner.address, ethers.parseEther("1000000"))) as ERC20Mock;
    await token1.waitForDeployment();
    
    token2 = (await tokenFactory.deploy("Token 2", "TKN2", owner.address, ethers.parseEther("1000000"))) as ERC20Mock;
    await token2.waitForDeployment();
    
    // Phase 2: Grant ROLE_TIMELOCK to owner
    const ROLE_TIMELOCK = await escrowVault.ROLE_TIMELOCK();
    await escrowVault.grantRole(ROLE_TIMELOCK, owner.address);
    
    // Phase 7: Setup resolution module (required for escrow creation)
    await setupResolutionModule(escrowVault, owner, resolver.address);
    
    // Transfer tokens to sender
    await token1.transfer(sender.address, ethers.parseEther("1000"));
    await token2.transfer(sender.address, ethers.parseEther("1000"));
  });

  describe("Deployment", function () {
    it("Should set the right owner", async function () {
      // Phase 2: Migrated from Ownable to AccessControl
      const DEFAULT_ADMIN_ROLE = await escrowVault.DEFAULT_ADMIN_ROLE();
      expect(await escrowVault.hasRole(DEFAULT_ADMIN_ROLE, owner.address)).to.be.true;
    });

    it("Should set the right escrow fee", async function () {
      expect(await escrowVault.escrowFee()).to.equal(ESCROW_FEE);
    });

    it("Should set the right fee address", async function () {
      expect(await escrowVault.escrowFeeAddress()).to.equal(feeAddress.address);
    });
  });

  describe("Multi-Token Escrow", function () {
    it("Should create escrow for token1", async function () {
      await token1.connect(sender).approve(await escrowVault.getAddress(), INITIAL_TRANSFER_AMOUNT);
      
      const tx = await escrowVault.connect(sender).createEscrow(
        await token1.getAddress(),
        recipient.address,
        INITIAL_TRANSFER_AMOUNT
      );
      await tx.wait();
      
      const workflowId = Number(await escrowVault.nextWorkflowId()) - 1;
      const escrowTransfer = await escrowVault.escrowTransfers(workflowId);
      
      expect(escrowTransfer.token).to.equal(await token1.getAddress());
      expect(escrowTransfer.to).to.equal(recipient.address);
      expect(escrowTransfer.from).to.equal(sender.address);
      expect(escrowTransfer.escrowState).to.equal(1); // PENDING
    });

    it("Should create escrow for token2", async function () {
      await token2.connect(sender).approve(await escrowVault.getAddress(), INITIAL_TRANSFER_AMOUNT);
      
      const tx = await escrowVault.connect(sender).createEscrow(
        await token2.getAddress(),
        recipient.address,
        INITIAL_TRANSFER_AMOUNT
      );
      await tx.wait();
      
      const workflowId = Number(await escrowVault.nextWorkflowId()) - 1;
      const escrowTransfer = await escrowVault.escrowTransfers(workflowId);
      
      expect(escrowTransfer.token).to.equal(await token2.getAddress());
    });

    it("Should track escrow balance per token", async function () {
      await token1.connect(sender).approve(await escrowVault.getAddress(), INITIAL_TRANSFER_AMOUNT * 2n);
      
      await escrowVault.connect(sender).createEscrow(
        await token1.getAddress(),
        recipient.address,
        INITIAL_TRANSFER_AMOUNT
      );
      
      const balance1 = await escrowVault.totalHeldInEscrowPerToken(await token1.getAddress());
      const fee = (INITIAL_TRANSFER_AMOUNT * BigInt(ESCROW_FEE)) / BigInt(ESCROW_FEE_DENOMINATOR);
      const amountAfterFee = INITIAL_TRANSFER_AMOUNT - fee;
      
      expect(balance1).to.equal(amountAfterFee);
      
      // Token2 should have 0 balance
      const balance2 = await escrowVault.totalHeldInEscrowPerToken(await token2.getAddress());
      expect(balance2).to.equal(0);
    });

    it("Should release escrow for correct token", async function () {
      await token1.connect(sender).approve(await escrowVault.getAddress(), INITIAL_TRANSFER_AMOUNT);
      
      const tx = await escrowVault.connect(sender).createEscrow(
        await token1.getAddress(),
        recipient.address,
        INITIAL_TRANSFER_AMOUNT
      );
      await tx.wait();
      
      const workflowId = Number(await escrowVault.nextWorkflowId()) - 1;
      const recipientBalanceBefore = await token1.balanceOf(recipient.address);
      
      await escrowVault.connect(sender).releaseEscrowTransfer(workflowId);
      
      const recipientBalanceAfter = await token1.balanceOf(recipient.address);
      const fee = (INITIAL_TRANSFER_AMOUNT * BigInt(ESCROW_FEE)) / BigInt(ESCROW_FEE_DENOMINATOR);
      const amountAfterFee = INITIAL_TRANSFER_AMOUNT - fee;
      
      expect(recipientBalanceAfter - recipientBalanceBefore).to.equal(amountAfterFee);
    });
  });

  describe("Fee Management Per Token", function () {
    it("Should track fees per token", async function () {
      await token1.connect(sender).approve(await escrowVault.getAddress(), INITIAL_TRANSFER_AMOUNT);
      
      await escrowVault.connect(sender).createEscrow(
        await token1.getAddress(),
        recipient.address,
        INITIAL_TRANSFER_AMOUNT
      );
      
      const fees1 = await escrowVault.totalFeesPerToken(await token1.getAddress());
      const expectedFee = (INITIAL_TRANSFER_AMOUNT * BigInt(ESCROW_FEE)) / BigInt(ESCROW_FEE_DENOMINATOR);
      
      expect(fees1).to.equal(expectedFee);
      
      // Token2 should have 0 fees
      const fees2 = await escrowVault.totalFeesPerToken(await token2.getAddress());
      expect(fees2).to.equal(0);
    });

    it("Should withdraw fees for specific token", async function () {
      await token1.connect(sender).approve(await escrowVault.getAddress(), INITIAL_TRANSFER_AMOUNT);
      
      await escrowVault.connect(sender).createEscrow(
        await token1.getAddress(),
        recipient.address,
        INITIAL_TRANSFER_AMOUNT
      );
      
      const feeAddressBalanceBefore = await token1.balanceOf(feeAddress.address);
      const expectedFee = (INITIAL_TRANSFER_AMOUNT * BigInt(ESCROW_FEE)) / BigInt(ESCROW_FEE_DENOMINATOR);
      
      await escrowVault.connect(feeAddress).withdrawFees(await token1.getAddress());
      
      const feeAddressBalanceAfter = await token1.balanceOf(feeAddress.address);
      expect(feeAddressBalanceAfter - feeAddressBalanceBefore).to.equal(expectedFee);
    });

    it("Should not allow withdrawing fees for token with no fees", async function () {
      // Get the fee address
      const feeAddress = await escrowVault.escrowFeeAddress();
      
      // If owner is not fee address, owner should get NotFeeAddress error
      if (feeAddress.toLowerCase() !== owner.address.toLowerCase()) {
        await expect(
          escrowVault.connect(owner).withdrawFees(await token2.getAddress())
        ).to.be.revertedWithCustomError(escrowVault, "NotFeeAddress");
      } else {
        // Owner is fee address, so should get NoFeesToWithdraw error (no fees for token2)
        await expect(
          escrowVault.connect(owner).withdrawFees(await token2.getAddress())
        ).to.be.revertedWithCustomError(escrowVault, "NoFeesToWithdraw");
      }
    });
  });

  describe("Settings System", function () {
    it("Should create escrow with custom settings", async function () {
      await token1.connect(sender).approve(await escrowVault.getAddress(), INITIAL_TRANSFER_AMOUNT);
      
      const currentTime = await time.latest();
      const autoReleaseTime = currentTime + 3600;
      
      const settings = {
        customResolver: resolver.address,
        yieldEnabled: true,
        autoReleaseTime: autoReleaseTime,
        autoCancelTime: 0,
        escrowType: 0
      };
      
      const tx = await escrowVault
        .connect(sender)
        .getFunction("createEscrow(address,address,uint256,(address,bool,uint256,uint256,uint8))")
        .send(await token1.getAddress(), recipient.address, INITIAL_TRANSFER_AMOUNT, settings);
      await tx.wait();
      
      const workflowId = Number(await escrowVault.nextWorkflowId()) - 1;
      const escrowSettings = await escrowVault.getEscrowSettings(workflowId);
      const escrowTransfer = await escrowVault.escrowTransfers(workflowId);
      
      expect(escrowSettings.customResolver).to.equal(resolver.address);
      expect(escrowSettings.yieldEnabled).to.equal(true);
      expect(escrowTransfer.disputeResolver).to.equal(resolver.address);
    });
  });

  describe("Dispute Resolution", function () {
    beforeEach(async function () {
      // Phase 7: Resolution module already set up in main beforeEach
    });

    it("Should allow raising dispute", async function () {
      await token1.connect(sender).approve(await escrowVault.getAddress(), INITIAL_TRANSFER_AMOUNT);
      
      const workflowId = await createEscrowTransfer(await token1.getAddress(), INITIAL_TRANSFER_AMOUNT);
      
      await escrowVault.connect(sender).raiseDispute(workflowId);
      
      const escrowTransfer = await escrowVault.escrowTransfers(workflowId);
      expect(escrowTransfer.escrowState).to.equal(4); // DISPUTED
    });

    it("Should allow resolver to release funds", async function () {
      await token1.connect(sender).approve(await escrowVault.getAddress(), INITIAL_TRANSFER_AMOUNT);
      
      const workflowId = await createEscrowTransfer(await token1.getAddress(), INITIAL_TRANSFER_AMOUNT);
      await escrowVault.connect(sender).raiseDispute(workflowId);
      
      const recipientBalanceBefore = await token1.balanceOf(recipient.address);
      
      await escrowVault.connect(resolver).releaseAsDisputeResolver(workflowId);
      
      const escrowTransfer = await escrowVault.escrowTransfers(workflowId);
      expect(escrowTransfer.escrowState).to.equal(5); // RESOLVED
      
      const recipientBalanceAfter = await token1.balanceOf(recipient.address);
      const fee = (INITIAL_TRANSFER_AMOUNT * BigInt(ESCROW_FEE)) / BigInt(ESCROW_FEE_DENOMINATOR);
      const amountAfterFee = INITIAL_TRANSFER_AMOUNT - fee;
      expect(recipientBalanceAfter - recipientBalanceBefore).to.equal(amountAfterFee);
    });
  });

  describe("resolve() Function", function () {
    beforeEach(async function () {
      // Phase 7: Resolution module already set up in main beforeEach
    });

    it("Should resolve with single payout", async function () {
      await token1.connect(sender).approve(await escrowVault.getAddress(), INITIAL_TRANSFER_AMOUNT);
      
      const workflowId = await createEscrowTransfer(await token1.getAddress(), INITIAL_TRANSFER_AMOUNT);
      await escrowVault.connect(sender).raiseDispute(workflowId);
      
      const escrowTransfer = await escrowVault.escrowTransfers(workflowId);
      const payouts = [{
        recipient: recipient.address,
        amount: escrowTransfer.remainingBalance
      }];
      
      const recipientBalanceBefore = await token1.balanceOf(recipient.address);
      
      await escrowVault
        .connect(resolver)
        .getFunction("resolve(uint256,(address,uint256)[],bytes32)")
        .send(workflowId, payouts, ethers.ZeroHash);
      
      const transfer = await escrowVault.escrowTransfers(workflowId);
      expect(transfer.escrowState).to.equal(5); // RESOLVED
      
      const recipientBalanceAfter = await token1.balanceOf(recipient.address);
      expect(recipientBalanceAfter - recipientBalanceBefore).to.equal(escrowTransfer.remainingBalance);
    });
  });

  // Helper function
  async function createEscrowTransfer(token: string, amount: bigint) {
    const tx = await escrowVault.connect(sender).createEscrow(token, recipient.address, amount);
    await tx.wait();
    const workflowId = Number(await escrowVault.nextWorkflowId()) - 1;
    return workflowId;
  }
});

