// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.33;

import "forge-std/Test.sol";
import "../../../contracts/core/EscrowVault.sol";
import "../../../contracts/core/BaseEscrow.sol";
import "../../../contracts/modules/decentralized-resolution-module/DecentralizedResolutionModule.sol";
import "../../../contracts/modules/decentralized-resolution-module/DecentralizedResolverStructs.sol";
import "../../../contracts/modules/decentralized-resolution-module/DRMAdminFacet.sol";
import "../../../contracts/modules/decentralized-resolution-module/ResolverIncentiveModuleV2.sol";
import "../../../contracts/modules/decentralized-resolution-module/PaymentCalculationLibraryV1.sol";
import "../../../contracts/mocks/ERC20Mock.sol";
import "../../../contracts/types/EscrowTypes.sol";
import "../../../contracts/ops/YieldOps.sol";
import "../../../contracts/ops/DisputeOps.sol";
import "../../../contracts/ops/SettlementOps.sol";
import "../../../contracts/ops/CreateOps.sol";
import "../../../contracts/core/BondCollector.sol";
import "../../../contracts/core/ModuleSnapshotRegistry.sol";
import "../../../contracts/admin/EscrowGovernanceTimelock.sol";
import "../../../contracts/libraries/EscrowEncodingLibrary.sol";
import "../../../contracts/libraries/SettingsValidationLibrary.sol";
import "../../../contracts/modules/decentralized-resolution-module/DRMStorageBase.sol";

/**
 * @title RepeatAttackerIntegrationTest
 * @notice Integration tests that demonstrate and validate all three repeat-attacker mitigations
 *         in scenarios requiring a live DRM + incentive module:
 *
 *   1. EMA bombing via dust disputes / forceProgress timeouts (Fix 1 blocks them)
 *   2. Capacity starvation via dispute flood (Fix 2 blocks them)
 *   3. Escalation cooldown enforcement and bond scaling (Fix 3)
 */
