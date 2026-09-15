// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.37;

import '../types/EscrowTypes.sol';
import '../core/ModuleSnapshotRegistry.sol';
import '../core/BaseEscrow.sol'; // For ModuleType enum

/**
 * @title ModuleGetterLibrary
 * @notice Shared module address retrieval for all escrow products.
 */
library ModuleGetterLibrary {
    /**
     * @notice Get module address from snapshot or default from ModuleSnapshotRegistry
     * @param workflowId The escrow ID
     * @param moduleType Type of module to retrieve
     * @param moduleSnapshots Storage reference to moduleSnapshots mapping
     * @param moduleManagement ModuleSnapshotRegistry instance
     * @param escrowContract Address of the escrow contract (msg.sender for ModuleSnapshotRegistry)
     * @return moduleAddress The module address
     */
    function getModuleAddress(
        uint256 workflowId,
        BaseEscrow.ModuleType moduleType,
        mapping(uint256 => ModuleSnapshot) storage moduleSnapshots,
        ModuleSnapshotRegistry moduleManagement,
        address escrowContract
    ) internal view returns (address moduleAddress) {
        ModuleSnapshot storage snapshot = moduleSnapshots[workflowId];
        address snapshotModule;
        if (moduleType == BaseEscrow.ModuleType.RESOLUTION) snapshotModule = snapshot.resolutionModule;
        else if (moduleType == BaseEscrow.ModuleType.RELEASE) snapshotModule = snapshot.releaseStrategy;
        else if (moduleType == BaseEscrow.ModuleType.CANCELLATION) snapshotModule = snapshot.cancellationStrategy;
        else if (moduleType == BaseEscrow.ModuleType.YIELD_GEN) snapshotModule = snapshot.yieldGenerationModule;
        else if (moduleType == BaseEscrow.ModuleType.YIELD_DIST) snapshotModule = snapshot.yieldDistributionModule;

        // If snapshot exists, return it
        if (snapshotModule != address(0)) {
            return snapshotModule;
        }

        // Query ModuleSnapshotRegistry for module
        return moduleManagement.getModule(escrowContract, moduleType);
    }
}
