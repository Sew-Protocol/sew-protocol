// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import '@openzeppelin/contracts/utils/Create2.sol';
import './EscrowVault.sol';

/**
 * @title CREATE2EscrowFactory
 * @notice Factory for deploying EscrowVault with deterministic addresses
 * @dev Uses CREATE2 to ensure same contract address across all L2s with identical salt
 */
contract CREATE2EscrowFactory {
    event EscrowDeployed(
        address indexed escrowVault,
        bytes32 salt,
        uint256 escrowFeeBps,
        address feeAddress
    );

    error DeploymentFailed(bytes32 salt);
    error AlreadyDeployed(bytes32 salt, address existing);

    /// @notice Get the address where an escrow will be deployed
    function getDeploymentAddress(
        uint256 escrowFeeBps,
        address feeAddress,
        address yieldOpsAddress,
        address disputeOpsAddress,
        address moduleManagementAddress,
        bytes32 salt
    ) external view returns (address predictedAddress) {
        bytes memory bytecode = abi.encodePacked(
            type(EscrowVault).creationCode,
            abi.encode(
                escrowFeeBps,
                feeAddress,
                yieldOpsAddress,
                disputeOpsAddress,
                moduleManagementAddress
            )
        );
        predictedAddress = Create2.computeAddress(salt, keccak256(bytecode));
    }

    /// @notice Deploy EscrowVault to deterministic address
    function deployEscrow(
        uint256 escrowFeeBps,
        address feeAddress,
        address yieldOpsAddress,
        address disputeOpsAddress,
        address moduleManagementAddress,
        bytes32 salt
    ) external returns (EscrowVault escrowVault) {
        bytes memory constructorArgs = abi.encode(
            escrowFeeBps,
            feeAddress,
            yieldOpsAddress,
            disputeOpsAddress,
            moduleManagementAddress
        );

        bytes memory bytecode = abi.encodePacked(
            type(EscrowVault).creationCode,
            constructorArgs
        );

        address predictedAddress = Create2.computeAddress(salt, keccak256(bytecode));
        if (predictedAddress.code.length > 0) {
            revert AlreadyDeployed(salt, predictedAddress);
        }

        escrowVault = EscrowVault(
            Create2.deploy(0, salt, bytecode)
        );

        if (address(escrowVault) == address(0)) {
            revert DeploymentFailed(salt);
        }

        emit EscrowDeployed(
            address(escrowVault),
            salt,
            escrowFeeBps,
            feeAddress
        );
    }

    /// @notice Check if escrow is deployed at predicted address
    function isDeployed(
        uint256 escrowFeeBps,
        address feeAddress,
        address yieldOpsAddress,
        address disputeOpsAddress,
        address moduleManagementAddress,
        bytes32 salt
    ) external view returns (bool deployed) {
        address predictedAddress = this.getDeploymentAddress(
            escrowFeeBps,
            feeAddress,
            yieldOpsAddress,
            disputeOpsAddress,
            moduleManagementAddress,
            salt
        );
        deployed = predictedAddress.code.length > 0;
    }
}
