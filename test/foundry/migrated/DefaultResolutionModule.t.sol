// SPDX-License-Identifier: MIT
import "../../../contracts/types/YieldPresets.sol";
pragma solidity ^0.8.33;

import 'forge-std/Test.sol';
import 'contracts/core/modules/DefaultResolutionModule.sol';
import 'contracts/shared/interfaces/IResolutionModule.sol';

contract Test_DefaultResolutionModule is Test {
    DefaultResolutionModule rm;
    address resolver = address(0x123);

    function setUp() public {
        rm = new DefaultResolutionModule(address(this), resolver);
    }

    function test_authorization_and_getter() public {
        (bool auth, uint8 role) = rm.isAuthorizedDisputeResolver(0, resolver, '');
        assertTrue(auth);
        assertEq(role, 0);

        (bool auth2, ) = rm.isAuthorizedDisputeResolver(0, address(0x456), '');
        assertFalse(auth2);

        (address d, uint8 lvl) = rm.getDisputeResolver(0, '');
        assertEq(d, resolver);
        assertEq(lvl, 0);
    }

    function test_escalation_and_bond() public {
        (bool can, address next, uint256 fee) = rm.canEscalate(0, 0, '');
        assertFalse(can);
        assertEq(next, address(0));
        assertEq(fee, 0);

        (bool success, address newRes, uint8 newLevel) = rm.executeEscalation(0, '');
        assertFalse(success);
        assertEq(newRes, address(0));
        assertEq(newLevel, 0);

        (uint256 amt, address tok) = rm.getRequiredAppealBond(0, 0, '');
        assertEq(amt, 0);
        assertEq(tok, address(0));
    }

    function test_module_meta_and_interface() public {
        assertEq(rm.moduleName(), 'DefaultSingleResolver');
        assertEq(rm.moduleVersion(), '1.0.0');

        bytes4 iid = type(IResolutionModule).interfaceId;
        assertTrue(rm.supportsInterface(iid));
    }
}
