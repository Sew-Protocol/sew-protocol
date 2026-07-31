// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import 'forge-std/Test.sol';
import '../../../contracts/modules/decentralized-resolution-module/ResolverIncentiveModuleV2.sol';
import '../../../contracts/modules/decentralized-resolution-module/DecentralizedResolutionModule.sol';
import '../../../contracts/modules/decentralized-resolution-module/DRMAdminFacet.sol';
import '../../../contracts/modules/decentralized-resolution-module/PaymentCalculationLibraryV1.sol';
import '../../../contracts/core/EscrowVault.sol';
import '../../../contracts/mocks/ERC20Mock.sol';
import '../../../contracts/ops/YieldOps.sol';
import '../../../contracts/ops/DisputeOps.sol';
import '../../../contracts/ops/CreateOps.sol';
import '../../../contracts/ops/SettlementOps.sol';
import '../../../contracts/core/ModuleSnapshotRegistry.sol';
import '../../../contracts/core/BondCollector.sol';
import '../../../contracts/types/EscrowTypes.sol';

// Expose V1 event for test assertions
event ResolutionModuleSet(address indexed oldModule, address indexed newModule);

contract BondBehaviourCorrectionTest is Test {
    EscrowVault public escrow;
    DecentralizedResolutionModule public drm;
    ResolverIncentiveModuleV2 public v2;
    ERC20Mock public token;
    BondCollector public bondCollector;
    ModuleSnapshotRegistry public moduleMgmt;

    address public deployer = address(this);
    address public feeAddr = makeAddr('fee');
    address public resolver0 = makeAddr('r0');
    address public resolver1 = makeAddr('r1');
    address public senior = makeAddr('senior');
    address public buyer = makeAddr('buyer');
    address public seller = makeAddr('seller');
    address public timelock = makeAddr('timelock');

    uint256 constant BOND = 1 ether;
    uint256 constant ESCROW_AMT = 1000 ether;
    uint256 constant WID = 0;

    function setUp() public {
        token = new ERC20Mock('T', 'T', address(this), 0);
        token.mint(buyer, ESCROW_AMT + BOND);

        PaymentCalculationLibraryV1 lib = new PaymentCalculationLibraryV1();
        v2 = new ResolverIncentiveModuleV2(deployer, address(lib));
        v2.grantRole(v2.ROLE_TIMELOCK(), address(this));
        v2.grantRole(v2.ROLE_TIMELOCK(), timelock);
        v2.registerEscrowContract(address(this));

        drm = new DecentralizedResolutionModule(deployer);
        { DRMAdminFacet f = new DRMAdminFacet(); drm.setAdminFacet(address(f)); }
        drm.grantRole(drm.ROLE_TIMELOCK(), address(this));
        drm.grantRole(drm.ROLE_TIMELOCK(), timelock);
        drm.registerEscrowContract(address(this));

        YieldOps yOps = new YieldOps(address(this));
        DisputeOps dOps = new DisputeOps(address(this));
        moduleMgmt = new ModuleSnapshotRegistry(address(this));
        escrow = new EscrowVault(100, feeAddr, address(yOps), address(dOps), address(moduleMgmt));

        CreateOps cOps = new CreateOps(address(this));
        SettlementOps sOps = new SettlementOps(address(this));
        bondCollector = new BondCollector(address(this));

        cOps.registerEscrowContract(address(escrow));
        sOps.registerEscrowContract(address(escrow));
        bondCollector.registerEscrowContract(address(escrow));
        dOps.registerEscrowContract(address(escrow));
        yOps.registerEscrowContract(address(escrow));

        escrow.grantRole(escrow.ROLE_ADMIN_CONTRACT(), address(this));
        escrow.setCreateOps(address(cOps));
        escrow.setSettlementOps(address(sOps));
        escrow.setBondCollector(address(bondCollector));

        // Wire modules
        drm.registerEscrowContract(address(escrow));
        v2.registerEscrowContract(address(escrow));
        drm.setIncentiveModule(address(v2));
        v2.setResolutionModule(address(drm));

        // Module management
        moduleMgmt.registerEscrowContract(address(escrow));
        moduleMgmt.grantRole(moduleMgmt.ROLE_ESCROW_CONTRACT(), address(escrow));
        moduleMgmt.queueModule(address(escrow), BaseEscrow.ModuleType.RESOLUTION, address(drm));
        vm.warp(block.timestamp + 8 days);
        moduleMgmt.activateModule(address(escrow), BaseEscrow.ModuleType.RESOLUTION);

        // Resolvers
        drm.appointSeniorResolver(senior, "S", "");
        vm.prank(senior);
        drm.appointResolver(resolver0, "R0", "");
        vm.prank(senior);
        drm.appointResolver(resolver1, "R1", "");

        // Enable escalation to round 1
        vm.prank(timelock);
        drm.queueEscalationConfig(1, DecentralizedResolverStructs.EscalationConfig({
            resolver: address(0), fee: 0, enabled: true
        }));
        { (, uint64 eta2,) = drm.getPendingEscalationConfig(1); vm.warp(eta2 + 1); }
        vm.prank(timelock);
        drm.activateEscalationConfig(1);

        // Escalation cost config
        vm.warp(block.timestamp + 1);
        vm.prank(timelock);
        drm.queueEscalationCostConfig(DecentralizedResolverStructs.EscalationCostConfig({
            curveType: DecentralizedResolverStructs.CostCurveType.LINEAR,
            baseCost: BOND, stepSize: BOND, multiplier: 0,
            bondToken: address(token), enabled: true
        }));
        (, uint64 eta,) = drm.getPendingEscalationCostConfig();
        vm.warp(eta + 1);
        vm.prank(timelock);
        drm.activateEscalationCostConfig();
    }

    // ──────────────────────────────────────────────────────────
    // 1. Happy-path refund through production path
    // ──────────────────────────────────────────────────────────

    function test_refund_through_production_path() public {
        _createAndDispute();
        _resolve(resolver0, true);      // round 0: RELEASE
        vm.prank(buyer);
        escrow.escalateDispute{value: 0}(WID);
        _resolve(senior, false);         // round 1: CANCEL (flip → refund)

        assertTrue(v2.getAppealBond(WID, address(escrow), 1).distributed, "bond must be distributed");
        assertEq(v2.claimableBondRefunds(address(escrow), WID, buyer), BOND, "claimable = BOND");
    }

    // ──────────────────────────────────────────────────────────
    // 2. Failed-appeal resolver payout through production path
    // ──────────────────────────────────────────────────────────

    function test_failed_appeal_pays_resolvers() public {
        _createAndDispute();
        _resolve(resolver0, true);      // round 0: RELEASE
        vm.prank(buyer);
        escrow.escalateDispute{value: 0}(WID);
        _resolve(senior, true);          // round 1: RELEASE (same → failed)

        assertTrue(v2.getAppealBond(WID, address(escrow), 1).distributed, "bond must be distributed");
        assertEq(v2.getClaimablePayment(WID, address(escrow), resolver0), BOND, "resolver0 gets bond");
    }

    // ──────────────────────────────────────────────────────────
    // 3. No silent no-op: distribution failures revert resolution
    // ──────────────────────────────────────────────────────────

    function test_no_silent_noop_distributionFailureRevertsResolution() public {
        _createAndDispute();
        _resolve(resolver0, true);
        vm.prank(buyer);
        escrow.escalateDispute{value: 0}(WID);
        // Remove the bond before resolution — distributeAppealBond will fail
        v2.forfeitAppealBond(WID, address(escrow), 1, "consume");
        // recordResolution must revert because distributeAppealBond reverts
        vm.prank(address(escrow));
        vm.expectRevert();
        drm.recordResolution(WID, address(escrow), senior, ResolutionOutcome.CANCEL, 100);
    }

    // ──────────────────────────────────────────────────────────
    // 4. No double distribution (metrics exact before/after)
    // ──────────────────────────────────────────────────────────

    function test_no_double_distribution_metrics() public {
        _createAndDispute();
        _resolve(resolver0, true);
        vm.prank(buyer); escrow.escalateDispute{value: 0}(WID);

        (,,, uint256 paidBefore, uint256 forfeitedBefore) = v2.getV2Metrics();
        assertEq(paidBefore, 0, "paid=0 before");
        assertEq(forfeitedBefore, 0, "forfeited=0 before");

        _resolve(senior, false);         // success: reversal, bond refunded

        (,,, uint256 paidMid, uint256 forfeitedMid) = v2.getV2Metrics();
        // Refund doesn't count as "paid to resolvers" or "forfeited"
        assertEq(paidMid, 0, "paid=0 after refund");
        assertEq(forfeitedMid, 0, "forfeited=0 after refund");

        // Second resolution on same round: bond already consumed, reverts
        vm.prank(address(escrow));
        vm.expectRevert();
        drm.recordResolution(WID, address(escrow), senior, ResolutionOutcome.CANCEL, 100);
    }

    function test_no_double_resolver_payout_metrics() public {
        _createAndDispute();
        _resolve(resolver0, true);
        vm.prank(buyer); escrow.escalateDispute{value: 0}(WID);

        (,uint256 refundBefore,, uint256 paidBefore, uint256 forfeitedBefore) = v2.getV2Metrics();

        _resolve(senior, true);          // failed appeal → resolvers get bond

        // Check state after distribution
        assertTrue(v2.getAppealBond(WID, address(escrow), 1).distributed, "bond distributed");

        uint256 claimable = v2.getClaimablePayment(WID, address(escrow), resolver0);
        assertEq(claimable, BOND, "resolver0 claimable = BOND");

        // Second resolution must revert (bond already distributed)
        vm.prank(address(escrow));
        vm.expectRevert();
        drm.recordResolution(WID, address(escrow), senior, ResolutionOutcome.RELEASE, 100);
    }

    // ──────────────────────────────────────────────────────────
    // 5. Forfeiture moves to reserve (exact balance check)
    // ──────────────────────────────────────────────────────────

    function test_forfeit_moves_to_reserve() public {
        _postDirectBond();
        uint256 v2bal = token.balanceOf(address(v2));
        assertEq(v2bal, BOND, "V2 holds bond");

        v2.forfeitAppealBond(WID, address(this), 1, "test");

        assertEq(v2.forfeitedBondReserve(address(token)), BOND, "reserve = BOND");
        assertEq(token.balanceOf(address(v2)), v2bal, "tokens stay in V2");
    }

    // ──────────────────────────────────────────────────────────
    // 6. Finalize cleanup moves principal to reserve
    // ──────────────────────────────────────────────────────────

    function test_finalize_moves_to_reserve() public {
        _postDirectBond();
        v2.onDisputeFinalized(WID, address(this), 1, ResolutionOutcome.RELEASE);
        assertEq(v2.forfeitedBondReserve(address(token)), BOND, "reserve = BOND");
    }

    // ──────────────────────────────────────────────────────────
    // 7. Reserve and claimable never double-count
    // ──────────────────────────────────────────────────────────

    function test_no_double_count_reserve_vs_claimable() public {
        _postDirectBond();
        v2.recordResolver(WID, address(this), resolver0, 0);
        v2.distributeAppealBond(WID, address(this), 0, false);
        assertEq(v2.getClaimablePayment(WID, address(this), resolver0), BOND, "claimable = BOND");
        assertEq(v2.forfeitedBondReserve(address(token)), 0, "reserve = 0");
    }

    // ──────────────────────────────────────────────────────────
    // 8. Regular claim still works (existing interface)
    // ──────────────────────────────────────────────────────────

    function test_regular_claim_still_works() public {
        _postDirectBond();
        assertEq(v2.claimableBondRefunds(address(this), WID, buyer), 0, "empty before");
        v2.distributeAppealBond(WID, address(this), 0, true);
        assertEq(v2.claimableBondRefunds(address(this), WID, buyer), BOND, "claimable after");

        uint256 balBefore = token.balanceOf(buyer);
        vm.prank(buyer);
        v2.claimBondRefund(WID, address(this), address(token));
        assertEq(token.balanceOf(buyer) - balBefore, BOND, "buyer got BOND");
    }

    // ──────────────────────────────────────────────────────────
    // 9. Resolution module authority works
    // ──────────────────────────────────────────────────────────

    function test_resolutionModule_authorized() public {
        _postDirectBond();
        vm.prank(address(drm));
        v2.distributeAppealBond(WID, address(this), 0, true);
        assertEq(v2.claimableBondRefunds(address(this), WID, buyer), BOND);
    }

    // ──────────────────────────────────────────────────────────
    // 10. Non-authorized caller blocked
    // ──────────────────────────────────────────────────────────

    function test_non_authorized_blocked() public {
        _postDirectBond();
        vm.prank(makeAddr("rando"));
        vm.expectRevert();
        v2.distributeAppealBond(WID, address(this), 0, true);
    }

    // ──────────────────────────────────────────────────────────
    // 11. Round ownership: resolver0 and resolver1 are different
    //     Only resolver0 (round 0) should receive failed-appeal payout
    // ──────────────────────────────────────────────────────────

    function test_round_ownership_correct_resolver_cohort() public {
        _createAndDispute();
        _resolve(resolver0, true);      // round 0 by resolver0
        vm.prank(buyer);
        escrow.escalateDispute{value: 0}(WID);
        _resolve(senior, true);          // round 1 by senior (same → failed)

        // resolver0 (round 0) should get the bond
        assertEq(v2.getClaimablePayment(WID, address(escrow), resolver0), BOND, "r0 gets bond");
        // resolver1 (round 0 but not this case) should get nothing
        assertEq(v2.getClaimablePayment(WID, address(escrow), resolver1), 0, "r1 gets nothing");
        // senior (round 1) should get nothing
        assertEq(v2.getClaimablePayment(WID, address(escrow), senior), 0, "senior gets nothing");
    }

    // ──────────────────────────────────────────────────────────
    // 12. setResolutionModule coverage
    // ──────────────────────────────────────────────────────────

    function test_setResolutionModule_rejects_zero() public {
        vm.expectRevert();
        v2.setResolutionModule(address(0));
    }

    function test_setResolutionModule_requires_role() public {
        vm.prank(makeAddr("unauthorized"));
        vm.expectRevert();
        v2.setResolutionModule(address(1));
    }

    function test_setResolutionModule_emits_event() public {
        address newMod = makeAddr("newDRM");
        vm.expectEmit(true, true, false, true);
        emit ResolutionModuleSet(address(drm), newMod);
        v2.setResolutionModule(newMod);
        assertEq(v2.resolutionModule(), newMod, "module updated");
    }

    // ──────────────────────────────────────────────────────────
    // Helpers
    // ──────────────────────────────────────────────────────────

    function _createAndDispute() internal {
        vm.startPrank(buyer);
        token.approve(address(escrow), ESCROW_AMT + BOND);
        escrow.createEscrow(address(token), seller, ESCROW_AMT, EscrowSettings({
            customResolver: address(0), releaseAddress: address(0),
            yieldPreset: YieldPreset.OFF, autoReleaseTime: 0, autoCancelTime: 0
        }));
        escrow.raiseDispute(WID);
        vm.stopPrank();
    }

    function _resolve(address by, bool isRelease) internal {
        ResolutionOutcome o = isRelease ? ResolutionOutcome.RELEASE : ResolutionOutcome.CANCEL;
        vm.prank(address(escrow));
        drm.recordResolution(WID, address(escrow), by, o, 100);
    }

    function _postDirectBond() internal {
        token.mint(buyer, BOND);
        vm.prank(buyer);
        token.approve(address(v2), BOND);
        v2.recordAppealBond(WID, address(this), buyer, buyer, BOND, address(token), 1);
    }
}
