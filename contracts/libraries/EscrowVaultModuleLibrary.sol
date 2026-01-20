// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import '../interfaces/IReleaseStrategy.sol';
import '../interfaces/IYieldGenerationModule.sol';
import '../interfaces/IYieldDistributionModule.sol';

library EscrowVaultModuleLibrary {
    function getReleaseStrategyOrDefault(
        address snapshot,
        IReleaseStrategy defaultModule
    ) internal pure returns (IReleaseStrategy) {
        return snapshot != address(0) ? IReleaseStrategy(snapshot) : defaultModule;
    }

    function getYieldGenerationModuleOrDefault(
        address snapshot,
        IYieldGenerationModule defaultModule
    ) internal pure returns (IYieldGenerationModule) {
        return snapshot != address(0) ? IYieldGenerationModule(snapshot) : defaultModule;
    }

    function getYieldDistributionModuleOrDefault(
        address snapshot,
        IYieldDistributionModule defaultModule
    ) internal pure returns (IYieldDistributionModule) {
        return snapshot != address(0) ? IYieldDistributionModule(snapshot) : defaultModule;
    }
}