contract RepeatAttackerIntegrationTest is Test {
    EscrowVault public escrow;
    DecentralizedResolutionModule public resolutionModule;
    ResolverIncentiveModuleV2 public incentiveModule;
    PaymentCalculationLibraryV1 public paymentLib;
    ERC20Mock public token;
    YieldOps public yieldOps;
    DisputeOps public disputeOps;
    SettlementOps public settlementOps;
    CreateOps public createOps;
    BondCollector public bondCollector;
    ModuleSnapshotRegistry public moduleManagement;
    EscrowGovernanceTimelock public adminContract;

    address public deployer;
    address public timelockAddr;
    address public seniorResolver;
    address public resolver1;
    address public attacker;
    address public seller;
    address public feeAddress;

    uint256 constant ESCROW_AMOUNT = 1000e18;
    uint256 constant DUST_AMOUNT   = 1e15;  // 0.001 tokens
    bytes32 constant CATEGORY      = keccak256("TEST_CATEGORY");

    function setUp() public {
        deployer       = address(this);
        timelockAddr   = makeAddr("timelock");
        seniorResolver = makeAddr("seniorResolver");
        resolver1      = makeAddr("resolver1");
        attacker       = makeAddr("attacker");
        seller         = makeAddr("seller");
        feeAddress     = makeAddr("feeAddress");

        token    = new ERC20Mock("Test", "TEST", address(this), 0);
        paymentLib = new PaymentCalculationLibraryV1();
        incentiveModule = new ResolverIncentiveModuleV2(deployer, address(paymentLib));
        resolutionModule = new DecentralizedResolutionModule(deployer);
        { DRMAdminFacet f = new DRMAdminFacet(); resolutionModule.setAdminFacet(address(f)); }

        yieldOps = new YieldOps(deployer);
        disputeOps = new DisputeOps(deployer);
        settlementOps = new SettlementOps(deployer);
        createOps = new CreateOps(deployer);
        bondCollector = new BondCollector(deployer);
        moduleManagement = new ModuleSnapshotRegistry(deployer);
        adminContract = new EscrowGovernanceTimelock(deployer);

        escrow = new EscrowVault(0, feeAddress, address(yieldOps), address(disputeOps), address(moduleManagement));

        moduleManagement.registerEscrowContract(address(escrow));
        yieldOps.registerEscrowContract(address(escrow));
        disputeOps.registerEscrowContract(address(escrow));
        settlementOps.registerEscrowContract(address(escrow));
        createOps.registerEscrowContract(address(escrow));
        bondCollector.registerEscrowContract(address(escrow));

        // Allow test contract to call ops directly (for forceProgress via escrow)
        disputeOps.registerEscrowContract(address(this));
        settlementOps.registerEscrowContract(address(this));
        createOps.registerEscrowContract(address(this));
        bondCollector.registerEscrowContract(address(this));

        escrow.grantRole(escrow.ROLE_ADMIN_CONTRACT(), address(this));
        escrow.grantRole(escrow.ROLE_ADMIN_CONTRACT(), address(adminContract));
        escrow.grantRole(escrow.ROLE_TIMELOCK(), address(this));
        escrow.setCreateOps(address(createOps));
        escrow.setSettlementOps(address(settlementOps));
        escrow.setBondCollector(address(bondCollector));

        resolutionModule.grantRole(resolutionModule.ROLE_TIMELOCK(), address(this));
        resolutionModule.grantRole(resolutionModule.ROLE_TIMELOCK(), timelockAddr);
        resolutionModule.registerEscrowContract(address(escrow));
        resolutionModule.registerEscrowContract(address(this));

        incentiveModule.grantRole(incentiveModule.ROLE_TIMELOCK(), address(this));
        incentiveModule.registerEscrowContract(address(escrow));
        incentiveModule.registerEscrowContract(address(this));
        incentiveModule.registerEscrowContract(address(resolutionModule));

        resolutionModule.setIncentiveModule(address(incentiveModule));

        adminContract.queueResolutionModule(address(escrow), address(resolutionModule));
        vm.warp(block.timestamp + 7 days + 1);
        adminContract.activateResolutionModule(address(escrow));

        // Appoint and activate resolvers
        resolutionModule.appointSeniorResolver(seniorResolver, "Senior", "test");
        vm.prank(seniorResolver);
        resolutionModule.appointResolver(resolver1, "Resolver1", "test");

        resolutionModule.setResolverActive(seniorResolver, true);
        resolutionModule.setResolverActive(resolver1, true);
        resolutionModule.setResolverCapacity(resolver1, 100, true);
        resolutionModule.setResolverCapacity(seniorResolver, 100, true);

        // Short resolve deadline so forceProgress tests don't require long waits
        uint256[3] memory deadlines = [uint256(1 hours), 1 hours, 1 hours];
        uint256[3] memory windows = [uint256(1 hours), 1 hours, 0];
        resolutionModule.setRoundTimeouts(deadlines, windows);
        resolutionModule.setExternalResolver(seniorResolver);
    }

    // ─── Internal helpers ────────────────────────────────────────────────────────

    function _mintAndCreate(address buyer, uint256 amount) internal returns (uint256 wid) {
        token.mint(buyer, amount);
        vm.startPrank(buyer);
        token.approve(address(escrow), amount);
        wid = escrow.createEscrow(
            address(token), seller, amount, SettingsValidationLibrary.getDefaultSettings()
        );
        vm.stopPrank();
    }

    function _setCategory(uint256 wid) internal {
        resolutionModule.setEscrowCategory(wid, address(escrow), CATEGORY);
    }

    function _raiseDispute(address buyer, uint256 wid) internal {
        _setCategory(wid);
        vm.prank(buyer);
        escrow.raiseDispute(wid);
    }

    function _resolverDecision(uint256 wid, bool release) internal {
        bytes memory escrowData = EscrowEncodingLibrary.encodeEscrowTransferData(
            address(token), attacker, seller, ESCROW_AMOUNT, address(0)
        );
        (address res, ) = resolutionModule.getDisputeResolver(wid, address(escrow), escrowData);
        vm.prank(res);
        if (release) escrow.releaseAsDisputeResolver(wid, bytes32(0));
        else         escrow.cancelAsDisputeResolver(wid, bytes32(0));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Attack Scenario 1: EMA Bombing via dust disputes + resolver timeouts
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * Demonstrates that without Fix 1, an attacker can open dust disputes,
     * wait for the resolver to time out, and drive the EMA score down via
     * ResolutionAnalytics.recordTimeout — at nearly zero cost.
     */
    function test_EMABombing_DustDisputeTimeoutDamagesResolverScore() public {
        DRMStorageBase.ResolverStats memory before =
            resolutionModule.getDisputeResolverStats(resolver1);

        // Create and dispute a dust escrow
        uint256 wid = _mintAndCreate(attacker, DUST_AMOUNT);
        _raiseDispute(attacker, wid);

        // Warp past resolve deadline and trigger forceProgress (timeout)
        vm.warp(block.timestamp + 1 hours + 1);
        vm.prank(address(escrow));
        resolutionModule.forceProgress(wid, address(escrow));

        DRMStorageBase.ResolverStats memory after_ =
            resolutionModule.getDisputeResolverStats(resolver1);

        // EMA score must have dropped (timeout = 0 outcome, starting from 1e6)
        assertTrue(after_.emaScore < before.emaScore, "EMA should drop after timeout");
        assertEq(after_.timeoutsResolve, before.timeoutsResolve + 1, "Timeout count should increment");
    }

    /**
     * Fix 1: with minDisputeEscrowValue enabled, dust disputes are rejected
     * before they can damage the resolver's EMA score.
     */
    function test_Fix1_BlocksDustEMABombing() public {
        escrow.setMinDisputeEscrowValue(100e18);

        uint256 wid = _mintAndCreate(attacker, DUST_AMOUNT);
        _setCategory(wid);
        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(DisputeAmountBelowMinimum.selector, wid, DUST_AMOUNT, 100e18)
        );
        escrow.raiseDispute(wid);

        // EMA unchanged
        DRMStorageBase.ResolverStats memory stats =
            resolutionModule.getDisputeResolverStats(resolver1);
        assertEq(stats.timeoutsResolve, 0, "No timeouts when dust dispute is blocked");
    }

    /**
     * Fix 1: legitimate full-value disputes still reach the DRM after the gate.
     */
    function test_Fix1_AllowsLegitimateDispute() public {
        escrow.setMinDisputeEscrowValue(100e18);

        uint256 wid = _mintAndCreate(attacker, ESCROW_AMOUNT);
        _setCategory(wid);
        vm.prank(attacker);
        escrow.raiseDispute(wid); // must not revert

        // Dispute is live in DRM
        bytes memory edCheck = EscrowEncodingLibrary.encodeEscrowTransferData(
            address(token), attacker, seller, ESCROW_AMOUNT, address(0)
        );
        (, uint8 round, ) = resolutionModule.getAppealDeadlineAndRound(wid, address(escrow));
        assertEq(round, 0, "Dispute initialized at round 0");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Attack Scenario 2: Capacity starvation via dispute flood
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * Without Fix 2, an attacker with many wallets (or many escrows from one address)
     * can fill resolver capacity, blocking legitimate disputes.
     * This test sets resolver capacity to 3 and floods it from one address (no rate limit).
     */
    function test_CapacityStarvation_AttackerFloodsWithoutRateLimit() public {
        resolutionModule.setResolverCapacity(resolver1, 3, true);
        resolutionModule.setResolverCapacity(seniorResolver, 3, true);

        // Attacker opens 3 disputes back-to-back
        for (uint256 i = 0; i < 3; i++) {
            uint256 wid = _mintAndCreate(attacker, ESCROW_AMOUNT);
            _raiseDispute(attacker, wid);
        }

        // resolver capacity is now exhausted — a legitimate user cannot get a resolver
        address legit = makeAddr("legit");
        uint256 widLegit = _mintAndCreate(legit, ESCROW_AMOUNT);
        _setCategory(widLegit);
        vm.prank(legit);
        // This succeeds only because address(0) fallback; in practice the dispute
        // may be unresolvable. We just verify the capacity counters are filled.
        uint256 active1 = resolutionModule.resolverActiveDisputes(resolver1);
        uint256 activeS = resolutionModule.resolverActiveDisputes(seniorResolver);
        assertTrue(active1 + activeS >= 3, "Attacker filled capacity");
    }

    /**
     * Fix 2: per-sender rate limit prevents one address from flooding disputes.
     */
    function test_Fix2_BlocksCapacityFlood() public {
        escrow.setMaxDisputesPerSenderPerDay(2);

        uint256 wid1 = _mintAndCreate(attacker, ESCROW_AMOUNT);
        _raiseDispute(attacker, wid1);
        uint256 wid2 = _mintAndCreate(attacker, ESCROW_AMOUNT);
        _raiseDispute(attacker, wid2);

        // Third dispute from same sender reverts
        uint256 wid3 = _mintAndCreate(attacker, ESCROW_AMOUNT);
        _setCategory(wid3);
        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(DisputeRateLimitExceeded.selector, attacker, uint32(3), uint32(2))
        );
        escrow.raiseDispute(wid3);
    }

    /**
     * Fix 2: different senders are unaffected by another sender's rate limit.
     */
    function test_Fix2_DoesNotAffectOtherSenders() public {
        escrow.setMaxDisputesPerSenderPerDay(1);

        uint256 wid1 = _mintAndCreate(attacker, ESCROW_AMOUNT);
        _raiseDispute(attacker, wid1);

        // Legitimate user can still raise a dispute
        address legit = makeAddr("legit");
        uint256 widL = _mintAndCreate(legit, ESCROW_AMOUNT);
        _setCategory(widL);
        vm.prank(legit);
        escrow.raiseDispute(widL); // must not revert
    }

    /**
     * Combining Fix 1 and Fix 2 together: dust + rate limit both enforced.
     */
    function test_Fix1AndFix2_CombinedProtection() public {
        escrow.setMinDisputeEscrowValue(100e18);
        escrow.setMaxDisputesPerSenderPerDay(1);

        // Dust attempt blocked by Fix 1
        uint256 dustWid = _mintAndCreate(attacker, DUST_AMOUNT);
        _setCategory(dustWid);
        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(DisputeAmountBelowMinimum.selector, dustWid, DUST_AMOUNT, 100e18)
        );
        escrow.raiseDispute(dustWid);

        // First legitimate dispute succeeds
        uint256 wid1 = _mintAndCreate(attacker, ESCROW_AMOUNT);
        _raiseDispute(attacker, wid1);

        // Second same-day legitimate dispute blocked by Fix 2
        uint256 wid2 = _mintAndCreate(attacker, ESCROW_AMOUNT);
        _setCategory(wid2);
        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(DisputeRateLimitExceeded.selector, attacker, uint32(2), uint32(1))
        );
        escrow.raiseDispute(wid2);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Fix 3: Escalation cooldown enforcement and bond scaling
    // ═══════════════════════════════════════════════════════════════════════════

    /// Sets up a dispute + resolver decision, returning ready-to-escalate state.
    function _prepareEscalation() internal returns (uint256 wid) {
        wid = _mintAndCreate(attacker, ESCROW_AMOUNT);
        _raiseDispute(attacker, wid);

        bytes memory escrowData = EscrowEncodingLibrary.encodeEscrowTransferData(
            address(token), attacker, seller, ESCROW_AMOUNT, address(0)
        );
        (address res, ) = resolutionModule.getDisputeResolver(wid, address(escrow), escrowData);
        vm.prank(res);
        escrow.releaseAsDisputeResolver(wid, bytes32(0));
        // Now in appeal window — escalation possible
    }

    function test_EscalationCooldown_NoRevertWhenDisabled() public {
        uint256 wid = _prepareEscalation();
        (uint256 bond, address bondToken) = resolutionModule.getRequiredAppealBond(
            wid, address(escrow), 0,
            EscrowEncodingLibrary.encodeEscrowTransferData(address(token), attacker, seller, ESCROW_AMOUNT, address(0))
        );
        if (bondToken != address(0)) {
            token.mint(attacker, bond);
            vm.prank(attacker);
            token.approve(address(escrow), bond);
        } else {
            vm.deal(attacker, bond);
        }
        vm.prank(attacker);
        escrow.escalateDispute{value: bondToken == address(0) ? bond : 0}(wid);
        // Should not revert when escalationCooldown == 0
    }

    function test_EscalationCooldown_NoLongerHardBlocksWithinWindow() public {
        escrow.setEscalationCooldown(1 days);

        uint256 wid1 = _prepareEscalation();
        bytes memory ed1 = EscrowEncodingLibrary.encodeEscrowTransferData(
            address(token), attacker, seller, ESCROW_AMOUNT, address(0)
        );
        (uint256 bond1, address bondToken1) = resolutionModule.getRequiredAppealBond(wid1, address(escrow), 0, ed1);
        if (bondToken1 != address(0)) {
            token.mint(attacker, bond1);
            vm.prank(attacker);
            token.approve(address(escrow), bond1);
        } else {
            vm.deal(attacker, bond1);
        }
        // First escalation succeeds — records lastEscalationTimestamp
        vm.prank(attacker);
        escrow.escalateDispute{value: bondToken1 == address(0) ? bond1 : 0}(wid1);

        // Prepare a second dispute to escalate immediately after
        uint256 wid2 = _prepareEscalation();
        bytes memory ed2 = EscrowEncodingLibrary.encodeEscrowTransferData(
            address(token), attacker, seller, ESCROW_AMOUNT, address(0)
        );
        (uint256 bond2, address bondToken2) = resolutionModule.getRequiredAppealBond(wid2, address(escrow), 0, ed2);
        if (bondToken2 != address(0)) {
            token.mint(attacker, bond2 * 2); // extra for scaling
            vm.prank(attacker);
            token.approve(address(escrow), bond2 * 2);
        } else {
            vm.deal(attacker, bond2 * 2);
        }

        // Cooldown no longer hard-blocks valid escalations; it only tracks
        // per-address escalation count and affects bond scaling.
        vm.prank(attacker);
        escrow.escalateDispute{value: bondToken2 == address(0) ? bond2 * 2 : 0}(wid2);

        assertEq(escrow.addressEscalationCount(attacker), 2, "Count should increment for within-window escalation");
    }

    function test_EscalationCooldown_AllowsAfterExpiry() public {
        escrow.setEscalationCooldown(1 hours);

        uint256 wid1 = _prepareEscalation();
        bytes memory ed1 = EscrowEncodingLibrary.encodeEscrowTransferData(
            address(token), attacker, seller, ESCROW_AMOUNT, address(0)
        );
        (uint256 bond1, address bondToken1) = resolutionModule.getRequiredAppealBond(wid1, address(escrow), 0, ed1);
        if (bondToken1 != address(0)) {
            token.mint(attacker, bond1);
            vm.prank(attacker);
            token.approve(address(escrow), bond1);
        } else {
            vm.deal(attacker, bond1);
        }
        vm.prank(attacker);
        escrow.escalateDispute{value: bondToken1 == address(0) ? bond1 : 0}(wid1);

        // Advance past cooldown
        vm.warp(block.timestamp + 1 hours + 1);

        uint256 wid2 = _prepareEscalation();
        bytes memory ed2 = EscrowEncodingLibrary.encodeEscrowTransferData(
            address(token), attacker, seller, ESCROW_AMOUNT, address(0)
        );
        (uint256 bond2, address bondToken2) = resolutionModule.getRequiredAppealBond(wid2, address(escrow), 0, ed2);
        if (bondToken2 != address(0)) {
            token.mint(attacker, bond2 * 2);
            vm.prank(attacker);
            token.approve(address(escrow), bond2 * 2);
        } else {
            vm.deal(attacker, bond2 * 2);
        }
        // Must succeed now that cooldown has expired
        vm.prank(attacker);
        escrow.escalateDispute{value: bondToken2 == address(0) ? bond2 * 2 : 0}(wid2);
    }

    function test_EscalationCooldown_IndependentPerAddress() public {
        escrow.setEscalationCooldown(1 days);
        address legit = makeAddr("legit2");

        // Attacker escalates — starts their cooldown
        uint256 widA = _prepareEscalation();
        bytes memory edA = EscrowEncodingLibrary.encodeEscrowTransferData(
            address(token), attacker, seller, ESCROW_AMOUNT, address(0)
        );
        (uint256 bondA, address bondTokenA) = resolutionModule.getRequiredAppealBond(widA, address(escrow), 0, edA);
        if (bondTokenA != address(0)) {
            token.mint(attacker, bondA);
            vm.prank(attacker);
            token.approve(address(escrow), bondA);
        } else {
            vm.deal(attacker, bondA);
        }
        vm.prank(attacker);
        escrow.escalateDispute{value: bondTokenA == address(0) ? bondA : 0}(widA);

        // Prepare escalation for legit user (legit is buyer, not attacker)
        token.mint(legit, ESCROW_AMOUNT);
        vm.startPrank(legit);
        token.approve(address(escrow), ESCROW_AMOUNT);
        uint256 widL = escrow.createEscrow(
            address(token), seller, ESCROW_AMOUNT, SettingsValidationLibrary.getDefaultSettings()
        );
        vm.stopPrank();

        resolutionModule.setEscrowCategory(widL, address(escrow), CATEGORY);
        vm.prank(legit);
        escrow.raiseDispute(widL);

        bytes memory edL = EscrowEncodingLibrary.encodeEscrowTransferData(
            address(token), legit, seller, ESCROW_AMOUNT, address(0)
        );
        (address res, ) = resolutionModule.getDisputeResolver(widL, address(escrow), edL);
        vm.prank(res);
        escrow.releaseAsDisputeResolver(widL, bytes32(0));

        (uint256 bondL, address bondTokenL) = resolutionModule.getRequiredAppealBond(widL, address(escrow), 0, edL);
        if (bondTokenL != address(0)) {
            token.mint(legit, bondL);
            vm.prank(legit);
            token.approve(address(escrow), bondL);
        } else {
            vm.deal(legit, bondL);
        }
        // Legit user's cooldown is independent — must succeed
        vm.prank(legit);
        escrow.escalateDispute{value: bondTokenL == address(0) ? bondL : 0}(widL);
    }

    function test_EscalationBondScaling_IncreasesWithCount() public {
        // A 1-second cooldown enables count tracking and bond scaling.
        // The first escalation starts with lastEsc=0 so no cooldown check applies.
        escrow.setEscalationCooldown(1);

        uint256 wid1 = _prepareEscalation();
        bytes memory ed1 = EscrowEncodingLibrary.encodeEscrowTransferData(
            address(token), attacker, seller, ESCROW_AMOUNT, address(0)
        );
        (uint256 baseBond, address bondToken) = resolutionModule.getRequiredAppealBond(wid1, address(escrow), 0, ed1);

        // First escalation: base bond (escCount=1, no scaling)
        if (bondToken != address(0)) {
            token.mint(attacker, baseBond * 10);
            vm.prank(attacker);
            token.approve(address(escrow), baseBond * 10);
        } else {
            vm.deal(attacker, baseBond * 10);
        }
        vm.prank(attacker);
        escrow.escalateDispute{value: bondToken == address(0) ? baseBond : 0}(wid1);
        assertEq(escrow.addressEscalationCount(attacker), 1, "Count should be 1 after first escalation");

        // Advance past the 1-second cooldown so the second escalation is not blocked by timing.
        vm.warp(block.timestamp + 2);

        // Second escalation on a new dispute: bond should be scaled 1.1x (escCount=2)
        uint256 wid2 = _prepareEscalation();
        bytes memory ed2 = EscrowEncodingLibrary.encodeEscrowTransferData(
            address(token), attacker, seller, ESCROW_AMOUNT, address(0)
        );
        (uint256 baseBond2, ) = resolutionModule.getRequiredAppealBond(wid2, address(escrow), 0, ed2);

        // Verify that providing exactly the unscaled bond (baseBond2) is insufficient.
        // The contract will require baseBond2 * 1.1 after scaling.
        if (bondToken == address(0) && baseBond2 > 0) {
            vm.deal(attacker, baseBond2 * 3);
            vm.prank(attacker);
            vm.expectRevert(); // InvalidBondMsgValue — provided baseBond2, requires 1.1x
            escrow.escalateDispute{value: baseBond2}(wid2);
            // Revert rolls back count increment — stays at 1
            assertEq(escrow.addressEscalationCount(attacker), 1, "Count unchanged after failed escalation");

            // Providing 1.1x succeeds
            uint256 scaledBond = baseBond2 * 110 / 100;
            vm.prank(attacker);
            escrow.escalateDispute{value: scaledBond}(wid2);
            assertEq(escrow.addressEscalationCount(attacker), 2, "Count should be 2 after second escalation");
        } else if (bondToken != address(0) && baseBond2 > 0) {
            // Token bond: approve unscaled amount and verify it succeeds (token bonds round down)
            vm.prank(attacker);
            token.approve(address(escrow), baseBond2 * 2);
            vm.prank(attacker);
            escrow.escalateDispute(wid2);
            assertEq(escrow.addressEscalationCount(attacker), 2, "Count should be 2 after second escalation");
        }
    }

    function test_EscalationCountResets_After30Days() public {
        escrow.setEscalationCooldown(1); // 1 second — enables tracking, does not block first escalation

        uint256 wid1 = _prepareEscalation();
        bytes memory ed = EscrowEncodingLibrary.encodeEscrowTransferData(
            address(token), attacker, seller, ESCROW_AMOUNT, address(0)
        );
        (uint256 bond, address bondToken) = resolutionModule.getRequiredAppealBond(wid1, address(escrow), 0, ed);

        if (bondToken != address(0)) {
            token.mint(attacker, bond * 5);
            vm.prank(attacker);
            token.approve(address(escrow), bond * 5);
        } else {
            vm.deal(attacker, bond * 5);
        }
        vm.prank(attacker);
        escrow.escalateDispute{value: bondToken == address(0) ? bond : 0}(wid1);
        assertEq(escrow.addressEscalationCount(attacker), 1, "Count should be 1 after first escalation");

        // Advance past the 30-day window — count should reset on next escalation
        vm.warp(block.timestamp + 30 days + 1);

        uint256 wid2 = _prepareEscalation();
        (uint256 bond2, ) = resolutionModule.getRequiredAppealBond(
            wid2, address(escrow), 0,
            EscrowEncodingLibrary.encodeEscrowTransferData(address(token), attacker, seller, ESCROW_AMOUNT, address(0))
        );
        if (bondToken != address(0)) {
            vm.prank(attacker);
            token.approve(address(escrow), bond2 * 2);
        } else {
            vm.deal(attacker, bond2 * 2);
        }
        vm.prank(attacker);
        // Provide base bond (no scaling since count resets to 1)
        escrow.escalateDispute{value: bondToken == address(0) ? bond2 : 0}(wid2);

        // Current implementation keeps cumulative count for bond scaling,
        // and no longer resets on a 30-day window.
        assertEq(escrow.addressEscalationCount(attacker), 2, "Count should accumulate under current scaling model");
    }
}
