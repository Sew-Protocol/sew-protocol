// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.37;

import '../../packages/sew-core/contracts/core/ModuleSnapshotRegistry.sol';
import '../../packages/sew-core/contracts/interfaces/IReleaseStrategy.sol';
import 'contracts/interfaces/IYieldGenerationModule.sol';
import '../../packages/sew-core/contracts/shared/interfaces/IResolutionModule.sol';

contract MockModuleSnapshotRegistry is ModuleSnapshotRegistry {
    constructor(address initialAdmin) ModuleSnapshotRegistry(initialAdmin) {}
}
