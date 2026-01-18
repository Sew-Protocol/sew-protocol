// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import 'forge-std/Test.sol';
import '../../../contracts/modules/DefaultYieldDistributionModule.sol';
import '../../../contracts/modules/DefaultReleaseStrategy.sol';
import '../../../contracts/core/modules/DefaultResolutionModule.sol';
import '../../../contracts/mocks/ERC20Mock.sol';

contract ModulesCoverageTest is Test {
    DefaultYieldDistributionModule public distModule;
    DefaultReleaseStrategy public relStrategy;
    DefaultResolutionModule public resModule;
    ERC20Mock public token;

    address public owner;
    address public resolver;
    address public timelock;

    function setUp() public {
        owner = address(this);
        resolver = address(0x123);
        timelock = address(0x456);

        distModule = new DefaultYieldDistributionModule();
        relStrategy = new DefaultReleaseStrategy();
        resModule = new DefaultResolutionModule(owner, resolver);
        token = new ERC20Mock("Test", "TEST", address(this), 10000e18);

        // Grant TIMELOCK role
        resModule.grantRole(resModule.ROLE_TIMELOCK(), timelock);
    }

    // ============ DefaultYieldDistributionModule Tests ============

    function test_DefaultDist_distributeYield_ZeroAmount() public {
        (bool success, uint256 distributed) = distModule.distributeYield(1, address(token), 0, "");
        assertTrue(success);
        assertEq(distributed, 0);
    }

    function test_DefaultDist_distributeYield_EmptyData() public {
        (bool success, uint256 distributed) = distModule.distributeYield(1, address(token), 100, "");
        assertTrue(success);
        assertEq(distributed, 0);
    }

    function test_DefaultDist_distributeYield_Success() public {
        address[] memory recipients = new address[](2);
        recipients[0] = address(0x1);
        recipients[1] = address(0x2);
        uint256[] memory percentages = new uint256[](2);
        percentages[0] = 5000;
        percentages[1] = 5000;
        bytes memory data = abi.encode(recipients, percentages);

        token.mint(address(distModule), 100);

        (bool success, uint256 distributed) = distModule.distributeYield(1, address(token), 100, data);
        assertTrue(success);
        assertEq(distributed, 100);
        assertEq(token.balanceOf(address(0x1)), 50);
        assertEq(token.balanceOf(address(0x2)), 50);
    }

    function test_DefaultDist_distributeYield_Mismatch() public {
        address[] memory recipients = new address[](1);
        uint256[] memory percentages = new uint256[](0);
        bytes memory data = abi.encode(recipients, percentages);

        (bool success, uint256 distributed) = distModule.distributeYield(1, address(token), 100, data);
        assertFalse(success);
        assertEq(distributed, 0);
    }

    function test_DefaultDist_distributeYield_BadSum() public {
        address[] memory recipients = new address[](1);
        recipients[0] = address(0x1);
        uint256[] memory percentages = new uint256[](1);
        percentages[0] = 9999;
        bytes memory data = abi.encode(recipients, percentages);

        (bool success, uint256 distributed) = distModule.distributeYield(1, address(token), 100, data);
        assertFalse(success);
        assertEq(distributed, 0);
    }

    function test_DefaultDist_Metadata() public {
        assertEq(distModule.moduleName(), "DefaultYieldDistribution");
        assertEq(distModule.moduleVersion(), "1.0.0");
        assertTrue(distModule.supportsInterface(type(IYieldDistributionModule).interfaceId));
    }

    // ============ DefaultReleaseStrategy Tests ============

    function test_DefaultRelease_canRelease() public {
        (bool allowed, string memory reason) = relStrategy.canRelease(1, address(0), "");
        assertTrue(allowed);
        assertEq(reason, "");
    }

    function test_DefaultRelease_executeRelease() public {
        (bool success, address recipient, uint256 amount) = relStrategy.executeRelease(1, "");
        assertTrue(success);
        assertEq(recipient, address(0));
        assertEq(amount, 0);
    }

    function test_DefaultRelease_Metadata() public {
        assertEq(relStrategy.moduleName(), "DefaultBuyerRelease");
        assertEq(relStrategy.strategyName(), "DefaultBuyerRelease");
        assertEq(relStrategy.moduleVersion(), "1.0.0");
        assertTrue(relStrategy.supportsInterface(type(IReleaseStrategy).interfaceId));
    }

    // ============ DefaultResolutionModule Tests ============

    function test_DefaultRes_Constructor() public {
        assertEq(resModule.resolver(), resolver);
        assertTrue(resModule.hasRole(resModule.DEFAULT_ADMIN_ROLE(), owner));
    }

    function test_DefaultRes_setResolver() public {
        address newResolver = address(0x999);
        vm.prank(timelock);
        resModule.setResolver(newResolver);
        assertEq(resModule.resolver(), newResolver);
    }

    function test_DefaultRes_setResolver_Unauthorized() public {
        address newResolver = address(0x999);
        vm.expectRevert();
        resModule.setResolver(newResolver);
    }

    function test_DefaultRes_isAuthorized() public {
        (bool auth, uint8 role) = resModule.isAuthorizedDisputeResolver(1, resolver, "");
        assertTrue(auth);
        assertEq(role, 0);

        (auth, role) = resModule.isAuthorizedDisputeResolver(1, address(0x999), "");
        assertFalse(auth);
    }

    function test_DefaultRes_getDisputeResolver() public {
        (address r, uint8 l) = resModule.getDisputeResolver(1, "");
        assertEq(r, resolver);
        assertEq(l, 0);
    }

    function test_DefaultRes_Escalation() public {
        (bool can, address next, uint256 fee) = resModule.canEscalate(1, 0, "");
        assertFalse(can);
        assertEq(next, address(0));
        assertEq(fee, 0);

        (bool success, address newR, uint8 newL) = resModule.executeEscalation(1, "");
        assertFalse(success);
        assertEq(newR, address(0));
        assertEq(newL, 0);
    }

    function test_DefaultRes_Metadata() public {
        assertEq(resModule.moduleName(), "DefaultSingleResolver");
        assertEq(resModule.moduleVersion(), "1.0.0");
        assertTrue(resModule.supportsInterface(type(IResolutionModule).interfaceId));
    }
}
