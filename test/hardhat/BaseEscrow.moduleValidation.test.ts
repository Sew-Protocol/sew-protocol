before(function () {
  this.skip();
}); // Migrated to Forge: test/foundry/migrated/BaseEscrow.moduleValidation.test.t.sol
/**
 * BaseEscrow Module Validation Tests
 *
 * Tests for module validation and interface detection in BaseEscrow:
 * - Module interface validation on registration
 * - Interface detection using ERC-165
 * - Version compatibility checks
 * - Backward compatibility
 */

import { expect } from 'chai';
import { ethers } from 'hardhat';
import { time } from '@nomicfoundation/hardhat-network-helpers';
import {
  EscrowableERC20,
  DecentralizedResolutionModule,
  DefaultResolutionModule,
  IResolutionModule,
} from '../../typechain-types';
import { SignerWithAddress } from '@nomicfoundation/hardhat-ethers/signers';

describe('BaseEscrow Module Validation', function () {
  let escrowableERC20: EscrowableERC20;
  let decentralizedModule: DecentralizedResolutionModule;
  let defaultModule: DefaultResolutionModule;
  let deployer: SignerWithAddress;
  let timelock: SignerWithAddress;
  let resolver: SignerWithAddress;
  let standardResolver: SignerWithAddress;
  let sender: SignerWithAddress;
  let recipient: SignerWithAddress;
  let feeAddress: SignerWithAddress;

  const ESCROW_FEE = 100;
  const INITIAL_TRANSFER_AMOUNT = ethers.parseEther('1');

  beforeEach(async function () {
    [deployer, timelock, resolver, standardResolver, sender, recipient, feeAddress] =
      await ethers.getSigners();

    // Deploy EscrowableERC20
    const EscrowableFactory = await ethers.getContractFactory('EscrowableERC20');
    escrowableERC20 = await EscrowableFactory.deploy(
      'Test Token',
      'TEST',
      ESCROW_FEE,
      feeAddress.address,
      ethers.ZeroAddress,
      ethers.ZeroAddress,
    );
    await escrowableERC20.waitForDeployment();

    // Grant ROLE_TIMELOCK
    const ROLE_TIMELOCK = await escrowableERC20.ROLE_TIMELOCK();
    await escrowableERC20.grantRole(ROLE_TIMELOCK, timelock.address);

    // Deploy DecentralizedResolutionModule
    const DecentralizedFactory = await ethers.getContractFactory('DecentralizedResolutionModule');
    decentralizedModule = await DecentralizedFactory.deploy();
    await decentralizedModule.waitForDeployment();
    await decentralizedModule.initialize(deployer.address);

    // Deploy DefaultResolutionModule
    const DefaultFactory = await ethers.getContractFactory('DefaultResolutionModule');
    defaultModule = await DefaultFactory.deploy(deployer.address, resolver.address);
    await defaultModule.waitForDeployment();

    // Set resolution module delay to minimum (2 days) for testing
    // Note: Can't set to 0 due to validation constraints
    await escrowableERC20.connect(timelock).setResolutionModuleDelay(172800); // 2 days

    // EscrowableERC20 uses defaultResolutionModule, not resolutionModule
    // Set it up using the helper pattern
    const TempDefaultFactory = await ethers.getContractFactory('DefaultResolutionModule');
    const tempDefaultModule = await TempDefaultFactory.deploy(deployer.address, resolver.address);
    await tempDefaultModule.waitForDeployment();

    // Queue and activate default resolution module
    // EscrowableERC20 uses consolidated module management functions
    // ModuleType.RESOLUTION = 0
    await escrowableERC20
      .connect(timelock)
      .queueModule(0, await tempDefaultModule.getAddress()); // RESOLUTION
    const [, eta] = await escrowableERC20.getPendingModule(0); // RESOLUTION
    await time.increaseTo(Number(eta) + 1);
    await escrowableERC20.connect(timelock).activateModule(0); // RESOLUTION
  });

  describe('Module Interface Validation', function () {
    it('Should accept valid IResolutionModule when queueing', async function () {
      // Queue valid module (EscrowableERC20 uses consolidated queueModule)
      // ModuleType.RESOLUTION = 0
      await expect(
        escrowableERC20
          .connect(timelock)
          .queueModule(0, await decentralizedModule.getAddress()), // RESOLUTION
      ).to.emit(escrowableERC20, 'DefaultResolutionModuleQueued');

      // Verify module supports IResolutionModule interface
      const interfaceId = await getIResolutionModuleInterfaceId();
      const supports = await decentralizedModule.supportsInterface(interfaceId);
      expect(supports).to.be.true;
    });

    it('Should accept DefaultResolutionModule when queueing', async function () {
      await expect(
        escrowableERC20
          .connect(timelock)
          .queueModule(0, await defaultModule.getAddress()), // RESOLUTION
      ).to.emit(escrowableERC20, 'DefaultResolutionModuleQueued');

      const interfaceId = await getIResolutionModuleInterfaceId();
      const supports = await defaultModule.supportsInterface(interfaceId);
      expect(supports).to.be.true;
    });

    it('Should activate valid module after delay', async function () {
      // Queue module (EscrowableERC20 uses consolidated queueModule)
      await escrowableERC20
        .connect(timelock)
        .queueModule(0, await decentralizedModule.getAddress()); // RESOLUTION

      // Fast-forward time to pass delay (7 days default)
      const [, eta] = await escrowableERC20.getPendingModule(0); // RESOLUTION
      await time.increaseTo(Number(eta) + 1);

      // Activate after delay
      await expect(escrowableERC20.connect(timelock).activateModule(0)).to.emit( // RESOLUTION
        escrowableERC20,
        'DefaultResolutionModuleActivated',
      );

      // Verify module is active
      const activeModule = await escrowableERC20.defaultDisputeResolutionModule();
      expect(activeModule).to.equal(await decentralizedModule.getAddress());
    });

    it('Should reject activation before delay expires', async function () {
      // Queue module (EscrowableERC20 uses consolidated queueModule)
      // ModuleType.RESOLUTION = 0
      await escrowableERC20
        .connect(timelock)
        .queueModule(0, await decentralizedModule.getAddress()); // RESOLUTION

      // Try to activate immediately (should fail - 7 day delay)
      await expect(
        escrowableERC20.connect(timelock).activateModule(0), // RESOLUTION
      ).to.be.revertedWithCustomError(escrowableERC20, 'NotReady');
    });
  });

  describe('Module Metadata Detection', function () {
    it('Should detect module name from active module', async function () {
      // Activate module
      await escrowableERC20
        .connect(timelock)
        .queueModule(0, await decentralizedModule.getAddress()); // RESOLUTION
      const [, eta] = await escrowableERC20.getPendingModule(0); // RESOLUTION
      await time.increaseTo(Number(eta) + 1);
      await escrowableERC20.connect(timelock).activateModule(0); // RESOLUTION

      // Get module name
      const moduleName = await decentralizedModule.moduleName();
      expect(moduleName).to.equal('DecentralizedResolution');
    });

    it('Should detect module version from active module', async function () {
      // Activate module
      await escrowableERC20
        .connect(timelock)
        .queueModule(0, await decentralizedModule.getAddress()); // RESOLUTION
      const [, eta] = await escrowableERC20.getPendingModule(0); // RESOLUTION
      await time.increaseTo(Number(eta) + 1);
      await escrowableERC20.connect(timelock).activateModule(0); // RESOLUTION

      // Get module version
      const version = await decentralizedModule.moduleVersion();
      expect(version).to.match(/^\d+\.\d+\.\d+$/); // Semantic version format
      expect(version).to.equal('1.0.0');
    });

    it('Should detect ERC-165 support from active module', async function () {
      // Activate module
      await escrowableERC20
        .connect(timelock)
        .queueModule(0, await decentralizedModule.getAddress()); // RESOLUTION
      const [, eta] = await escrowableERC20.getPendingModule(0); // RESOLUTION
      await time.increaseTo(Number(eta) + 1);
      await escrowableERC20.connect(timelock).activateModule(0); // RESOLUTION

      // Check ERC-165 support
      const erc165Id = '0x01ffc9a7';
      const supports = await decentralizedModule.supportsInterface(erc165Id);
      expect(supports).to.be.true;
    });
  });

  describe('Module Functionality Integration', function () {
    beforeEach(async function () {
      // Activate DecentralizedResolutionModule
      await escrowableERC20
        .connect(timelock)
        .queueModule(0, await decentralizedModule.getAddress()); // RESOLUTION

      // Fast-forward time to pass delay
      const [, eta] = await escrowableERC20.getPendingModule(0); // RESOLUTION
      await time.increaseTo(Number(eta) + 1);
      await escrowableERC20.connect(timelock).activateModule(0); // RESOLUTION

      // Register escrow contract in module
      const ROLE_TIMELOCK = await decentralizedModule.ROLE_TIMELOCK();
      await decentralizedModule.grantRole(ROLE_TIMELOCK, timelock.address);
      await decentralizedModule
        .connect(timelock)
        .registerEscrowContract(await escrowableERC20.getAddress());

      // Appoint a senior resolver
      await decentralizedModule
        .connect(timelock)
        .appointSeniorResolver(
          resolver.address,
          'Test Senior Resolver',
          'Senior resolver for integration tests',
        );

      // Appoint a standard resolver (so they appear in approvedResolvers list)
      // Senior resolvers can appoint standard resolvers
      await decentralizedModule
        .connect(resolver)
        .appointResolver(
          standardResolver.address,
          'Standard Resolver',
          'Standard resolver for testing',
        );

      // Set up a default resolution table entry so getResolver works
      const defaultCategory = ethers.keccak256(ethers.toUtf8Bytes('default'));
      const ResolutionTableEntry = {
        initialResolver: standardResolver.address,
        maxEscalationLevel: 2,
        escalationFee: 0,
        enabled: true,
        categoryName: 'default',
      };
      await decentralizedModule
        .connect(timelock)
        .setResolutionTableEntry(defaultCategory, ResolutionTableEntry);
    });

    it('Should use module to get resolver for new escrow', async function () {
      // Transfer tokens
      await escrowableERC20.transfer(sender.address, INITIAL_TRANSFER_AMOUNT);

      // Create escrow
      const tx = await escrowableERC20
        .connect(sender)
        .getFunction('createEscrow(address,uint256)')
        .send(recipient.address, INITIAL_TRANSFER_AMOUNT);
      const receipt = await tx.wait();

      // Get workflow ID from event
      const workflowId = 0;

      // Verify module was used to get resolver
      const activeModule = await escrowableERC20.defaultDisputeResolutionModule();
      expect(activeModule).to.equal(await decentralizedModule.getAddress());

      // Check that resolver was set (should be standardResolver from resolution table)
      const escrowTransfer = await escrowableERC20.escrowTransfers(workflowId);
      expect(escrowTransfer.disputeResolver).to.equal(standardResolver.address);
    });

    it('Should use module for dispute resolution', async function () {
      // Transfer tokens and create escrow
      await escrowableERC20.transfer(sender.address, INITIAL_TRANSFER_AMOUNT);
      const tx = await escrowableERC20
        .connect(sender)
        .getFunction('createEscrow(address,uint256)')
        .send(recipient.address, INITIAL_TRANSFER_AMOUNT);
      await tx.wait();
      const workflowId = 0;

      // Raise dispute
      await escrowableERC20.connect(sender).raiseDispute(workflowId);

      // Verify module is used for authorization
      const escrowTransfer = await escrowableERC20.escrowTransfers(workflowId);
      const escrowData = encodeEscrowData(
        escrowTransfer.token,
        escrowTransfer.from,
        escrowTransfer.to,
        escrowTransfer.remainingBalance,
        escrowTransfer.totalDeposited,
      );

      const [authorized] = await decentralizedModule.isAuthorizedDisputeResolver(
        workflowId,
        resolver.address,
        escrowData,
      );
      expect(authorized).to.be.true;
    });
  });

  describe('Backward Compatibility', function () {
    it("Should work with old modules that don't have metadata functions", async function () {
      // This test ensures backward compatibility
      // If we have an old module without moduleVersion(), it should still work
      // (Note: This is a theoretical test - all current modules have metadata)

      // Activate module
      await escrowableERC20
        .connect(timelock)
        .queueModule(0, await defaultModule.getAddress()); // RESOLUTION
      const [, eta] = await escrowableERC20.getPendingModule(0); // RESOLUTION
      await time.increaseTo(Number(eta) + 1);
      await escrowableERC20.connect(timelock).activateModule(0); // RESOLUTION

      // Module should still work even if we check metadata
      const moduleName = await defaultModule.moduleName();
      expect(moduleName).to.equal('DefaultSingleResolver');
    });

    it('Should handle module upgrade without breaking existing escrows', async function () {
      // Create escrow with first module
      await escrowableERC20
        .connect(timelock)
        .proposeResolutionModule(await defaultModule.getAddress());
      let eta = await escrowableERC20.pendingDisputeResolutionModuleEta();
      await time.increaseTo(Number(eta) + 1);
      await escrowableERC20.connect(timelock).activateResolutionModule();

      await escrowableERC20.transfer(sender.address, INITIAL_TRANSFER_AMOUNT);
      const tx = await escrowableERC20
        .connect(sender)
        .getFunction('createEscrow(address,uint256)')
        .send(recipient.address, INITIAL_TRANSFER_AMOUNT);
      await tx.wait();
      const workflowId = 0;

      // Get resolver from first module
      const escrowTransfer1 = await escrowableERC20.escrowTransfers(workflowId);
      const resolver1 = escrowTransfer1.disputeResolver;

      // Upgrade to new module
      await escrowableERC20
        .connect(timelock)
        .queueModule(0, await decentralizedModule.getAddress()); // RESOLUTION
      [, eta] = await escrowableERC20.getPendingModule(0); // RESOLUTION
      await time.increaseTo(Number(eta) + 1);
      await escrowableERC20.connect(timelock).activateModule(0); // RESOLUTION

      // Existing escrow should still use old resolver
      const escrowTransfer2 = await escrowableERC20.escrowTransfers(workflowId);
      expect(escrowTransfer2.disputeResolver).to.equal(resolver1);
    });
  });

  describe('Version Compatibility', function () {
    it('Should detect module version for compatibility checking', async function () {
      // Activate module
      await escrowableERC20
        .connect(timelock)
        .queueModule(0, await decentralizedModule.getAddress()); // RESOLUTION
      const [, eta] = await escrowableERC20.getPendingModule(0); // RESOLUTION
      await time.increaseTo(Number(eta) + 1);
      await escrowableERC20.connect(timelock).activateModule(0); // RESOLUTION

      // Get version
      const version = await decentralizedModule.moduleVersion();
      const [major, minor, patch] = version.split('.').map(Number);

      // Verify semantic versioning format
      expect(major).to.be.a('number');
      expect(minor).to.be.a('number');
      expect(patch).to.be.a('number');
      expect(major).to.be.greaterThanOrEqual(0);
    });

    it('Should allow version checking before activation', async function () {
      // Check version before proposing
      const version = await decentralizedModule.moduleVersion();
      expect(version).to.equal('1.0.0');

      // Queue and activate
      await escrowableERC20
        .connect(timelock)
        .queueModule(0, await decentralizedModule.getAddress()); // RESOLUTION
      const [, eta] = await escrowableERC20.getPendingModule(0); // RESOLUTION
      await time.increaseTo(Number(eta) + 1);
      await escrowableERC20.connect(timelock).activateModule(0); // RESOLUTION

      // Version should remain the same
      const versionAfter = await decentralizedModule.moduleVersion();
      expect(versionAfter).to.equal(version);
    });
  });

  // Helper function to calculate IResolutionModule interface ID
  async function getIResolutionModuleInterfaceId(): Promise<string> {
    // Calculate interface ID from function selectors (XOR of all function selectors)
    const isAuthorizedSelector = ethers
      .id('isAuthorizedDisputeResolver(uint256,address,bytes)')
      .slice(0, 10);
    const getDisputeResolverSelector = ethers.id('getDisputeResolver(uint256,bytes)').slice(0, 10);
    const canEscalateSelector = ethers.id('canEscalate(uint256,uint8,bytes)').slice(0, 10);
    const executeEscalationSelector = ethers.id('executeEscalation(uint256,bytes)').slice(0, 10);
    const moduleNameSelector = ethers.id('moduleName()').slice(0, 10);
    const moduleVersionSelector = ethers.id('moduleVersion()').slice(0, 10);

    let calculatedInterfaceId = BigInt(0);
    for (const selector of [
      isAuthorizedSelector,
      getDisputeResolverSelector,
      canEscalateSelector,
      executeEscalationSelector,
      moduleNameSelector,
      moduleVersionSelector,
    ]) {
      calculatedInterfaceId = calculatedInterfaceId ^ BigInt(selector);
    }
    return ethers.toBeHex(calculatedInterfaceId, 4);
  }

  // Helper function to encode escrow data
  function encodeEscrowData(
    token: string,
    from: string,
    to: string,
    amount: bigint,
    originalAmount: bigint,
  ): string {
    // Simple encoding - in production this would match EscrowEncodingLibrary
    return ethers.AbiCoder.defaultAbiCoder().encode(
      ['address', 'address', 'address', 'uint256', 'uint256'],
      [token, from, to, amount, originalAmount],
    );
  }
});
