// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import '../shared/interfaces/IResolutionModule.sol';
import '../types/EscrowTypes.sol';

library ResolutionModuleLibrary {
    event ResolutionModuleActivated(address indexed oldModule, address indexed newModule);

    struct Storage {
        address disputeResolutionModule;
    }

    function setResolutionModule(Storage storage self, address module) internal {
        address oldModule = self.disputeResolutionModule;
        self.disputeResolutionModule = module;
        emit ResolutionModuleActivated(oldModule, module);
    }

    function getResolutionModule(
        Storage storage self,
        address snapshotResolutionModule
    ) internal view returns (IResolutionModule) {
        if (snapshotResolutionModule != address(0)) return IResolutionModule(snapshotResolutionModule);
        return IResolutionModule(self.disputeResolutionModule);
    }
}
