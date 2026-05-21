// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import '../types/EscrowTypes.sol';
import '../core/ModuleSnapshotRegistry.sol';
import '../core/BaseEscrow.sol'; // For ModuleType enum

/**
 * @title ModuleGetterLibrary
 * @notice Library for optimized module address retrieval
 * @dev Extracted from EscrowVault to reduce contract size. Uses assembly for efficient storage lookups.
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
     * @dev Uses assembly for optimized storage reads and switch pattern
     */
    function getModuleAddress(
        uint256 workflowId,
        BaseEscrow.ModuleType moduleType,
        mapping(uint256 => ModuleSnapshot) storage moduleSnapshots,
        ModuleSnapshotRegistry moduleManagement,
        address escrowContract
    ) internal view returns (address moduleAddress) {
        address snapshotModule;

        // Use assembly for optimized switch-like pattern (saves ~600 bytes vs if/else chain)
        ModuleSnapshot storage snapshot = moduleSnapshots[workflowId];
        
        assembly {
            // Switch on moduleType (0=RESOLUTION, 1=RELEASE, 2=CANCELLATION, 3=YIELD_GEN, 4=YIELD_DIST)
            // Access struct fields via storage pointer offsets
            let slot := snapshot.slot
            switch moduleType
            case 0 {
                // RESOLUTION: snapshot.resolutionModule (offset 0)
                snapshotModule := sload(slot)
            }
            case 1 {
                // RELEASE: snapshot.releaseStrategy (offset 1)
                snapshotModule := sload(add(slot, 1))
            }
            case 2 {
                // CANCELLATION: snapshot.cancellationStrategy (offset 2)
                snapshotModule := sload(add(slot, 2))
            }
            case 3 {
                // YIELD_GEN: snapshot.yieldGenerationModule (offset 3)
                snapshotModule := sload(add(slot, 3))
            }
            case 4 {
                // YIELD_DIST: snapshot.yieldDistributionModule (offset 4)
                snapshotModule := sload(add(slot, 4))
            }
        }

        // If snapshot exists, return it
        if (snapshotModule != address(0)) {
            return snapshotModule;
        }

        // Query ModuleSnapshotRegistry for module
        return moduleManagement.getModule(escrowContract, moduleType);
    }
}
