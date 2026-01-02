/**
 * Bounds Enforcement Tests
 * 
 * Tests for on-chain bounds validation:
 * - Auto cancel/release time bounds (0-30 days)
 * - Max attachments bounds (0-20)
 * - Fee bps bounds (0-200)
 * - Resolution delay bounds (48h-30 days)
 * - Yield distribution validation (1-10 recipients, sum=10000)
 * - Out-of-bounds reverts with clear errors
 */

import { expect } from "chai";
import { ethers } from "hardhat";
import { time } from "@nomicfoundation/hardhat-network-helpers";
import { 
  EscrowableERC20,
  EscrowVault
} from "../../typechain-types";

describe("Bounds Enforcement", function () {
  let escrowableERC20: EscrowableERC20;
  let escrowVault: EscrowVault;
  let deployer: any;
  let timelock: any;
  let feeAddress: any;

  const ESCROW_FEE = 100; // 1%
  const ESCROW_FEE_DENOMINATOR = 10000;

  // Bounds constants
  const MAX_AUTO_TIME_DAYS = 30 * 24 * 60 * 60; // 30 days
  const MAX_ATTACHMENTS = 20;
  const MAX_FEE_BPS = 200; // 2%
  const MIN_RESOLUTION_DELAY = 48 * 60 * 60; // 48 hours
  const MAX_RESOLUTION_DELAY = 30 * 24 * 60 * 60; // 30 days
  const MIN_YIELD_RECIPIENTS = 1;
  const MAX_YIELD_RECIPIENTS = 10;
  const BPS_DENOMINATOR = 10000;

  beforeEach(async function () {
    [deployer, timelock, feeAddress] = await ethers.getSigners();

    // Deploy contracts
    const EscrowableERC20Factory = await ethers.getContractFactory("EscrowableERC20");
    escrowableERC20 = await EscrowableERC20Factory.deploy(
      "Test Token",
      "TEST",
      ESCROW_FEE,
      feeAddress.address
    );
    await escrowableERC20.waitForDeployment();

    const EscrowVaultFactory = await ethers.getContractFactory("EscrowVault");
    escrowVault = await EscrowVaultFactory.deploy(
      ESCROW_FEE,
      feeAddress.address
    );
    await escrowVault.waitForDeployment();

    // Grant ROLE_TIMELOCK to timelock
    const ROLE_TIMELOCK = await escrowableERC20.ROLE_TIMELOCK();
    await escrowableERC20.grantRole(ROLE_TIMELOCK, timelock.address);
    await escrowVault.grantRole(ROLE_TIMELOCK, timelock.address);
  });

  describe("Auto Cancel Time Bounds", function () {
    it("Should accept 0 (disabled)", async function () {
      await escrowableERC20.connect(timelock).setDefaultAutoCancelTime(0);
      const time = await escrowableERC20.defaultAutoCancelTime();
      expect(time).to.equal(0);
    });

    it("Should accept max value (30 days)", async function () {
      const currentTime = await time.latest();
      const maxTime = BigInt(currentTime) + BigInt(MAX_AUTO_TIME_DAYS);
      await escrowableERC20.connect(timelock).setDefaultAutoCancelTime(maxTime);
      const result = await escrowableERC20.defaultAutoCancelTime();
      expect(result).to.equal(maxTime);
    });

    it("Should accept value within bounds", async function () {
      const currentTime = await time.latest();
      const validTime = BigInt(currentTime) + BigInt(7 * 24 * 60 * 60); // 7 days in the future
      await escrowableERC20.connect(timelock).setDefaultAutoCancelTime(validTime);
      const result = await escrowableERC20.defaultAutoCancelTime();
      expect(result).to.equal(validTime);
    });

    it("Should revert if exceeds 30 days", async function () {
      const currentTime = await time.latest();
      const invalidTime = BigInt(currentTime) + BigInt(MAX_AUTO_TIME_DAYS) + 1n;
      await expect(
        escrowableERC20.connect(timelock).setDefaultAutoCancelTime(invalidTime)
      ).to.be.revertedWithCustomError(escrowableERC20, "OutOfBounds");
    });
  });

  describe("Auto Release Time Bounds", function () {
    it("Should accept 0 (disabled)", async function () {
      await escrowableERC20.connect(timelock).setDefaultAutoReleaseTime(0);
      const time = await escrowableERC20.defaultAutoReleaseTime();
      expect(time).to.equal(0);
    });

    it("Should accept max value (30 days)", async function () {
      const currentTime = await time.latest();
      const maxTime = BigInt(currentTime) + BigInt(MAX_AUTO_TIME_DAYS);
      await escrowableERC20.connect(timelock).setDefaultAutoReleaseTime(maxTime);
      const result = await escrowableERC20.defaultAutoReleaseTime();
      expect(result).to.equal(maxTime);
    });

    it("Should revert if exceeds 30 days", async function () {
      const currentTime = await time.latest();
      const invalidTime = BigInt(currentTime) + BigInt(MAX_AUTO_TIME_DAYS) + 1n;
      await expect(
        escrowableERC20.connect(timelock).setDefaultAutoReleaseTime(invalidTime)
      ).to.be.revertedWithCustomError(escrowableERC20, "OutOfBounds");
    });
  });

  describe("Max Attachments Bounds", function () {
    it("Should accept 0", async function () {
      await escrowableERC20.connect(timelock).setMaxAttachments(0);
      const max = await escrowableERC20.maxAttachments();
      expect(max).to.equal(0);
    });

    it("Should accept max value (20)", async function () {
      await escrowableERC20.connect(timelock).setMaxAttachments(MAX_ATTACHMENTS);
      const max = await escrowableERC20.maxAttachments();
      expect(max).to.equal(MAX_ATTACHMENTS);
    });

    it("Should accept value within bounds", async function () {
      const validMax = 10;
      await escrowableERC20.connect(timelock).setMaxAttachments(validMax);
      const max = await escrowableERC20.maxAttachments();
      expect(max).to.equal(validMax);
    });

    it("Should revert if exceeds 20", async function () {
      const invalidMax = MAX_ATTACHMENTS + 1;
      await expect(
        escrowableERC20.connect(timelock).setMaxAttachments(invalidMax)
      ).to.be.revertedWithCustomError(escrowableERC20, "OutOfBounds");
    });
  });

  describe("Fee BPS Bounds", function () {
    it("Should accept 0", async function () {
      await escrowableERC20.connect(timelock).queueEscrowFee(0);
      const [value] = await escrowableERC20.getPendingEscrowFee();
      expect(value).to.equal(0);
    });

    it("Should accept max value (200 bps = 2%)", async function () {
      await escrowableERC20.connect(timelock).queueEscrowFee(MAX_FEE_BPS);
      const [value] = await escrowableERC20.getPendingEscrowFee();
      expect(value).to.equal(MAX_FEE_BPS);
    });

    it("Should accept value within bounds", async function () {
      const validFee = 150; // 1.5%
      await escrowableERC20.connect(timelock).queueEscrowFee(validFee);
      const [value] = await escrowableERC20.getPendingEscrowFee();
      expect(value).to.equal(validFee);
    });

    it("Should revert if exceeds 200 bps", async function () {
      const invalidFee = MAX_FEE_BPS + 1;
      await expect(
        escrowableERC20.connect(timelock).queueEscrowFee(invalidFee)
      ).to.be.revertedWithCustomError(escrowableERC20, "OutOfBounds");
    });
  });

  describe("Resolution Delay Bounds", function () {
    it("Should accept min value (48 hours)", async function () {
      await escrowableERC20.connect(timelock).setResolutionModuleDelay(MIN_RESOLUTION_DELAY);
      const delay = await escrowableERC20.resolutionModuleDelay();
      expect(delay).to.equal(MIN_RESOLUTION_DELAY);
    });

    it("Should accept max value (30 days)", async function () {
      await escrowableERC20.connect(timelock).setResolutionModuleDelay(MAX_RESOLUTION_DELAY);
      const delay = await escrowableERC20.resolutionModuleDelay();
      expect(delay).to.equal(MAX_RESOLUTION_DELAY);
    });

    it("Should accept value within bounds", async function () {
      const validDelay = 7 * 24 * 60 * 60; // 7 days
      await escrowableERC20.connect(timelock).setResolutionModuleDelay(validDelay);
      const delay = await escrowableERC20.resolutionModuleDelay();
      expect(delay).to.equal(validDelay);
    });

    it("Should revert if below 48 hours", async function () {
      const invalidDelay = MIN_RESOLUTION_DELAY - 1;
      await expect(
        escrowableERC20.connect(timelock).setResolutionModuleDelay(invalidDelay)
      ).to.be.revertedWithCustomError(escrowableERC20, "OutOfBounds");
    });

    it("Should revert if exceeds 30 days", async function () {
      const invalidDelay = MAX_RESOLUTION_DELAY + 1;
      await expect(
        escrowableERC20.connect(timelock).setResolutionModuleDelay(invalidDelay)
      ).to.be.revertedWithCustomError(escrowableERC20, "OutOfBounds");
    });
  });

  describe("Yield Distribution Validation", function () {
    let recipient1: any;
    let recipient2: any;
    let recipient3: any;
    let recipient4: any;
    let recipient5: any;
    let recipient6: any;
    let recipient7: any;
    let recipient8: any;
    let recipient9: any;
    let recipient10: any;
    let recipient11: any;

    beforeEach(async function () {
      [
        , , , , , ,
        recipient1, recipient2, recipient3, recipient4, recipient5,
        recipient6, recipient7, recipient8, recipient9, recipient10, recipient11
      ] = await ethers.getSigners();
    });

    it("Should accept 1 recipient with 100%", async function () {
      const recipients = [recipient1.address];
      const percentages = [BPS_DENOMINATOR];
      
      await escrowableERC20.connect(timelock).setDefaultYieldDistribution(recipients, percentages);
      const distribution = await escrowableERC20.defaultYieldDistribution();
      expect(distribution.recipients.length).to.equal(1);
      expect(distribution.isSet).to.be.true;
    });

    it("Should accept max recipients (10)", async function () {
      const recipients = [
        recipient1.address, recipient2.address, recipient3.address, recipient4.address,
        recipient5.address, recipient6.address, recipient7.address, recipient8.address,
        recipient9.address, recipient10.address
      ];
      const percentages = Array(10).fill(BPS_DENOMINATOR / 10); // 10% each
      
      await escrowableERC20.connect(timelock).setDefaultYieldDistribution(recipients, percentages);
      const distribution = await escrowableERC20.defaultYieldDistribution();
      expect(distribution.recipients.length).to.equal(10);
    });

    it("Should revert if 0 recipients", async function () {
      const recipients: string[] = [];
      const percentages: bigint[] = [];
      
      await expect(
        escrowableERC20.connect(timelock).setDefaultYieldDistribution(recipients, percentages)
      ).to.be.revertedWithCustomError(escrowableERC20, "OutOfBounds");
    });

    it("Should revert if exceeds 10 recipients", async function () {
      const recipients = [
        recipient1.address, recipient2.address, recipient3.address, recipient4.address,
        recipient5.address, recipient6.address, recipient7.address, recipient8.address,
        recipient9.address, recipient10.address, recipient11.address
      ];
      const percentages = Array(11).fill(BPS_DENOMINATOR / 11);
      
      await expect(
        escrowableERC20.connect(timelock).setDefaultYieldDistribution(recipients, percentages)
      ).to.be.revertedWithCustomError(escrowableERC20, "TooManyRecipients");
    });

    it("Should revert if array lengths mismatch", async function () {
      const recipients = [recipient1.address, recipient2.address];
      const percentages = [BPS_DENOMINATOR]; // Only 1 percentage
      
      await expect(
        escrowableERC20.connect(timelock).setDefaultYieldDistribution(recipients, percentages)
      ).to.be.revertedWithCustomError(escrowableERC20, "InvalidArrayLength");
    });

    it("Should revert if sum doesn't equal 10000", async function () {
      const recipients = [recipient1.address, recipient2.address];
      const percentages = [5000, 4999]; // Sum = 9999, not 10000
      
      await expect(
        escrowableERC20.connect(timelock).setDefaultYieldDistribution(recipients, percentages)
      ).to.be.revertedWithCustomError(escrowableERC20, "InvalidBpsSum");
    });

    it("Should revert if sum exceeds 10000", async function () {
      const recipients = [recipient1.address, recipient2.address];
      const percentages = [5000, 5001]; // Sum = 10001
      
      await expect(
        escrowableERC20.connect(timelock).setDefaultYieldDistribution(recipients, percentages)
      ).to.be.revertedWithCustomError(escrowableERC20, "InvalidBpsSum");
    });

    it("Should revert if recipient is zero address", async function () {
      const recipients = [ethers.ZeroAddress];
      const percentages = [BPS_DENOMINATOR];
      
      await expect(
        escrowableERC20.connect(timelock).setDefaultYieldDistribution(recipients, percentages)
      ).to.be.revertedWithCustomError(escrowableERC20, "InvalidAddressKey");
    });

    it("Should revert if duplicate recipients", async function () {
      const recipients = [recipient1.address, recipient1.address];
      const percentages = [5000, 5000];
      
      await expect(
        escrowableERC20.connect(timelock).setDefaultYieldDistribution(recipients, percentages)
      ).to.be.revertedWithCustomError(escrowableERC20, "DuplicateRecipient");
    });

    it("Should accept valid distribution with multiple recipients", async function () {
      const recipients = [recipient1.address, recipient2.address, recipient3.address];
      const percentages = [4000, 3000, 3000]; // Sum = 10000
      
      await escrowableERC20.connect(timelock).setDefaultYieldDistribution(recipients, percentages);
      const distribution = await escrowableERC20.defaultYieldDistribution();
      expect(distribution.recipients.length).to.equal(3);
      expect(distribution.isSet).to.be.true;
    });
  });

  describe("EscrowVault Bounds", function () {
    it("Should enforce same bounds as EscrowableERC20", async function () {
      // Test max attachments
      await expect(
        escrowVault.connect(timelock).setMaxAttachments(MAX_ATTACHMENTS + 1)
      ).to.be.revertedWithCustomError(escrowVault, "OutOfBounds");

      // Test auto cancel time
      const currentTime = await time.latest();
      const invalidTime = BigInt(currentTime) + BigInt(MAX_AUTO_TIME_DAYS) + 1n;
      await expect(
        escrowVault.connect(timelock).setDefaultAutoCancelTime(invalidTime)
      ).to.be.revertedWithCustomError(escrowVault, "OutOfBounds");
    });
  });
});

