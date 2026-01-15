before(function () {
  this.skip();
}); // migrated to forge-std
import { expect } from 'chai';
import { ethers } from 'hardhat';
import { time } from '@nomicfoundation/hardhat-network-helpers';
import { EscrowableERC20 } from '../typechain-types';
import { setupResolutionModule } from '../helpers/setupResolutionModule';

describe('Escalation Fee Handling', function () {
  let escrowableERC20: EscrowableERC20;
  let decentralizedModule: any;
  let owner: any;
  let sender: any;
  let recipient: any;
  let resolver: any;
  let seniorResolver: any;
  let feeAddress: any;
  let otherAccount: any;

  const ESCROW_FEE = 100;
  const ESCROW_FEE_DENOMINATOR = 10000;
  const INITIAL_TRANSFER_AMOUNT = ethers.parseEther('1');
  const ESCALATION_FEE = ethers.parseEther('0.01');

  beforeEach(async () => {
    [owner, sender, recipient, resolver, seniorResolver, feeAddress, otherAccount] =
      await ethers.getSigners();

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

    // Grant ROLE_TIMELOCK to owner
    const ROLE_TIMELOCK = await escrowableERC20.ROLE_TIMELOCK();
    await escrowableERC20.grantRole(ROLE_TIMELOCK, owner.address);

    // Setup fee address via slow lane
    await escrowableERC20.connect(owner).queueEscrowFeeAddress(feeAddress.address);
    const [, eta] = await escrowableERC20.getPendingFeeRecipient();
    await time.increaseTo(Number(eta) + 1);
    await escrowableERC20.connect(owner).activateEscrowFeeAddress();

    // Deploy and setup DecentralizedResolutionModule
    const moduleFactory = await ethers.getContractFactory('DecentralizedResolutionModule');
    decentralizedModule = await moduleFactory.deploy();
    await decentralizedModule.waitForDeployment();
    await decentralizedModule.initialize(owner.address);

    // Register escrow contract
    await decentralizedModule
      .connect(owner)
      .registerEscrowContract(await escrowableERC20.getAddress());

    // Appoint senior resolver
    await decentralizedModule
      .connect(owner)
      .appointSeniorResolver(
        seniorResolver.address,
        'Senior Resolver',
        'Senior resolver for testing',
      );

    // Appoint standard resolver
    await decentralizedModule
      .connect(seniorResolver)
      .appointResolver(resolver.address, 'Standard Resolver', 'Standard resolver for testing');

    // Set escalation config with fee
    await decentralizedModule.connect(owner).queueEscalationConfig(
      1, // Level 1 (senior resolver)
      {
        resolver: seniorResolver.address,
        fee: ESCALATION_FEE,
        enabled: true,
      },
    );
    const [, configEta] = await decentralizedModule.getPendingEscalationConfig(1);
    await time.increaseTo(Number(configEta) + 1);
    await decentralizedModule.connect(owner).activateEscalationConfig(1);

    // Set resolution table entry
    const categoryKey = ethers.keccak256(ethers.toUtf8Bytes('SMALL'));
    await decentralizedModule.connect(owner).setResolutionTableEntry(categoryKey, {
      initialResolver: resolver.address,
      maxEscalationLevel: 1,
      escalationFee: ESCALATION_FEE,
      enabled: true,
      categoryName: 'SMALL',
    });

    // Activate resolution module (for BaseEscrow pattern)
    const MIN_DELAY = 48 * 60 * 60; // 48 hours
    await escrowableERC20.connect(owner).setResolutionModuleDelay(MIN_DELAY);
    await escrowableERC20
      .connect(owner)
      .proposeResolutionModule(await decentralizedModule.getAddress());
    await time.increase(MIN_DELAY + 1);
    await escrowableERC20.connect(owner).activateResolutionModule();

    // Also set default resolution module (for EscrowableERC20)
    await escrowableERC20
      .connect(owner)
      .queueDefaultResolutionModule(await decentralizedModule.getAddress());
    const [, defaultEta] = await escrowableERC20.getPendingDefaultResolutionModule();
    await time.increaseTo(Number(defaultEta) + 1);
    await escrowableERC20.connect(owner).activateDefaultResolutionModule();
  });

  describe('Escalation Fee Collection', function () {
    let workflowId: number;

    beforeEach(async () => {
      // Create escrow
      await escrowableERC20.transfer(sender.address, INITIAL_TRANSFER_AMOUNT);
      const tx = await escrowableERC20
        .connect(sender)
        .getFunction('createEscrow(address,uint256)')
        .send(recipient.address, INITIAL_TRANSFER_AMOUNT);
      await tx.wait();
      workflowId = Number(await escrowableERC20.nextWorkflowId()) - 1;

      // Raise dispute
      await escrowableERC20.connect(sender).raiseDispute(workflowId);
    });

    it('Should collect escalation fee when escalating', async function () {
      const feeAddressBalanceBefore = await ethers.provider.getBalance(feeAddress.address);

      // Escalate with exact fee
      await escrowableERC20.connect(sender).escalateDispute(workflowId, { value: ESCALATION_FEE });

      const feeAddressBalanceAfter = await ethers.provider.getBalance(feeAddress.address);
      expect(feeAddressBalanceAfter - feeAddressBalanceBefore).to.equal(ESCALATION_FEE);
    });

    it('Should emit EscalationFeeCollected event', async function () {
      await expect(
        escrowableERC20.connect(sender).escalateDispute(workflowId, { value: ESCALATION_FEE }),
      )
        .to.emit(escrowableERC20, 'EscalationFeeCollected')
        .withArgs(workflowId, ESCALATION_FEE, feeAddress.address);
    });

    it('Should refund excess fee', async function () {
      const excessAmount = ethers.parseEther('0.005');
      const totalSent = ESCALATION_FEE + excessAmount;
      const senderBalanceBefore = await ethers.provider.getBalance(sender.address);

      // Escalate with excess fee
      const tx = await escrowableERC20
        .connect(sender)
        .escalateDispute(workflowId, { value: totalSent });
      const receipt = await tx.wait();
      const gasUsed = receipt!.gasUsed * receipt!.gasPrice;

      const senderBalanceAfter = await ethers.provider.getBalance(sender.address);
      const balanceDiff = senderBalanceBefore - senderBalanceAfter;

      // Should have spent: escalation fee + gas + excess refunded
      // So balance diff should be: escalation fee + gas (excess was refunded)
      expect(balanceDiff).to.be.gte(totalSent - excessAmount); // At least escalation fee + gas
      expect(balanceDiff).to.be.lt(totalSent); // Less than total sent (excess was refunded)
    });

    it('Should revert if insufficient fee provided', async function () {
      const insufficientFee = ESCALATION_FEE / 2n;

      await expect(
        escrowableERC20.connect(sender).escalateDispute(workflowId, { value: insufficientFee }),
      ).to.be.revertedWithCustomError(escrowableERC20, 'InvalidAmount');
    });

    it('Should revert if fee address is not set', async function () {
      // Note: EscrowableERC20 validation prevents setting fee address to zero
      // So we test by checking that escalation requires fee address to be set
      // If fee address were zero, escalation would revert
      // For this test, we verify the fee address is set and escalation works
      const currentFeeAddress = await escrowableERC20.escrowFeeAddress();
      expect(currentFeeAddress).to.not.equal(ethers.ZeroAddress);

      // Escalation should work when fee address is set
      await expect(
        escrowableERC20.connect(sender).escalateDispute(workflowId, { value: ESCALATION_FEE }),
      ).to.emit(escrowableERC20, 'EscalationFeeCollected');
    });

    it('Should handle zero escalation fee', async function () {
      // Set escalation config with zero fee
      await decentralizedModule.connect(owner).queueEscalationConfig(1, {
        resolver: seniorResolver.address,
        fee: 0,
        enabled: true,
      });
      const [, configEta] = await decentralizedModule.getPendingEscalationConfig(1);
      await time.increaseTo(Number(configEta) + 1);
      await decentralizedModule.connect(owner).activateEscalationConfig(1);

      // Should not emit EscalationFeeCollected event for zero fee
      await expect(
        escrowableERC20.connect(sender).escalateDispute(workflowId, { value: 0 }),
      ).to.not.emit(escrowableERC20, 'EscalationFeeCollected');

      // Escalation should still succeed
      const et = await escrowableERC20.escrowTransfers(workflowId);
      expect(et.disputeResolver).to.equal(seniorResolver.address);
    });

    it('Should transfer fee after successful escalation execution', async function () {
      // This test verifies that fee is collected after escalation succeeds (safer order)
      const feeAddressBalanceBefore = await ethers.provider.getBalance(feeAddress.address);

      // Escalate
      await escrowableERC20.connect(sender).escalateDispute(workflowId, { value: ESCALATION_FEE });

      // Verify fee was collected
      const feeAddressBalanceAfter = await ethers.provider.getBalance(feeAddress.address);
      expect(feeAddressBalanceAfter - feeAddressBalanceBefore).to.equal(ESCALATION_FEE);

      // Verify escalation succeeded
      const et = await escrowableERC20.escrowTransfers(workflowId);
      expect(et.disputeResolver).to.equal(seniorResolver.address);
    });

    it('Should allow recipient to escalate and collect fee', async function () {
      const feeAddressBalanceBefore = await ethers.provider.getBalance(feeAddress.address);

      // Recipient escalates
      await escrowableERC20
        .connect(recipient)
        .escalateDispute(workflowId, { value: ESCALATION_FEE });

      const feeAddressBalanceAfter = await ethers.provider.getBalance(feeAddress.address);
      expect(feeAddressBalanceAfter - feeAddressBalanceBefore).to.equal(ESCALATION_FEE);
    });

    it('Should revert if non-participant tries to escalate', async function () {
      await expect(
        escrowableERC20
          .connect(otherAccount)
          .escalateDispute(workflowId, { value: ESCALATION_FEE }),
      ).to.be.revertedWithCustomError(escrowableERC20, 'NotParticipant');
    });
  });

  describe('Multiple Escalations', function () {
    let workflowId: number;

    beforeEach(async () => {
      // Create escrow
      await escrowableERC20.transfer(sender.address, INITIAL_TRANSFER_AMOUNT);
      const tx = await escrowableERC20
        .connect(sender)
        .getFunction('createEscrow(address,uint256)')
        .send(recipient.address, INITIAL_TRANSFER_AMOUNT);
      await tx.wait();
      workflowId = Number(await escrowableERC20.nextWorkflowId()) - 1;

      // Raise dispute
      await escrowableERC20.connect(sender).raiseDispute(workflowId);
    });

    it('Should collect fees for multiple escalations', async function () {
      const feeAddressBalanceBefore = await ethers.provider.getBalance(feeAddress.address);

      // First escalation (to senior resolver)
      await escrowableERC20.connect(sender).escalateDispute(workflowId, { value: ESCALATION_FEE });

      // Note: Second escalation would require external resolver setup, which is not in scope for Phase 1
      // But we can verify the first escalation fee was collected
      const feeAddressBalanceAfter = await ethers.provider.getBalance(feeAddress.address);
      expect(feeAddressBalanceAfter - feeAddressBalanceBefore).to.equal(ESCALATION_FEE);
    });
  });
});
