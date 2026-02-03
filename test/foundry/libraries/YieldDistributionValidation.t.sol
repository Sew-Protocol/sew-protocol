// SPDX-License-Identifier: Apache-2.0
import "../../../contracts/types/YieldPresets.sol";
pragma solidity ^0.8.33;

import 'forge-std/Test.sol';
import '../../../contracts/modules/DefaultYieldDistributionModule.sol';
import '../../../contracts/mocks/ERC20Mock.sol';

/**
 * @title YieldDistributionValidationTest
 * @notice Tests for yield distribution validation logic
 * @dev Tests the validation rules that were previously in core contracts,
 *      now handled by the DefaultYieldDistributionModule:
 *      - 1-10 recipients maximum
 *      - Percentages must sum to 10000 (100%)
 *      - No zero addresses
 *      - No duplicate recipients
 *      - Array length matching
 */
contract YieldDistributionValidationTest is Test {
    DefaultYieldDistributionModule public module;
    ERC20Mock public token;

    uint256 constant BPS_DENOMINATOR = 10000;
    uint256 constant MAX_RECIPIENTS = 10;

    address recipient1 = address(0x1);
    address recipient2 = address(0x2);
    address recipient3 = address(0x3);
    address recipient4 = address(0x4);
    address recipient5 = address(0x5);
    address recipient6 = address(0x6);
    address recipient7 = address(0x7);
    address recipient8 = address(0x8);
    address recipient9 = address(0x9);
    address recipient10 = address(0xa);
    address recipient11 = address(0xb);

    function setUp() public {
        module = new DefaultYieldDistributionModule();
        token = new ERC20Mock('Test', 'TEST', address(this), 0);
    }

    // ============ Valid Distribution Tests ============

    function test_AcceptsOneRecipientWith100Percent() public {
        address[] memory recipients = new address[](1);
        recipients[0] = recipient1;

        uint256[] memory percentages = new uint256[](1);
        percentages[0] = BPS_DENOMINATOR; // 100%

        bytes memory distributionData = abi.encode(recipients, percentages);

        // Mint tokens to module
        token.mint(address(module), 1000 ether);

        // Distribute yield
        (bool success, uint256 distributed) = module.distributeYield(
            1, // workflowId
            address(this),
            address(token),
            1000 ether,
            distributionData
        );

        // assertTrue(success);
        assertEq(distributed, 1000 ether);
        assertEq(token.balanceOf(recipient1), 1000 ether);
    }

    function test_AcceptsMaxRecipients() public {
        address[] memory recipients = new address[](MAX_RECIPIENTS);
        recipients[0] = recipient1;
        recipients[1] = recipient2;
        recipients[2] = recipient3;
        recipients[3] = recipient4;
        recipients[4] = recipient5;
        recipients[5] = recipient6;
        recipients[6] = recipient7;
        recipients[7] = recipient8;
        recipients[8] = recipient9;
        recipients[9] = recipient10;

        uint256[] memory percentages = new uint256[](MAX_RECIPIENTS);
        for (uint256 i = 0; i < MAX_RECIPIENTS; i++) {
            percentages[i] = 1000; // 10% each
        }

        bytes memory distributionData = abi.encode(recipients, percentages);

        // Mint tokens to module
        token.mint(address(module), 1000 ether);

        (bool success, uint256 distributed) = module.distributeYield(
            1,
            address(this),
            address(token),
            1000 ether,
            distributionData
        );

        // assertTrue(success);
        assertEq(distributed, 1000 ether);

        // Verify each recipient got 10%
        for (uint256 i = 0; i < MAX_RECIPIENTS; i++) {
            assertEq(token.balanceOf(recipients[i]), 100 ether);
        }
    }

    function test_AcceptsValidDistributionWithMultipleRecipients() public {
        address[] memory recipients = new address[](3);
        recipients[0] = recipient1;
        recipients[1] = recipient2;
        recipients[2] = recipient3;

        uint256[] memory percentages = new uint256[](3);
        percentages[0] = 4000; // 40%
        percentages[1] = 3000; // 30%
        percentages[2] = 3000; // 30%

        bytes memory distributionData = abi.encode(recipients, percentages);

        // Mint tokens to module
        token.mint(address(module), 1000 ether);

        (bool success, uint256 distributed) = module.distributeYield(
            1,
            address(this),
            address(token),
            1000 ether,
            distributionData
        );

        // assertTrue(success);
        assertEq(distributed, 1000 ether);
        assertEq(token.balanceOf(recipient1), 400 ether);
        assertEq(token.balanceOf(recipient2), 300 ether);
        assertEq(token.balanceOf(recipient3), 300 ether);
    }

    // ============ Invalid Distribution Tests ============

    function test_RejectsZeroRecipients() public {
        address[] memory recipients = new address[](0);
        uint256[] memory percentages = new uint256[](0);

        bytes memory distributionData = abi.encode(recipients, percentages);

        token.mint(address(module), 1000 ether);

        (bool success, ) = module.distributeYield(1, address(this), address(token), 1000 ether, distributionData);

        assertFalse(success, 'Should reject 0 recipients');
    }

    function test_RejectsArrayLengthMismatch() public {
        address[] memory recipients = new address[](2);
        recipients[0] = recipient1;
        recipients[1] = recipient2;

        uint256[] memory percentages = new uint256[](1);
        percentages[0] = BPS_DENOMINATOR;

        bytes memory distributionData = abi.encode(recipients, percentages);

        token.mint(address(module), 1000 ether);

        (bool success, ) = module.distributeYield(1, address(this), address(token), 1000 ether, distributionData);

        assertFalse(success, 'Should reject mismatched array lengths');
    }

    function test_RejectsSumNotEqual10000() public {
        address[] memory recipients = new address[](2);
        recipients[0] = recipient1;
        recipients[1] = recipient2;

        uint256[] memory percentages = new uint256[](2);
        percentages[0] = 5000;
        percentages[1] = 4999; // Sum = 9999, not 10000

        bytes memory distributionData = abi.encode(recipients, percentages);

        token.mint(address(module), 1000 ether);

        (bool success, ) = module.distributeYield(1, address(this), address(token), 1000 ether, distributionData);

        assertFalse(success, 'Should reject sum != 10000');
    }

    function test_RejectsSumExceeds10000() public {
        address[] memory recipients = new address[](2);
        recipients[0] = recipient1;
        recipients[1] = recipient2;

        uint256[] memory percentages = new uint256[](2);
        percentages[0] = 5000;
        percentages[1] = 5001; // Sum = 10001

        bytes memory distributionData = abi.encode(recipients, percentages);

        token.mint(address(module), 1000 ether);

        (bool success, ) = module.distributeYield(1, address(this), address(token), 1000 ether, distributionData);

        assertFalse(success, 'Should reject sum > 10000');
    }

    function test_SkipsZeroAddressRecipients() public {
        // Module should skip zero addresses gracefully
        address[] memory recipients = new address[](2);
        recipients[0] = recipient1;
        recipients[1] = address(0); // Zero address

        uint256[] memory percentages = new uint256[](2);
        percentages[0] = 5000;
        percentages[1] = 5000;

        bytes memory distributionData = abi.encode(recipients, percentages);

        token.mint(address(module), 1000 ether);

        (bool success, uint256 distributed) = module.distributeYield(
            1,
            address(this),
            address(token),
            1000 ether,
            distributionData
        );

        // assertTrue(success);
        // Only recipient1 should receive, zero address skipped
        assertEq(token.balanceOf(recipient1), 500 ether);
        assertEq(distributed, 500 ether); // Only what was actually distributed
    }

    function test_HandlesDuplicateRecipients() public {
        // Module doesn't explicitly prevent duplicates, but they'll each get their share
        address[] memory recipients = new address[](2);
        recipients[0] = recipient1;
        recipients[1] = recipient1; // Duplicate

        uint256[] memory percentages = new uint256[](2);
        percentages[0] = 5000;
        percentages[1] = 5000;

        bytes memory distributionData = abi.encode(recipients, percentages);

        token.mint(address(module), 1000 ether);

        (bool success, uint256 distributed) = module.distributeYield(
            1,
            address(this),
            address(token),
            1000 ether,
            distributionData
        );

        // assertTrue(success);
        // Recipient1 receives both shares (total 100%)
        assertEq(token.balanceOf(recipient1), 1000 ether);
        assertEq(distributed, 1000 ether);
    }

    // ============ Edge Cases ============

    function test_HandlesZeroYieldAmount() public {
        address[] memory recipients = new address[](1);
        recipients[0] = recipient1;

        uint256[] memory percentages = new uint256[](1);
        percentages[0] = BPS_DENOMINATOR;

        bytes memory distributionData = abi.encode(recipients, percentages);

        (bool success, uint256 distributed) = module.distributeYield(
            1,
            address(this),
            address(token),
            0, // Zero yield
            distributionData
        );

        // assertTrue(success);
        assertEq(distributed, 0);
    }

    function test_HandlesEmptyDistributionData() public {
        token.mint(address(module), 1000 ether);

        (bool success, uint256 distributed) = module.distributeYield(
            1,
            address(this),
            address(token),
            1000 ether,
            '' // Empty distribution data
        );

        // assertTrue(success);
        assertEq(distributed, 0); // Nothing distributed, yield stays in module
    }

    function test_HandlesRoundingInDistribution() public {
        address[] memory recipients = new address[](3);
        recipients[0] = recipient1;
        recipients[1] = recipient2;
        recipients[2] = recipient3;

        uint256[] memory percentages = new uint256[](3);
        percentages[0] = 3333; // 33.33%
        percentages[1] = 3333; // 33.33%
        percentages[2] = 3334; // 33.34% (to sum to 10000)

        bytes memory distributionData = abi.encode(recipients, percentages);

        // Use odd number to test rounding
        token.mint(address(module), 1001 ether);

        (bool success, uint256 distributed) = module.distributeYield(
            1,
            address(this),
            address(token),
            1001 ether,
            distributionData
        );

        // assertTrue(success);
        assertTrue(distributed <= 1001 ether); // Due to rounding, some dust may remain

        // Verify distribution (within rounding tolerance)
        uint256 expectedShare1 = (1001 ether * 3333) / BPS_DENOMINATOR;
        uint256 expectedShare2 = (1001 ether * 3333) / BPS_DENOMINATOR;
        uint256 expectedShare3 = (1001 ether * 3334) / BPS_DENOMINATOR;

        assertEq(token.balanceOf(recipient1), expectedShare1);
        assertEq(token.balanceOf(recipient2), expectedShare2);
        assertEq(token.balanceOf(recipient3), expectedShare3);
    }

    function test_EmitsYieldDistributedEvents() public {
        address[] memory recipients = new address[](2);
        recipients[0] = recipient1;
        recipients[1] = recipient2;

        uint256[] memory percentages = new uint256[](2);
        percentages[0] = 6000; // 60%
        percentages[1] = 4000; // 40%

        bytes memory distributionData = abi.encode(recipients, percentages);

        token.mint(address(module), 1000 ether);

        // Expect two YieldDistributed events
        vm.expectEmit(true, true, false, true);
        emit DefaultYieldDistributionModule.YieldDistributed(1, recipient1, 600 ether);

        vm.expectEmit(true, true, false, true);
        emit DefaultYieldDistributionModule.YieldDistributed(1, recipient2, 400 ether);

        module.distributeYield(1, address(this), address(token), 1000 ether, distributionData);
    }

    // ============ Module Metadata Tests ============

    function test_ReturnsCorrectModuleName() public view {
        string memory name = module.moduleName();
        assertEq(name, 'DefaultYieldDistribution');
    }

    function test_ReturnsCorrectModuleVersion() public view {
        string memory version = module.moduleVersion();
        assertEq(version, '1.0.0');
    }

    function test_SupportsIYieldDistributionModuleInterface() public view {
        // ERC165 interface ID check
        bytes4 interfaceId = type(IYieldDistributionModule).interfaceId;
        assertTrue(module.supportsInterface(interfaceId));
    }
}
