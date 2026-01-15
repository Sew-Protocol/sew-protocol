before(function () { this.skip(); }); // migrated to forge-std
/**
 * Access Control Tests
 * 
 * Tests for role-based access control (RBAC) implementation:
 * - ROLE_TIMELOCK: Standard and Slow lane governance actions
 * - ROLE_GUARDIAN: Emergency down-only actions
 * - DEFAULT_ADMIN_ROLE: Role management
 * 
 * Validates that access control migration from Ownable to AccessControl is correct.
 */

import { expect } from "chai";
import { ethers } from "hardhat";
import { time } from "@nomicfoundation/hardhat-network-helpers";
import { 
  EscrowableERC20,
  EscrowVault,
  BaseEscrow
} from "../../typechain-types";

describe("Access Control", function () {
  let escrowableERC20: EscrowableERC20;
  let escrowVault: EscrowVault;
  let deployer: any;
  let timelock: any;
  let guardian: any;
  let unauthorized: any;
  let feeAddress: any;

  const ESCROW_FEE = 100; // 1%
  const ESCROW_FEE_DENOMINATOR = 10000;

  beforeEach(async function () {
    [deployer, timelock, guardian, unauthorized, feeAddress] = await ethers.getSigners();

    // Deploy EscrowableERC20
    const EscrowableERC20Factory = await ethers.getContractFactory("EscrowableERC20");
    escrowableERC20 = await EscrowableERC20Factory.deploy(
      "Test Token",
      "TEST",
      ESCROW_FEE,
      feeAddress.address,
      ethers.ZeroAddress,
      ethers.ZeroAddress
    );
    await escrowableERC20.waitForDeployment();

    // Deploy EscrowVault
    const EscrowVaultFactory = await ethers.getContractFactory("EscrowVault");
    escrowVault = await EscrowVaultFactory.deploy(
      ESCROW_FEE,
      feeAddress.address,
      ethers.ZeroAddress,
      ethers.ZeroAddress
    );
    await escrowVault.waitForDeployment();
  });

  describe("Role Constants", function () {
    it("Should have ROLE_TIMELOCK constant", async function () {
      const ROLE_TIMELOCK = await escrowableERC20.ROLE_TIMELOCK();
      expect(ROLE_TIMELOCK).to.not.equal(ethers.ZeroHash);
    });

    it("Should have ROLE_GUARDIAN constant", async function () {
      const ROLE_GUARDIAN = await escrowableERC20.ROLE_GUARDIAN();
      expect(ROLE_GUARDIAN).to.not.equal(ethers.ZeroHash);
    });

    it("Should have DEFAULT_ADMIN_ROLE", async function () {
      const DEFAULT_ADMIN_ROLE = await escrowableERC20.DEFAULT_ADMIN_ROLE();
      expect(DEFAULT_ADMIN_ROLE).to.equal(ethers.ZeroHash); // OpenZeppelin uses 0x00
    });
  });

  describe("Initial Role Assignment", function () {
    it("Deployer should have DEFAULT_ADMIN_ROLE", async function () {
      const DEFAULT_ADMIN_ROLE = await escrowableERC20.DEFAULT_ADMIN_ROLE();
      const hasRole = await escrowableERC20.hasRole(DEFAULT_ADMIN_ROLE, deployer.address);
      expect(hasRole).to.be.true;
    });

    it("Deployer should be able to grant roles", async function () {
      const ROLE_TIMELOCK = await escrowableERC20.ROLE_TIMELOCK();
      await escrowableERC20.grantRole(ROLE_TIMELOCK, timelock.address);
      const hasRole = await escrowableERC20.hasRole(ROLE_TIMELOCK, timelock.address);
      expect(hasRole).to.be.true;
    });
  });

  describe("ROLE_TIMELOCK Access", function () {
    beforeEach(async function () {
      const ROLE_TIMELOCK = await escrowableERC20.ROLE_TIMELOCK();
      await escrowableERC20.grantRole(ROLE_TIMELOCK, timelock.address);
    });

    it("Timelock should be able to set default auto cancel time", async function () {
      const currentTime = await time.latest();
      const newTime = BigInt(currentTime) + BigInt(7 * 24 * 60 * 60); // 7 days in the future
      await escrowableERC20.connect(timelock).setDefaultAutoCancelTime(newTime);
      const autoCancelTime = await escrowableERC20.defaultAutoCancelTime();
      expect(autoCancelTime).to.equal(newTime);
    });

    it("Timelock should be able to set max attachments", async function () {
      const newMax = 15;
      await escrowableERC20.connect(timelock).setMaxAttachments(newMax);
      const maxAttachments = await escrowableERC20.maxAttachments();
      expect(maxAttachments).to.equal(newMax);
    });

    it("Unauthorized should not be able to set default auto cancel time", async function () {
      const newTime = 7 * 24 * 60 * 60;
      await expect(
        escrowableERC20.connect(unauthorized).setDefaultAutoCancelTime(newTime)
      ).to.be.revertedWithCustomError(escrowableERC20, "AccessControlUnauthorizedAccount");
    });
  });

  describe("ROLE_GUARDIAN Access", function () {
    beforeEach(async function () {
      const ROLE_GUARDIAN = await escrowableERC20.ROLE_GUARDIAN();
      await escrowableERC20.grantRole(ROLE_GUARDIAN, guardian.address);
    });

    it("Guardian should be able to pause", async function () {
      await escrowableERC20.connect(guardian).pause();
      const paused = await escrowableERC20.paused();
      expect(paused).to.be.true;
    });

    it("Guardian should not be able to unpause", async function () {
      await escrowableERC20.connect(guardian).pause();
      await expect(
        escrowableERC20.connect(guardian).unpause()
      ).to.be.revertedWithCustomError(escrowableERC20, "AccessControlUnauthorizedAccount");
    });

    it("Unauthorized should not be able to pause", async function () {
      await expect(
        escrowableERC20.connect(unauthorized).pause()
      ).to.be.revertedWithCustomError(escrowableERC20, "AccessControlUnauthorizedAccount");
    });
  });

  describe("Role Transfer to Timelock", function () {
    it("Should transfer DEFAULT_ADMIN_ROLE to Timelock", async function () {
      const DEFAULT_ADMIN_ROLE = await escrowableERC20.DEFAULT_ADMIN_ROLE();
      const ROLE_TIMELOCK = await escrowableERC20.ROLE_TIMELOCK();

      // Grant ROLE_TIMELOCK to timelock
      await escrowableERC20.grantRole(ROLE_TIMELOCK, timelock.address);

      // Grant DEFAULT_ADMIN_ROLE to timelock
      await escrowableERC20.grantRole(DEFAULT_ADMIN_ROLE, timelock.address);

      // Revoke deployer's DEFAULT_ADMIN_ROLE
      await escrowableERC20.revokeRole(DEFAULT_ADMIN_ROLE, deployer.address);

      // Verify timelock has roles
      expect(await escrowableERC20.hasRole(DEFAULT_ADMIN_ROLE, timelock.address)).to.be.true;
      expect(await escrowableERC20.hasRole(ROLE_TIMELOCK, timelock.address)).to.be.true;
      expect(await escrowableERC20.hasRole(DEFAULT_ADMIN_ROLE, deployer.address)).to.be.false;
    });

    it("Deployer should not be able to revoke timelock's role after transfer", async function () {
      const DEFAULT_ADMIN_ROLE = await escrowableERC20.DEFAULT_ADMIN_ROLE();
      const ROLE_TIMELOCK = await escrowableERC20.ROLE_TIMELOCK();

      // Transfer roles
      await escrowableERC20.grantRole(ROLE_TIMELOCK, timelock.address);
      await escrowableERC20.grantRole(DEFAULT_ADMIN_ROLE, timelock.address);
      await escrowableERC20.revokeRole(DEFAULT_ADMIN_ROLE, deployer.address);

      // Deployer should not be able to revoke timelock's role
      await expect(
        escrowableERC20.revokeRole(ROLE_TIMELOCK, timelock.address)
      ).to.be.revertedWithCustomError(escrowableERC20, "AccessControlUnauthorizedAccount");
    });
  });

  describe("EscrowVault Access Control", function () {
    it("Should have same role structure as EscrowableERC20", async function () {
      const ROLE_TIMELOCK_ERC20 = await escrowableERC20.ROLE_TIMELOCK();
      const ROLE_TIMELOCK_VAULT = await escrowVault.ROLE_TIMELOCK();
      expect(ROLE_TIMELOCK_ERC20).to.equal(ROLE_TIMELOCK_VAULT);

      const ROLE_GUARDIAN_ERC20 = await escrowableERC20.ROLE_GUARDIAN();
      const ROLE_GUARDIAN_VAULT = await escrowVault.ROLE_GUARDIAN();
      expect(ROLE_GUARDIAN_ERC20).to.equal(ROLE_GUARDIAN_VAULT);
    });

    it("Timelock should be able to configure EscrowVault", async function () {
      const ROLE_TIMELOCK = await escrowVault.ROLE_TIMELOCK();
      await escrowVault.grantRole(ROLE_TIMELOCK, timelock.address);

      const currentTime = await time.latest();
      const newTime = BigInt(currentTime) + BigInt(7 * 24 * 60 * 60); // 7 days in the future
      await escrowVault.connect(timelock).setDefaultAutoCancelTime(newTime);
      const autoCancelTime = await escrowVault.defaultAutoCancelTime();
      expect(autoCancelTime).to.equal(newTime);
    });
  });
});

