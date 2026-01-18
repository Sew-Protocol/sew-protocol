before(function () {
  this.skip();
}); // migrated to forge-std
/**
 * @title CoreContractsCoverage
 * @notice Comprehensive Hardhat tests to achieve 100% coverage for core contracts
 * @dev These tests complement existing tests to ensure all functions and code paths are covered
 */

import { expect } from 'chai';
import { ethers } from 'hardhat';
import { time } from '@nomicfoundation/hardhat-network-helpers';
import {
  EscrowVault,
  EscrowableERC20,
  DefaultResolutionModule,
  DefaultReleaseStrategy,
  DefaultYieldDistributionModule,
  ERC20Mock,
} from '../typechain-types';
import { setupResolutionModule } from '../helpers/setupResolutionModule';

describe('Core Contracts - Coverage Tests', function () {
  let escrowVault: EscrowVault;
  let escrowableERC20: EscrowableERC20;
  let token1: ERC20Mock;
  let token2: ERC20Mock;
  let resolutionModule: DefaultResolutionModule;
  let releaseStrategy: DefaultReleaseStrategy;
  let yieldDistributionModule: DefaultYieldDistributionModule;
  let owner: any;
  let timelock: any;
  let guardian: any;
  let feeAddress: any;
  let resolver: any;
  let buyer: any;
  let seller: any;

  const ESCROW_FEE = 100;
  const INITIAL_AMOUNT = ethers.parseEther('1000');

  beforeEach(async function () {
    [owner, timelock, guardian, feeAddress, resolver, buyer, seller] = await ethers.getSigners();

    // Deploy EscrowVault
    const escrowVaultFactory = await ethers.getContractFactory('EscrowVault');
    escrowVault = (await escrowVaultFactory.deploy(
      ESCROW_FEE,
      feeAddress.address,
      ethers.ZeroAddress,
      ethers.ZeroAddress,
    )) as EscrowVault;
    await escrowVault.waitForDeployment();

    // Deploy EscrowableERC20
    const escrowableERC20Factory = await ethers.getContractFactory('EscrowableERC20');
    escrowableERC20 = (await escrowableERC20Factory.deploy(
      'Test Token',
      'TEST',
      ESCROW_FEE,
      feeAddress.address,
      ethers.ZeroAddress,
      ethers.ZeroAddress,
    )) as EscrowableERC20;
    await escrowableERC20.waitForDeployment();

    // Deploy modules
    const resolutionModuleFactory = await ethers.getContractFactory('DefaultResolutionModule');
    resolutionModule = (await resolutionModuleFactory.deploy(
      owner.address,
      resolver.address,
    )) as DefaultResolutionModule;
    await resolutionModule.waitForDeployment();

    const releaseStrategyFactory = await ethers.getContractFactory('DefaultReleaseStrategy');
    releaseStrategy = (await releaseStrategyFactory.deploy()) as DefaultReleaseStrategy;
    await releaseStrategy.waitForDeployment();

    const yieldDistributionModuleFactory = await ethers.getContractFactory(
      'DefaultYieldDistributionModule',
    );
    yieldDistributionModule =
      (await yieldDistributionModuleFactory.deploy()) as DefaultYieldDistributionModule;
    await yieldDistributionModule.waitForDeployment();

    // Deploy mock tokens
    const tokenFactory = await ethers.getContractFactory('ERC20Mock');
    token1 = (await tokenFactory.deploy(
      'Token 1',
      'TKN1',
      owner.address,
      ethers.parseEther('1000000'),
    )) as ERC20Mock;
    await token1.waitForDeployment();
    token2 = (await tokenFactory.deploy(
      'Token 2',
      'TKN2',
      owner.address,
      ethers.parseEther('1000000'),
    )) as ERC20Mock;
    await token2.waitForDeployment();

    // Setup roles
    const ROLE_TIMELOCK = await escrowVault.ROLE_TIMELOCK();
    const ROLE_GUARDIAN = await escrowVault.ROLE_GUARDIAN();
    await escrowVault.grantRole(ROLE_TIMELOCK, owner.address);
    await escrowVault.grantRole(ROLE_TIMELOCK, timelock.address);
    await escrowVault.grantRole(ROLE_GUARDIAN, guardian.address);

    await escrowableERC20.grantRole(ROLE_TIMELOCK, owner.address);
    await escrowableERC20.grantRole(ROLE_TIMELOCK, timelock.address);
    await escrowableERC20.grantRole(ROLE_GUARDIAN, guardian.address);

    // Setup modules
    await escrowVault
      .connect(owner)
      .queueDefaultResolutionModule(await resolutionModule.getAddress());
    await escrowVault
      .connect(owner)
      .queueDefaultReleaseStrategy(await releaseStrategy.getAddress());
    await escrowVault
      .connect(owner)
      .queueDefaultYieldDistributionModule(await yieldDistributionModule.getAddress());

    const [, eta] = await escrowVault.getPendingDefaultResolutionModule();
    await time.increaseTo(Number(eta) + 1);
    await escrowVault.connect(owner).activateDefaultResolutionModule();
    await escrowVault.connect(owner).activateDefaultReleaseStrategy();
    await escrowVault.connect(owner).activateDefaultYieldDistributionModule();

    // EscrowableERC20 uses consolidated module management functions
    // ModuleType: RESOLUTION=0, RELEASE=1, YIELD_GEN=2, YIELD_DIST=3
    await escrowableERC20
      .connect(owner)
      .queueDefaultModule(0, await resolutionModule.getAddress()); // RESOLUTION
    await escrowableERC20
      .connect(owner)
      .queueDefaultModule(1, await releaseStrategy.getAddress()); // RELEASE
    await escrowableERC20
      .connect(owner)
      .queueDefaultModule(3, await yieldDistributionModule.getAddress()); // YIELD_DIST

    const [, eta2] = await escrowableERC20.getPendingDefaultModule(0); // RESOLUTION
    await time.increaseTo(Number(eta2) + 1);
    await escrowableERC20.connect(owner).activateDefaultModule(0); // RESOLUTION
    await escrowableERC20.connect(owner).activateDefaultModule(1); // RELEASE
    await escrowableERC20.connect(owner).activateDefaultModule(3); // YIELD_DIST

    // Transfer tokens
    await token1.transfer(buyer.address, ethers.parseEther('10000'));
    await token2.transfer(buyer.address, ethers.parseEther('10000'));
    await escrowableERC20.transfer(buyer.address, ethers.parseEther('10000'));
  });

  describe('BaseEscrow - Governance Functions', function () {
    it('Should set default auto cancel time', async function () {
      const newTime = (await time.latest()) + 7 * 24 * 60 * 60;
      await escrowVault.connect(timelock).setDefaultAutoCancelTime(newTime);
      expect(await escrowVault.defaultAutoCancelTime()).to.equal(newTime);
    });

    it('Should set default auto release time', async function () {
      const newTime = (await time.latest()) + 7 * 24 * 60 * 60;
      await escrowVault.connect(timelock).setDefaultAutoReleaseTime(newTime);
      expect(await escrowVault.defaultAutoReleaseTime()).to.equal(newTime);
    });

    it('Should set max dispute duration', async function () {
      const newDuration = 30 * 24 * 60 * 60; // 30 days
      await escrowVault.connect(timelock).setMaxDisputeDuration(newDuration);
      expect(await escrowVault.maxDisputeDuration()).to.equal(newDuration);
    });

    it('Should revert if max dispute duration too short', async function () {
      await expect(
        escrowVault.connect(timelock).setMaxDisputeDuration(6 * 24 * 60 * 60),
      ).to.be.revertedWith('Too short');
    });

    it('Should revert if max dispute duration too long', async function () {
      await expect(
        escrowVault.connect(timelock).setMaxDisputeDuration(366 * 24 * 60 * 60),
      ).to.be.revertedWith('Too long');
    });

    it('Should set max attachments', async function () {
      await escrowVault.connect(timelock).setMaxAttachments(15);
      expect(await escrowVault.maxAttachments()).to.equal(15);
    });

    it('Should set resolution module delay', async function () {
      const newDelay = 10 * 24 * 60 * 60; // 10 days
      await escrowVault.connect(timelock).setResolutionModuleDelay(newDelay);
      expect(await escrowVault.disputeResolutionModuleDelay()).to.equal(newDelay);
    });
  });

  describe('BaseEscrow - Fee Management', function () {
    it('Should queue escrow fee', async function () {
      const newFee = 200; // 2%
      await escrowVault.connect(timelock).queueEscrowFee(newFee);
      const [value, , exists] = await escrowVault.getPendingEscrowFee();
      expect(exists).to.be.true;
      expect(value).to.equal(newFee);
    });

    it('Should activate escrow fee', async function () {
      const newFee = 200;
      await escrowVault.connect(timelock).queueEscrowFee(newFee);
      const [, eta] = await escrowVault.getPendingEscrowFee();
      await time.increaseTo(Number(eta) + 1);
      await escrowVault.connect(timelock).activateEscrowFee();
      expect(await escrowVault.escrowFee()).to.equal(newFee);
    });

    it('Should queue escrow fee address', async function () {
      const newFeeAddress = ethers.Wallet.createRandom().address;
      await escrowVault.connect(timelock).queueEscrowFeeAddress(newFeeAddress);
      const [value, , exists] = await escrowVault.getPendingFeeRecipient();
      expect(exists).to.be.true;
      expect(value).to.equal(newFeeAddress);
    });

    it('Should activate escrow fee address', async function () {
      const newFeeAddress = ethers.Wallet.createRandom().address;
      await escrowVault.connect(timelock).queueEscrowFeeAddress(newFeeAddress);
      const [, eta] = await escrowVault.getPendingFeeRecipient();
      await time.increaseTo(Number(eta) + 1);
      await escrowVault.connect(timelock).activateEscrowFeeAddress();
      expect(await escrowVault.escrowFeeAddress()).to.equal(newFeeAddress);
    });
  });

  describe('BaseEscrow - Pause/Unpause', function () {
    it('Should pause protocol', async function () {
      await escrowVault.connect(guardian).pause();
      expect(await escrowVault.paused()).to.be.true;
    });

    it('Should unpause protocol', async function () {
      await escrowVault.connect(guardian).pause();
      await escrowVault.connect(timelock).unpause();
      expect(await escrowVault.paused()).to.be.false;
    });
  });

  describe('BaseEscrow - Module Management', function () {
    it('Should propose resolution module', async function () {
      const newModuleFactory = await ethers.getContractFactory('DefaultResolutionModule');
      const newModule = await newModuleFactory.deploy(owner.address, resolver.address);
      await newModule.waitForDeployment();

      await escrowVault.connect(timelock).proposeResolutionModule(await newModule.getAddress());
      expect(await escrowVault.pendingDisputeResolutionModule()).to.equal(
        await newModule.getAddress(),
      );
    });

    it('Should activate resolution module', async function () {
      const newModuleFactory = await ethers.getContractFactory('DefaultResolutionModule');
      const newModule = await newModuleFactory.deploy(owner.address, resolver.address);
      await newModule.waitForDeployment();

      await escrowVault.connect(timelock).proposeResolutionModule(await newModule.getAddress());
      const delay = await escrowVault.disputeResolutionModuleDelay();
      await time.increase(Number(delay) + 1);
      await escrowVault.connect(timelock).activateResolutionModule();
      expect(await escrowVault.disputeResolutionModule()).to.equal(await newModule.getAddress());
    });
  });

  describe('BaseEscrow - Dispute Timeout', function () {
    it('Should auto cancel disputed escrow after timeout', async function () {
      await token1.connect(buyer).approve(await escrowVault.getAddress(), INITIAL_AMOUNT);
      const tx = await escrowVault
        .connect(buyer)
        .createEscrow(await token1.getAddress(), seller.address, INITIAL_AMOUNT);
      await tx.wait();
      const workflowId = Number(await escrowVault.nextWorkflowId()) - 1;

      await escrowVault.connect(buyer).raiseDispute(workflowId);

      await escrowVault.connect(timelock).setMaxDisputeDuration(7 * 24 * 60 * 60);
      await time.increase(7 * 24 * 60 * 60 + 1);

      await escrowVault.autoCancelDisputedEscrow(workflowId);

      const et = await escrowVault.escrowTransfers(workflowId);
      expect(et.escrowState).to.equal(5); // RESOLVED
    });

    it('Should check if dispute is timed out', async function () {
      await token1.connect(buyer).approve(await escrowVault.getAddress(), INITIAL_AMOUNT);
      const tx = await escrowVault
        .connect(buyer)
        .createEscrow(await token1.getAddress(), seller.address, INITIAL_AMOUNT);
      await tx.wait();
      const workflowId = Number(await escrowVault.nextWorkflowId()) - 1;

      await escrowVault.connect(buyer).raiseDispute(workflowId);

      await escrowVault.connect(timelock).setMaxDisputeDuration(7 * 24 * 60 * 60);
      await time.increase(7 * 24 * 60 * 60 + 1);

      const [isTimedOut, timeRemaining] = await escrowVault.isDisputeTimedOut(workflowId);
      expect(isTimedOut).to.be.true;
      expect(timeRemaining).to.equal(0);
    });
  });

  describe('BaseEscrow - Timed Actions', function () {
    it('Should automate timed actions for single escrow', async function () {
      const currentTime = await time.latest();
      const autoCancelTime = currentTime + 60;

      await escrowVault.connect(timelock).setDefaultAutoCancelTime(autoCancelTime);

      await token1.connect(buyer).approve(await escrowVault.getAddress(), INITIAL_AMOUNT);
      const settings = {
        customResolver: ethers.ZeroAddress,
        yieldEnabled: false,
        autoReleaseTime: 0,
        autoCancelTime: autoCancelTime,
      };
      const tx = await escrowVault
        .connect(buyer)
        [
          'createEscrow(address,address,uint256,(address,bool,uint256,uint256,uint8))'
        ](await token1.getAddress(), seller.address, INITIAL_AMOUNT, settings);
      await tx.wait();
      const workflowId = Number(await escrowVault.nextWorkflowId()) - 1;

      await time.increaseTo(autoCancelTime + 1);
      await escrowVault.automateTimedActions(workflowId, 0);

      const et = await escrowVault.escrowTransfers(workflowId);
      expect(et.escrowState).to.equal(3); // REFUNDED
    });

    it('Should automate timed actions for range', async function () {
      const currentTime = await time.latest();
      const autoCancelTime = currentTime + 60;

      await escrowVault.connect(timelock).setDefaultAutoCancelTime(autoCancelTime);

      await token1.connect(buyer).approve(await escrowVault.getAddress(), INITIAL_AMOUNT * 3n);
      const settings = {
        customResolver: ethers.ZeroAddress,
        yieldEnabled: false,
        autoReleaseTime: 0,
        autoCancelTime: autoCancelTime,
      };

      await escrowVault
        .connect(buyer)
        [
          'createEscrow(address,address,uint256,(address,bool,uint256,uint256,uint8))'
        ](await token1.getAddress(), seller.address, INITIAL_AMOUNT, settings);
      await escrowVault
        .connect(buyer)
        [
          'createEscrow(address,address,uint256,(address,bool,uint256,uint256,uint8))'
        ](await token1.getAddress(), seller.address, INITIAL_AMOUNT, settings);
      await escrowVault
        .connect(buyer)
        [
          'createEscrow(address,address,uint256,(address,bool,uint256,uint256,uint8))'
        ](await token1.getAddress(), seller.address, INITIAL_AMOUNT, settings);

      const workflowId1 = Number(await escrowVault.nextWorkflowId()) - 3;
      const workflowId3 = Number(await escrowVault.nextWorkflowId()) - 1;

      await time.increaseTo(autoCancelTime + 1);
      await escrowVault.automateTimedActions(workflowId1, workflowId3 + 1);

      const et1 = await escrowVault.escrowTransfers(workflowId1);
      expect(et1.escrowState).to.equal(3); // REFUNDED
    });
  });

  describe('BaseEscrow - Attachments', function () {
    it('Should add attachment', async function () {
      await token1.connect(buyer).approve(await escrowVault.getAddress(), INITIAL_AMOUNT);
      const tx = await escrowVault
        .connect(buyer)
        .createEscrow(await token1.getAddress(), seller.address, INITIAL_AMOUNT);
      await tx.wait();
      const workflowId = Number(await escrowVault.nextWorkflowId()) - 1;

      const uri = 'https://example.com/attachment';
      const hash = ethers.id('attachment data');

      await escrowVault.connect(buyer).addAttachment(workflowId, uri, hash);

      const [uris, hashes] = await escrowVault.getAttachments(workflowId);
      expect(uris.length).to.equal(1);
      expect(uris[0]).to.equal(uri);
    });

    it('Should revert if max attachments reached', async function () {
      await escrowVault.connect(timelock).setMaxAttachments(1);

      await token1.connect(buyer).approve(await escrowVault.getAddress(), INITIAL_AMOUNT);
      const tx = await escrowVault
        .connect(buyer)
        .createEscrow(await token1.getAddress(), seller.address, INITIAL_AMOUNT);
      await tx.wait();
      const workflowId = Number(await escrowVault.nextWorkflowId()) - 1;

      const uri = 'https://example.com/attachment';
      const hash = ethers.id('attachment data');

      await escrowVault.connect(buyer).addAttachment(workflowId, uri, hash);

      await expect(escrowVault.connect(buyer).addAttachment(workflowId, uri, hash)).to.be.reverted;
    });
  });

  describe('BaseEscrow - Cancellation', function () {
    it('Should allow recipient cancel', async function () {
      await token1.connect(buyer).approve(await escrowVault.getAddress(), INITIAL_AMOUNT);
      const tx = await escrowVault
        .connect(buyer)
        .createEscrow(await token1.getAddress(), seller.address, INITIAL_AMOUNT);
      await tx.wait();
      const workflowId = Number(await escrowVault.nextWorkflowId()) - 1;

      await escrowVault.connect(seller).recipientCancel(workflowId);

      const et = await escrowVault.escrowTransfers(workflowId);
      expect(Number(et.recipientStatus)).to.equal(1); // AGREE_TO_CANCEL
    });

    it('Should allow sender cancel', async function () {
      await token1.connect(buyer).approve(await escrowVault.getAddress(), INITIAL_AMOUNT);
      const tx = await escrowVault
        .connect(buyer)
        .createEscrow(await token1.getAddress(), seller.address, INITIAL_AMOUNT);
      await tx.wait();
      const workflowId = Number(await escrowVault.nextWorkflowId()) - 1;

      await escrowVault.connect(buyer).senderCancel(workflowId);

      const et = await escrowVault.escrowTransfers(workflowId);
      // When sender cancels alone, it sets senderStatus to AGREE_TO_CANCEL (1)
      // The escrow is only canceled when both parties agree
      expect(Number(et.senderStatus)).to.equal(1); // AGREE_TO_CANCEL
      // Escrow remains in PENDING state until both parties agree
      expect(Number(et.escrowState)).to.equal(1); // PENDING
    });

    it('Should cancel when both parties agree', async function () {
      await token1.connect(buyer).approve(await escrowVault.getAddress(), INITIAL_AMOUNT);
      const tx = await escrowVault
        .connect(buyer)
        .createEscrow(await token1.getAddress(), seller.address, INITIAL_AMOUNT);
      await tx.wait();
      const workflowId = Number(await escrowVault.nextWorkflowId()) - 1;

      await escrowVault.connect(seller).recipientCancel(workflowId);
      await escrowVault.connect(buyer).senderCancel(workflowId);

      const et = await escrowVault.escrowTransfers(workflowId);
      expect(et.escrowState).to.equal(3); // REFUNDED
    });
  });

  describe('BaseEscrow - Resolver Actions', function () {
    it('Should allow resolver to cancel', async function () {
      await token1.connect(buyer).approve(await escrowVault.getAddress(), INITIAL_AMOUNT);
      const tx = await escrowVault
        .connect(buyer)
        .createEscrow(await token1.getAddress(), seller.address, INITIAL_AMOUNT);
      await tx.wait();
      const workflowId = Number(await escrowVault.nextWorkflowId()) - 1;

      await escrowVault.connect(buyer).raiseDispute(workflowId);

      await escrowVault.connect(resolver).cancelAsDisputeResolver(workflowId, ethers.ZeroHash);

      const et = await escrowVault.escrowTransfers(workflowId);
      expect(Number(et.escrowState)).to.equal(5); // RESOLVED
    });

    it('Should allow resolver to release', async function () {
      await token1.connect(buyer).approve(await escrowVault.getAddress(), INITIAL_AMOUNT);
      const tx = await escrowVault
        .connect(buyer)
        .createEscrow(await token1.getAddress(), seller.address, INITIAL_AMOUNT);
      await tx.wait();
      const workflowId = Number(await escrowVault.nextWorkflowId()) - 1;

      await escrowVault.connect(buyer).raiseDispute(workflowId);

      await escrowVault.connect(resolver).releaseAsDisputeResolver(workflowId, ethers.ZeroHash);

      const et = await escrowVault.escrowTransfers(workflowId);
      expect(Number(et.escrowState)).to.equal(5); // RESOLVED
    });

    it('Should allow resolver to partial release', async function () {
      await token1.connect(buyer).approve(await escrowVault.getAddress(), INITIAL_AMOUNT);
      const tx = await escrowVault
        .connect(buyer)
        .createEscrow(await token1.getAddress(), seller.address, INITIAL_AMOUNT);
      await tx.wait();
      const workflowId = Number(await escrowVault.nextWorkflowId()) - 1;

      await escrowVault.connect(buyer).raiseDispute(workflowId);

      const remainingBalance = await escrowVault.getRemainingBalance(workflowId);
      const partialAmount = remainingBalance / 2n;

      await escrowVault
        .connect(resolver)
        .partialReleaseAsDisputeResolver(workflowId, partialAmount, ethers.ZeroHash);

      expect(await escrowVault.getRemainingBalance(workflowId)).to.equal(
        remainingBalance - partialAmount,
      );
    });

    it('Should allow resolver to partial cancel', async function () {
      await token1.connect(buyer).approve(await escrowVault.getAddress(), INITIAL_AMOUNT);
      const tx = await escrowVault
        .connect(buyer)
        .createEscrow(await token1.getAddress(), seller.address, INITIAL_AMOUNT);
      await tx.wait();
      const workflowId = Number(await escrowVault.nextWorkflowId()) - 1;

      await escrowVault.connect(buyer).raiseDispute(workflowId);

      const remainingBalance = await escrowVault.getRemainingBalance(workflowId);
      const partialAmount = remainingBalance / 2n;

      await escrowVault
        .connect(resolver)
        .partialCancelAsDisputeResolver(workflowId, partialAmount, ethers.ZeroHash);

      expect(await escrowVault.getRemainingBalance(workflowId)).to.equal(
        remainingBalance - partialAmount,
      );
    });
  });

  describe('BaseEscrow - Dispute Functions', function () {
    it('Should raise dispute', async function () {
      await token1.connect(buyer).approve(await escrowVault.getAddress(), INITIAL_AMOUNT);
      const tx = await escrowVault
        .connect(buyer)
        .createEscrow(await token1.getAddress(), seller.address, INITIAL_AMOUNT);
      await tx.wait();
      const workflowId = Number(await escrowVault.nextWorkflowId()) - 1;

      await escrowVault.connect(buyer).raiseDispute(workflowId);

      const et = await escrowVault.escrowTransfers(workflowId);
      expect(et.escrowState).to.equal(4); // DISPUTED
    });

    // NOTE: resolve() function was removed. Multi-recipient resolution may be added
    // back in the future with participant approval mechanism.
    //
    // it("Should resolve with payouts", async function () {
    //   // Test removed - resolve() function no longer exists
    //   // Use releaseAsDisputeResolver() or cancelAsDisputeResolver() instead
    // });
    //
    // it("Should resolve with partial payouts", async function () {
    //   // Test removed - resolve() function no longer exists
    //   // Use partialReleaseAsDisputeResolver() or partialCancelAsDisputeResolver() instead
    // });
  });

  describe('BaseEscrow - View Functions', function () {
    it('Should get escrow transfer', async function () {
      await token1.connect(buyer).approve(await escrowVault.getAddress(), INITIAL_AMOUNT);
      const tx = await escrowVault
        .connect(buyer)
        .createEscrow(await token1.getAddress(), seller.address, INITIAL_AMOUNT);
      await tx.wait();
      const workflowId = Number(await escrowVault.nextWorkflowId()) - 1;

      const et = await escrowVault.getEscrowTransfer(workflowId);
      expect(et.from).to.equal(buyer.address);
      expect(et.to).to.equal(seller.address);
    });

    it('Should get total deposited', async function () {
      await token1.connect(buyer).approve(await escrowVault.getAddress(), INITIAL_AMOUNT);
      const tx = await escrowVault
        .connect(buyer)
        .createEscrow(await token1.getAddress(), seller.address, INITIAL_AMOUNT);
      await tx.wait();
      const workflowId = Number(await escrowVault.nextWorkflowId()) - 1;

      expect(await escrowVault.getTotalDeposited(workflowId)).to.equal(INITIAL_AMOUNT);
    });

    it('Should get remaining balance', async function () {
      await token1.connect(buyer).approve(await escrowVault.getAddress(), INITIAL_AMOUNT);
      const tx = await escrowVault
        .connect(buyer)
        .createEscrow(await token1.getAddress(), seller.address, INITIAL_AMOUNT);
      await tx.wait();
      const workflowId = Number(await escrowVault.nextWorkflowId()) - 1;

      const fee = (INITIAL_AMOUNT * BigInt(ESCROW_FEE)) / 10000n;
      const expectedBalance = INITIAL_AMOUNT - fee;
      expect(await escrowVault.getRemainingBalance(workflowId)).to.equal(expectedBalance);
    });

    it('Should get escrow participants', async function () {
      await token1.connect(buyer).approve(await escrowVault.getAddress(), INITIAL_AMOUNT);
      const tx = await escrowVault
        .connect(buyer)
        .createEscrow(await token1.getAddress(), seller.address, INITIAL_AMOUNT);
      await tx.wait();
      const workflowId = Number(await escrowVault.nextWorkflowId()) - 1;

      const [from, to] = await escrowVault.getEscrowParticipants(workflowId);
      expect(from).to.equal(buyer.address);
      expect(to).to.equal(seller.address);
    });

    it('Should get total escrows by status', async function () {
      await token1.connect(buyer).approve(await escrowVault.getAddress(), INITIAL_AMOUNT * 3n);
      await escrowVault
        .connect(buyer)
        .createEscrow(await token1.getAddress(), seller.address, INITIAL_AMOUNT);
      await escrowVault
        .connect(buyer)
        .createEscrow(await token1.getAddress(), seller.address, INITIAL_AMOUNT);
      await escrowVault
        .connect(buyer)
        .createEscrow(await token1.getAddress(), seller.address, INITIAL_AMOUNT);

      const pendingCount = await escrowVault.getTotalEscrowsByStatus(1); // PENDING
      expect(pendingCount).to.be.gte(3);
    });

    it('Should get escrow settings', async function () {
      await token1.connect(buyer).approve(await escrowVault.getAddress(), INITIAL_AMOUNT);
      const settings = {
        customResolver: ethers.ZeroAddress,
        yieldEnabled: false,
        autoReleaseTime: 0,
        autoCancelTime: 0
      };
      const tx = await escrowVault
        .connect(buyer)
        [
          'createEscrow(address,address,uint256,(address,bool,uint256,uint256,uint8))'
        ](await token1.getAddress(), seller.address, INITIAL_AMOUNT, settings);
      await tx.wait();
      const workflowId = Number(await escrowVault.nextWorkflowId()) - 1;

      const retrieved = await escrowVault.getEscrowSettings(workflowId);
      expect(retrieved.escrowType).to.equal(0); // STANDARD
    });

    // NOTE: updateEscrowSettings() was removed to enforce strict snapshot immutability.

    it('Should get attachments', async function () {
      await token1.connect(buyer).approve(await escrowVault.getAddress(), INITIAL_AMOUNT);
      const tx = await escrowVault
        .connect(buyer)
        .createEscrow(await token1.getAddress(), seller.address, INITIAL_AMOUNT);
      await tx.wait();
      const workflowId = Number(await escrowVault.nextWorkflowId()) - 1;

      const uri = 'https://example.com/attachment';
      const hash = ethers.id('attachment data');
      await escrowVault.connect(buyer).addAttachment(workflowId, uri, hash);

      const [uris, hashes] = await escrowVault.getAttachments(workflowId);
      expect(uris.length).to.equal(1);
      expect(uris[0]).to.equal(uri);
      expect(hashes[0]).to.equal(hash);
    });

    it('Should get escrow status info', async function () {
      await token1.connect(buyer).approve(await escrowVault.getAddress(), INITIAL_AMOUNT);
      const tx = await escrowVault
        .connect(buyer)
        .createEscrow(await token1.getAddress(), seller.address, INITIAL_AMOUNT);
      await tx.wait();
      const workflowId = Number(await escrowVault.nextWorkflowId()) - 1;

      const [status, isActive] = await escrowVault.getEscrowStatusInfo(workflowId);
      expect(status).to.equal(1); // PENDING
      expect(isActive).to.be.true;
    });

    it('Should support IERC165 interface', async function () {
      const IERC165_ID = '0x01ffc9a7';
      expect(await escrowVault.supportsInterface(IERC165_ID)).to.be.true;
    });
  });

  describe('EscrowVault - Specific Functions', function () {
    it('Should create escrow with settings', async function () {
      await token1.connect(buyer).approve(await escrowVault.getAddress(), INITIAL_AMOUNT);
      const settings = {
        customResolver: ethers.ZeroAddress,
        yieldEnabled: false,
        autoReleaseTime: 0,
        autoCancelTime: 0
      };
      const tx = await escrowVault
        .connect(buyer)
        [
          'createEscrow(address,address,uint256,(address,bool,uint256,uint256,uint8))'
        ](await token1.getAddress(), seller.address, INITIAL_AMOUNT, settings);
      await tx.wait();
      const workflowId = Number(await escrowVault.nextWorkflowId()) - 1;
      // Don't assert specific workflowId as it depends on previous tests
      expect(workflowId).to.be.gte(0);
    });

    it('Should create escrow with auto times', async function () {
      await token1.connect(buyer).approve(await escrowVault.getAddress(), INITIAL_AMOUNT);
      const currentTime = await time.latest();
      const autoReleaseTime = currentTime + 7 * 24 * 60 * 60;
      const autoCancelTime = 0;

      // Use settings version to avoid reentrancy guard conflict
      const settings = {
        customResolver: ethers.ZeroAddress,
        yieldEnabled: false,
        autoReleaseTime: autoReleaseTime,
        autoCancelTime: autoCancelTime,
      };
      const tx = await escrowVault
        .connect(buyer)
        [
          'createEscrow(address,address,uint256,(address,bool,uint256,uint256,uint8))'
        ](await token1.getAddress(), seller.address, INITIAL_AMOUNT, settings);
      await tx.wait();
      const workflowId = Number(await escrowVault.nextWorkflowId()) - 1;
      // Don't assert specific workflowId as it depends on previous tests
      expect(workflowId).to.be.gte(0);
    });

    it('Should get release strategy', async function () {
      await token1.connect(buyer).approve(await escrowVault.getAddress(), INITIAL_AMOUNT);
      const tx = await escrowVault
        .connect(buyer)
        .createEscrow(await token1.getAddress(), seller.address, INITIAL_AMOUNT);
      await tx.wait();
      const workflowId = Number(await escrowVault.nextWorkflowId()) - 1;

      const strategy = await escrowVault.getReleaseStrategy(workflowId);
      expect(strategy).to.equal(await releaseStrategy.getAddress());
    });

    it('Should get resolution module', async function () {
      await token1.connect(buyer).approve(await escrowVault.getAddress(), INITIAL_AMOUNT);
      const tx = await escrowVault
        .connect(buyer)
        .createEscrow(await token1.getAddress(), seller.address, INITIAL_AMOUNT);
      await tx.wait();
      const workflowId = Number(await escrowVault.nextWorkflowId()) - 1;

      const module = await escrowVault.getResolutionModule(workflowId);
      expect(module).to.equal(await resolutionModule.getAddress());
    });

    it('Should get yield generation module', async function () {
      await token1.connect(buyer).approve(await escrowVault.getAddress(), INITIAL_AMOUNT);
      const tx = await escrowVault
        .connect(buyer)
        .createEscrow(await token1.getAddress(), seller.address, INITIAL_AMOUNT);
      await tx.wait();
      const workflowId = Number(await escrowVault.nextWorkflowId()) - 1;

      const module = await escrowVault.getYieldGenerationModule(workflowId);
      // May be zero if not set
      expect(module).to.be.a('string');
    });

    it('Should get yield distribution module', async function () {
      await token1.connect(buyer).approve(await escrowVault.getAddress(), INITIAL_AMOUNT);
      const tx = await escrowVault
        .connect(buyer)
        .createEscrow(await token1.getAddress(), seller.address, INITIAL_AMOUNT);
      await tx.wait();
      const workflowId = Number(await escrowVault.nextWorkflowId()) - 1;

      const module = await escrowVault.getYieldDistributionModule(workflowId);
      expect(module).to.equal(await yieldDistributionModule.getAddress());
    });

    it('Should withdraw fees for single token', async function () {
      await token1.connect(buyer).approve(await escrowVault.getAddress(), INITIAL_AMOUNT);
      await escrowVault
        .connect(buyer)
        .createEscrow(await token1.getAddress(), seller.address, INITIAL_AMOUNT);

      const fees = await escrowVault.totalFeesPerToken(await token1.getAddress());
      expect(fees).to.be.gt(0);

      const balanceBefore = await token1.balanceOf(feeAddress.address);
      await escrowVault.connect(feeAddress).withdrawFees(await token1.getAddress());
      const balanceAfter = await token1.balanceOf(feeAddress.address);

      expect(balanceAfter - balanceBefore).to.equal(fees);
    });

    it('Should withdraw fees batch', async function () {
      await token1.connect(buyer).approve(await escrowVault.getAddress(), INITIAL_AMOUNT);
      await token2.connect(buyer).approve(await escrowVault.getAddress(), INITIAL_AMOUNT);
      await escrowVault
        .connect(buyer)
        .createEscrow(await token1.getAddress(), seller.address, INITIAL_AMOUNT);
      await escrowVault
        .connect(buyer)
        .createEscrow(await token2.getAddress(), seller.address, INITIAL_AMOUNT);

      const tokens = [await token1.getAddress(), await token2.getAddress()];
      await escrowVault.connect(feeAddress).withdrawFeesBatch(tokens);

      // Verify fees were withdrawn
      const fees1 = await escrowVault.totalFeesPerToken(await token1.getAddress());
      const fees2 = await escrowVault.totalFeesPerToken(await token2.getAddress());
      expect(fees1).to.equal(0);
      expect(fees2).to.equal(0);
    });

    it('Should get token info', async function () {
      await token1.connect(buyer).approve(await escrowVault.getAddress(), INITIAL_AMOUNT);
      await escrowVault
        .connect(buyer)
        .createEscrow(await token1.getAddress(), seller.address, INITIAL_AMOUNT);

      const [balance, fees] = await escrowVault.getTokenInfo(await token1.getAddress());
      expect(balance).to.be.gt(0);
      expect(fees).to.be.gt(0);
    });

    it('Should recover ERC20', async function () {
      // Send tokens directly to vault
      await token1.transfer(await escrowVault.getAddress(), INITIAL_AMOUNT);

      const balanceBefore = await token1.balanceOf(seller.address);
      await escrowVault
        .connect(timelock)
        .recoverERC20(await token1.getAddress(), seller.address, INITIAL_AMOUNT);
      const balanceAfter = await token1.balanceOf(seller.address);

      expect(balanceAfter - balanceBefore).to.equal(INITIAL_AMOUNT);
    });
  });

  describe('EscrowableERC20 - Specific Functions', function () {
    it('Should create escrow with settings', async function () {
      await escrowableERC20
        .connect(buyer)
        .approve(await escrowableERC20.getAddress(), INITIAL_AMOUNT);
      const settings = {
        customResolver: ethers.ZeroAddress,
        yieldEnabled: false,
        autoReleaseTime: 0,
        autoCancelTime: 0
      };
      const tx = await escrowableERC20
        .connect(buyer)
        [
          'createEscrow(address,uint256,(address,bool,uint256,uint256,uint8))'
        ](seller.address, INITIAL_AMOUNT, settings);
      await tx.wait();
      const workflowId = Number(await escrowableERC20.nextWorkflowId()) - 1;
      // Don't assert specific workflowId as it depends on previous tests
      expect(workflowId).to.be.gte(0);
    });

    it('Should create escrow with auto times', async function () {
      await escrowableERC20
        .connect(buyer)
        .approve(await escrowableERC20.getAddress(), INITIAL_AMOUNT);
      const currentTime = await time.latest();
      const autoReleaseTime = currentTime + 7 * 24 * 60 * 60;
      const autoCancelTime = 0;

      // Use explicit function signature to avoid ambiguity
      const tx = await escrowableERC20
        .connect(buyer)
        [
          'createEscrow(address,uint256,uint256,uint256)'
        ](seller.address, INITIAL_AMOUNT, autoReleaseTime, autoCancelTime);
      await tx.wait();
      const workflowId = Number(await escrowableERC20.nextWorkflowId()) - 1;
      expect(workflowId).to.equal(0);
    });

    it('Should get release strategy', async function () {
      await escrowableERC20
        .connect(buyer)
        .approve(await escrowableERC20.getAddress(), INITIAL_AMOUNT);
      const tx = await escrowableERC20.connect(buyer).createEscrow(seller.address, INITIAL_AMOUNT);
      await tx.wait();
      const workflowId = Number(await escrowableERC20.nextWorkflowId()) - 1;

      const strategy = await escrowableERC20.getReleaseStrategy(workflowId);
      expect(strategy).to.equal(await releaseStrategy.getAddress());
    });

    it('Should get resolution module', async function () {
      await escrowableERC20
        .connect(buyer)
        .approve(await escrowableERC20.getAddress(), INITIAL_AMOUNT);
      const tx = await escrowableERC20.connect(buyer).createEscrow(seller.address, INITIAL_AMOUNT);
      await tx.wait();
      const workflowId = Number(await escrowableERC20.nextWorkflowId()) - 1;

      const module = await escrowableERC20.getResolutionModule(workflowId);
      expect(module).to.equal(await resolutionModule.getAddress());
    });

    it('Should get yield generation module', async function () {
      await escrowableERC20
        .connect(buyer)
        .approve(await escrowableERC20.getAddress(), INITIAL_AMOUNT);
      const tx = await escrowableERC20.connect(buyer).createEscrow(seller.address, INITIAL_AMOUNT);
      await tx.wait();
      const workflowId = Number(await escrowableERC20.nextWorkflowId()) - 1;

      const module = await escrowableERC20.getYieldGenerationModule(workflowId);
      expect(module).to.be.a('string');
    });

    it('Should get yield distribution module', async function () {
      await escrowableERC20
        .connect(buyer)
        .approve(await escrowableERC20.getAddress(), INITIAL_AMOUNT);
      const tx = await escrowableERC20.connect(buyer).createEscrow(seller.address, INITIAL_AMOUNT);
      await tx.wait();
      const workflowId = Number(await escrowableERC20.nextWorkflowId()) - 1;

      const module = await escrowableERC20.getYieldDistributionModule(workflowId);
      expect(module).to.equal(await yieldDistributionModule.getAddress());
    });

    it('Should withdraw fees', async function () {
      await escrowableERC20
        .connect(buyer)
        .approve(await escrowableERC20.getAddress(), INITIAL_AMOUNT);
      await escrowableERC20.connect(buyer).createEscrow(seller.address, INITIAL_AMOUNT);

      const fees = await escrowableERC20.totalFeesPerToken(await escrowableERC20.getAddress());
      expect(fees).to.be.gt(0);

      const balanceBefore = await escrowableERC20.balanceOf(feeAddress.address);
      await escrowableERC20.connect(feeAddress).withdrawFees(await escrowableERC20.getAddress());
      const balanceAfter = await escrowableERC20.balanceOf(feeAddress.address);

      expect(balanceAfter - balanceBefore).to.equal(fees);
    });

    it('Should get total held in escrow', async function () {
      await escrowableERC20
        .connect(buyer)
        .approve(await escrowableERC20.getAddress(), INITIAL_AMOUNT);
      await escrowableERC20.connect(buyer).createEscrow(seller.address, INITIAL_AMOUNT);

      const held = await escrowableERC20.totalHeldInEscrow();
      expect(held).to.be.gt(0);
    });
  });

  describe('DefaultResolutionModule - Coverage', function () {
    it('Should get dispute resolver', async function () {
      await token1.connect(buyer).approve(await escrowVault.getAddress(), INITIAL_AMOUNT);
      const tx = await escrowVault
        .connect(buyer)
        .createEscrow(await token1.getAddress(), seller.address, INITIAL_AMOUNT);
      await tx.wait();
      const workflowId = Number(await escrowVault.nextWorkflowId()) - 1;

      const escrowData = ethers.AbiCoder.defaultAbiCoder().encode(
        ['address', 'address', 'address', 'uint256', 'uint256'],
        [await token1.getAddress(), buyer.address, seller.address, INITIAL_AMOUNT, INITIAL_AMOUNT],
      );

      const [resolverAddress, escalationLevel] = await resolutionModule.getDisputeResolver(
        workflowId,
        escrowData,
      );
      expect(resolverAddress).to.equal(resolver.address);
      expect(escalationLevel).to.equal(0);
    });

    it('Should check if address is authorized dispute resolver', async function () {
      await token1.connect(buyer).approve(await escrowVault.getAddress(), INITIAL_AMOUNT);
      const tx = await escrowVault
        .connect(buyer)
        .createEscrow(await token1.getAddress(), seller.address, INITIAL_AMOUNT);
      await tx.wait();
      const workflowId = Number(await escrowVault.nextWorkflowId()) - 1;

      const escrowData = ethers.AbiCoder.defaultAbiCoder().encode(
        ['address', 'address', 'address', 'uint256', 'uint256'],
        [await token1.getAddress(), buyer.address, seller.address, INITIAL_AMOUNT, INITIAL_AMOUNT],
      );

      const [authorized, role] = await resolutionModule.isAuthorizedDisputeResolver(
        workflowId,
        resolver.address,
        escrowData,
      );
      expect(authorized).to.be.true;
      expect(role).to.equal(0);

      const [notAuthorized] = await resolutionModule.isAuthorizedDisputeResolver(
        workflowId,
        buyer.address,
        escrowData,
      );
      expect(notAuthorized).to.be.false;
    });

    it('Should check if can escalate', async function () {
      await token1.connect(buyer).approve(await escrowVault.getAddress(), INITIAL_AMOUNT);
      const tx = await escrowVault
        .connect(buyer)
        .createEscrow(await token1.getAddress(), seller.address, INITIAL_AMOUNT);
      await tx.wait();
      const workflowId = Number(await escrowVault.nextWorkflowId()) - 1;

      const escrowData = ethers.AbiCoder.defaultAbiCoder().encode(
        ['address', 'address', 'address', 'uint256', 'uint256'],
        [await token1.getAddress(), buyer.address, seller.address, INITIAL_AMOUNT, INITIAL_AMOUNT],
      );

      const [canEscalate, nextResolver, fee] = await resolutionModule.canEscalate(
        workflowId,
        0,
        escrowData,
      );
      expect(canEscalate).to.be.false; // DefaultResolutionModule doesn't support escalation
      expect(nextResolver).to.equal(ethers.ZeroAddress);
      expect(fee).to.equal(0);
    });

    it('Should execute escalation (returns false for DefaultResolutionModule)', async function () {
      await token1.connect(buyer).approve(await escrowVault.getAddress(), INITIAL_AMOUNT);
      const tx = await escrowVault
        .connect(buyer)
        .createEscrow(await token1.getAddress(), seller.address, INITIAL_AMOUNT);
      await tx.wait();
      const workflowId = Number(await escrowVault.nextWorkflowId()) - 1;

      const escrowData = ethers.AbiCoder.defaultAbiCoder().encode(
        ['address', 'address', 'address', 'uint256', 'uint256'],
        [await token1.getAddress(), buyer.address, seller.address, INITIAL_AMOUNT, INITIAL_AMOUNT],
      );

      const [success, newResolver, newLevel] = await resolutionModule.executeEscalation(
        workflowId,
        escrowData,
      );
      expect(success).to.be.false; // DefaultResolutionModule doesn't support escalation
      expect(newResolver).to.equal(ethers.ZeroAddress);
      expect(newLevel).to.equal(0);
    });

    it('Should get module name', async function () {
      const name = await resolutionModule.moduleName();
      expect(name).to.equal('DefaultSingleResolver');
    });

    it('Should get module version', async function () {
      const version = await resolutionModule.moduleVersion();
      expect(version).to.equal('1.0.0');
    });

    it('Should set resolver', async function () {
      const ROLE_TIMELOCK = await resolutionModule.ROLE_TIMELOCK();
      await resolutionModule.grantRole(ROLE_TIMELOCK, owner.address);

      const newResolver = ethers.Wallet.createRandom().address;
      await resolutionModule.connect(owner).setResolver(newResolver);
      expect(await resolutionModule.resolver()).to.equal(newResolver);
    });

    it('Should support IERC165 interface', async function () {
      const IERC165_ID = '0x01ffc9a7';
      expect(await resolutionModule.supportsInterface(IERC165_ID)).to.be.true;
    });
  });
});
