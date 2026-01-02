import { expect } from "chai";
import { ethers } from "hardhat";
import { time } from "@nomicfoundation/hardhat-network-helpers";
import { EscrowableERC20 } from "../typechain-types";
import { setupResolutionModule } from "../helpers/setupResolutionModule";

describe("BaseEscrow", function () {
  let escrowableERC20: EscrowableERC20;
  let defaultResolutionModule: any;
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
    const escrowableERC20Factory = await ethers.getContractFactory("EscrowableERC20");
    escrowableERC20 = (await escrowableERC20Factory.deploy("Test Token", "TEST", ESCROW_FEE, feeAddress.address)) as EscrowableERC20;
    await escrowableERC20.waitForDeployment();
    
    // Phase 2: Grant ROLE_TIMELOCK to owner for admin functions
    const ROLE_TIMELOCK = await escrowableERC20.ROLE_TIMELOCK();
    const DEFAULT_ADMIN_ROLE = await escrowableERC20.DEFAULT_ADMIN_ROLE();
    await escrowableERC20.grantRole(ROLE_TIMELOCK, owner.address);
    
    // Phase 3: Use queue/activate for slow lane functions
    await escrowableERC20.connect(owner).queueEscrowFeeAddress(feeAddress.address);
    // Fast-forward time for testing (skip 7-day delay)
    const [, eta] = await escrowableERC20.getPendingFeeRecipient();
    await time.increaseTo(Number(eta) + 1);
    await escrowableERC20.connect(owner).activateEscrowFeeAddress();
    
    // Phase 7: Setup resolution module (required for escrow creation)
    defaultResolutionModule = await setupResolutionModule(escrowableERC20, owner, resolver.address);
  });

  describe("Governance resolution-module hook (affects only NEW escrows)", function () {
    it("Should pin disputeResolver at creation time and not change old escrows after module activation", async function () {
      await escrowableERC20.transfer(sender.address, INITIAL_TRANSFER_AMOUNT * 2n);

      // Create escrow BEFORE module activation -> should pin to current resolution module resolver
      const id0Tx = await escrowableERC20
        .connect(sender)
        .getFunction("createEscrow(address,uint256)")
        .send(recipient.address, INITIAL_TRANSFER_AMOUNT);
      await id0Tx.wait();
      const workflowId0 = Number(await escrowableERC20.nextWorkflowId()) - 1;
      const et0 = await escrowableERC20.escrowTransfers(workflowId0);
      expect(et0.disputeResolver).to.equal(resolver.address);

      // Activate module (governance hook)
      const escrowGov: any = escrowableERC20.connect(owner);
      // Phase 6: Minimum resolution delay is 48 hours (MIN_RESOLUTION_DELAY)
      const MIN_DELAY = 48 * 60 * 60; // 48 hours
      await escrowGov.setResolutionModuleDelay(MIN_DELAY);
      await escrowGov.proposeResolutionModule(await defaultResolutionModule.getAddress());
      // Fast-forward time to allow activation
      await time.increase(MIN_DELAY + 1);
      await escrowGov.activateResolutionModule();

      // Create escrow AFTER module activation -> should pin to module resolver
      const id1Tx = await escrowableERC20
        .connect(sender)
        .getFunction("createEscrow(address,uint256)")
        .send(recipient.address, INITIAL_TRANSFER_AMOUNT);
      await id1Tx.wait();
      const workflowId1 = Number(await escrowableERC20.nextWorkflowId()) - 1;
      const et1 = await escrowableERC20.escrowTransfers(workflowId1);
      expect(et1.disputeResolver).to.equal(resolver.address); // same in this module, but pinned via module path

      // Phase 7: authorizedResolver removed - test that module changes don't affect existing escrows
      // Deploy new resolution module and swap to it
      const newResolutionModuleFactory = await ethers.getContractFactory("DefaultResolutionModule");
      const newResolutionModule = await newResolutionModuleFactory.deploy(owner.address, owner.address);
      await newResolutionModule.waitForDeployment();
      await escrowableERC20.connect(owner).proposeResolutionModule(await newResolutionModule.getAddress());
      // Wait for resolution module delay before activating
      const resolutionDelay = await escrowableERC20.resolutionModuleDelay();
      await time.increase(Number(resolutionDelay) + 1);
      await escrowableERC20.connect(owner).activateResolutionModule();
      const et0After = await escrowableERC20.escrowTransfers(workflowId0);
      const et1After = await escrowableERC20.escrowTransfers(workflowId1);
      expect(et0After.disputeResolver).to.equal(resolver.address);
      expect(et1After.disputeResolver).to.equal(resolver.address);
    });
  });

  describe("Settings System", function () {
    it("Should create escrow with custom settings", async function () {
      await escrowableERC20.transfer(sender.address, INITIAL_TRANSFER_AMOUNT);
      
      const currentTime = await time.latest();
      const autoReleaseTime = currentTime + 3600;
      
      const settings = {
        customResolver: resolver.address,
        yieldEnabled: true,
        autoReleaseTime: autoReleaseTime,
        autoCancelTime: 0,
        escrowType: 0 // STANDARD
      };
      
      const tx = await escrowableERC20
        .connect(sender)
        .getFunction("createEscrow(address,uint256,(address,bool,uint256,uint256,uint8))")
        .send(recipient.address, INITIAL_TRANSFER_AMOUNT, settings);
      await tx.wait();
      
      const workflowId = Number(await escrowableERC20.nextWorkflowId()) - 1;
      const escrowSettings = await escrowableERC20.getEscrowSettings(workflowId);
      const escrowTransfer = await escrowableERC20.escrowTransfers(workflowId);
      
      expect(escrowSettings.customResolver).to.equal(resolver.address);
      expect(escrowSettings.yieldEnabled).to.equal(true);
      expect(escrowSettings.autoReleaseTime).to.equal(autoReleaseTime);
      expect(escrowTransfer.disputeResolver).to.equal(resolver.address);
    });

    it("Should update escrow settings for pending escrow", async function () {
      const workflowId = await createEscrowTransfer(INITIAL_TRANSFER_AMOUNT);
      
      const newSettings = {
        customResolver: resolver.address,
        yieldEnabled: true,
        autoReleaseTime: 0,
        autoCancelTime: 0,
        escrowType: 0
      };
      
      await escrowableERC20.connect(sender).updateEscrowSettings(workflowId, newSettings);
      
      const escrowSettings = await escrowableERC20.getEscrowSettings(workflowId);
      expect(escrowSettings.customResolver).to.equal(resolver.address);
      expect(escrowSettings.yieldEnabled).to.equal(true);
    });

    it("Should not allow updating settings for non-pending escrow", async function () {
      const workflowId = await createEscrowTransfer(INITIAL_TRANSFER_AMOUNT);
      await escrowableERC20.connect(sender).releaseEscrowTransfer(workflowId);
      
      const newSettings = {
        customResolver: resolver.address,
        yieldEnabled: false,
        autoReleaseTime: 0,
        autoCancelTime: 0,
        escrowType: 0
      };
      
      await expect(
        escrowableERC20.connect(sender).updateEscrowSettings(workflowId, newSettings)
      ).to.be.revertedWithCustomError(escrowableERC20, "TransferNotPending");
    });

    it("Should validate auto time limits", async function () {
      await escrowableERC20.transfer(sender.address, INITIAL_TRANSFER_AMOUNT);
      
      const currentTime = await time.latest();
      const maxTime = currentTime + 10 * 365 * 24 * 60 * 60; // 10 years
      const invalidTime = maxTime + 100; // Exceeds max by 100 seconds
      
      const settings = {
        customResolver: ethers.ZeroAddress,
        yieldEnabled: false,
        autoReleaseTime: invalidTime,
        autoCancelTime: 0,
        escrowType: 0
      };
      
      await expect(
        escrowableERC20
          .connect(sender)
          .getFunction("createEscrow(address,uint256,(address,bool,uint256,uint256,uint8))")
          .send(recipient.address, INITIAL_TRANSFER_AMOUNT, settings)
      ).to.be.revertedWithCustomError(escrowableERC20, "AutoTimeExceedsMaxLimit");
    });
  });

  describe("Batch Operations", function () {
    it("Should batch release multiple escrows", async function () {
      const workflowId1 = await createEscrowTransfer(INITIAL_TRANSFER_AMOUNT);
      const workflowId2 = await createEscrowTransfer(INITIAL_TRANSFER_AMOUNT);
      const workflowId3 = await createEscrowTransfer(INITIAL_TRANSFER_AMOUNT);
      
      const recipientBalanceBefore = await escrowableERC20.balanceOf(recipient.address);
      
      await escrowableERC20.connect(sender).batchReleaseEscrow([workflowId1, workflowId2, workflowId3]);
      
      const transfer1 = await escrowableERC20.escrowTransfers(workflowId1);
      const transfer2 = await escrowableERC20.escrowTransfers(workflowId2);
      const transfer3 = await escrowableERC20.escrowTransfers(workflowId3);
      
      expect(transfer1.escrowState).to.equal(2); // RELEASED (enum value 2)
      expect(transfer2.escrowState).to.equal(2); // RELEASED (enum value 2)
      expect(transfer3.escrowState).to.equal(2); // RELEASED (enum value 2)
      
      const recipientBalanceAfter = await escrowableERC20.balanceOf(recipient.address);
      const expectedAmount = (INITIAL_TRANSFER_AMOUNT - (INITIAL_TRANSFER_AMOUNT * BigInt(ESCROW_FEE)) / BigInt(ESCROW_FEE_DENOMINATOR)) * 3n;
      expect(recipientBalanceAfter - recipientBalanceBefore).to.equal(expectedAmount);
    });

    it("Should batch cancel multiple escrows", async function () {
      const workflowId1 = await createEscrowTransfer(INITIAL_TRANSFER_AMOUNT);
      const workflowId2 = await createEscrowTransfer(INITIAL_TRANSFER_AMOUNT);
      
      // Request cancellation for both
      await escrowableERC20.connect(recipient).recipientCancel(workflowId1);
      await escrowableERC20.connect(recipient).recipientCancel(workflowId2);
      
      const senderBalanceBefore = await escrowableERC20.balanceOf(sender.address);
      
      // Batch cancel (sender confirms both cancellations)
      await escrowableERC20.connect(sender).batchCancelEscrow([workflowId1, workflowId2]);
      
      const transfer1 = await escrowableERC20.escrowTransfers(workflowId1);
      const transfer2 = await escrowableERC20.escrowTransfers(workflowId2);
      
      expect(transfer1.escrowState).to.equal(3); // REFUNDED (enum value 3)
      expect(transfer2.escrowState).to.equal(3); // REFUNDED (enum value 3)
      
      const senderBalanceAfter = await escrowableERC20.balanceOf(sender.address);
      const expectedAmount = (INITIAL_TRANSFER_AMOUNT - (INITIAL_TRANSFER_AMOUNT * BigInt(ESCROW_FEE)) / BigInt(ESCROW_FEE_DENOMINATOR)) * 2n;
      expect(senderBalanceAfter - senderBalanceBefore).to.equal(expectedAmount);
    });

    it("Should skip non-pending escrows in batch operations", async function () {
      const workflowId1 = await createEscrowTransfer(INITIAL_TRANSFER_AMOUNT);
      const workflowId2 = await createEscrowTransfer(INITIAL_TRANSFER_AMOUNT);
      
      // Release first escrow
      await escrowableERC20.connect(sender).releaseEscrowTransfer(workflowId1);
      
      // Try to batch release both (should only release workflowId2)
      await escrowableERC20.connect(sender).batchReleaseEscrow([workflowId1, workflowId2]);
      
      const transfer1 = await escrowableERC20.escrowTransfers(workflowId1);
      const transfer2 = await escrowableERC20.escrowTransfers(workflowId2);
      
      expect(transfer1.escrowState).to.equal(2); // Still RELEASED (enum value 2)
      expect(transfer2.escrowState).to.equal(2); // RELEASED (enum value 2)
    });
  });

  describe("State Machine and Events", function () {
    it("Should emit EscrowStateChanged on release", async function () {
      const workflowId = await createEscrowTransfer(INITIAL_TRANSFER_AMOUNT);
      
      await expect(
        escrowableERC20.connect(sender).releaseEscrowTransfer(workflowId)
      ).to.emit(escrowableERC20, "EscrowStateChanged")
        .withArgs(workflowId, 1, 2); // PENDING (1) -> RELEASED (2) - enum values are correct
    });

    it("Should emit EscrowStateChanged on cancel", async function () {
      const workflowId = await createEscrowTransfer(INITIAL_TRANSFER_AMOUNT);
      
      await expect(
        escrowableERC20.connect(recipient).recipientCancel(workflowId)
      ).to.emit(escrowableERC20, "CancelRequested")
        .withArgs(workflowId, recipient.address);
      
      await expect(
        escrowableERC20.connect(sender).senderCancel(workflowId)
      ).to.emit(escrowableERC20, "EscrowStateChanged")
        .withArgs(workflowId, 1, 3); // PENDING (1) -> REFUNDED (3)
    });

    it("Should emit CancelRequested events", async function () {
      const workflowId = await createEscrowTransfer(INITIAL_TRANSFER_AMOUNT);
      
      await expect(
        escrowableERC20.connect(sender).senderCancel(workflowId)
      ).to.emit(escrowableERC20, "CancelRequested")
        .withArgs(workflowId, sender.address);
    });

    it("Should emit DisputeOpened event", async function () {
      const workflowId = await createEscrowTransfer(INITIAL_TRANSFER_AMOUNT);
      
      await expect(
        escrowableERC20.connect(sender).raiseDispute(workflowId)
      ).to.emit(escrowableERC20, "DisputeOpened")
        .withArgs(workflowId, sender.address, resolver.address); // resolver is set in beforeEach
    });
  });

  describe("executeTimeout Alias", function () {
    it("Should execute timeout using executeTimeout alias", async function () {
      await escrowableERC20.transfer(sender.address, INITIAL_TRANSFER_AMOUNT);
      
      const currentTime = await time.latest();
      const autoReleaseTime = currentTime + 60;
      
      const tx = await escrowableERC20
        .connect(sender)
        .getFunction("createEscrow(address,uint256,uint256,uint256)")
        .send(recipient.address, INITIAL_TRANSFER_AMOUNT, autoReleaseTime, 0);
      await tx.wait();
      
      const workflowId = Number(await escrowableERC20.nextWorkflowId()) - 1;
      await time.increase(120);
      
      // Use executeTimeout alias instead of automateTimedActions
      await escrowableERC20.connect(sender).executeTimeout(workflowId);
      
      const escrowTransfer = await escrowableERC20.escrowTransfers(workflowId);
      expect(escrowTransfer.escrowState).to.equal(2); // RELEASED (enum value 2)
    });

    it("Should emit TimeoutExecuted event", async function () {
      await escrowableERC20.transfer(sender.address, INITIAL_TRANSFER_AMOUNT);
      
      const currentTime = await time.latest();
      const autoReleaseTime = currentTime + 60;
      
      await escrowableERC20
        .connect(sender)
        .getFunction("createEscrow(address,uint256,uint256,uint256)")
        .send(recipient.address, INITIAL_TRANSFER_AMOUNT, autoReleaseTime, 0);
      
      const workflowId = Number(await escrowableERC20.nextWorkflowId()) - 1;
      await time.increase(120);
      
      await expect(
        escrowableERC20.connect(sender).executeTimeout(workflowId)
      ).to.emit(escrowableERC20, "TimeoutExecuted")
        .withArgs(workflowId, 0); // 0 = RELEASE action (1 = CANCEL)
    });
  });

  describe("resolve() Function", function () {
    beforeEach(async function () {
      // setAuthorizedResolver is deprecated - resolution module is already set up in main beforeEach
    });

    it("Should resolve with single payout (full release)", async function () {
      const workflowId = await createEscrowTransfer(INITIAL_TRANSFER_AMOUNT);
      await escrowableERC20.connect(sender).raiseDispute(workflowId);
      
      const escrowTransfer = await escrowableERC20.escrowTransfers(workflowId);
      const payoutAmount = escrowTransfer.remainingBalance;
      
      const payouts = [{
        recipient: recipient.address,
        amount: payoutAmount
      }];
      
      const recipientBalanceBefore = await escrowableERC20.balanceOf(recipient.address);
      
      await escrowableERC20
        .connect(resolver)
        .getFunction("resolve(uint256,(address,uint256)[],bytes32)")
        .send(workflowId, payouts, ethers.ZeroHash);
      
      const transfer = await escrowableERC20.escrowTransfers(workflowId);
      expect(transfer.escrowState).to.equal(5); // RESOLVED
      
      const recipientBalanceAfter = await escrowableERC20.balanceOf(recipient.address);
      expect(recipientBalanceAfter - recipientBalanceBefore).to.equal(payoutAmount);
    });

    it("Should resolve with multiple payouts (split)", async function () {
      const workflowId = await createEscrowTransfer(INITIAL_TRANSFER_AMOUNT);
      await escrowableERC20.connect(sender).raiseDispute(workflowId);
      
      const escrowTransfer = await escrowableERC20.escrowTransfers(workflowId);
      const totalAmount = escrowTransfer.remainingBalance;
      const halfAmount = totalAmount / 2n;
      
      const payouts = [
        { recipient: recipient.address, amount: halfAmount },
        { recipient: sender.address, amount: halfAmount }
      ];
      
      const recipientBalanceBefore = await escrowableERC20.balanceOf(recipient.address);
      const senderBalanceBefore = await escrowableERC20.balanceOf(sender.address);
      
      await escrowableERC20
        .connect(resolver)
        .getFunction("resolve(uint256,(address,uint256)[],bytes32)")
        .send(workflowId, payouts, ethers.ZeroHash);
      
      const transfer = await escrowableERC20.escrowTransfers(workflowId);
      expect(transfer.escrowState).to.equal(5); // RESOLVED
      
      const recipientBalanceAfter = await escrowableERC20.balanceOf(recipient.address);
      const senderBalanceAfter = await escrowableERC20.balanceOf(sender.address);
      
      expect(recipientBalanceAfter - recipientBalanceBefore).to.equal(halfAmount);
      expect(senderBalanceAfter - senderBalanceBefore).to.equal(halfAmount);
    });

    it("Should emit EscrowResolved event", async function () {
      const workflowId = await createEscrowTransfer(INITIAL_TRANSFER_AMOUNT);
      await escrowableERC20.connect(sender).raiseDispute(workflowId);
      
      const escrowTransfer = await escrowableERC20.escrowTransfers(workflowId);
      const payouts = [{
        recipient: recipient.address,
        amount: escrowTransfer.remainingBalance
      }];
      
      const resolutionHash = ethers.keccak256(ethers.toUtf8Bytes("resolution"));
      
      await expect(
        escrowableERC20
          .connect(resolver)
          .getFunction("resolve(uint256,(address,uint256)[],bytes32)")
          .send(workflowId, payouts, resolutionHash)
      ).to.emit(escrowableERC20, "EscrowResolved")
        .withArgs(workflowId, resolver.address, resolutionHash);
    });

    it("Should not allow non-resolver to resolve", async function () {
      const workflowId = await createEscrowTransfer(INITIAL_TRANSFER_AMOUNT);
      await escrowableERC20.connect(sender).raiseDispute(workflowId);
      
      const escrowTransfer = await escrowableERC20.escrowTransfers(workflowId);
      const payouts = [{
        recipient: recipient.address,
        amount: escrowTransfer.remainingBalance
      }];
      
      await expect(
        escrowableERC20
          .connect(sender)
          .getFunction("resolve(uint256,(address,uint256)[],bytes32)")
          .send(workflowId, payouts, ethers.ZeroHash)
      ).to.be.revertedWithCustomError(escrowableERC20, "NotAuthorizedResolver");
    });

    it("Should revert if payout sum doesn't match escrow amount", async function () {
      const workflowId = await createEscrowTransfer(INITIAL_TRANSFER_AMOUNT);
      await escrowableERC20.connect(sender).raiseDispute(workflowId);
      
      const escrowTransfer = await escrowableERC20.escrowTransfers(workflowId);
      const wrongAmount = escrowTransfer.remainingBalance + ethers.parseEther("0.1");
      
      const payouts = [{
        recipient: recipient.address,
        amount: wrongAmount
      }];
      
      await expect(
        escrowableERC20.connect(resolver).resolve(workflowId, payouts, ethers.ZeroHash)
      ).to.be.revertedWithCustomError(escrowableERC20, "InvalidAmount");
    });
  });

  describe("ERC-165 Support", function () {
    it("Should support IERC165 interface", async function () {
      const IERC165_ID = "0x01ffc9a7";
      expect(await escrowableERC20.supportsInterface(IERC165_ID)).to.be.true;
    });
  });

  describe("View Functions", function () {
    it("Should return correct escrow count", async function () {
      expect(await escrowableERC20.getEscrowCount()).to.equal(0);
      
      await createEscrowTransfer(INITIAL_TRANSFER_AMOUNT);
      expect(await escrowableERC20.getEscrowCount()).to.equal(1);
      
      await createEscrowTransfer(INITIAL_TRANSFER_AMOUNT);
      expect(await escrowableERC20.getEscrowCount()).to.equal(2);
    });

    it("Should check if escrow is pending", async function () {
      const workflowId = await createEscrowTransfer(INITIAL_TRANSFER_AMOUNT);
      
      expect(await escrowableERC20.isEscrowPending(workflowId)).to.be.true;
      
      await escrowableERC20.connect(sender).releaseEscrowTransfer(workflowId);
      
      expect(await escrowableERC20.isEscrowPending(workflowId)).to.be.false;
    });

    it("Should get escrow participants", async function () {
      const workflowId = await createEscrowTransfer(INITIAL_TRANSFER_AMOUNT);
      
      const [from, to] = await escrowableERC20.getEscrowParticipants(workflowId);
      expect(from).to.equal(sender.address);
      expect(to).to.equal(recipient.address);
    });
  });

  // Helper function
  async function createEscrowTransfer(amount: bigint) {
    await escrowableERC20.transfer(sender.address, amount);
    const tx = await escrowableERC20.connect(sender).createEscrow(recipient.address, amount);
    await tx.wait();
    const workflowId = Number(await escrowableERC20.nextWorkflowId()) - 1;
    return workflowId;
  }
});

