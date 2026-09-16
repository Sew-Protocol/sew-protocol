// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import 'forge-std/Test.sol';
import '../../../contracts/core/EscrowVault.sol';
import '../../../contracts/core/EscrowableERC20.sol';
import '../../../contracts/core/ModuleSnapshotRegistry.sol';
import '../../../contracts/core/BondCollector.sol';
import '../../../contracts/mocks/ERC20Mock.sol';
import '../../../contracts/ops/YieldOps.sol';
import '../../../contracts/core/EscrowCreationPolicy.sol';
import '../../../contracts/libraries/SettingsValidationLibrary.sol';
import '../../../contracts/types/EscrowTypes.sol';
import '../../../contracts/modules/decentralized-resolution-module/DecentralizedResolutionModule.sol';
import '../../../contracts/modules/decentralized-resolution-module/DRMAdminFacet.sol';
import '../../../contracts/modules/decentralized-resolution-module/DecentralizedResolverStructs.sol';
import '../../../contracts/modules/decentralized-resolution-module/ResolverIncentiveModuleV2.sol';
import '../../../contracts/modules/decentralized-resolution-module/PaymentCalculationLibraryV1.sol';
import '../helpers/KlerosHandoffFixture.sol';

/// @notice Product-level coverage for direct DRM config selection entry points.
contract DirectResolutionConfigSelectionIntegrationTest is Test, KlerosHandoffFixture {
    EscrowVault internal vault;
    EscrowableERC20 internal escrowToken;
    ERC20Mock internal paymentToken;
    ERC20Mock internal bondToken;
    DecentralizedResolutionModule internal drm;

    address internal constant BUYER = address(0xB0B);
    address internal constant SELLER = address(0xA11CE);
    address internal constant RESOLVER = address(0xBEEF);
    address internal constant SENIOR = address(0xCAFE);
    address internal externalBackstop;
    address internal constant FEE_RECIPIENT = address(0xFEE);
    bytes32 internal constant DIRECT_CATEGORY = keccak256('direct-policy-category');

    event ResolutionConfigBound(uint256 indexed workflowId, address indexed resolutionModule, uint256 indexed version, bytes32 configRoot);

    function setUp() public {
        YieldOps yieldOps = new YieldOps(address(this));
        EscrowCreationPolicy creationPolicy = new EscrowCreationPolicy(address(this));
        BondCollector bondCollector = new BondCollector(address(this));
        ModuleSnapshotRegistry registry = new ModuleSnapshotRegistry(address(this));

        vault = new EscrowVault(0,FEE_RECIPIENT,address(yieldOps),address(registry));
        escrowToken = new EscrowableERC20('Escrow','ESC',0,FEE_RECIPIENT,address(yieldOps),address(registry));
        paymentToken = new ERC20Mock('Payment', 'PAY', BUYER, 1_000 ether);
        bondToken = new ERC20Mock('Bond', 'BOND', BUYER, 1_000 ether);
        (KlerosArbitrableProxy proxy, ) = _deployKlerosHandoffProxy(address(vault), address(this), 0);
        externalBackstop = address(proxy);

        _wireEscrow(address(vault), registry, yieldOps, creationPolicy, bondCollector);
        _wireEscrow(address(escrowToken), registry, yieldOps, creationPolicy, bondCollector);
        vault.grantRole(vault.ROLE_ADMIN_CONTRACT(), address(this));
        vault.setCreationPolicy(address(creationPolicy));
        vault.setBondCollector(address(bondCollector));
        escrowToken.grantRole(escrowToken.ROLE_ADMIN_CONTRACT(), address(this));
        escrowToken.setCreationPolicy(address(creationPolicy));
        escrowToken.setBondCollector(address(bondCollector));

        drm = new DecentralizedResolutionModule(address(this));
        drm.setAdminFacet(address(new DRMAdminFacet()));
        drm.grantRole(drm.ROLE_TIMELOCK(), address(this));
        drm.registerEscrowContract(address(vault));
        drm.registerEscrowContract(address(escrowToken));
        drm.appointSeniorResolver(SENIOR, 'senior', '');
        vm.prank(SENIOR);
        drm.appointResolver(RESOLVER, 'resolver', '');
        drm.setResolverActive(SENIOR, true);
        drm.setResolverActive(RESOLVER, true);
        drm.setResolverCapacity(SENIOR, 0, true);
        drm.setResolverCapacity(RESOLVER, 0, true);

        PaymentCalculationLibraryV1 paymentLibrary = new PaymentCalculationLibraryV1();
        ResolverIncentiveModuleV2 incentive = new ResolverIncentiveModuleV2(address(this), address(paymentLibrary));
        incentive.grantRole(incentive.ROLE_TIMELOCK(), address(this));
        incentive.registerEscrowContract(address(vault));
        incentive.registerEscrowContract(address(escrowToken));
        incentive.registerEscrowContract(address(bondCollector));
        incentive.registerEscrowContract(address(drm));
        drm.setIncentiveModule(address(incentive));

        vault.setResolutionModule(address(drm));
        escrowToken.setResolutionModule(address(drm));

        escrowToken.transfer(BUYER, 1_000 ether);
        vm.prank(BUYER);
        paymentToken.approve(address(vault), type(uint256).max);
    }

    function _wireEscrow(
        address escrow,
        ModuleSnapshotRegistry registry,
        YieldOps yieldOps,
        EscrowCreationPolicy creationPolicy,
        BondCollector bondCollector
    ) internal {
        registry.registerEscrowContract(escrow);
        yieldOps.registerEscrowContract(escrow);
        bondCollector.registerEscrowContract(escrow);
    }

    function _publishPolicyB() internal returns (uint256 version) {
        DecentralizedResolverStructs.ResolutionConfig memory config = drm.getResolutionConfig(1);
        config.resolveDeadlines[0] = 3 hours;
        config.appealWindows[0] = 1 hours;
        config.appealWindows[1] = 1 hours;
        config.escalationConfigs[1].enabled = true;
        config.escalationConfigs[2].enabled = true;
        config.escalationCostConfig.enabled = true;
        config.escalationCostConfig.baseCost = 2 ether;
        config.escalationCostConfig.stepSize = 0;
        config.escalationCostConfig.bondToken = address(bondToken);
        config.bondAssetFixed = true;
        config.externalResolver = externalBackstop;
        config.categoryKeys = new bytes32[](1);
        config.categoryKeys[0] = DIRECT_CATEGORY;
        config.categoryRouteBehavior = DecentralizedResolverStructs.CategoryRouteBehavior.CATEGORY_ONLY;
        drm.publishResolutionConfig(config);
        return 2;
    }

    function _activateCAndDeprecateB(uint256 policyB) internal returns (uint256 policyC) {
        DecentralizedResolverStructs.ResolutionConfig memory config = drm.getResolutionConfig(policyB);
        config.resolveDeadlines[0] = 4 hours;
        config.categoryKeys = new bytes32[](0);
        drm.publishResolutionConfig(config);
        policyC = policyB + 1;
        drm.activateResolutionConfig(policyC);
        drm.deprecateResolutionConfig(policyB);
    }

    function _createVault(uint256 version) internal returns (uint256 workflowId) {
        vm.prank(BUYER);
        if (version == 0) {
            workflowId = vault.createEscrow(address(paymentToken), SELLER, 100 ether, SettingsValidationLibrary.getDefaultSettings());
        } else {
            workflowId = vault.createEscrowWithResolutionConfig(
                address(paymentToken), SELLER, 100 ether, SettingsValidationLibrary.getDefaultSettings(), version
            );
        }
    }

    function _createToken(uint256 version) internal returns (uint256 workflowId) {
        vm.prank(BUYER);
        if (version == 0) {
            workflowId = escrowToken.createEscrow(SELLER, 100 ether, 0, 0);
        } else {
            workflowId = escrowToken.createEscrowWithResolutionConfig(SELLER, 100 ether, 0, 0, version);
        }
    }

    function test_directApisBindExplicitBAndEmitAuditEventsMatchingDRMState() public {
        uint256 policyB = _publishPolicyB();
        bytes32 root = drm.resolutionConfigRoot(policyB);

        vm.expectEmit(true, true, true, true, address(vault));
        emit ResolutionConfigBound(0, address(drm), policyB, root);
        uint256 vaultWorkflow = _createVault(policyB);

        vm.expectEmit(true, true, true, true, address(escrowToken));
        emit ResolutionConfigBound(0, address(drm), policyB, root);
        uint256 tokenWorkflow = _createToken(policyB);

        assertEq(vaultWorkflow, 0);
        assertEq(vault.workflowResolutionConfigVersion(vaultWorkflow), policyB);
        assertEq(escrowToken.workflowResolutionConfigVersion(tokenWorkflow), policyB);

        vm.prank(BUYER);
        vault.raiseDispute(vaultWorkflow);
        vm.prank(BUYER);
        escrowToken.raiseDispute(tokenWorkflow);
        assertEq(drm.workflowResolutionConfigVersion(address(vault), vaultWorkflow), policyB);
        assertEq(drm.workflowResolutionConfigVersion(address(escrowToken), tokenWorkflow), policyB);
        assertEq(vault.workflowResolutionConfigVersion(vaultWorkflow), drm.workflowResolutionConfigVersion(address(vault), vaultWorkflow));
        assertEq(
            escrowToken.workflowResolutionConfigVersion(tokenWorkflow),
            drm.workflowResolutionConfigVersion(address(escrowToken), tokenWorkflow)
        );
    }

    function test_explicitBRemainsRoutableAndExecutableAfterCActivationAndBDeprecation() public {
        uint256 workflowId = _createVault(_publishPolicyB());
        vm.prank(address(vault));
        drm.setEscrowCategory(workflowId, address(vault), DIRECT_CATEGORY);

        uint256 policyB = vault.workflowResolutionConfigVersion(workflowId);
        uint256 policyC = _activateCAndDeprecateB(policyB);
        assertEq(drm.activeResolutionConfigVersion(), policyC);
        assertFalse(drm.isResolutionConfigSelectable(policyB));

        vm.prank(BUYER);
        vault.raiseDispute(workflowId);
        DecentralizedResolverStructs.DisputeMetadata memory metadata = drm.getDisputeMetadata(workflowId, address(vault));
        assertEq(drm.workflowResolutionConfigVersion(address(vault), workflowId), policyB);
        assertEq(metadata.resolverAtRound[0], RESOLVER);
        assertEq(metadata.resolveBy, block.timestamp + 3 hours);

        vm.prank(RESOLVER);
        vault.releaseAsDisputeResolver(workflowId, bytes32('round-zero'));
        IEscrowAppeal.AppealQuote memory firstQuote = vault.getAppealQuote(workflowId, BUYER);
        assertTrue(firstQuote.appealable);
        assertEq(firstQuote.bondAsset, address(bondToken));
        assertEq(firstQuote.bondAmount, 2 ether);
        assertEq(firstQuote.successorResolver, SENIOR);

        vm.startPrank(BUYER);
        bondToken.approve(address(vault), firstQuote.bondAmount);
        vault.escalateDispute(workflowId);
        vm.stopPrank();

        vm.prank(SENIOR);
        vault.releaseAsDisputeResolver(workflowId, bytes32('round-one'));
        IEscrowAppeal.AppealQuote memory backstopQuote = vault.getAppealQuote(workflowId, BUYER);
        assertTrue(backstopQuote.appealable);
        assertEq(backstopQuote.successorResolver, externalBackstop);
        assertEq(backstopQuote.bondAmount, 0);
        assertEq(backstopQuote.bondAsset, address(0));

        vm.prank(BUYER);
        (bool success, address resolver, uint8 level) = vault.escalateDispute(workflowId);
        assertTrue(success);
        assertEq(resolver, externalBackstop);
        assertEq(level, 2);
    }

    function test_explicitDirectInvalidVersionsHaveParityAcrossProductsIncludingZero() public {
        uint256 policyB = _publishPolicyB();
        drm.setResolutionConfigSelectable(policyB, false);

        vm.startPrank(BUYER);
        vm.expectRevert(abi.encodeWithSelector(ResolutionConfigUnavailable.selector, address(drm), 0));
        vault.createEscrowWithResolutionConfig(address(paymentToken), SELLER, 1 ether, SettingsValidationLibrary.getDefaultSettings(), 0);
        vm.expectRevert(abi.encodeWithSelector(ResolutionConfigUnavailable.selector, address(drm), 0));
        escrowToken.createEscrowWithResolutionConfig(SELLER, 1 ether, 0, 0, 0);
        vm.expectRevert(abi.encodeWithSelector(ResolutionConfigUnavailable.selector, address(drm), 99));
        vault.createEscrowWithResolutionConfig(address(paymentToken), SELLER, 1 ether, SettingsValidationLibrary.getDefaultSettings(), 99);
        vm.expectRevert(abi.encodeWithSelector(ResolutionConfigUnavailable.selector, address(drm), 99));
        escrowToken.createEscrowWithResolutionConfig(SELLER, 1 ether, 0, 0, 99);
        vm.expectRevert(abi.encodeWithSelector(ResolutionConfigUnavailable.selector, address(drm), policyB));
        vault.createEscrowWithResolutionConfig(address(paymentToken), SELLER, 1 ether, SettingsValidationLibrary.getDefaultSettings(), policyB);
        vm.expectRevert(abi.encodeWithSelector(ResolutionConfigUnavailable.selector, address(drm), policyB));
        escrowToken.createEscrowWithResolutionConfig(SELLER, 1 ether, 0, 0, policyB);
        vm.stopPrank();
        assertEq(vault.getEscrowCount(), 0);
        assertEq(escrowToken.getEscrowCount(), 0);

        drm.setResolutionConfigSelectable(policyB, true);
        _activateCAndDeprecateB(policyB);
        vm.startPrank(BUYER);
        vm.expectRevert(abi.encodeWithSelector(ResolutionConfigUnavailable.selector, address(drm), policyB));
        vault.createEscrowWithResolutionConfig(address(paymentToken), SELLER, 1 ether, SettingsValidationLibrary.getDefaultSettings(), policyB);
        vm.expectRevert(abi.encodeWithSelector(ResolutionConfigUnavailable.selector, address(drm), policyB));
        escrowToken.createEscrowWithResolutionConfig(SELLER, 1 ether, 0, 0, policyB);
        vm.stopPrank();
        assertEq(vault.getEscrowCount(), 0);
        assertEq(escrowToken.getEscrowCount(), 0);
    }

    function test_explicitSelectionSupportsCompleteVaultLifecycle() public {
        uint256 policyB = _publishPolicyB();
        uint256 workflowId = _createVault(policyB);

        vm.prank(BUYER);
        vault.raiseDispute(workflowId);
        vm.prank(RESOLVER);
        vault.releaseAsDisputeResolver(workflowId, bytes32('release'));

        assertEq(vault.workflowResolutionConfigVersion(workflowId), policyB);
        assertEq(uint8(vault.getEscrowState(workflowId)), uint8(EscrowState.DISPUTED));
    }

    function test_customResolverCannotBeCombinedWithConfigSelectionAndHasNoEffects() public {
        uint256 policyB = _publishPolicyB();
        EscrowSettings memory settings = SettingsValidationLibrary.getDefaultSettings();
        settings.customResolver = address(new CustomResolver());
        uint256 buyerBalance = paymentToken.balanceOf(BUYER);

        vm.prank(BUYER);
        vm.expectRevert(abi.encodeWithSelector(ResolutionConfigWithCustomResolver.selector, settings.customResolver));
        vault.createEscrowWithResolutionConfig(address(paymentToken), SELLER, 1 ether, settings, policyB);

        assertEq(vault.getEscrowCount(), 0);
        assertEq(paymentToken.balanceOf(BUYER), buyerBalance);
    }

    function test_implicitAndExplicitAHaveEquivalentDisputeAndQuoteSemantics() public {
        uint256 implicitA = _createVault(0);
        uint256 explicitA = _createVault(1);
        assertEq(vault.workflowResolutionConfigVersion(implicitA), 1);
        assertEq(vault.workflowResolutionConfigVersion(explicitA), 1);

        vm.prank(BUYER);
        vault.raiseDispute(implicitA);
        vm.prank(BUYER);
        vault.raiseDispute(explicitA);

        DecentralizedResolverStructs.DisputeMetadata memory implicitMetadata = drm.getDisputeMetadata(implicitA, address(vault));
        DecentralizedResolverStructs.DisputeMetadata memory explicitMetadata = drm.getDisputeMetadata(explicitA, address(vault));
        assertEq(implicitMetadata.resolverAtRound[0], explicitMetadata.resolverAtRound[0]);
        assertEq(implicitMetadata.resolveBy, explicitMetadata.resolveBy);

        vm.prank(RESOLVER);
        vault.releaseAsDisputeResolver(implicitA, bytes32('implicit-a'));
        vm.prank(RESOLVER);
        vault.releaseAsDisputeResolver(explicitA, bytes32('explicit-a'));
        IEscrowAppeal.AppealQuote memory implicitQuote = vault.getAppealQuote(implicitA, BUYER);
        IEscrowAppeal.AppealQuote memory explicitQuote = vault.getAppealQuote(explicitA, BUYER);
        assertEq(implicitQuote.appealable, explicitQuote.appealable);
        assertEq(implicitQuote.predecessorRound, explicitQuote.predecessorRound);
        assertEq(implicitQuote.successorRound, explicitQuote.successorRound);
        assertEq(implicitQuote.predecessorResolver, explicitQuote.predecessorResolver);
        assertEq(implicitQuote.successorResolver, explicitQuote.successorResolver);
        assertEq(implicitQuote.appealDeadline, explicitQuote.appealDeadline);
        assertEq(implicitQuote.bondAsset, explicitQuote.bondAsset);
        assertEq(implicitQuote.bondAmount, explicitQuote.bondAmount);
    }
}

contract CustomResolver {}
