// SPDX-License-Identifier: Apache-2.0
import "../../../contracts/types/YieldPresets.sol";
pragma solidity ^0.8.37;

import 'forge-std/Test.sol';
import {DefaultResolutionModule} from '../../../contracts/modules/DefaultResolutionModule.sol';
import {DefaultReleaseStrategy} from '../../../contracts/modules/DefaultReleaseStrategy.sol';
import {IResolutionModule} from '../../../contracts/shared/interfaces/IResolutionModule.sol';
import {IReleaseStrategy} from '../../../contracts/interfaces/IReleaseStrategy.sol';

contract ModuleMetadataSimple is Test {
    function test_DefaultResolutionModule_metadataAndInterface() public {
        DefaultResolutionModule mod = new DefaultResolutionModule(address(this), address(0x1234));
        string memory name = mod.moduleName();
        string memory version = mod.moduleVersion();
        assertEq(name, 'DefaultSingleResolver');
        assertEq(version, '1.0.0');

        // supports IResolutionModule
        bytes4 iid = type(IResolutionModule).interfaceId;
        assertTrue(mod.supportsInterface(iid));
    }

    function test_DefaultReleaseStrategy_metadataAndInterface() public {
        DefaultReleaseStrategy strat = new DefaultReleaseStrategy();
        string memory name = strat.moduleName();
        string memory version = strat.moduleVersion();
        assertEq(name, 'DefaultBuyerRelease');
        assertEq(version, '1.0.0');

        bytes4 iid = type(IReleaseStrategy).interfaceId;
        assertTrue(strat.supportsInterface(iid));
    }

}
