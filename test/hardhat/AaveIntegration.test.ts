before(function () { this.skip(); }); // migrated to forge-std
import { expect } from "chai";
import { ethers } from "hardhat";
import { time } from "@nomicfoundation/hardhat-network-helpers";
import { EscrowableERC20 } from "../typechain-types";
import { ERC20Mock } from "../typechain-types";
import { MockAavePool, MockAToken, MockPoolAddressesProvider } from "../typechain-types";

describe("Aave Integration", function () {
  let escrowableERC20: EscrowableERC20;
  let aaveModule: any; // AaveYieldGenerationModule
  let mockToken: ERC20Mock;
  let mockAavePool: MockAavePool;
  let mockAToken: MockAToken;
  let escrowTokenAToken: MockAToken; // aToken for EscrowableERC20's token
  let mockPoolAddressesProvider: MockPoolAddressesProvider;
  
  let owner: any;
  let sender: any;
  let recipient: any;
  let resolver: any;
  let feeAddress: any;
  let yieldRecipient1: any;
  let yieldRecipient2: any;

  const ESCROW_FEE = 100;
  const ESCROW_FEE_DENOMINATOR = 10000;
  const INITIAL_TRANSFER_AMOUNT = ethers.parseEther("100");
  const YIELD_AMOUNT = ethers.parseEther("5"); // 5% yield for testing

  beforeEach(async function () {
    [owner, sender, recipient, resolver, feeAddress, yieldRecipient1, yieldRecipient2] = await ethers.getSigners();

    // Deploy EscrowableERC20
    const escrowableERC20Factory = await ethers.getContractFactory("EscrowableERC20");
    escrowableERC20 = (await escrowableERC20Factory.deploy(
      "Test Token",
      "TEST",
      ESCROW_FEE,
      feeAddress.address,
      ethers.ZeroAddress,
      ethers.ZeroAddress
    )) as EscrowableERC20;
    await escrowableERC20.waitForDeployment();

    // Deploy mock ERC20 token
    const tokenFactory = await ethers.getContractFactory("ERC20Mock");
    mockToken = (await tokenFactory.deploy(
      "Mock Token",
      "MOCK",
      owner.address,
      ethers.parseEther("1000000")
    )) as ERC20Mock;
    await mockToken.waitForDeployment();

    // Deploy mock Aave Pool
    const poolFactory = await ethers.getContractFactory("MockAavePool");
    mockAavePool = (await poolFactory.deploy()) as MockAavePool;
    await mockAavePool.waitForDeployment();

    // Deploy mock aToken
    const aTokenFactory = await ethers.getContractFactory("MockAToken");
    mockAToken = (await aTokenFactory.deploy(
      await mockToken.getAddress(),
      "aMock Token",
      "aMOCK"
    )) as MockAToken;
    await mockAToken.waitForDeployment();

    // Link aToken to pool
    await mockAToken.setPool(await mockAavePool.getAddress());
    await mockAavePool.setAToken(await mockToken.getAddress(), await mockAToken.getAddress());

    // Deploy mock Pool Addresses Provider
    const providerFactory = await ethers.getContractFactory("MockPoolAddressesProvider");
    mockPoolAddressesProvider = (await providerFactory.deploy(await mockAavePool.getAddress())) as MockPoolAddressesProvider;
    await mockPoolAddressesProvider.waitForDeployment();

    // Deploy aToken for EscrowableERC20's token (the contract itself)
    const escrowTokenATokenFactory = await ethers.getContractFactory("MockAToken");
    escrowTokenAToken = (await escrowTokenATokenFactory.deploy(
      await escrowableERC20.getAddress(),
      "aTest Token",
      "aTEST"
    )) as MockAToken;
    await escrowTokenAToken.waitForDeployment();
    await escrowTokenAToken.setPool(await mockAavePool.getAddress());
    await mockAavePool.setAToken(await escrowableERC20.getAddress(), await escrowTokenAToken.getAddress());

    // Deploy AaveYieldGenerationModule
    const aaveModuleFactory = await ethers.getContractFactory("AaveYieldGenerationModule");
    aaveModule = await aaveModuleFactory.deploy(owner.address);
    await aaveModule.waitForDeployment();

    // Phase 2: Grant ROLE_TIMELOCK to owner for Aave module
    const ROLE_TIMELOCK = await aaveModule.ROLE_TIMELOCK();
    await aaveModule.grantRole(ROLE_TIMELOCK, owner.address);
    
    // Phase 3: Use queue/activate for slow lane functions
    await aaveModule.connect(owner).queueAavePoolProvider(await mockPoolAddressesProvider.getAddress());
    // Fast-forward time for testing (skip 7-day delay)
    const [, eta] = await aaveModule.getPendingAavePoolProvider();
    await time.increaseTo(Number(eta) + 1);
    await aaveModule.connect(owner).activateAavePoolProvider();
    
    await aaveModule.setAaveEnabled(true);
    // Register EscrowableERC20's token (the contract itself) for Aave
    await aaveModule.registerTokenForAave(await escrowableERC20.getAddress(), await escrowTokenAToken.getAddress());

    // Phase 2: Grant ROLE_TIMELOCK to owner for escrowableERC20 (must be before queueDefaultYieldGenerationModule)
    const ROLE_TIMELOCK_ERC20 = await escrowableERC20.ROLE_TIMELOCK();
    await escrowableERC20.grantRole(ROLE_TIMELOCK_ERC20, owner.address);

    // Phase 3: Set the module as default yield generation module (queue/activate pattern)
    await escrowableERC20.connect(owner).queueDefaultYieldGenerationModule(await aaveModule.getAddress());
    // Fast-forward time for testing (skip 7-day delay)
    const [, etaYield] = await escrowableERC20.getPendingDefaultYieldGenerationModule();
    await time.increaseTo(Number(etaYield) + 1);
    await escrowableERC20.connect(owner).activateDefaultYieldGenerationModule();
    
    // Phase 7: Setup resolution module (required for escrow creation)
    const { setupResolutionModule } = await import("../helpers/setupResolutionModule");
    await setupResolutionModule(escrowableERC20, owner, resolver.address);

    // Setup yield distribution module (required for yield distribution)
    // Use TestYieldDistributionModule for testing (allows setting default distribution)
    const YieldDistFactory = await ethers.getContractFactory("TestYieldDistributionModule");
    const yieldDistModule = await YieldDistFactory.deploy();
    await yieldDistModule.waitForDeployment();
    
    // Set default distribution for tests (60% to recipient1, 40% to recipient2)
    const recipients = [yieldRecipient1.address, yieldRecipient2.address];
    const percentages = [6000, 4000]; // 60% and 40%
    await yieldDistModule.setDefaultDistribution(recipients, percentages);
    
    await escrowableERC20.connect(owner).queueDefaultYieldDistributionModule(await yieldDistModule.getAddress());
    const [, etaYieldDist] = await escrowableERC20.getPendingDefaultYieldDistributionModule();
    await time.increaseTo(Number(etaYieldDist) + 1);
    await escrowableERC20.connect(owner).activateDefaultYieldDistributionModule();

    // Transfer tokens to sender
    await escrowableERC20.transfer(sender.address, INITIAL_TRANSFER_AMOUNT);
    
    // Give mockToken to sender (for EscrowVault tests)
    await mockToken.transfer(sender.address, INITIAL_TRANSFER_AMOUNT);
    
    // Approve mockToken for Aave Pool
    await mockToken.connect(sender).approve(await mockAavePool.getAddress(), ethers.MaxUint256);
    
    // Approve EscrowableERC20 contract to spend its own tokens for Aave (needed for _depositToAave)
    // The contract needs to approve itself to spend tokens when depositing to Aave
    // This is handled internally by forceApprove in _depositToAave, but we need to ensure the contract has tokens
  });

  describe("Aave Configuration", function () {
    it("Should set Aave Pool Addresses Provider", async function () {
      const provider = await aaveModule.aavePoolAddressesProvider();
      expect(provider).to.equal(await mockPoolAddressesProvider.getAddress());
    });

    it("Should enable/disable Aave", async function () {
      expect(await aaveModule.aaveEnabled()).to.be.true;
      
      await aaveModule.setAaveEnabled(false);
      expect(await aaveModule.aaveEnabled()).to.be.false;
      
      await aaveModule.setAaveEnabled(true);
      expect(await aaveModule.aaveEnabled()).to.be.true;
    });

    it("Should register token for Aave", async function () {
      // Test with EscrowableERC20's token (the contract itself)
      const aTokenAddress = await aaveModule.getATokenAddress(await escrowableERC20.getAddress());
      expect(aTokenAddress).to.equal(await escrowTokenAToken.getAddress());
      
      const isSupported = await aaveModule.isTokenSupportedByAave(await escrowableERC20.getAddress());
      expect(isSupported).to.be.true;
    });

    it("Should batch register tokens", async function () {
      // Deploy another token
      const token2Factory = await ethers.getContractFactory("ERC20Mock");
      const token2 = await token2Factory.deploy("Token2", "TK2", owner.address, ethers.parseEther("1000000"));
      await token2.waitForDeployment();

      const aToken2Factory = await ethers.getContractFactory("MockAToken");
      const aToken2 = await aToken2Factory.deploy(await token2.getAddress(), "aToken2", "aTK2");
      await aToken2.waitForDeployment();
      await aToken2.setPool(await mockAavePool.getAddress());
      await mockAavePool.setAToken(await token2.getAddress(), await aToken2.getAddress());

      const tokens = [await token2.getAddress()];
      const aTokens = [await aToken2.getAddress()];

      await aaveModule.batchRegisterTokensForAave(tokens, aTokens);

      const aTokenAddress = await aaveModule.getATokenAddress(await token2.getAddress());
      expect(aTokenAddress).to.equal(await aToken2.getAddress());
    });

    it("Should not allow non-owner to configure Aave", async function () {
      await expect(
        aaveModule.connect(sender).queueAavePoolProvider(ethers.ZeroAddress)
      ).to.be.revertedWithCustomError(aaveModule, "AccessControlUnauthorizedAccount");
    });
  });

  describe("Aave Deposit Flow", function () {
    it("Should deposit to Aave when creating escrow with yield enabled", async function () {
      const settings = {
        customResolver: ethers.ZeroAddress,
        yieldEnabled: true,
        autoReleaseTime: 0,
        autoCancelTime: 0,
        escrowType: 0
      };

      const tx = await escrowableERC20
        .connect(sender)
        .getFunction("createEscrow(address,uint256,(address,bool,uint256,uint256,uint8))")
        .send(recipient.address, INITIAL_TRANSFER_AMOUNT, settings);
      await tx.wait();

      const workflowId = Number(await escrowableERC20.nextWorkflowId()) - 1;
      
      // Check that escrow is in Aave
      const inAave = await aaveModule.escrowInAave(await escrowableERC20.getAddress(), workflowId);
      expect(inAave).to.be.true;

      // Check aToken balance
      const aTokenBalance = await aaveModule.escrowATokenBalance(await escrowableERC20.getAddress(), workflowId);
      const fee = (INITIAL_TRANSFER_AMOUNT * BigInt(ESCROW_FEE)) / BigInt(ESCROW_FEE_DENOMINATOR);
      const amountAfterFee = INITIAL_TRANSFER_AMOUNT - fee;
      expect(aTokenBalance).to.equal(amountAfterFee);

      // Check original deposit (this returns the amount before fee deduction)
      const originalDeposit = await escrowableERC20.getTotalDeposited(workflowId);
      expect(originalDeposit).to.equal(INITIAL_TRANSFER_AMOUNT);
    });

    it("Should not deposit to Aave when yield is disabled", async function () {
      const settings = {
        customResolver: ethers.ZeroAddress,
        yieldEnabled: false,
        autoReleaseTime: 0,
        autoCancelTime: 0,
        escrowType: 0
      };

      const tx = await escrowableERC20
        .connect(sender)
        .getFunction("createEscrow(address,uint256,(address,bool,uint256,uint256,uint8))")
        .send(recipient.address, INITIAL_TRANSFER_AMOUNT, settings);
      await tx.wait();

      const workflowId = Number(await escrowableERC20.nextWorkflowId()) - 1;
      
      const inAave = await aaveModule.escrowInAave(await escrowableERC20.getAddress(), workflowId);
      expect(inAave).to.be.false;
    });

    it("Should not deposit to Aave when Aave is disabled", async function () {
      await aaveModule.setAaveEnabled(false);

      const settings = {
        customResolver: ethers.ZeroAddress,
        yieldEnabled: true,
        autoReleaseTime: 0,
        autoCancelTime: 0,
        escrowType: 0
      };

      const tx = await escrowableERC20
        .connect(sender)
        .getFunction("createEscrow(address,uint256,(address,bool,uint256,uint256,uint8))")
        .send(recipient.address, INITIAL_TRANSFER_AMOUNT, settings);
      await tx.wait();

      const workflowId = Number(await escrowableERC20.nextWorkflowId()) - 1;
      
      const inAave = await aaveModule.escrowInAave(await escrowableERC20.getAddress(), workflowId);
      expect(inAave).to.be.false;
    });
  });

  describe("Aave Withdrawal Flow", function () {
    beforeEach(async function () {
      // Create escrow with yield enabled
      const settings = {
        customResolver: ethers.ZeroAddress,
        yieldEnabled: true,
        autoReleaseTime: 0,
        autoCancelTime: 0,
        escrowType: 0
      };

      const tx = await escrowableERC20
        .connect(sender)
        .getFunction("createEscrow(address,uint256,(address,bool,uint256,uint256,uint8))")
        .send(recipient.address, INITIAL_TRANSFER_AMOUNT, settings);
      await tx.wait();
      
      // After creating escrow, tokens are deposited to Aave (transferred to MockAavePool)
      // The MockAavePool now has the deposit amount (after fee)
      // We'll add more tokens after simulating yield in the test to ensure we have enough
    });

    it("Should withdraw from Aave on release", async function () {
      const workflowId = Number(await escrowableERC20.nextWorkflowId()) - 1;
      
      // Get the aToken balance before simulating yield
      const aTokenBalance = await aaveModule.escrowATokenBalance(await escrowableERC20.getAddress(), workflowId);
      
      // Simulate yield
      await mockAavePool.simulateYield(await escrowableERC20.getAddress(), 10);
      
      // Calculate expected withdrawal amount with yield
      // The MockAavePool's withdraw function calculates: actualAmount = (aTokenBalance * liquidityIndex) / INITIAL_LIQUIDITY_INDEX
      // We need to ensure the pool has enough tokens to cover this withdrawal
      // To be safe, transfer a generous amount (1000 tokens) to ensure we have enough
      // Owner has plenty of tokens from initial deployment (1,000,000 tokens)
      await escrowableERC20.connect(owner).transfer(await mockAavePool.getAddress(), ethers.parseEther("1000"));
      
      // Verify pool has enough tokens (we transferred 1000, should be more than enough)
      const poolBalance = await escrowableERC20.balanceOf(await mockAavePool.getAddress());
      expect(poolBalance).to.be.gte(ethers.parseEther("100")); // At least 100 tokens
      
      const recipientBalanceBefore = await escrowableERC20.balanceOf(recipient.address);
      
      await escrowableERC20.connect(sender).releaseEscrowTransfer(workflowId);
      
      const recipientBalanceAfter = await escrowableERC20.balanceOf(recipient.address);
      const amountReceived = recipientBalanceAfter - recipientBalanceBefore;
      
      // Should receive more than original (due to yield)
      const escrowFeeAmount = (INITIAL_TRANSFER_AMOUNT * BigInt(ESCROW_FEE)) / BigInt(ESCROW_FEE_DENOMINATOR);
      const depositAmount = INITIAL_TRANSFER_AMOUNT - escrowFeeAmount;
      expect(amountReceived).to.be.gte(depositAmount);
      
      // Check that escrow is no longer in Aave
      const inAave = await aaveModule.escrowInAave(await escrowableERC20.getAddress(), workflowId);
      expect(inAave).to.be.false;
    });

    it("Should withdraw from Aave on cancel", async function () {
      const workflowId = Number(await escrowableERC20.nextWorkflowId()) - 1;
      
      // Simulate yield
      await mockAavePool.simulateYield(await escrowableERC20.getAddress(), 10);
      
      // Ensure pool has enough tokens to cover withdrawal with yield
      // Transfer tokens to pool to ensure it can cover the withdrawal
      await escrowableERC20.connect(owner).transfer(await mockAavePool.getAddress(), ethers.parseEther("1000"));
      
      const senderBalanceBefore = await escrowableERC20.balanceOf(sender.address);
      
      await escrowableERC20.connect(recipient).recipientCancel(workflowId);
      await escrowableERC20.connect(sender).senderCancel(workflowId);
      
      // Cancel should trigger withdrawal
      const escrowTransfer = await escrowableERC20.escrowTransfers(workflowId);
      expect(escrowTransfer.escrowState).to.equal(3); // REFUNDED
      
      const senderBalanceAfter = await escrowableERC20.balanceOf(sender.address);
      const amountReceived = senderBalanceAfter - senderBalanceBefore;
      
      // Should receive more than original (due to yield)
      const fee = (INITIAL_TRANSFER_AMOUNT * BigInt(ESCROW_FEE)) / BigInt(ESCROW_FEE_DENOMINATOR);
      const amountAfterFee = INITIAL_TRANSFER_AMOUNT - fee;
      expect(amountReceived).to.be.gte(amountAfterFee);
    });
  });

  describe("Yield Calculation", function () {
    beforeEach(async function () {
      const settings = {
        customResolver: ethers.ZeroAddress,
        yieldEnabled: true,
        autoReleaseTime: 0,
        autoCancelTime: 0,
        escrowType: 0
      };

      const tx = await escrowableERC20
        .connect(sender)
        .getFunction("createEscrow(address,uint256,(address,bool,uint256,uint256,uint8))")
        .send(recipient.address, INITIAL_TRANSFER_AMOUNT, settings);
      await tx.wait();
    });

    it("Should calculate yield correctly", async function () {
      const workflowId = Number(await escrowableERC20.nextWorkflowId()) - 1;
      
      // Simulate yield over multiple blocks
      await mockAavePool.simulateYield(await escrowableERC20.getAddress(), 100);
      
      // Note: _calculateYield is internal, so we test it indirectly through withdrawal
      const originalDeposit = await escrowableERC20.getTotalDeposited(workflowId);
      const fee = (originalDeposit * BigInt(ESCROW_FEE)) / BigInt(ESCROW_FEE_DENOMINATOR);
      const amountAfterFee = originalDeposit - fee;
      const aTokenBalance = await aaveModule.escrowATokenBalance(await escrowableERC20.getAddress(), workflowId);
      
      // aToken balance should be higher than amount after fee due to yield
      expect(aTokenBalance).to.be.gte(amountAfterFee);
    });
  });

  describe("Yield Distribution", function () {
    beforeEach(async function () {
      // Set up yield distribution
      const recipients = [yieldRecipient1.address, yieldRecipient2.address];
      const percentages = [6000, 4000]; // 60% and 40%

      // setDefaultYieldDistribution was removed - yield distribution now handled entirely by module
      // await escrowableERC20.setDefaultYieldDistribution(recipients, percentages);

      // Ensure MockAavePool has sufficient tokens for withdrawals (with yield)
      // Transfer enough tokens to cover the escrow amount plus potential yield
      const amountWithYield = INITIAL_TRANSFER_AMOUNT * 2n; // Enough for yield
      await escrowableERC20.transfer(await mockAavePool.getAddress(), amountWithYield);

      const settings = {
        customResolver: ethers.ZeroAddress,
        yieldEnabled: true,
        autoReleaseTime: 0,
        autoCancelTime: 0,
        escrowType: 0
      };

      const tx = await escrowableERC20
        .connect(sender)
        .getFunction("createEscrow(address,uint256,(address,bool,uint256,uint256,uint8))")
        .send(recipient.address, INITIAL_TRANSFER_AMOUNT, settings);
      await tx.wait();
    });

    it("Should distribute yield on release", async function () {
      const workflowId = Number(await escrowableERC20.nextWorkflowId()) - 1;
      
      // Simulate yield
      await mockAavePool.simulateYield(await escrowableERC20.getAddress(), 100);
      
      const recipient1BalanceBefore = await escrowableERC20.balanceOf(yieldRecipient1.address);
      const recipient2BalanceBefore = await escrowableERC20.balanceOf(yieldRecipient2.address);
      
      await escrowableERC20.connect(sender).releaseEscrowTransfer(workflowId);
      
      const recipient1BalanceAfter = await escrowableERC20.balanceOf(yieldRecipient1.address);
      const recipient2BalanceAfter = await escrowableERC20.balanceOf(yieldRecipient2.address);
      
      const yield1 = recipient1BalanceAfter - recipient1BalanceBefore;
      const yield2 = recipient2BalanceAfter - recipient2BalanceBefore;
      
      // Both should receive yield
      expect(yield1).to.be.gt(0);
      expect(yield2).to.be.gt(0);
      
      // Check distribution ratio (approximately 60/40)
      const ratio = (yield1 * 10000n) / yield2;
      expect(ratio).to.be.closeTo(15000n, 1000n); // 60/40 = 1.5, with some tolerance
    });

    it("Should allow per-escrow yield distribution", async function () {
      const workflowId = Number(await escrowableERC20.nextWorkflowId()) - 1;
      
      // Set custom yield distribution for this escrow using TestYieldDistributionModule
      // For this test, we want 100% to recipient1
      const TestYieldDistFactory = await ethers.getContractFactory("TestYieldDistributionModule");
      const testYieldDistModule = TestYieldDistFactory.attach(await escrowableERC20.defaultYieldDistributionModule());
      const customRecipients = [yieldRecipient1.address];
      const customPercentages = [10000]; // 100% to recipient1
      await testYieldDistModule.setDefaultDistribution(customRecipients, customPercentages);
      
      // Simulate yield
      await mockAavePool.simulateYield(await escrowableERC20.getAddress(), 100);
      
      const recipient1BalanceBefore = await escrowableERC20.balanceOf(yieldRecipient1.address);
      const recipient2BalanceBefore = await escrowableERC20.balanceOf(yieldRecipient2.address);
      
      await escrowableERC20.connect(sender).releaseEscrowTransfer(workflowId);
      
      const recipient1BalanceAfter = await escrowableERC20.balanceOf(yieldRecipient1.address);
      const recipient2BalanceAfter = await escrowableERC20.balanceOf(yieldRecipient2.address);
      
      // Only recipient1 should receive yield
      expect(recipient1BalanceAfter - recipient1BalanceBefore).to.be.gt(0);
      expect(recipient2BalanceAfter - recipient2BalanceBefore).to.equal(0);
      
      // Restore default distribution for other tests
      const recipients = [yieldRecipient1.address, yieldRecipient2.address];
      const percentages = [6000, 4000]; // 60% and 40%
      await testYieldDistModule.setDefaultDistribution(recipients, percentages);
    });
  });

  describe("Proportional Withdrawals", function () {
    beforeEach(async function () {
      const settings = {
        customResolver: ethers.ZeroAddress,
        yieldEnabled: true,
        autoReleaseTime: 0,
        autoCancelTime: 0,
        escrowType: 0
      };

      const tx = await escrowableERC20
        .connect(sender)
        .getFunction("createEscrow(address,uint256,(address,bool,uint256,uint256,uint8))")
        .send(recipient.address, INITIAL_TRANSFER_AMOUNT, settings);
      await tx.wait();
    });

    it("Should handle proportional withdrawal for partial release", async function () {
      const workflowId = Number(await escrowableERC20.nextWorkflowId()) - 1;
      
      await escrowableERC20.connect(sender).raiseDispute(workflowId);
      
      // Simulate yield
      await mockAavePool.simulateYield(await escrowableERC20.getAddress(), 100);
      
      const escrowTransfer = await escrowableERC20.escrowTransfers(workflowId);
      const halfAmount = escrowTransfer.remainingBalance / 2n;
      
      const recipientBalanceBefore = await escrowableERC20.balanceOf(recipient.address);
      
      await escrowableERC20.connect(resolver).partialReleaseAsDisputeResolver(workflowId, halfAmount, ethers.ZeroHash);
      
      const recipientBalanceAfter = await escrowableERC20.balanceOf(recipient.address);
      const amountReceived = recipientBalanceAfter - recipientBalanceBefore;
      
      // Should receive proportional amount with yield
      expect(amountReceived).to.be.gte(halfAmount);
    });

    it("Should handle proportional withdrawal for partial cancel", async function () {
      const workflowId = Number(await escrowableERC20.nextWorkflowId()) - 1;
      
      await escrowableERC20.connect(sender).raiseDispute(workflowId);
      
      // Simulate yield
      await mockAavePool.simulateYield(await escrowableERC20.getAddress(), 100);
      
      const escrowTransfer = await escrowableERC20.escrowTransfers(workflowId);
      const halfAmount = escrowTransfer.remainingBalance / 2n;
      
      const senderBalanceBefore = await escrowableERC20.balanceOf(sender.address);
      
      await escrowableERC20.connect(resolver).partialCancelAsDisputeResolver(workflowId, halfAmount, ethers.ZeroHash);
      
      const senderBalanceAfter = await escrowableERC20.balanceOf(sender.address);
      const amountReceived = senderBalanceAfter - senderBalanceBefore;
      
      // Should receive proportional amount with yield
      expect(amountReceived).to.be.gte(halfAmount);
    });
  });

  describe("Failure Scenarios", function () {
    it("Should handle Aave withdrawal failure gracefully", async function () {
      // This would require a more sophisticated mock that can fail
      // For now, we test that the system doesn't break if Aave is unavailable
      
      await aaveModule.setAaveEnabled(false);
      
      const settings = {
        customResolver: ethers.ZeroAddress,
        yieldEnabled: true,
        autoReleaseTime: 0,
        autoCancelTime: 0,
        escrowType: 0
      };

      const tx = await escrowableERC20
        .connect(sender)
        .getFunction("createEscrow(address,uint256,(address,bool,uint256,uint256,uint8))")
        .send(recipient.address, INITIAL_TRANSFER_AMOUNT, settings);
      await tx.wait();

      const workflowId = Number(await escrowableERC20.nextWorkflowId()) - 1;
      
      // Should still be able to release even if Aave is disabled
      await expect(
        escrowableERC20.connect(sender).releaseEscrowTransfer(workflowId)
      ).to.not.be.reverted;
    });

    it("Should revert if token not registered for Aave", async function () {
      // Unregister token
      // Note: There's no unregister function, so we test with a different token
      const token2Factory = await ethers.getContractFactory("ERC20Mock");
      const token2 = await token2Factory.deploy("Token2", "TK2", owner.address, ethers.parseEther("1000000"));
      await token2.waitForDeployment();
      
      // Try to create escrow with unregistered token (this would be for EscrowVault)
      // For EscrowableERC20, the token is always the contract itself, so this test
      // would need to be in EscrowVault tests
    });
  });

  describe("Total Deposited Tracking", function () {
    it("Should track total deposited to Aave", async function () {
      const settings = {
        customResolver: ethers.ZeroAddress,
        yieldEnabled: true,
        autoReleaseTime: 0,
        autoCancelTime: 0,
        escrowType: 0
      };

      const totalBefore = await aaveModule.getTotalDepositedToAave(await escrowableERC20.getAddress());
      
      const tx = await escrowableERC20
        .connect(sender)
        .getFunction("createEscrow(address,uint256,(address,bool,uint256,uint256,uint8))")
        .send(recipient.address, INITIAL_TRANSFER_AMOUNT, settings);
      await tx.wait();

      const totalAfter = await aaveModule.getTotalDepositedToAave(await escrowableERC20.getAddress());
      
      const fee = (INITIAL_TRANSFER_AMOUNT * BigInt(ESCROW_FEE)) / BigInt(ESCROW_FEE_DENOMINATOR);
      const amountAfterFee = INITIAL_TRANSFER_AMOUNT - fee;
      
      expect(totalAfter - totalBefore).to.equal(amountAfterFee);
    });
  });
});

