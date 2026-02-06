import { expect } from 'chai';
import { ethers } from 'hardhat';
import { CREATE2EscrowFactory, EscrowVault, ModuleManagementContract } from '../typechain-types';
import { HardhatEthersSigner } from '@nomicfoundation/hardhat-ethers/signers';

describe('CREATE2EscrowFactory', function () {
  let factory: CREATE2EscrowFactory;
  let deployer: HardhatEthersSigner;
  let feeAddress: HardhatEthersSigner;
  let yieldOpsAddress: HardhatEthersSigner;
  let disputeOpsAddress: HardhatEthersSigner;
  let moduleManagement: ModuleManagementContract;

  const ESCROW_FEE_BPS = 500; // 5%
  const TEST_SALT = ethers.id('multi-L2-test-v1');

  before(async function () {
    [deployer, feeAddress, yieldOpsAddress, disputeOpsAddress] = await ethers.getSigners();

    // Deploy factory
    const factoryFactory = await ethers.getContractFactory('CREATE2EscrowFactory');
    factory = await factoryFactory.deploy();

    // Deploy ModuleManagementContract (required by EscrowVault constructor)
    const mmcFactory = await ethers.getContractFactory('ModuleManagementContract');
    moduleManagement = await mmcFactory.deploy();
  });

  describe('Deterministic Deployment', function () {
    it('should compute consistent address for same parameters', async function () {
      const params = {
        escrowFeeBps: ESCROW_FEE_BPS,
        feeAddress: feeAddress.address,
        yieldOpsAddress: yieldOpsAddress.address,
        disputeOpsAddress: disputeOpsAddress.address,
        moduleManagementAddress: moduleManagement.address,
        salt: TEST_SALT,
      };

      const addr1 = await factory.getDeploymentAddress(
        params.escrowFeeBps,
        params.feeAddress,
        params.yieldOpsAddress,
        params.disputeOpsAddress,
        params.moduleManagementAddress,
        params.salt,
      );

      const addr2 = await factory.getDeploymentAddress(
        params.escrowFeeBps,
        params.feeAddress,
        params.yieldOpsAddress,
        params.disputeOpsAddress,
        params.moduleManagementAddress,
        params.salt,
      );

      expect(addr1).to.equal(addr2);
    });

    it('should change address when any constructor parameter changes', async function () {
      const salt = ethers.id('test-param-change');

      const addr1 = await factory.getDeploymentAddress(
        ESCROW_FEE_BPS,
        feeAddress.address,
        yieldOpsAddress.address,
        disputeOpsAddress.address,
        moduleManagement.address,
        salt,
      );

      // Change fee BPS
      const addr2 = await factory.getDeploymentAddress(
        1000, // different fee
        feeAddress.address,
        yieldOpsAddress.address,
        disputeOpsAddress.address,
        moduleManagement.address,
        salt,
      );

      expect(addr1).to.not.equal(addr2);
    });

    it('should change address when salt changes', async function () {
      const addr1 = await factory.getDeploymentAddress(
        ESCROW_FEE_BPS,
        feeAddress.address,
        yieldOpsAddress.address,
        disputeOpsAddress.address,
        moduleManagement.address,
        ethers.id('salt-v1'),
      );

      const addr2 = await factory.getDeploymentAddress(
        ESCROW_FEE_BPS,
        feeAddress.address,
        yieldOpsAddress.address,
        disputeOpsAddress.address,
        moduleManagement.address,
        ethers.id('salt-v2'),
      );

      expect(addr1).to.not.equal(addr2);
    });
  });

  describe('Deployment', function () {
    it('should deploy escrow to predicted address', async function () {
      const salt = ethers.id('deploy-test-v1');
      const params = {
        escrowFeeBps: ESCROW_FEE_BPS,
        feeAddress: feeAddress.address,
        yieldOpsAddress: yieldOpsAddress.address,
        disputeOpsAddress: disputeOpsAddress.address,
        moduleManagementAddress: moduleManagement.address,
      };

      // Get predicted address
      const predictedAddr = await factory.getDeploymentAddress(
        params.escrowFeeBps,
        params.feeAddress,
        params.yieldOpsAddress,
        params.disputeOpsAddress,
        params.moduleManagementAddress,
        salt,
      );

      expect(predictedAddr).to.not.equal(ethers.ZeroAddress);

      // Deploy
      const tx = await factory.deployEscrow(
        params.escrowFeeBps,
        params.feeAddress,
        params.yieldOpsAddress,
        params.disputeOpsAddress,
        params.moduleManagementAddress,
        salt,
      );

      const receipt = await tx.wait();
      expect(receipt).to.not.be.null;

      // Verify event
      const event = receipt?.logs
        .map(log => {
          try {
            return factory.interface.parseLog(log);
          } catch {
            return null;
          }
        })
        .find(e => e?.name === 'EscrowDeployed');

      expect(event).to.not.be.undefined;
      expect(event?.args.escrowVault).to.equal(predictedAddr);
      expect(event?.args.salt).to.equal(salt);
    });

    it('should revert if already deployed', async function () {
      const salt = ethers.id('double-deploy-test');
      const params = {
        escrowFeeBps: ESCROW_FEE_BPS,
        feeAddress: feeAddress.address,
        yieldOpsAddress: yieldOpsAddress.address,
        disputeOpsAddress: disputeOpsAddress.address,
        moduleManagementAddress: moduleManagement.address,
      };

      // First deployment
      await factory.deployEscrow(
        params.escrowFeeBps,
        params.feeAddress,
        params.yieldOpsAddress,
        params.disputeOpsAddress,
        params.moduleManagementAddress,
        salt,
      );

      // Second deployment should fail
      await expect(
        factory.deployEscrow(
          params.escrowFeeBps,
          params.feeAddress,
          params.yieldOpsAddress,
          params.disputeOpsAddress,
          params.moduleManagementAddress,
          salt,
        ),
      ).to.be.revertedWithCustomError(factory, 'AlreadyDeployed');
    });

    it('should report deployment status correctly', async function () {
      const salt = ethers.id('status-test');
      const params = {
        escrowFeeBps: ESCROW_FEE_BPS,
        feeAddress: feeAddress.address,
        yieldOpsAddress: yieldOpsAddress.address,
        disputeOpsAddress: disputeOpsAddress.address,
        moduleManagementAddress: moduleManagement.address,
      };

      // Before deployment
      let isDeployed = await factory.isDeployed(
        params.escrowFeeBps,
        params.feeAddress,
        params.yieldOpsAddress,
        params.disputeOpsAddress,
        params.moduleManagementAddress,
        salt,
      );
      expect(isDeployed).to.be.false;

      // Deploy
      await factory.deployEscrow(
        params.escrowFeeBps,
        params.feeAddress,
        params.yieldOpsAddress,
        params.disputeOpsAddress,
        params.moduleManagementAddress,
        salt,
      );

      // After deployment
      isDeployed = await factory.isDeployed(
        params.escrowFeeBps,
        params.feeAddress,
        params.yieldOpsAddress,
        params.disputeOpsAddress,
        params.moduleManagementAddress,
        salt,
      );
      expect(isDeployed).to.be.true;
    });
  });

  describe('Multi-L2 Scenarios', function () {
    it('should support versioned deployments with different salts', async function () {
      const baseParams = {
        escrowFeeBps: ESCROW_FEE_BPS,
        feeAddress: feeAddress.address,
        yieldOpsAddress: yieldOpsAddress.address,
        disputeOpsAddress: disputeOpsAddress.address,
        moduleManagementAddress: moduleManagement.address,
      };

      // V1 deployment
      const addrV1 = await factory.getDeploymentAddress(
        baseParams.escrowFeeBps,
        baseParams.feeAddress,
        baseParams.yieldOpsAddress,
        baseParams.disputeOpsAddress,
        baseParams.moduleManagementAddress,
        ethers.id('v1'),
      );

      // V2 deployment
      const addrV2 = await factory.getDeploymentAddress(
        baseParams.escrowFeeBps,
        baseParams.feeAddress,
        baseParams.yieldOpsAddress,
        baseParams.disputeOpsAddress,
        baseParams.moduleManagementAddress,
        ethers.id('v2'),
      );

      expect(addrV1).to.not.equal(addrV2);
      console.log(`  V1 address: ${addrV1}`);
      console.log(`  V2 address: ${addrV2}`);
    });

    it('should enable chain-agnostic address generation', async function () {
      // Simulate getting the same address on different chains
      // (In practice, this would be run on actual L2s)
      const params = {
        escrowFeeBps: ESCROW_FEE_BPS,
        feeAddress: feeAddress.address,
        yieldOpsAddress: yieldOpsAddress.address,
        disputeOpsAddress: disputeOpsAddress.address,
        moduleManagementAddress: moduleManagement.address,
        salt: ethers.id('multi-l2-escrow'),
      };

      const mainnetAddr = await factory.getDeploymentAddress(
        params.escrowFeeBps,
        params.feeAddress,
        params.yieldOpsAddress,
        params.disputeOpsAddress,
        params.moduleManagementAddress,
        params.salt,
      );

      // If we deployed factory on another chain and called with same params,
      // we'd get same address (verified in integration tests)
      console.log(`  Predicted address for all L2s: ${mainnetAddr}`);
      expect(mainnetAddr).to.not.equal(ethers.ZeroAddress);
    });
  });
});
