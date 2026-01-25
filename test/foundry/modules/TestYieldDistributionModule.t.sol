// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import 'forge-std/Test.sol';
import '../../../contracts/modules/TestYieldDistributionModule.sol';
import '../../../contracts/mocks/ERC20Mock.sol';

contract TestYieldDistributionModuleTest is Test {
    TestYieldDistributionModule public module;
    ERC20Mock public token;

    function setUp() public {
        module = new TestYieldDistributionModule();
        token = new ERC20Mock("Test", "TEST", address(this), 1000e18);
    }

    function test_DefaultDistribution() public {
        address[] memory recipients = new address[](2);
        recipients[0] = address(0x1);
        recipients[1] = address(0x2);
        uint256[] memory percentages = new uint256[](2);
        percentages[0] = 5000;
        percentages[1] = 5000;

        module.setDefaultDistribution(recipients, percentages);
        
        token.mint(address(module), 100);

        (bool success, uint256 distributed) = module.distributeYield(1, address(token), 100, "");
        
        assertTrue(success);
        assertEq(distributed, 100);
        assertEq(token.balanceOf(address(0x1)), 50);
        assertEq(token.balanceOf(address(0x2)), 50);
    }

    function test_SetDefaultDistribution_Mismatch() public {
        address[] memory recipients = new address[](1);
        uint256[] memory percentages = new uint256[](0);
        vm.expectRevert("Array length mismatch");
        module.setDefaultDistribution(recipients, percentages);
    }

    function test_SetDefaultDistribution_Empty() public {
        address[] memory recipients = new address[](0);
        uint256[] memory percentages = new uint256[](0);
        vm.expectRevert("Must have at least one recipient");
        module.setDefaultDistribution(recipients, percentages);
    }

    function test_SetDefaultDistribution_BadSum() public {
        address[] memory recipients = new address[](1);
        recipients[0] = address(0x1);
        uint256[] memory percentages = new uint256[](1);
        percentages[0] = 9999;
        vm.expectRevert("Percentages must sum to 10000");
        module.setDefaultDistribution(recipients, percentages);
    }

    function test_DefaultDistribution_NoConfig() public {
        (bool success, uint256 distributed) = module.distributeYield(1, address(token), 100, "");
        assertTrue(success);
        assertEq(distributed, 0);
    }

    function test_DistributeYield_BadSum() public {
        address[] memory recipients = new address[](1);
        recipients[0] = address(0x1);
        uint256[] memory percentages = new uint256[](1);
        percentages[0] = 9999;
        bytes memory data = abi.encode(recipients, percentages);

        (bool success, uint256 distributed) = module.distributeYield(1, address(token), 100, data);
        assertFalse(success);
        assertEq(distributed, 0);
    }

    function test_DistributeYield_SkipZero() public {
        address[] memory recipients = new address[](2);
        recipients[0] = address(0);
        recipients[1] = address(0x2);
        uint256[] memory percentages = new uint256[](2);
        percentages[0] = 5000;
        percentages[1] = 5000;
        bytes memory data = abi.encode(recipients, percentages);

        token.mint(address(module), 100);

        (bool success, uint256 distributed) = module.distributeYield(1, address(token), 100, data);
        assertTrue(success);
        assertEq(distributed, 50);
        assertEq(token.balanceOf(address(0x2)), 50);
    }

    function test_DistributeYield_MismatchedLength() public {
        address[] memory recipients = new address[](2);
        uint256[] memory percentages = new uint256[](1);
        bytes memory data = abi.encode(recipients, percentages);

        (bool success, uint256 distributed) = module.distributeYield(1, address(token), 100, data);
        assertFalse(success);
        assertEq(distributed, 0);
    }

    function test_DistributeYield_EmptyRecipients() public {
        address[] memory recipients = new address[](0);
        uint256[] memory percentages = new uint256[](0);
        bytes memory data = abi.encode(recipients, percentages);

        (bool success, uint256 distributed) = module.distributeYield(1, address(token), 100, data);
        assertFalse(success);
        assertEq(distributed, 0);
    }

    function test_DistributeYield_ZeroShare() public {
        address[] memory r = new address[](1);
        r[0] = address(0x1);
        uint256[] memory p = new uint256[](1);
        p[0] = 1; // 0.01%
        bytes memory data = abi.encode(r, p);
        
        // This will fail validation because total percentage must be 10000.
        (bool success, uint256 distributed) = module.distributeYield(1, address(token), 100, data);
        assertFalse(success);
        assertEq(distributed, 0);
        
        // Correct sum but small amount
        address[] memory r2 = new address[](2);
        r2[0] = address(0x1);
        r2[1] = address(0x2);
        uint256[] memory p2 = new uint256[](2);
        p2[0] = 1;
        p2[1] = 9999;
        bytes memory data2 = abi.encode(r2, p2);
        
        token.mint(address(module), 1);
        (success, distributed) = module.distributeYield(1, address(token), 1, data2);
        assertTrue(success);
        assertEq(distributed, 0);
    }

    function test_Metadata() public {
        assertEq(module.moduleName(), "TestYieldDistribution");
        assertEq(module.moduleVersion(), "1.0.0");
        assertTrue(module.supportsInterface(type(IYieldDistributionModule).interfaceId));
        assertFalse(module.supportsInterface(0x12345678));
    }
}
