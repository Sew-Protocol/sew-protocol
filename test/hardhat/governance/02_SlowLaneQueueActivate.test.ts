before(function () {
  this.skip();
}); // Migrated to Forge: test/foundry/migrated/02_SlowLaneQueueActivate.test.t.sol
/**
 * Slow Lane Queue/Activate Tests
 *
 * Tests for the slow lane governance pattern (7-day delay):
 * - Queue functions (queueEscrowFee, queueEscrowFeeAddress)
 * - ETA enforcement (7-day delay)
 * - Activate functions after ETA
 * - Revert on early activation
 * - Pending state queries
 *
 * Note: queueDao/activateDao tests are skipped - DAO address is now unchangeable
 */

import { expect } from 'chai';
import { ethers } from 'hardhat';
import { time } from '@nomicfoundation/hardhat-network-helpers';
import { EscrowableERC20, EscrowVault } from '../../typechain-types';

describe('Slow Lane Queue/Activate', function () {
  let escrowableERC20: EscrowableERC20;
  let escrowVault: EscrowVault;
  let deployer: any;
  let timelock: any;
  let unauthorized: any;
  let feeAddress: any;
  let newFeeAddress: any;

  const ESCROW_FEE = 100; // 1%
  const ESCROW_FEE_DENOMINATOR = 10000;
  const SLOW_DELAY = 7 * 24 * 60 * 60; // 7 days

  beforeEach(async function () {
    [deployer, timelock, unauthorized, feeAddress, newFeeAddress] = await ethers.getSigners();

    // Deploy contracts
    const EscrowableERC20Factory = await ethers.getContractFactory('EscrowableERC20');
    escrowableERC20 = await EscrowableERC20Factory.deploy(
      'Test Token',
      'TEST',
      ESCROW_FEE,
      feeAddress.address,
      ethers.ZeroAddress,
      ethers.ZeroAddress,
    );
    await escrowableERC20.waitForDeployment();

    const EscrowVaultFactory = await ethers.getContractFactory('EscrowVault');
    escrowVault = await EscrowVaultFactory.deploy(
      ESCROW_FEE,
      feeAddress.address,
      ethers.ZeroAddress,
      ethers.ZeroAddress,
    );
    await escrowVault.waitForDeployment();

    // Grant ROLE_TIMELOCK to timelock
    const ROLE_TIMELOCK = await escrowableERC20.ROLE_TIMELOCK();
    await escrowableERC20.grantRole(ROLE_TIMELOCK, timelock.address);
    await escrowVault.grantRole(ROLE_TIMELOCK, timelock.address);
  });

  describe('Queue Escrow Fee Address', function () {
    it('Should queue new fee address', async function () {
      await escrowableERC20.connect(timelock).queueEscrowFeeAddress(newFeeAddress.address);

      const [value, eta, exists] = await escrowableERC20.getPendingFeeRecipient();
      expect(value).to.equal(newFeeAddress.address);
      expect(exists).to.be.true;
      expect(eta).to.be.greaterThan(await time.latest());
    });

    it('Should revert on zero address', async function () {
      await expect(
        escrowableERC20.connect(timelock).queueEscrowFeeAddress(ethers.ZeroAddress),
      ).to.be.revertedWithCustomError(escrowableERC20, 'InvalidAddressKey');
    });

    it('Should revert if not timelock', async function () {
      await expect(
        escrowableERC20.connect(unauthorized).queueEscrowFeeAddress(newFeeAddress.address),
      ).to.be.revertedWithCustomError(escrowableERC20, 'AccessControlUnauthorizedAccount');
    });

    it('Should emit EscrowFeeAddressQueued event', async function () {
      const currentFeeAddress = await escrowableERC20.escrowFeeAddress();
      await expect(escrowableERC20.connect(timelock).queueEscrowFeeAddress(newFeeAddress.address))
        .to.emit(escrowableERC20, 'EscrowFeeAddressQueued')
        .withArgs(currentFeeAddress, newFeeAddress.address, (eta: bigint) => eta > 0n);
    });
  });

  describe('Activate Escrow Fee Address', function () {
    beforeEach(async function () {
      await escrowableERC20.connect(timelock).queueEscrowFeeAddress(newFeeAddress.address);
    });

    it('Should revert if activated before ETA', async function () {
      await expect(
        escrowableERC20.connect(timelock).activateEscrowFeeAddress(),
      ).to.be.revertedWithCustomError(escrowableERC20, 'NotReady');
    });

    it('Should activate after ETA', async function () {
      const [, eta] = await escrowableERC20.getPendingFeeRecipient();
      await time.increaseTo(Number(eta) + 1);

      const oldAddress = await escrowableERC20.escrowFeeAddress();
      await escrowableERC20.connect(timelock).activateEscrowFeeAddress();

      const newAddress = await escrowableERC20.escrowFeeAddress();
      expect(newAddress).to.equal(newFeeAddress.address);
      expect(newAddress).to.not.equal(oldAddress);
    });

    it('Should clear pending state after activation', async function () {
      const [, eta] = await escrowableERC20.getPendingFeeRecipient();
      await time.increaseTo(Number(eta) + 1);

      await escrowableERC20.connect(timelock).activateEscrowFeeAddress();

      const [, , exists] = await escrowableERC20.getPendingFeeRecipient();
      expect(exists).to.be.false;
    });

    it('Should emit EscrowFeeAddressActivated event', async function () {
      const oldAddress = await escrowableERC20.escrowFeeAddress();
      const [, eta] = await escrowableERC20.getPendingFeeRecipient();
      await time.increaseTo(Number(eta) + 1);

      await expect(escrowableERC20.connect(timelock).activateEscrowFeeAddress())
        .to.emit(escrowableERC20, 'EscrowFeeAddressActivated')
        .withArgs(oldAddress, newFeeAddress.address);
    });
  });

  describe('Queue Escrow Fee', function () {
    it('Should queue new fee', async function () {
      const newFee = 150; // 1.5%
      await escrowableERC20.connect(timelock).queueEscrowFee(newFee);

      const [value, eta, exists] = await escrowableERC20.getPendingEscrowFee();
      expect(value).to.equal(newFee);
      expect(exists).to.be.true;
      expect(eta).to.be.greaterThan(await time.latest());
    });

    it('Should revert if fee exceeds max (200 bps)', async function () {
      const newFee = 201; // Exceeds max
      await expect(
        escrowableERC20.connect(timelock).queueEscrowFee(newFee),
      ).to.be.revertedWithCustomError(escrowableERC20, 'OutOfBounds');
    });

    it('Should allow fee of 0', async function () {
      await escrowableERC20.connect(timelock).queueEscrowFee(0);
      const [value] = await escrowableERC20.getPendingEscrowFee();
      expect(value).to.equal(0);
    });

    it('Should allow max fee (200 bps)', async function () {
      const maxFee = 200;
      await escrowableERC20.connect(timelock).queueEscrowFee(maxFee);
      const [value] = await escrowableERC20.getPendingEscrowFee();
      expect(value).to.equal(maxFee);
    });
  });

  describe('Activate Escrow Fee', function () {
    beforeEach(async function () {
      await escrowableERC20.connect(timelock).queueEscrowFee(150);
    });

    it('Should revert if activated before ETA', async function () {
      await expect(
        escrowableERC20.connect(timelock).activateEscrowFee(),
      ).to.be.revertedWithCustomError(escrowableERC20, 'NotReady');
    });

    it('Should activate after ETA', async function () {
      const [, eta] = await escrowableERC20.getPendingEscrowFee();
      await time.increaseTo(Number(eta) + 1);

      const oldFee = await escrowableERC20.escrowFee();
      await escrowableERC20.connect(timelock).activateEscrowFee();

      const newFee = await escrowableERC20.escrowFee();
      expect(newFee).to.equal(150);
      expect(newFee).to.not.equal(oldFee);
    });
  });

  describe.skip('Queue DAO Address', function () {
    // Skipped: DAO address is now unchangeable (set in constructor only)
    it('Should queue new DAO address', async function () {
      await escrowableERC20.connect(timelock).queueDao(newFeeAddress.address);

      const [value, eta, exists] = await escrowableERC20.getPendingDao();
      expect(value).to.equal(newFeeAddress.address);
      expect(exists).to.be.true;
    });

    it('Should revert on zero address', async function () {
      await expect(
        escrowableERC20.connect(timelock).queueDao(ethers.ZeroAddress),
      ).to.be.revertedWithCustomError(escrowableERC20, 'InvalidValue');
    });
  });

  describe.skip('Activate DAO Address', function () {
    // Skipped: DAO address is now unchangeable (set in constructor only)
    beforeEach(async function () {
      await escrowableERC20.connect(timelock).queueDao(newFeeAddress.address);
    });

    it('Should revert if activated before ETA', async function () {
      await expect(escrowableERC20.connect(timelock).activateDao()).to.be.revertedWithCustomError(
        escrowableERC20,
        'NotReady',
      );
    });

    it('Should activate after ETA', async function () {
      const [, eta] = await escrowableERC20.getPendingDao();
      await time.increaseTo(Number(eta) + 1);

      await escrowableERC20.connect(timelock).activateDao();

      const dao = await escrowableERC20.dao();
      expect(dao).to.equal(newFeeAddress.address);
    });
  });

  describe('EscrowVault Slow Lane', function () {
    it('Should have same slow lane functions', async function () {
      await escrowVault.connect(timelock).queueEscrowFeeAddress(newFeeAddress.address);
      const [value] = await escrowVault.getPendingFeeRecipient();
      expect(value).to.equal(newFeeAddress.address);
    });
  });
});
