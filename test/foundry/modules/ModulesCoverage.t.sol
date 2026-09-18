// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import 'forge-std/Test.sol';
import '../../../contracts/modules/DefaultReleaseStrategy.sol';
import '../../../contracts/modules/DefaultResolutionModule.sol';
import '../../../contracts/mocks/ERC20Mock.sol';
import '../../../contracts/libraries/EscrowEncodingLibrary.sol';

contract ModulesCoverageTest is Test {
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

        relStrategy = new DefaultReleaseStrategy();
        resModule = new DefaultResolutionModule(owner, resolver);
        token = new ERC20Mock("Test", "TEST", address(this), 10000e18);

        // Grant TIMELOCK role
        resModule.grantRole(resModule.ROLE_TIMELOCK(), timelock);
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
