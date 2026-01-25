// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import 'forge-std/Test.sol';
import '../../../contracts/registry/ModuleRegistry.sol';
import '../../../contracts/interfaces/IModuleRegistry.sol';
import '../../../contracts/interfaces/IYieldGenerationModule.sol';
import '../../../contracts/interfaces/IYieldDistributionModule.sol';
import '../../../contracts/shared/interfaces/IResolutionModule.sol';

contract ModuleRegistryTest is Test {
    ModuleRegistry public registry;
    address public timelock;
    address public unauthorized;

    MockGenRegModule public genModule;
    MockDistRegModule public distModule;
    MockResRegModule public resModule;
    MockInvalidModule public invalidModule;

    function setUp() public {
        timelock = address(0x1);
        unauthorized = address(0x2);
        registry = new ModuleRegistry(timelock);

        genModule = new MockGenRegModule();
        distModule = new MockDistRegModule();
        resModule = new MockResRegModule();
        invalidModule = new MockInvalidModule();
    }

    function test_constructor() public {
        ModuleRegistry r = new ModuleRegistry(address(0x1));
        assertTrue(r.hasRole(r.ROLE_TIMELOCK(), address(0x1)));
        assertTrue(r.hasRole(r.DEFAULT_ADMIN_ROLE(), address(0x1)));
    }

    function test_constructor_ZeroAdmin() public {
        vm.expectRevert();
        new ModuleRegistry(address(0));
    }

    function test_addModule_YieldGen() public {
        IModuleRegistry.ModuleMetadata memory meta = IModuleRegistry.ModuleMetadata({
            name: "Gen",
            version: "1.0",
            status: IModuleRegistry.ModuleStatus.ACTIVE,
            featureFlags: 0,
            supportedTokens: new address[](0)
        });

        vm.prank(timelock);
        registry.addModule(IModuleRegistry.ModuleType.YIELD_GENERATION, address(genModule), meta);

        assertTrue(registry.isApproved(IModuleRegistry.ModuleType.YIELD_GENERATION, address(genModule)));
        
        address[] memory list = registry.enumerateModules(IModuleRegistry.ModuleType.YIELD_GENERATION);
        assertEq(list.length, 1);
        assertEq(list[0], address(genModule));

        IModuleRegistry.ModuleMetadata memory retrieved = registry.getMetadata(IModuleRegistry.ModuleType.YIELD_GENERATION, address(genModule));
        assertEq(retrieved.name, "Gen");
    }

    function test_addModule_YieldDist() public {
        IModuleRegistry.ModuleMetadata memory meta = IModuleRegistry.ModuleMetadata({
            name: "Dist",
            version: "1.0",
            status: IModuleRegistry.ModuleStatus.ACTIVE,
            featureFlags: 0,
            supportedTokens: new address[](0)
        });

        vm.prank(timelock);
        registry.addModule(IModuleRegistry.ModuleType.YIELD_DISTRIBUTION, address(distModule), meta);

        assertTrue(registry.isApproved(IModuleRegistry.ModuleType.YIELD_DISTRIBUTION, address(distModule)));
    }

    function test_addModule_Resolution() public {
        IModuleRegistry.ModuleMetadata memory meta = IModuleRegistry.ModuleMetadata({
            name: "Res",
            version: "1.0",
            status: IModuleRegistry.ModuleStatus.ACTIVE,
            featureFlags: 0,
            supportedTokens: new address[](0)
        });

        vm.prank(timelock);
        registry.addModule(IModuleRegistry.ModuleType.RESOLUTION, address(resModule), meta);

        assertTrue(registry.isApproved(IModuleRegistry.ModuleType.RESOLUTION, address(resModule)));
    }

    function test_addModule_NotContract() public {
        IModuleRegistry.ModuleMetadata memory meta = IModuleRegistry.ModuleMetadata({
            name: "EOA",
            version: "1.0",
            status: IModuleRegistry.ModuleStatus.ACTIVE,
            featureFlags: 0,
            supportedTokens: new address[](0)
        });

        vm.prank(timelock);
        vm.expectRevert(abi.encodeWithSelector(ModuleRegistry.RegistryNotAContract.selector, address(0x999)));
        registry.addModule(IModuleRegistry.ModuleType.YIELD_GENERATION, address(0x999), meta);
    }

    function test_addModule_InvalidInterface() public {
        IModuleRegistry.ModuleMetadata memory meta = IModuleRegistry.ModuleMetadata({
            name: "Invalid",
            version: "1.0",
            status: IModuleRegistry.ModuleStatus.ACTIVE,
            featureFlags: 0,
            supportedTokens: new address[](0)
        });

        vm.prank(timelock);
        vm.expectRevert(abi.encodeWithSelector(ModuleRegistry.InvalidInterface.selector, IModuleRegistry.ModuleType.YIELD_GENERATION, address(invalidModule)));
        registry.addModule(IModuleRegistry.ModuleType.YIELD_GENERATION, address(invalidModule), meta);
    }

    function test_addModule_AlreadyExists() public {
        IModuleRegistry.ModuleMetadata memory meta = IModuleRegistry.ModuleMetadata({
            name: "Gen",
            version: "1.0",
            status: IModuleRegistry.ModuleStatus.ACTIVE,
            featureFlags: 0,
            supportedTokens: new address[](0)
        });

        vm.prank(timelock);
        registry.addModule(IModuleRegistry.ModuleType.YIELD_GENERATION, address(genModule), meta);

        vm.prank(timelock);
        vm.expectRevert(abi.encodeWithSelector(ModuleRegistry.ModuleAlreadyExists.selector, IModuleRegistry.ModuleType.YIELD_GENERATION, address(genModule)));
        registry.addModule(IModuleRegistry.ModuleType.YIELD_GENERATION, address(genModule), meta);
    }

    function test_addModule_Unauthorized() public {
        IModuleRegistry.ModuleMetadata memory meta = IModuleRegistry.ModuleMetadata({
            name: "Gen",
            version: "1.0",
            status: IModuleRegistry.ModuleStatus.ACTIVE,
            featureFlags: 0,
            supportedTokens: new address[](0)
        });

        vm.prank(unauthorized);
        vm.expectRevert();
        registry.addModule(IModuleRegistry.ModuleType.YIELD_GENERATION, address(genModule), meta);
    }

    function test_deprecateModule() public {
        IModuleRegistry.ModuleMetadata memory meta = IModuleRegistry.ModuleMetadata({
            name: "Gen",
            version: "1.0",
            status: IModuleRegistry.ModuleStatus.ACTIVE,
            featureFlags: 0,
            supportedTokens: new address[](0)
        });

        vm.prank(timelock);
        registry.addModule(IModuleRegistry.ModuleType.YIELD_GENERATION, address(genModule), meta);

        vm.prank(timelock);
        registry.deprecateModule(IModuleRegistry.ModuleType.YIELD_GENERATION, address(genModule));

        assertFalse(registry.isApproved(IModuleRegistry.ModuleType.YIELD_GENERATION, address(genModule)));
        
        // Should be removed from list
        address[] memory list = registry.enumerateModules(IModuleRegistry.ModuleType.YIELD_GENERATION);
        assertEq(list.length, 0);

        // Metadata should show deprecated
        IModuleRegistry.ModuleMetadata memory retrieved = registry.getMetadata(IModuleRegistry.ModuleType.YIELD_GENERATION, address(genModule));
        assertEq(uint(retrieved.status), uint(IModuleRegistry.ModuleStatus.DEPRECATED));
    }

    function test_deprecateModule_NotActive() public {
        vm.prank(timelock);
        // Not registered
        vm.expectRevert(); // InvalidStatusTransition
        registry.deprecateModule(IModuleRegistry.ModuleType.YIELD_GENERATION, address(genModule));
    }

    function test_deprecateModule_NotLast() public {
        IModuleRegistry.ModuleMetadata memory meta = IModuleRegistry.ModuleMetadata({
            name: "Gen",
            version: "1.0",
            status: IModuleRegistry.ModuleStatus.ACTIVE,
            featureFlags: 0,
            supportedTokens: new address[](0)
        });

        MockGenRegModule genModule2 = new MockGenRegModule();

        vm.startPrank(timelock);
        registry.addModule(IModuleRegistry.ModuleType.YIELD_GENERATION, address(genModule), meta);
        registry.addModule(IModuleRegistry.ModuleType.YIELD_GENERATION, address(genModule2), meta);

        // List has [genModule, genModule2]
        registry.deprecateModule(IModuleRegistry.ModuleType.YIELD_GENERATION, address(genModule));
        
        address[] memory list = registry.enumerateModules(IModuleRegistry.ModuleType.YIELD_GENERATION);
        assertEq(list.length, 1);
        assertEq(list[0], address(genModule2));
        vm.stopPrank();
    }

    function test_deprecateModule_Unauthorized() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        registry.deprecateModule(IModuleRegistry.ModuleType.YIELD_GENERATION, address(genModule));
    }
}

// Mocks
contract MockGenRegModule {
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IYieldGenerationModule).interfaceId || interfaceId == type(IERC165).interfaceId;
    }
}

contract MockDistRegModule {
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IYieldDistributionModule).interfaceId || interfaceId == type(IERC165).interfaceId;
    }
}

contract MockResRegModule {
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IResolutionModule).interfaceId || interfaceId == type(IERC165).interfaceId;
    }
}

contract MockInvalidModule {
    function supportsInterface(bytes4) external pure returns (bool) {
        return false;
    }
}
