// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import 'forge-std/Test.sol';
import '../../../contracts/modules/decentralized-resolution-module/DecentralizedResolutionModule.sol';
import '../../../contracts/modules/decentralized-resolution-module/DRMAdminFacet.sol';
import '../../../contracts/modules/decentralized-resolution-module/DecentralizedResolverStructs.sol';
import '../../../contracts/types/EscrowTypes.sol';
import '../../../contracts/shared/interfaces/IResolutionModule.sol';

contract VersionedResolutionConfigTest is Test {
    DecentralizedResolutionModule internal drm;
    DRMAdminFacet internal facet;
    address internal constant ESCROW = address(0xE5C0);
    address internal constant RESOLVER = address(0xA11CE);
    address internal constant SENIOR = address(0xB0B);
    address internal constant EXTERNAL = address(0xCAFE);
    address internal constant BOND_A = address(0xB0A);
    address internal constant BOND_B = address(0xB0B0);
    bytes32 internal constant CATEGORY_A = keccak256('category-a');
    bytes32 internal constant CATEGORY_B = keccak256('category-b');

    function setUp() public {
        drm = new DecentralizedResolutionModule(address(this));
        facet = new DRMAdminFacet();
        drm.setAdminFacet(address(facet));
        drm.grantRole(drm.ROLE_TIMELOCK(), address(this));
        drm.registerEscrowContract(ESCROW);
        drm.appointSeniorResolver(SENIOR, 'senior', '');
        vm.prank(SENIOR);
        drm.appointResolver(RESOLVER, 'resolver', '');
    }

    function _policyConfig(address bondAsset) internal view returns (DecentralizedResolverStructs.ResolutionConfig memory config) {
        config = drm.getResolutionConfig(1);
        config.escalationCostConfig.bondToken = bondAsset;
        config.bondAssetFixed = true;
        config.categoryKeys = new bytes32[](1);
        config.categoryKeys[0] = CATEGORY_A;
    }

    function test_boundConfigRetainsCostAndExternalBackstopAfterActivation() public {
        bytes memory escrowData = abi.encode(address(0x1234), address(1), address(2), 100 ether, address(0));
        vm.prank(ESCROW);
        drm.initializeDisputeWithCategoryAndConfig(1, ESCROW, escrowData, 1);

        DecentralizedResolverStructs.ResolutionConfig memory config = drm.getResolutionConfig(1);
        bytes32 rootOne = drm.resolutionConfigRoot(1);
        config.resolveDeadlines[0] = 3 hours;
        config.escalationCostConfig.baseCost = 5 ether;
        config.externalResolver = EXTERNAL;
        config.escalationConfigs[2].enabled = true;
        drm.publishResolutionConfig(config);
        drm.activateResolutionConfig(2);

        assertEq(drm.workflowResolutionConfigVersion(ESCROW, 1), 1);
        assertTrue(rootOne != drm.resolutionConfigRoot(2));

        // Bound workflow uses v1's cost and has no external backstop.
        (uint256 oldCost, ) = drm.getRequiredAppealBond(1, ESCROW, 1, escrowData);
        assertEq(oldCost, 0.02 ether);

        // An unbound legacy workflow substitutes the active default (v2).
        (uint256 newCost, ) = drm.getRequiredAppealBond(2, ESCROW, 0, escrowData);
        assertEq(newCost, 5 ether);
        (uint256 backstopCost, ) = drm.getRequiredAppealBond(2, ESCROW, 1, escrowData);
        assertEq(backstopCost, 0);
    }

    function test_configAwareInitializationUsesBoundDeadline() public {
        DecentralizedResolverStructs.ResolutionConfig memory config = drm.getResolutionConfig(1);
        config.resolveDeadlines[0] = 3 hours;
        drm.publishResolutionConfig(config);
        drm.activateResolutionConfig(2);

        bytes memory escrowData = abi.encode(address(0x1234), address(1), address(2), 100 ether, address(0));
        uint256 openedAt = block.timestamp;
        vm.prank(ESCROW);
        drm.initializeDisputeWithCategoryAndConfig(9, ESCROW, escrowData, 2);

        DecentralizedResolverStructs.DisputeMetadata memory metadata = drm.getDisputeMetadata(9, ESCROW);
        assertEq(drm.workflowResolutionConfigVersion(ESCROW, 9), 2);
        assertEq(metadata.resolveBy, openedAt + 3 hours);
    }

    function test_legacyInitializerFallsBackToTheActiveDefault() public {
        DecentralizedResolverStructs.ResolutionConfig memory config = drm.getResolutionConfig(1);
        config.resolveDeadlines[0] = 4 hours;
        drm.publishResolutionConfig(config);
        drm.setDefaultResolutionConfigVersion(2);

        bytes memory escrowData = abi.encode(address(0x1234), address(1), address(2), 100 ether, address(0));
        uint256 openedAt = block.timestamp;
        vm.prank(ESCROW);
        drm.initializeDisputeWithCategory(10, ESCROW, escrowData);

        DecentralizedResolverStructs.DisputeMetadata memory metadata = drm.getDisputeMetadata(10, ESCROW);
        assertEq(drm.workflowResolutionConfigVersion(ESCROW, 10), 0);
        assertEq(metadata.resolveBy, openedAt + 4 hours);
    }

    function test_legacyCostActivationPublishesSuccessorWithoutChangingBoundWorkflow() public {
        bytes memory escrowData = abi.encode(address(0x1234), address(1), address(2), 100 ether, address(0));
        vm.prank(ESCROW);
        drm.initializeDisputeWithCategoryAndConfig(20, ESCROW, escrowData, 1);

        DecentralizedResolverStructs.EscalationCostConfig memory cost = drm.getResolutionConfig(1).escalationCostConfig;
        cost.baseCost = 7 ether;
        cost.stepSize = 0;
        drm.queueEscalationCostConfig(cost);
        vm.warp(block.timestamp + 7 days + 1);
        drm.activateEscalationCostConfig();

        assertEq(drm.activeResolutionConfigVersion(), 2);
        (uint256 boundCost, ) = drm.getRequiredAppealBond(20, ESCROW, 0, escrowData);
        (uint256 currentCost, ) = drm.getRequiredAppealBond(21, ESCROW, 0, escrowData);
        assertEq(boundCost, 0.01 ether);
        assertEq(currentCost, 7 ether);
    }

    function test_boundConfigRetainsBondAssetWhileResolverMembershipRemainsLive() public {
        address resolverB = address(0xBEEF);
        vm.prank(SENIOR);
        drm.appointResolver(resolverB, 'resolver-b', '');

        drm.publishResolutionConfig(_policyConfig(BOND_A));
        drm.activateResolutionConfig(2);
        drm.publishResolutionConfig(_policyConfig(BOND_B));
        drm.activateResolutionConfig(3);

        bytes memory escrowData = abi.encode(address(0x1234), address(1), address(2), 100 ether, address(0));
        vm.prank(ESCROW);
        drm.setEscrowCategory(11, ESCROW, CATEGORY_A);
        vm.prank(ESCROW);
        drm.initializeDisputeWithCategoryAndConfig(11, ESCROW, escrowData, 2);

        DecentralizedResolverStructs.DisputeMetadata memory metadata = drm.getDisputeMetadata(11, ESCROW);
        assertTrue(metadata.resolverAtRound[0] == RESOLVER || metadata.resolverAtRound[0] == resolverB);
        (, address bondAsset) = drm.getRequiredAppealBond(11, ESCROW, 0, escrowData);
        assertEq(bondAsset, BOND_A);
    }

    function test_configRootCommitsToPolicyAndRemainsImmutable() public {
        DecentralizedResolverStructs.ResolutionConfig memory config = _policyConfig(BOND_A);
        drm.publishResolutionConfig(config);
        bytes32 policyRoot = drm.resolutionConfigRoot(2);

        config.escalationCostConfig.bondToken = BOND_B;
        config.categoryKeys[0] = keccak256('category-b');
        drm.publishResolutionConfig(config);
        drm.activateResolutionConfig(3);

        assertTrue(policyRoot != drm.resolutionConfigRoot(3));
        config.bondAssetFixed = false;
        drm.publishResolutionConfig(config);
        assertTrue(drm.resolutionConfigRoot(3) != drm.resolutionConfigRoot(4));
        config.minEmaScoreThreshold++;
        config.categoryRouteBehavior = DecentralizedResolverStructs.CategoryRouteBehavior.CATEGORY_ONLY;
        drm.publishResolutionConfig(config);
        assertTrue(drm.resolutionConfigRoot(4) != drm.resolutionConfigRoot(5));
        drm.deprecateResolutionConfig(2);
        assertEq(drm.resolutionConfigRoot(2), policyRoot);
        DecentralizedResolverStructs.ResolutionConfig memory stored = drm.getResolutionConfig(2);
        assertEq(stored.escalationCostConfig.bondToken, BOND_A);
        assertEq(stored.categoryKeys[0], CATEGORY_A);
    }

    function test_boundRoutingUsesPolicyAInsteadOfMutableGlobalOrPolicyB() public {
        // Create a live resolver that is below policy B's threshold but above policy A's.
        vm.prank(ESCROW);
        drm.initializeDispute(70, ESCROW, RESOLVER, CATEGORY_A);
        DecentralizedResolverStructs.DisputeMetadata memory timedOut = drm.getDisputeMetadata(70, ESCROW);
        vm.warp(timedOut.resolveBy);
        vm.prank(ESCROW);
        drm.forceProgress(70, ESCROW);

        DecentralizedResolverStructs.ResolutionConfig memory policyA = _policyConfig(BOND_A);
        policyA.minEmaScoreThreshold = 800_000;
        policyA.maxTimeoutRateBps = 10_000;
        drm.publishResolutionConfig(policyA);

        DecentralizedResolverStructs.ResolutionConfig memory policyB = _policyConfig(BOND_B);
        policyB.minEmaScoreThreshold = 950_000;
        policyB.maxTimeoutRateBps = 10_000;
        drm.publishResolutionConfig(policyB);

        // Changing globals cannot make a policy-A workflow ineligible.
        drm.setEMAParameters(1_000, 1_000_000, 0);
        bytes memory escrowData = abi.encode(address(0x1234), address(1), address(2), 100 ether, address(0));
        vm.prank(ESCROW);
        drm.initializeDisputeWithCategoryAndConfig(71, ESCROW, escrowData, 2);
        assertEq(drm.getDisputeMetadata(71, ESCROW).resolverAtRound[0], RESOLVER);

        // The same live member is invalid under stricter policy B.
        vm.prank(ESCROW);
        drm.initializeDisputeWithCategoryAndConfig(72, ESCROW, escrowData, 3);
        assertEq(drm.getDisputeMetadata(72, ESCROW).resolverAtRound[0], address(0));
    }

    function test_boundPolicyFreezesCategoryButUsesLiveMembers() public {
        address resolverB = address(0xBEEF);
        vm.prank(SENIOR);
        drm.appointResolver(resolverB, 'resolver-b', '');

        DecentralizedResolverStructs.ResolutionConfig memory config = _policyConfig(BOND_A);
        config.categoryRouteBehavior = DecentralizedResolverStructs.CategoryRouteBehavior.CATEGORY_ONLY;
        drm.publishResolutionConfig(config);

        // Membership is intentionally live: a member appointed after publication is eligible.
        drm.setResolverActive(RESOLVER, false);
        bytes memory escrowData = abi.encode(address(0x1234), address(1), address(2), 100 ether, address(0));
        vm.prank(ESCROW);
        drm.setEscrowCategory(73, ESCROW, CATEGORY_A);
        vm.prank(ESCROW);
        drm.initializeDisputeWithCategoryAndConfig(73, ESCROW, escrowData, 2);
        assertEq(drm.getDisputeMetadata(73, ESCROW).resolverAtRound[0], resolverB);

        // A later escrow-side category write cannot redirect the bound dispute's appeal route.
        vm.prank(ESCROW);
        drm.setEscrowCategory(73, ESCROW, CATEGORY_B);
        vm.prank(ESCROW);
        drm.recordResolution(73, ESCROW, resolverB, ResolutionOutcome.RELEASE, 1);
        IResolutionModule.ResolutionAppealQuote memory quote = drm.quoteAppealTransition(73, ESCROW, escrowData);
        assertTrue(quote.appealable);
        assertEq(quote.successorResolver, SENIOR);
        assertEq(drm.getDisputeMetadata(73, ESCROW).categoryKey, CATEGORY_A);
    }

    function test_boundSelectionStillHonorsPauseAndCapacity() public {
        DecentralizedResolverStructs.ResolutionConfig memory config = _policyConfig(BOND_A);
        drm.publishResolutionConfig(config);
        bytes memory escrowData = abi.encode(address(0x1234), address(1), address(2), 100 ether, address(0));

        drm.pauseNewAssignments('incident');
        vm.prank(ESCROW);
        drm.initializeDisputeWithCategoryAndConfig(74, ESCROW, escrowData, 2);
        assertEq(drm.getDisputeMetadata(74, ESCROW).resolverAtRound[0], address(0));

        drm.resumeNewAssignments();
        drm.setResolverCapacity(RESOLVER, 1, false);
        vm.prank(ESCROW);
        drm.initializeDisputeWithCategoryAndConfig(75, ESCROW, escrowData, 2);
        assertEq(drm.getDisputeMetadata(75, ESCROW).resolverAtRound[0], address(0));
    }

    function test_selectableStatusDistinguishesPublishedAndDeprecatedConfigs() public {
        DecentralizedResolverStructs.ResolutionConfig memory config = drm.getResolutionConfig(1);
        drm.publishResolutionConfig(config);

        (bool exists, bool selectable, bool deprecated, bytes32 root) = drm.resolutionConfigStatus(2);
        assertTrue(exists);
        assertTrue(selectable);
        assertFalse(deprecated);
        assertEq(root, drm.resolutionConfigRoot(2));

        drm.setResolutionConfigSelectable(2, false);
        assertFalse(drm.isResolutionConfigSelectable(2));
        drm.setResolutionConfigSelectable(2, true);
        drm.activateResolutionConfig(2);

        DecentralizedResolverStructs.ResolutionConfig memory successor = drm.getResolutionConfig(2);
        successor.resolveDeadlines[0] = 3 hours;
        drm.publishResolutionConfig(successor);
        drm.activateResolutionConfig(3);
        drm.deprecateResolutionConfig(2);

        (, selectable, deprecated,) = drm.resolutionConfigStatus(2);
        assertFalse(selectable);
        assertTrue(deprecated);
    }

    function test_deprecatedBoundConfigStillInitializesWithItsFrozenSemantics() public {
        DecentralizedResolverStructs.ResolutionConfig memory config = drm.getResolutionConfig(1);
        config.resolveDeadlines[0] = 3 hours;
        drm.publishResolutionConfig(config);
        drm.activateResolutionConfig(2);

        DecentralizedResolverStructs.ResolutionConfig memory successor = drm.getResolutionConfig(2);
        successor.resolveDeadlines[0] = 4 hours;
        drm.publishResolutionConfig(successor);
        drm.activateResolutionConfig(3);
        drm.deprecateResolutionConfig(2);

        bytes memory escrowData = abi.encode(address(0x1234), address(1), address(2), 100 ether, address(0));
        uint256 openedAt = block.timestamp;
        vm.prank(ESCROW);
        drm.initializeDisputeWithCategoryAndConfig(99, ESCROW, escrowData, 2);

        assertEq(drm.workflowResolutionConfigVersion(ESCROW, 99), 2);
        assertEq(drm.getDisputeMetadata(99, ESCROW).resolveBy, openedAt + 3 hours);
    }
}
