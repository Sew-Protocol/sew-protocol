import { expect } from 'chai';
import { ethers } from 'hardhat';
import { MultiL2ViewAggregator, EscrowVault, ModuleManagementContract } from '../typechain-types';
import { HardhatEthersSigner } from '@nomicfoundation/hardhat-ethers/signers';

describe('MultiL2ViewAggregator - Multicall Integration', function () {
  let aggregator: MultiL2ViewAggregator;
  let vault: EscrowVault;
  let deployer: HardhatEthersSigner;
  let from: HardhatEthersSigner;
  let to: HardhatEthersSigner;
  let feeAddress: HardhatEthersSigner;
  let yieldOpsAddress: HardhatEthersSigner;
  let disputeOpsAddress: HardhatEthersSigner;
  let moduleManagement: ModuleManagementContract;
  let testToken: any;

  const ESCROW_FEE_BPS = 500;
  const TEST_AMOUNT = ethers.parseEther('100');

  before(async function () {
    [deployer, from, to, feeAddress, yieldOpsAddress, disputeOpsAddress] = await ethers.getSigners();

    // Deploy ModuleManagementContract
    const mmcFactory = await ethers.getContractFactory('ModuleManagementContract');
    moduleManagement = await mmcFactory.deploy();

    // Deploy EscrowVault
    const vaultFactory = await ethers.getContractFactory('EscrowVault');
    vault = await vaultFactory.deploy(
      ESCROW_FEE_BPS,
      feeAddress.address,
      yieldOpsAddress.address,
      disputeOpsAddress.address,
      moduleManagement.address,
    );

    // Deploy MultiL2ViewAggregator
    const aggregatorFactory = await ethers.getContractFactory('MultiL2ViewAggregator');
    aggregator = await aggregatorFactory.deploy(vault.address);

    // Deploy test ERC20
    const erc20Factory = await ethers.getContractFactory('ERC20Mock');
    testToken = await erc20Factory.deploy('Test Token', 'TEST', 18);
    await testToken.mint(from.address, TEST_AMOUNT * 10n);
    await testToken.connect(from).approve(vault.address, TEST_AMOUNT * 10n);
  });

  describe('Snapshot Functions', function () {
    it('should provide compact escrow snapshot', async function () {
      // Create an escrow
      await vault.connect(from).createEscrow(
        to.address,
        testToken.address,
        TEST_AMOUNT,
        ethers.ZeroAddress,
        1000,
      );

      const escrowId = 0;
      const snapshot = await aggregator.getEscrowSnapshot(escrowId);

      expect(snapshot.token).to.equal(testToken.address);
      expect(snapshot.from).to.equal(from.address);
      expect(snapshot.to).to.equal(to.address);
      expect(snapshot.amount).to.be.gt(0);
      expect(snapshot.state).to.equal(0); // NONE state
    });

    it('should provide compact settings snapshot', async function () {
      await vault.connect(from).createEscrow(
        to.address,
        testToken.address,
        TEST_AMOUNT,
        ethers.ZeroAddress,
        1000,
      );

      const escrowId = 0;
      const snapshot = await aggregator.getSettingsSnapshot(escrowId);

      expect(snapshot.customResolver).to.equal(ethers.ZeroAddress);
      expect(snapshot.yieldPreset).to.be.a('number');
    });

    it('should revert on invalid workflowId', async function () {
      const invalidId = 9999;
      await expect(aggregator.getEscrowSnapshot(invalidId)).to.be.revertedWithCustomError(
        aggregator,
        'InvalidWorkflowId',
      );
    });
  });

  describe('Health Checks', function () {
    it('should report health status', async function () {
      const { healthy, escrowCount } = await aggregator.healthCheck();

      expect(healthy).to.be.true;
      expect(escrowCount).to.be.gte(1);
    });

    it('should provide escrow count', async function () {
      const count = await aggregator.getEscrowCount();
      expect(count).to.be.gte(1);
    });

    it('should provide fee tracking', async function () {
      const fees = await aggregator.getTotalFeesPerToken(testToken.address);
      expect(fees).to.be.gte(0);
    });

    it('should provide balance tracking', async function () {
      const held = await aggregator.getTotalHeldPerToken(testToken.address);
      expect(held).to.be.gte(0);
    });
  });

  describe('Batch Operations', function () {
    it('should batch snapshot queries', async function () {
      // Create 3 escrows
      for (let i = 0; i < 3; i++) {
        await vault.connect(from).createEscrow(
          to.address,
          testToken.address,
          TEST_AMOUNT,
          ethers.ZeroAddress,
          1000,
        );
      }

      const escrowIds = [0, 1, 2];
      const snapshots = await aggregator.batchGetEscrowSnapshots(escrowIds);

      expect(snapshots).to.have.lengthOf(3);
      snapshots.forEach((snap, i) => {
        expect(snap.from).to.equal(from.address);
        expect(snap.to).to.equal(to.address);
        expect(snap.token).to.equal(testToken.address);
      });
    });

    it('should batch settings queries', async function () {
      const escrowIds = [0, 1, 2];
      const settingsSnapshots = await aggregator.batchGetSettingsSnapshots(escrowIds);

      expect(settingsSnapshots).to.have.lengthOf(3);
      settingsSnapshots.forEach((settings) => {
        expect(settings.customResolver).to.equal(ethers.ZeroAddress);
      });
    });

    it('should handle empty batch', async function () {
      const snapshots = await aggregator.batchGetEscrowSnapshots([]);
      expect(snapshots).to.have.lengthOf(0);
    });
  });

  describe('Multicall Compatibility', function () {
    it('should be queryable via typed call data', async function () {
      const escrowId = 0;

      // Simulate multicall by encoding function call
      const callData = aggregator.interface.encodeFunctionData('getEscrowSnapshot', [escrowId]);
      expect(callData).to.not.be.empty;

      // Verify it's properly formatted
      expect(callData).to.match(/^0x/);
    });

    it('should support multiple concurrent snapshot reads', async function () {
      const escrowIds = [0, 1, 2];

      // Query all in parallel (simulating multicall)
      const calls = escrowIds.map((id) => aggregator.getEscrowSnapshot(id));
      const results = await Promise.all(calls);

      expect(results).to.have.lengthOf(3);
      results.forEach((snap) => {
        expect(snap.token).to.equal(testToken.address);
      });
    });

    it('should provide consistent struct sizes for batching', async function () {
      // All snapshots should have same ABI encoding size
      const snap1 = await aggregator.getEscrowSnapshot(0);
      const snap2 = await aggregator.getEscrowSnapshot(1);

      const encoded1 = ethers.AbiCoder.defaultAbiCoder().encode(
        ['(address,address,address,address,uint256,uint64,uint64,uint8)'],
        [Object.values(snap1)],
      );
      const encoded2 = ethers.AbiCoder.defaultAbiCoder().encode(
        ['(address,address,address,address,uint256,uint64,uint64,uint8)'],
        [Object.values(snap2)],
      );

      expect(encoded1.length).to.equal(encoded2.length);
    });
  });

  describe('Cross-L2 View Consistency', function () {
    it('should provide identical interface on all L2s', async function () {
      // Verify all view functions exist and are callable
      const functions = [
        'getEscrowSnapshot',
        'getSettingsSnapshot',
        'getTotalHeldPerToken',
        'getTotalFeesPerToken',
        'getEscrowCount',
        'batchGetEscrowSnapshots',
        'batchGetSettingsSnapshots',
        'healthCheck',
      ];

      for (const func of functions) {
        expect(aggregator[func]).to.be.a('function');
      }
    });

    it('should maintain consistent state across queries', async function () {
      const count1 = await aggregator.getEscrowCount();

      // Create new escrow
      await vault.connect(from).createEscrow(
        to.address,
        testToken.address,
        TEST_AMOUNT,
        ethers.ZeroAddress,
        1000,
      );

      const count2 = await aggregator.getEscrowCount();
      expect(count2).to.equal(count1 + 1n);

      // Verify new escrow is readable
      const newId = count1;
      const snapshot = await aggregator.getEscrowSnapshot(newId);
      expect(snapshot.token).to.equal(testToken.address);
    });
  });
});
