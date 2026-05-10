// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import 'forge-std/Test.sol';
import '../../../contracts/modules/DefaultYieldDistributionModule.sol';
import '../../../contracts/modules/DefaultReleaseStrategy.sol';
import '../../../contracts/core/modules/DefaultResolutionModule.sol';
import '../../../contracts/mocks/ERC20Mock.sol';
import '../../../contracts/libraries/EscrowEncodingLibrary.sol';

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
        (bool success, uint256 distributed) = distModule.distributeYield(1, address(this), address(token), 0, "");
        assertTrue(success);
        assertEq(distributed, 0);
    }

    function test_DefaultDist_distributeYield_EmptyData() public {
        (bool success, uint256 distributed) = distModule.distributeYield(1, address(this), address(token), 100, "");
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

        (bool success, uint256 distributed) = distModule.distributeYield(1, address(this), address(token), 100, data);
        assertTrue(success);
        assertEq(distributed, 0);
        assertEq(token.balanceOf(address(0x1)), 0);
        assertEq(token.balanceOf(address(0x2)), 0);
    }

    function test_DefaultDist_distributeYield_Mismatch() public {
        address[] memory recipients = new address[](1);
        uint256[] memory percentages = new uint256[](0);
        bytes memory data = abi.encode(recipients, percentages);

        (bool success, uint256 distributed) = distModule.distributeYield(1, address(this), address(token), 100, data);
        assertFalse(success);
        assertEq(distributed, 0);
    }

    function test_DefaultDist_distributeYield_BadSum() public {
        address[] memory recipients = new address[](1);
        recipients[0] = address(0x1);
        uint256[] memory percentages = new uint256[](1);
        percentages[0] = 9999;
        bytes memory data = abi.encode(recipients, percentages);

        (bool success, uint256 distributed) = distModule.distributeYield(1, address(this), address(token), 100, data);
        assertFalse(success);
        assertEq(distributed, 0);
    }

    function test_DefaultDist_distributeYield_MismatchedLength() public {
        address[] memory recipients = new address[](2);
        uint256[] memory percentages = new uint256[](1);
        bytes memory data = abi.encode(recipients, percentages);

        (bool success, uint256 distributed) = distModule.distributeYield(1, address(this), address(token), 100, data);
        assertFalse(success);
        assertEq(distributed, 0);
    }

    function test_DefaultDist_Metadata() public {
        assertEq(distModule.moduleName(), "DefaultYieldDistribution");
        assertEq(distModule.moduleVersion(), "1.0.0");
        assertTrue(distModule.supportsInterface(type(IYieldDistributionModule).interfaceId));
        assertFalse(distModule.supportsInterface(0x12345678));
    }

    function test_DefaultDist_distributeYield_SkipZero() public {
        address[] memory recipients = new address[](2);
        recipients[0] = address(0);
        recipients[1] = address(0x2);
        uint256[] memory percentages = new uint256[](2);
        percentages[0] = 5000;
        percentages[1] = 5000;
        bytes memory data = abi.encode(recipients, percentages);

        token.mint(address(distModule), 100);

        (bool success, uint256 distributed) = distModule.distributeYield(1, address(this), address(token), 100, data);
        assertTrue(success);
        assertEq(distributed, 0);
        assertEq(token.balanceOf(address(0x2)), 0);
    }

    function test_DefaultDist_distributeYield_ZeroShare() public {
        address[] memory recipients = new address[](1);
        recipients[0] = address(0x1);
        uint256[] memory percentages = new uint256[](1);
        percentages[0] = 10000;
        bytes memory data = abi.encode(recipients, percentages);

        token.mint(address(distModule), 100);

        // yieldAmount = 0 handled already. Try very small yield that results in 0 share if denominator was larger, 
        // but here percentages[0] is 10000, so it will be 100.
        // To get 0 share with 10000 denominator: yieldAmount * 1 / 10000 where yieldAmount < 10000.
        
        uint256 smallYield = 1;
        uint256 tinyPercentage = 1; // 0.01%
        
        address[] memory r2 = new address[](2);
        r2[0] = address(0x1);
        r2[1] = address(0x2);
        uint256[] memory p2 = new uint256[](2);
        p2[0] = tinyPercentage; 
        p2[1] = 10000 - tinyPercentage;
        bytes memory data2 = abi.encode(r2, p2);
        
        token.mint(address(distModule), smallYield);
        (bool success, uint256 distributed) = distModule.distributeYield(1, address(this), address(token), smallYield, data2);
        assertTrue(success);
        // share0 = 1 * 1 / 10000 = 0
        // share1 = 1 * 9999 / 10000 = 0
        assertEq(distributed, 0);
    }

    // ============ DefaultReleaseStrategy Tests ============

    function test_DefaultRelease_canRelease() public {
        address sender = address(0x123);
        address recipient = address(0x456);
        bytes memory escrowData = EscrowEncodingLibrary.encodeEscrowTransferData(
            address(token),
            sender,
            recipient,
            1000e18,
            address(0) // Added default releaseAddress
        );
        
        // Non-sender (address(0)) should not be allowed
        (bool allowed, uint8 reasonCode) = relStrategy.canRelease(1, address(this), address(0), escrowData);
        assertFalse(allowed);  // address(0) is not the sender
        assertEq(reasonCode, 1);  // REASON_NOT_AUTHORIZED
        
        // Sender should be allowed
        (allowed, reasonCode) = relStrategy.canRelease(1, address(this), sender, escrowData);
        assertTrue(allowed);
        assertEq(reasonCode, 0);  // REASON_ALLOWED
    }

    function test_DefaultRelease_executeRelease() public {
        // executeRelease is not implemented in v1, should revert
        vm.expectRevert();
        relStrategy.executeRelease(1, address(this), "");
    }

    function test_DefaultRelease_Metadata() public {
        assertEq(relStrategy.moduleName(), "DefaultBuyerRelease");
        assertEq(relStrategy.strategyName(), "DefaultBuyerRelease");
        assertEq(relStrategy.moduleVersion(), "1.0.0");
        assertTrue(relStrategy.supportsInterface(type(IReleaseStrategy).interfaceId));
        assertFalse(relStrategy.supportsInterface(0x12345678));
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
        (bool auth, uint8 role) = resModule.isAuthorizedDisputeResolver(1, address(this), resolver, "");
        assertTrue(auth);
        assertEq(role, 0);

        (auth, role) = resModule.isAuthorizedDisputeResolver(1, address(this), address(0x999), "");
        assertFalse(auth);
    }

    function test_DefaultRes_getDisputeResolver() public {
        (address r, uint8 l) = resModule.getDisputeResolver(1, address(this), "");
        assertEq(r, resolver);
        assertEq(l, 0);
    }

    function test_DefaultRes_Escalation() public {
        (bool can, address next, uint256 fee) = resModule.canEscalate(1, address(this), 0, "");
        assertFalse(can);
        assertEq(next, address(0));
        assertEq(fee, 0);

        (bool success, address newR, uint8 newL) = resModule.executeEscalation(1, address(this), "");
        assertFalse(success);
        assertEq(newR, address(0));
        assertEq(newL, 0);
    }

    function test_DefaultRes_Metadata() public {
        assertEq(resModule.moduleName(), "DefaultSingleResolver");
        assertEq(resModule.moduleVersion(), "1.0.0");
        assertTrue(resModule.supportsInterface(type(IResolutionModule).interfaceId));
        assertFalse(resModule.supportsInterface(0x12345678));
    }

    function test_DefaultRes_AdditionalFunctions() public {
        (uint256 amount, address bondToken) = resModule.getRequiredAppealBond(1, address(this), 0, "");
        assertEq(amount, 0);
        assertEq(bondToken, address(0));

        address inc = resModule.incentiveModule();
        assertEq(inc, address(0));
    }
}
