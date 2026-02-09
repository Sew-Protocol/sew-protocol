// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import 'contracts/core/ModuleSnapshotRegistry.sol';
import 'contracts/interfaces/IReleaseStrategy.sol';
import 'contracts/interfaces/IYieldGenerationModule.sol';
import 'contracts/interfaces/IYieldDistributionModule.sol';
import 'contracts/shared/interfaces/IResolutionModule.sol';

contract MockModuleSnapshotRegistry is ModuleSnapshotRegistry {
    constructor(address initialAdmin) ModuleSnapshotRegistry(initialAdmin) {}
}
