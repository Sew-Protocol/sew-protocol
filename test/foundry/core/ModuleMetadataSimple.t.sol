// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import 'forge-std/Test.sol';
import {DefaultResolutionModule} from '../../../contracts/core/modules/DefaultResolutionModule.sol';
import {DefaultYieldModule} from '../../../contracts/modules/DefaultYieldModule.sol';
import {DefaultReleaseStrategy} from '../../../contracts/modules/DefaultReleaseStrategy.sol';
import {DefaultYieldDistributionModule} from '../../../contracts/modules/DefaultYieldDistributionModule.sol';
import {IResolutionModule} from '../../../contracts/shared/interfaces/IResolutionModule.sol';
import {IYieldGenerationModule} from '../../../contracts/interfaces/IYieldGenerationModule.sol';
import {IReleaseStrategy} from '../../../contracts/interfaces/IReleaseStrategy.sol';
import {IYieldDistributionModule} from '../../../contracts/interfaces/IYieldDistributionModule.sol';

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

    function test_DefaultYieldModule_metadataAndInterface() public {
        DefaultYieldModule mod = new DefaultYieldModule();
        string memory name = mod.moduleName();
        string memory version = mod.moduleVersion();
        assertEq(name, 'DefaultNoYield');
        assertEq(version, '1.0.0');

        bytes4 iid = type(IYieldGenerationModule).interfaceId;
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

    function test_DefaultYieldDistribution_metadataAndInterface() public {
        DefaultYieldDistributionModule mod = new DefaultYieldDistributionModule();
        string memory name = mod.moduleName();
        string memory version = mod.moduleVersion();
        assertEq(name, 'DefaultYieldDistribution');
        assertEq(version, '1.0.0');

        bytes4 iid = type(IYieldDistributionModule).interfaceId;
        assertTrue(mod.supportsInterface(iid));
    }
}
