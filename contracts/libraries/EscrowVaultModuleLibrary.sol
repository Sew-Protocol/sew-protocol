// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import '../interfaces/IYieldModule.sol';
import '../interfaces/IYieldDistributionModule.sol';
import '../interfaces/IReleaseStrategy.sol';
import '../types/EscrowTypes.sol';
import '../core/BaseEscrow.sol';
import '../core/ModuleSnapshotRegistry.sol';
import './ModuleGetterLibrary.sol';

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
        uint256 workflowId,
        mapping(uint256 => ModuleSnapshot) storage moduleSnapshots,
        ModuleSnapshotRegistry moduleManagement,
        address vaultAddress
    ) internal view returns (IYieldDistributionModule) {
        address moduleAddr = ModuleGetterLibrary.getModuleAddress(
            workflowId,
            BaseEscrow.ModuleType.YIELD_DIST,
            moduleSnapshots,
            moduleManagement,
            vaultAddress
        );
        return IYieldDistributionModule(moduleAddr);
    }

    function getReleaseStrategy(
        uint256 workflowId,
        mapping(uint256 => ModuleSnapshot) storage moduleSnapshots,
        ModuleSnapshotRegistry moduleManagement,
        address vaultAddress
    ) internal view returns (IReleaseStrategy) {
        address moduleAddr = ModuleGetterLibrary.getModuleAddress(
            workflowId,
            BaseEscrow.ModuleType.RELEASE,
            moduleSnapshots,
            moduleManagement,
            vaultAddress
        );
        return IReleaseStrategy(moduleAddr);
    }

    function getCancellationStrategy(
        uint256 workflowId,
        mapping(uint256 => ModuleSnapshot) storage moduleSnapshots,
        ModuleSnapshotRegistry moduleManagement,
        address vaultAddress
    ) internal view returns (address) {
        address snap = moduleSnapshots[workflowId].cancellationStrategy;
        if (snap != address(0)) return snap;
        return address(moduleManagement.getDefaultCancellationStrategy(vaultAddress));
    }

    function getResolutionModule(
        uint256 workflowId,
        mapping(uint256 => ModuleSnapshot) storage moduleSnapshots,
        ModuleSnapshotRegistry moduleManagement,
        address vaultAddress,
        address fallbackModule
    ) internal view returns (IResolutionModule) {
        address snap = moduleSnapshots[workflowId].resolutionModule;
        if (snap != address(0)) return IResolutionModule(snap);
        address def = address(moduleManagement.getDefaultResolutionModule(vaultAddress));
        return IResolutionModule(def != address(0) ? def : fallbackModule);
    }
}
