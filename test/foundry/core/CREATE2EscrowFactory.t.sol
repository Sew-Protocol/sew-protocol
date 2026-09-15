// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.37;

import 'forge-std/Test.sol';
import '../../../contracts/core/CREATE2EscrowFactory.sol';
import '../../../contracts/core/EscrowVault.sol';
import '../../../contracts/ops/YieldOps.sol';
import '../../../contracts/core/ModuleSnapshotRegistry.sol';

/// @notice Verifies CREATE2 derivation after the DisputeOps constructor argument
/// was removed: prediction, deployment, and detection must agree on the new
/// constructor encoding, and salt semantics must be unchanged.
contract CREATE2EscrowFactoryTest is Test {
    CREATE2EscrowFactory internal factory;
    YieldOps internal yieldOps;
    ModuleSnapshotRegistry internal registry;

    uint256 internal constant FEE_BPS = 100;
    address internal constant FEE_ADDR = address(0xFEE);

    function setUp() public {
        factory = new CREATE2EscrowFactory();
        yieldOps = new YieldOps(address(this));
        registry = new ModuleSnapshotRegistry(address(this));
    }

    function test_predictedAddress_matchesDeployedAddress() public {
        bytes32 salt = keccak256('sew.create2.test.1');
        address predicted = factory.getDeploymentAddress(
            FEE_BPS, FEE_ADDR, address(yieldOps), address(registry), salt
        );
        assertEq(predicted.code.length, 0, 'already deployed before deploy');

        EscrowVault deployed = factory.deployEscrow(
            FEE_BPS, FEE_ADDR, address(yieldOps), address(registry), salt
        );
        assertEq(address(deployed), predicted, 'deployed != predicted');
        assertGt(address(deployed).code.length, 0, 'no code');
    }

    function test_isDeployed_agreesWithPrediction() public {
        bytes32 salt = keccak256('sew.create2.test.2');
        assertFalse(
            factory.isDeployed(FEE_BPS, FEE_ADDR, address(yieldOps), address(registry), salt),
            'isDeployed before deploy'
        );

        address predicted = factory.getDeploymentAddress(
            FEE_BPS, FEE_ADDR, address(yieldOps), address(registry), salt
        );
        factory.deployEscrow(FEE_BPS, FEE_ADDR, address(yieldOps), address(registry), salt);

        assertTrue(
            factory.isDeployed(FEE_BPS, FEE_ADDR, address(yieldOps), address(registry), salt),
            'isDeployed after deploy'
        );
        assertEq(predicted, _deployedAddr(salt), 'prediction mismatch after deploy');
    }

    function _deployedAddr(bytes32 salt) internal view returns (address) {
        return factory.getDeploymentAddress(FEE_BPS, FEE_ADDR, address(yieldOps), address(registry), salt);
    }

    function test_sameSaltSameArgs_isDeterministic() public view {
        bytes32 salt = keccak256('sew.create2.determinism');
        address a = factory.getDeploymentAddress(FEE_BPS, FEE_ADDR, address(yieldOps), address(registry), salt);
        address b = factory.getDeploymentAddress(FEE_BPS, FEE_ADDR, address(yieldOps), address(registry), salt);
        assertEq(a, b, 'not deterministic');
    }

    function test_differentSalt_changesAddress() public view {
        address a = factory.getDeploymentAddress(
            FEE_BPS, FEE_ADDR, address(yieldOps), address(registry), keccak256('salt.a')
        );
        address b = factory.getDeploymentAddress(
            FEE_BPS, FEE_ADDR, address(yieldOps), address(registry), keccak256('salt.b')
        );
        assertNotEq(a, b, 'salt did not affect address');
    }

    function test_differentArgs_changesAddress() public view {
        bytes32 salt = keccak256('sew.create2.args');
        address a = factory.getDeploymentAddress(
            FEE_BPS, FEE_ADDR, address(yieldOps), address(registry), salt
        );
        address b = factory.getDeploymentAddress(
            FEE_BPS + 1, FEE_ADDR, address(yieldOps), address(registry), salt
        );
        assertNotEq(a, b, 'args did not affect address');
    }

    function test_redeploySameSalt_revertsAlreadyDeployed() public {
        bytes32 salt = keccak256('sew.create2.redeploy');
        address predicted = factory.getDeploymentAddress(
            FEE_BPS, FEE_ADDR, address(yieldOps), address(registry), salt
        );
        factory.deployEscrow(FEE_BPS, FEE_ADDR, address(yieldOps), address(registry), salt);
        vm.expectRevert(abi.encodeWithSelector(CREATE2EscrowFactory.AlreadyDeployed.selector, salt, predicted));
        factory.deployEscrow(FEE_BPS, FEE_ADDR, address(yieldOps), address(registry), salt);
    }
}
