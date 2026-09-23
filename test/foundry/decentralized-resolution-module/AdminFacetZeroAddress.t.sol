// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.37;

import 'forge-std/Test.sol';
import '../../../contracts/modules/decentralized-resolution-module/DecentralizedResolutionModule.sol';
import '../../../contracts/modules/decentralized-resolution-module/DRMAdminFacet.sol';

/**
 * @title AdminFacetZeroAddressTest
 * @notice Guards the adminFacet pointer against address(0).
 * @dev Aderyn L-13 (address set without checks) review: adminFacet is a "must
 *      never be zero" binding. DecentralizedResolutionModule::_delegateAdmin
 *      reverts AdminFacetNotSet() when adminFacet is address(0), so zero is never
 *      a legitimate configured value — only an error state. These tests pin the
 *      set-time early rejection on the DRM bootstrap and TIMELOCK-rotation paths.
 *      DRMAdminFacet.setAdminFacet is intentionally not covered: DRM defines its
 *      own setAdminFacet directly, so the fallback never routes the selector to
 *      the facet; the facet setter is not production-reachable.
 */
contract AdminFacetZeroAddressTest is Test {
    bytes32 public constant ROLE_TIMELOCK = keccak256('ROLE_TIMELOCK');

    address public owner;
    address public timelock;

    function setUp() public {
        owner = address(this);
        timelock = makeAddr('timelock');
    }

    function test_drm_setAdminFacet_zero_reverts_on_bootstrap() public {
        DecentralizedResolutionModule drm = new DecentralizedResolutionModule(owner);
        // First (bootstrap) call is authorized to DEFAULT_ADMIN_ROLE (owner).
        vm.expectRevert(abi.encodeWithSelector(DecentralizedResolutionModule.ZeroAddress.selector, 'adminFacet'));
        drm.setAdminFacet(address(0));
    }

    function test_drm_setAdminFacet_zero_reverts_on_rotation() public {
        DecentralizedResolutionModule drm = new DecentralizedResolutionModule(owner);
        drm.setAdminFacet(address(new DRMAdminFacet()));
        drm.grantRole(ROLE_TIMELOCK, timelock);

        vm.prank(timelock);
        vm.expectRevert(abi.encodeWithSelector(DecentralizedResolutionModule.ZeroAddress.selector, 'adminFacet'));
        drm.setAdminFacet(address(0));
    }
}
