before(function () { this.skip(); }); // migrated to forge-std
/**
 * Guardian Controls Tests
 * 
 * Tests for guardian emergency controls (down-only):
 * - Guardian can pause
 * - Guardian can disable Aave
 * - Guardian can lower caps (down-only)
 * - Guardian cannot unpause
 * - Guardian cannot raise caps
 * - Guardian cannot change fees
 * - Guardian cannot swap modules
 */

import { expect } from "chai";
import { ethers } from "hardhat";
import { time } from "@nomicfoundation/hardhat-network-helpers";
import { 
  EscrowableERC20,
  EscrowVault,
  AaveYieldGenerationModule,
  MockAavePool,
  MockPoolAddressesProvider
} from "../../typechain-types";
import { time } from "@nomicfoundation/hardhat-network-helpers";

describe("Guardian Controls", function () {
  let escrowableERC20: EscrowableERC20;
  let escrowVault: EscrowVault;
  let aaveModule: AaveYieldGenerationModule;
  let mockAavePool: MockAavePool;
  let mockPoolAddressesProvider: MockPoolAddressesProvider;
  let deployer: any;
  let timelock: any;
  let guardian: any;
  let unauthorized: any;
  let feeAddress: any;
  let aavePoolProvider: any;

  const ESCROW_FEE = 100; // 1%

  beforeEach(async function () {
    [deployer, timelock, guardian, unauthorized, feeAddress, aavePoolProvider] = await ethers.getSigners();

    // Deploy contracts
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

    const EscrowVaultFactory = await ethers.getContractFactory("EscrowVault");
    escrowVault = await EscrowVaultFactory.deploy(
      ESCROW_FEE,
      feeAddress.address,
      ethers.ZeroAddress,
      ethers.ZeroAddress
    );
    await escrowVault.waitForDeployment();

    // Deploy Aave module
    const AaveModuleFactory = await ethers.getContractFactory("AaveYieldGenerationModule");
    aaveModule = await AaveModuleFactory.deploy(deployer.address);
    await aaveModule.waitForDeployment();

    // Deploy mock Aave Pool and Provider
    const poolFactory = await ethers.getContractFactory("MockAavePool");
    mockAavePool = (await poolFactory.deploy()) as MockAavePool;
    await mockAavePool.waitForDeployment();

    const providerFactory = await ethers.getContractFactory("MockPoolAddressesProvider");
    mockPoolAddressesProvider = (await providerFactory.deploy(await mockAavePool.getAddress())) as MockPoolAddressesProvider;
    await mockPoolAddressesProvider.waitForDeployment();

    // Grant roles
    const ROLE_TIMELOCK = await escrowableERC20.ROLE_TIMELOCK();
    const ROLE_GUARDIAN = await escrowableERC20.ROLE_GUARDIAN();
    
    await escrowableERC20.grantRole(ROLE_TIMELOCK, timelock.address);
    await escrowableERC20.grantRole(ROLE_GUARDIAN, guardian.address);
    
    await escrowVault.grantRole(ROLE_TIMELOCK, timelock.address);
    await escrowVault.grantRole(ROLE_GUARDIAN, guardian.address);

    await aaveModule.grantRole(ROLE_TIMELOCK, timelock.address);
    await aaveModule.grantRole(ROLE_GUARDIAN, guardian.address);
  });

  describe("Pause Control", function () {
    it("Guardian should be able to pause", async function () {
      await escrowableERC20.connect(guardian).pause();
      const paused = await escrowableERC20.paused();
      expect(paused).to.be.true;
    });

    it("Guardian should NOT be able to unpause", async function () {
      await escrowableERC20.connect(guardian).pause();
      await expect(
        escrowableERC20.connect(guardian).unpause()
      ).to.be.revertedWithCustomError(escrowableERC20, "AccessControlUnauthorizedAccount");
    });

    it("Timelock should be able to unpause", async function () {
      await escrowableERC20.connect(guardian).pause();
      await escrowableERC20.connect(timelock).unpause();
      const paused = await escrowableERC20.paused();
      expect(paused).to.be.false;
    });

    it("Unauthorized should not be able to pause", async function () {
      await expect(
        escrowableERC20.connect(unauthorized).pause()
      ).to.be.revertedWithCustomError(escrowableERC20, "AccessControlUnauthorizedAccount");
    });
  });

  describe("Aave Module Guardian Controls", function () {
    beforeEach(async function () {
      // Set up Aave module with initial state
      // First, configure the Aave pool provider (required before enabling)
      await aaveModule.connect(timelock).queueAavePoolProvider(await mockPoolAddressesProvider.getAddress());
      const [, eta] = await aaveModule.getPendingAavePoolProvider();
      await time.increaseTo(Number(eta) + 1);
      await aaveModule.connect(timelock).activateAavePoolProvider();
      
      const token = ethers.ZeroAddress; // Use zero address as token key
      await aaveModule.connect(timelock).setAaveEnabled(true);
      await aaveModule.connect(timelock).setTokenCap(token, ethers.parseEther("10000"));
      await aaveModule.connect(timelock).setGlobalCap(token, ethers.parseEther("100000"));
    });

    it("Guardian should be able to disable Aave", async function () {
      await aaveModule.connect(guardian).guardianDisableAave();
      const enabled = await aaveModule.aaveEnabled();
      expect(enabled).to.be.false;
    });

    it("Guardian should NOT be able to enable Aave", async function () {
      await aaveModule.connect(guardian).guardianDisableAave();
      // Guardian cannot call setAaveEnabled (only timelock)
      const ROLE_TIMELOCK = await aaveModule.ROLE_TIMELOCK();
      await expect(
        aaveModule.connect(guardian).setAaveEnabled(true)
      ).to.be.revertedWithCustomError(aaveModule, "AccessControlUnauthorizedAccount");
    });

    it("Guardian should be able to lower token cap (down-only)", async function () {
      const currentCap = await aaveModule.tokenCap(ethers.ZeroAddress);
      const lowerCap = currentCap / 2n;
      
      await aaveModule.connect(guardian).guardianLowerTokenCap(ethers.ZeroAddress, lowerCap);
      const newCap = await aaveModule.tokenCap(ethers.ZeroAddress);
      expect(newCap).to.equal(lowerCap);
    });

    it("Guardian should NOT be able to raise token cap", async function () {
      const currentCap = await aaveModule.tokenCap(ethers.ZeroAddress);
      const higherCap = currentCap * 2n;
      
      await expect(
        aaveModule.connect(guardian).guardianLowerTokenCap(ethers.ZeroAddress, higherCap)
      ).to.be.revertedWith("Guardian can only lower caps");
    });

    it("Guardian should be able to set cap to current value", async function () {
      const currentCap = await aaveModule.tokenCap(ethers.ZeroAddress);
      await aaveModule.connect(guardian).guardianLowerTokenCap(ethers.ZeroAddress, currentCap);
      const newCap = await aaveModule.tokenCap(ethers.ZeroAddress);
      expect(newCap).to.equal(currentCap);
    });

    it("Guardian should be able to lower global cap (down-only)", async function () {
      const token = ethers.ZeroAddress; // Use zero address as token key
      const currentCap = await aaveModule.globalCap(token);
      const lowerCap = currentCap / 2n;
      
      await aaveModule.connect(guardian).guardianLowerGlobalCap(token, lowerCap);
      const newCap = await aaveModule.globalCap(token);
      expect(newCap).to.equal(lowerCap);
    });

    it("Guardian should NOT be able to raise global cap", async function () {
      const token = ethers.ZeroAddress; // Use zero address as token key
      const currentCap = await aaveModule.globalCap(token);
      const higherCap = currentCap * 2n;
      
      await expect(
        aaveModule.connect(guardian).guardianLowerGlobalCap(token, higherCap)
      ).to.be.revertedWith("Guardian can only lower caps");
    });
  });

  describe("Guardian Cannot Perform Timelock Actions", function () {
    it("Guardian should NOT be able to change escrow fee", async function () {
      const ROLE_TIMELOCK = await escrowableERC20.ROLE_TIMELOCK();
      await expect(
        escrowableERC20.connect(guardian).queueEscrowFee(150)
      ).to.be.revertedWithCustomError(escrowableERC20, "AccessControlUnauthorizedAccount");
    });

    it("Guardian should NOT be able to change fee address", async function () {
      await expect(
        escrowableERC20.connect(guardian).queueEscrowFeeAddress(unauthorized.address)
      ).to.be.revertedWithCustomError(escrowableERC20, "AccessControlUnauthorizedAccount");
    });

    it("Guardian should NOT be able to set max attachments", async function () {
      await expect(
        escrowableERC20.connect(guardian).setMaxAttachments(15)
      ).to.be.revertedWithCustomError(escrowableERC20, "AccessControlUnauthorizedAccount");
    });

    it("Guardian should NOT be able to set default auto cancel time", async function () {
      const currentTime = await time.latest();
      const newTime = BigInt(currentTime) + BigInt(7 * 24 * 60 * 60);
      await expect(
        escrowableERC20.connect(guardian).setDefaultAutoCancelTime(newTime)
      ).to.be.revertedWithCustomError(escrowableERC20, "AccessControlUnauthorizedAccount");
    });
  });

  describe("Guardian Cannot Swap Modules", function () {
    it("Guardian should NOT be able to set Aave pool provider", async function () {
      const ROLE_TIMELOCK = await aaveModule.ROLE_TIMELOCK();
      await expect(
        aaveModule.connect(guardian).queueAavePoolProvider(aavePoolProvider.address)
      ).to.be.revertedWithCustomError(aaveModule, "AccessControlUnauthorizedAccount");
    });
  });

  describe("EscrowVault Guardian Controls", function () {
    it("Guardian should be able to pause EscrowVault", async function () {
      await escrowVault.connect(guardian).pause();
      const paused = await escrowVault.paused();
      expect(paused).to.be.true;
    });

    it("Guardian should NOT be able to unpause EscrowVault", async function () {
      await escrowVault.connect(guardian).pause();
      await expect(
        escrowVault.connect(guardian).unpause()
      ).to.be.revertedWithCustomError(escrowVault, "AccessControlUnauthorizedAccount");
    });
  });
});

