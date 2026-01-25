// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import 'forge-std/Test.sol';
import '../../../contracts/registry/ModuleRegistry.sol';
import '../../../contracts/interfaces/IModuleRegistry.sol';
import '../../../contracts/interfaces/IYieldGenerationModule.sol';
import '../../../contracts/interfaces/IYieldDistributionModule.sol';
import '../../../contracts/shared/interfaces/IResolutionModule.sol';

contract ModuleRegistryGapsTest is Test {
    ModuleRegistry public registry;
    address public timelock = address(0x1);

    MockGenRegModule public genModule;

    function setUp() public {
        registry = new ModuleRegistry(timelock);
        genModule = new MockGenRegModule();
    }

    function test_addModule_NotActive() public {
        IModuleRegistry.ModuleMetadata memory meta = IModuleRegistry.ModuleMetadata({
            name: "Gen",
            version: "1.0",
            status: IModuleRegistry.ModuleStatus.DEPRECATED,
            featureFlags: 0,
            supportedTokens: new address[](0)
        });

        vm.prank(timelock);
        registry.addModule(IModuleRegistry.ModuleType.YIELD_GENERATION, address(genModule), meta);

        // Should NOT be approved
        assertFalse(registry.isApproved(IModuleRegistry.ModuleType.YIELD_GENERATION, address(genModule)));
        
        // Should NOT be in list
        address[] memory list = registry.enumerateModules(IModuleRegistry.ModuleType.YIELD_GENERATION);
        assertEq(list.length, 0);

        // Metadata should be stored
        IModuleRegistry.ModuleMetadata memory retrieved = registry.getMetadata(IModuleRegistry.ModuleType.YIELD_GENERATION, address(genModule));
        assertEq(retrieved.name, "Gen");
        assertEq(uint8(retrieved.status), uint8(IModuleRegistry.ModuleStatus.DEPRECATED));
    }

    function test_deprecateModule_AlreadyDeprecated() public {
        IModuleRegistry.ModuleMetadata memory meta = IModuleRegistry.ModuleMetadata({
            name: "Gen",
            version: "1.0",
            status: IModuleRegistry.ModuleStatus.ACTIVE,
            featureFlags: 0,
            supportedTokens: new address[](0)
        });

        vm.startPrank(timelock);
        registry.addModule(IModuleRegistry.ModuleType.YIELD_GENERATION, address(genModule), meta);
        registry.deprecateModule(IModuleRegistry.ModuleType.YIELD_GENERATION, address(genModule));

        // Try deprecating again
        vm.expectRevert(); // InvalidStatusTransition
        registry.deprecateModule(IModuleRegistry.ModuleType.YIELD_GENERATION, address(genModule));
        vm.stopPrank();
    }
}

contract MockGenRegModule {
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IYieldGenerationModule).interfaceId || interfaceId == type(IERC165).interfaceId;
    }
}
