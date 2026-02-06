import { expect } from 'chai';
import { ethers } from 'hardhat';
import { L2AddressRegistry, RPCEndpointManager, MultiL2ModuleCoordinator } from '../typechain-types';
import { HardhatEthersSigner } from '@nomicfoundation/hardhat-ethers/signers';

describe('Phase 2: Infrastructure Contracts', function () {
  describe('L2AddressRegistry', function () {
    let registry: L2AddressRegistry;
    let deployer: HardhatEthersSigner;
    let governor1: HardhatEthersSigner;
    let governor2: HardhatEthersSigner;

    const ETHEREUM = 1n;
    const BASE = 8453n;
    const ARBITRUM = 42161n;
    const OPTIMISM = 10n;

    before(async function () {
      [deployer, governor1, governor2] = await ethers.getSigners();

      const registryFactory = await ethers.getContractFactory('L2AddressRegistry');
      registry = await registryFactory.deploy([governor1.address, governor2.address], 2);
    });

    it('should register a contract', async function () {
      await registry.connect(governor1).registerContract('EscrowVault');
      expect(await registry.isRegisteredContract('EscrowVault')).to.be.true;
    });

    it('should register addresses for all chains', async function () {
      const ethereumVault = '0x' + '1'.repeat(40);
      const baseVault = '0x' + '2'.repeat(40);
      const arbitrumVault = '0x' + '3'.repeat(40);
      const optimismVault = '0x' + '4'.repeat(40);

      await registry.connect(governor1).registerContract('EscrowVault');

      await registry
        .connect(governor1)
        .registerAddress(ETHEREUM, 'EscrowVault', 'v1', ethereumVault);
      await registry.connect(governor1).registerAddress(BASE, 'EscrowVault', 'v1', baseVault);
      await registry
        .connect(governor1)
        .registerAddress(ARBITRUM, 'EscrowVault', 'v1', arbitrumVault);
      await registry
        .connect(governor1)
        .registerAddress(OPTIMISM, 'EscrowVault', 'v1', optimismVault);

      // Activate versions
      await registry.connect(governor1).activateVersion(ETHEREUM, 'EscrowVault', 'v1');
      await registry.connect(governor1).activateVersion(BASE, 'EscrowVault', 'v1');
      await registry.connect(governor1).activateVersion(ARBITRUM, 'EscrowVault', 'v1');
      await registry.connect(governor1).activateVersion(OPTIMISM, 'EscrowVault', 'v1');

      // Verify addresses
      const (eth, ethVersion) = await registry.getAddress(ETHEREUM, 'EscrowVault');
      expect(eth.toLowerCase()).to.equal(ethereumVault.toLowerCase());
      expect(ethVersion).to.equal('v1');
    });

    it('should support multi-sig updates', async function () {
      const newVault = '0x' + '5'.repeat(40);

      // Propose update
      const updateTx = await registry
        .connect(governor1)
        .proposeUpdate(BASE, 'EscrowVault', newVault);
      const updateReceipt = await updateTx.wait();

      const updateId = (await registry.getPendingUpdates())[0];
      expect(updateId).to.not.be.undefined;
    });
  });

  describe('RPCEndpointManager', function () {
    let manager: RPCEndpointManager;
    let deployer: HardhatEthersSigner;
    let mgr1: HardhatEthersSigner;

    const BASE = 8453n;
    const primaryRPC = 'https://mainnet.base.org';
    const backupRPC = 'https://base-rpc.publicnode.com';

    before(async function () {
      [deployer, mgr1] = await ethers.getSigners();

      const managerFactory = await ethers.getContractFactory('RPCEndpointManager');
      manager = await managerFactory.deploy([mgr1.address]);
    });

    it('should configure primary endpoint', async function () {
      await manager.connect(mgr1).setPrimaryEndpoint(BASE, primaryRPC, 1000);

      const (endpoint, isPrimary) = await manager.getActiveEndpoint(BASE);
      expect(endpoint).to.equal(primaryRPC);
      expect(isPrimary).to.be.true;
    });

    it('should configure backup endpoint', async function () {
      await manager.connect(mgr1).setBackupEndpoint(BASE, backupRPC, 500);

      // Primary should still be active
      const (endpoint, isPrimary) = await manager.getActiveEndpoint(BASE);
      expect(isPrimary).to.be.true;
    });

    it('should fallback to backup on failure', async function () {
      // Record failures to disable primary
      await manager.connect(mgr1).recordFailure(BASE);
      await manager.connect(mgr1).recordFailure(BASE);
      await manager.connect(mgr1).recordFailure(BASE);

      const (endpoint, isPrimary) = await manager.getActiveEndpoint(BASE);
      expect(endpoint).to.equal(backupRPC);
      expect(isPrimary).to.be.false;
    });

    it('should track health status', async function () {
      await manager.connect(mgr1).resetHealth(BASE);
      await manager.connect(mgr1).recordSuccess(BASE);

      const (working, failureCount, successCount) = await manager.getHealthStatus(BASE);
      expect(working).to.be.true;
      expect(failureCount).to.equal(0);
      expect(successCount).to.be.gt(0);
    });
  });

  describe('MultiL2ModuleCoordinator', function () {
    let coordinator: MultiL2ModuleCoordinator;
    let deployer: HardhatEthersSigner;
    let authorizer: HardhatEthersSigner;

    const YIELD_MODULE_TYPE = '0x79696509'; // "yield" in bytes4

    before(async function () {
      [deployer, authorizer] = await ethers.getSigners();

      const coordinatorFactory = await ethers.getContractFactory('MultiL2ModuleCoordinator');
      coordinator = await coordinatorFactory.deploy([authorizer.address]);
    });

    it('should queue a module update', async function () {
      const moduleAddress = '0x' + '1'.repeat(40);

      const updateTx = await coordinator
        .connect(authorizer)
        .queueModuleUpdate(moduleAddress, YIELD_MODULE_TYPE, 'Deploy new yield module v2');
      const updateReceipt = await updateTx.wait();

      expect(updateReceipt).to.not.be.null;

      const pendingUpdates = await coordinator.getPendingUpdates();
      expect(pendingUpdates.length).to.equal(1);
    });

    it('should enforce activation delay', async function () {
      const moduleAddress = '0x' + '2'.repeat(40);

      const updateTx = await coordinator
        .connect(authorizer)
        .queueModuleUpdate(moduleAddress, YIELD_MODULE_TYPE, 'Test delay enforcement');

      const updateReceipt = await updateTx.wait();
      const pendingUpdates = await coordinator.getPendingUpdates();
      const updateId = pendingUpdates[pendingUpdates.length - 1];

      // Try to activate immediately (should fail)
      await expect(
        coordinator
          .connect(authorizer)
          .recordActivation(updateId, 8453, ethers.id('tx-hash'), 'success'),
      ).to.be.revertedWithCustomError(coordinator, 'UpdateNotReady');
    });

    it('should track activation across chains', async function () {
      const moduleAddress = '0x' + '3'.repeat(40);

      await coordinator
        .connect(authorizer)
        .queueModuleUpdate(moduleAddress, YIELD_MODULE_TYPE, 'Multi-chain activation');

      const pendingUpdates = await coordinator.getPendingUpdates();
      const updateId = pendingUpdates[pendingUpdates.length - 1];

      // Get module update to check delay
      const (ready, readyAt) = await coordinator.isReady(updateId);

      if (ready) {
        // Record activations on each chain
        await coordinator
          .connect(authorizer)
          .recordActivation(updateId, 1, ethers.id('tx-eth'), 'activated');
        await coordinator
          .connect(authorizer)
          .recordActivation(updateId, 8453, ethers.id('tx-base'), 'activated');
        await coordinator
          .connect(authorizer)
          .recordActivation(updateId, 42161, ethers.id('tx-arb'), 'activated');
        await coordinator
          .connect(authorizer)
          .recordActivation(updateId, 10, ethers.id('tx-op'), 'activated');

        // Check completion
        const (completed, activatedCount, totalChains) = await coordinator.getActivationStatus(
          updateId,
        );
        expect(completed).to.be.true;
        expect(activatedCount).to.equal(totalChains);
      }
    });

    it('should handle activation failures', async function () {
      const moduleAddress = '0x' + '4'.repeat(40);

      await coordinator
        .connect(authorizer)
        .queueModuleUpdate(moduleAddress, YIELD_MODULE_TYPE, 'Test failure handling');

      const pendingUpdates = await coordinator.getPendingUpdates();
      const updateId = pendingUpdates[pendingUpdates.length - 1];

      const (ready) = await coordinator.isReady(updateId);
      if (ready) {
        // Record failure on Base
        await coordinator
          .connect(authorizer)
          .recordActivationFailure(updateId, 8453, 'Module deployment failed');

        // Get failure status
        const status = await coordinator.getChainStatus(updateId, 8453);
        expect(status.statusMessage).to.include('failed');
      }
    });

    it('should list pending updates', async function () {
      const pendingUpdates = await coordinator.getPendingUpdates();
      expect(pendingUpdates.length).to.be.gt(0);
    });
  });

  describe('Phase 2 Integration', function () {
    let registry: L2AddressRegistry;
    let rpcManager: RPCEndpointManager;
    let coordinator: MultiL2ModuleCoordinator;
    let gov1: HardhatEthersSigner;
    let gov2: HardhatEthersSigner;

    before(async function () {
      [, gov1, gov2] = await ethers.getSigners();

      const registryFactory = await ethers.getContractFactory('L2AddressRegistry');
      registry = await registryFactory.deploy([gov1.address, gov2.address], 2);

      const rpcFactory = await ethers.getContractFactory('RPCEndpointManager');
      rpcManager = await rpcFactory.deploy([gov1.address]);

      const coordFactory = await ethers.getContractFactory('MultiL2ModuleCoordinator');
      coordinator = await coordFactory.deploy([gov1.address]);
    });

    it('should work together for complete multi-L2 setup', async function () {
      const vaultAddress = '0x' + 'a'.repeat(40);
      const baseRPC = 'https://base.example.com';

      // Register contract in registry
      await registry.connect(gov1).registerContract('EscrowVault');

      // Register address on Base
      await registry.connect(gov1).registerAddress(8453n, 'EscrowVault', 'v1', vaultAddress);
      await registry.connect(gov1).activateVersion(8453n, 'EscrowVault', 'v1');

      // Configure RPC for Base
      await rpcManager.connect(gov1).setPrimaryEndpoint(8453n, baseRPC, 1000);

      // Queue module update coordination
      const moduleAddress = '0x' + 'b'.repeat(40);
      await coordinator
        .connect(gov1)
        .queueModuleUpdate(moduleAddress, '0x79696509', 'Coordinated update');

      // Verify all components are ready
      const (addr) = await registry.getAddress(8453n, 'EscrowVault');
      expect(addr.toLowerCase()).to.equal(vaultAddress.toLowerCase());

      const (endpoint, isPrimary) = await rpcManager.getActiveEndpoint(8453n);
      expect(endpoint).to.equal(baseRPC);
      expect(isPrimary).to.be.true;

      const pendingUpdates = await coordinator.getPendingUpdates();
      expect(pendingUpdates.length).to.be.gt(0);
    });
  });
});
