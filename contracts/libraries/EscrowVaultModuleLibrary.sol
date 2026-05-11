// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import '../interfaces/IYieldModule.sol';
import '../interfaces/IYieldDistributionModule.sol';
import '../types/EscrowTypes.sol';
import '../core/ModuleSnapshotRegistry.sol';

library EscrowVaultModuleLibrary {
    function getYieldGenerationModule(
        uint256 workflowId,
        mapping(uint256 => ModuleSnapshot) storage moduleSnapshots,
        ModuleSnapshotRegistry moduleManagement,
        address vaultAddress
    ) internal view returns (IYieldModule) {
        address snap = moduleSnapshots[workflowId].yieldGenerationModule;
        if (snap != address(0)) return IYieldModule(snap);
        return IYieldModule(address(moduleManagement.getDefaultYieldGenerationModule(vaultAddress)));
    }

    function getYieldDistributionModule(
        ModuleSnapshotRegistry moduleManagement,
        address vaultAddress
    ) internal view returns (IYieldDistributionModule) {
        return IYieldDistributionModule(moduleManagement.getDefaultYieldDistributionModule(vaultAddress));
    }

    function getReleaseStrategy(
        ModuleSnapshotRegistry moduleManagement,
        address vaultAddress
    ) internal view returns (IReleaseStrategy) {
        return moduleManagement.getDefaultReleaseStrategy(vaultAddress);
    }
}
