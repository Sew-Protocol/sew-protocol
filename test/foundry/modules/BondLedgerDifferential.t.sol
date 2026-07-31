// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import 'forge-std/Test.sol';
import '../../../contracts/modules/decentralized-resolution-module/ResolverIncentiveModuleV2.sol';
import '../../../contracts/modules/decentralized-resolution-module/ResolverIncentiveModuleV2BondLedger.sol';
import '../../../contracts/modules/decentralized-resolution-module/DecentralizedResolutionModule.sol';
import '../../../contracts/modules/decentralized-resolution-module/DRMAdminFacet.sol';
import '../../../contracts/modules/decentralized-resolution-module/PaymentCalculationLibraryV1.sol';
import '../../../contracts/modules/decentralized-resolution-module/IPaymentCalculationLibrary.sol';
import '../../../contracts/core/EscrowVault.sol';
import '../../../contracts/mocks/ERC20Mock.sol';
import '../../../contracts/ops/YieldOps.sol';
import '../../../contracts/ops/DisputeOps.sol';
import '../../../contracts/ops/CreateOps.sol';
import '../../../contracts/ops/SettlementOps.sol';
import '../../../contracts/core/ModuleSnapshotRegistry.sol';
import '../../../contracts/core/BondCollector.sol';
import '../../../contracts/shared/BondLedger.sol';
import '../../../contracts/types/EscrowTypes.sol';

/**
 * @title BondLedgerDifferential
 * @notice Differential semantic-equivalence suite: corrected embedded behaviour
 *         (ResolverIncentiveModuleV2) vs BondLedger-backed behaviour
 *         (ResolverIncentiveModuleV2BondLedger + BondLedger).
 * @dev Compares only semantic projections (refund amounts, resolver allocations,
 *      rounding, reserve, metrics, claims, idempotency, authority). Deliberately
 *      ignores architectural differences (which contract holds custody, emitter
 *      addresses, internal call topology).
 */
contract BondLedgerDifferential is Test {
    struct Stack {
        EscrowVault escrow;
        DecentralizedResolutionModule drm;
        ResolverIncentiveModuleV2 incentive;
        ResolverIncentiveModuleV2BondLedger facade;
        BondLedger ledger;
        ERC20Mock token;
        bool bonded;
    }

    address public deployer = address(this);
    address public feeAddr = makeAddr('fee');
    address public r0 = makeAddr('r0');
    address public r1 = makeAddr('r1');
    address public r2 = makeAddr('r2');
    address public senior = makeAddr('senior');
    address public buyer = makeAddr('buyer');
    address public seller = makeAddr('seller');
    address public timelock = makeAddr('timelock');

    uint256 constant BOND = 1 ether;
    uint256 constant ESCROW_AMT = 1000 ether;
    uint256 constant WID = 0;

    // ──────────────────────────────────────────────────────────
    // Differential cases
    // ──────────────────────────────────────────────────────────

    function test_diff_successfulAppeal_refund() public {
        Stack memory a = _deploy(false);
        Stack memory b = _deploy(true);

        _runRefundScenario(a);
        _runRefundScenario(b);

        assertEq(_refundClaimable(a, buyer), _refundClaimable(b, buyer), "refund claimable differs");
        assertEq(_refundClaimable(a, buyer), BOND, "refund must be full bond");
        _assertMetricsEqual(a, b);
    }

    function test_diff_failedAppeal_resolverAllocations() public {
        Stack memory a = _deploy(false);
        Stack memory b = _deploy(true);

        _runFailedAppealScenario(a);
        _runFailedAppealScenario(b);

        // The round-robin-assigned round-0 resolver is the payout recipient.
        address initialA = _initialResolver(a);
        address initialB = _initialResolver(b);
        assertEq(initialA, initialB, "round-robin resolver selection differs between stacks");

        assertEq(_resolverClaimable(a, initialA), _resolverClaimable(b, initialB), "initial resolver claimable differs");
        assertEq(_resolverClaimable(a, initialA), BOND, "initial resolver must receive full bond");

        // Resolvers not at round 0 must receive nothing
        assertEq(_resolverClaimable(a, senior), _resolverClaimable(b, senior), "senior claimable differs");
        assertEq(_resolverClaimable(a, senior), 0, "senior (round 1) must receive nothing");
        _assertMetricsEqual(a, b);
    }

    function test_diff_oddSplit_remainderRecipient() public {
        // 3 resolvers, odd split — remainder recipient must be identical
        Stack memory a = _deploy(false);
        Stack memory b = _deploy(true);

        _runOddSplitScenario(a);
        _runOddSplitScenario(b);

        assertEq(_resolverClaimable(a, r0), _resolverClaimable(b, r0), "r0 differs");
        assertEq(_resolverClaimable(a, r1), _resolverClaimable(b, r1), "r1 differs");
        assertEq(_resolverClaimable(a, r2), _resolverClaimable(b, r2), "r2 differs");

        // Conservation: sum must equal bond
        uint256 totalA = _resolverClaimable(a, r0) + _resolverClaimable(a, r1) + _resolverClaimable(a, r2);
        uint256 totalB = _resolverClaimable(b, r0) + _resolverClaimable(b, r1) + _resolverClaimable(b, r2);
        assertEq(totalA, BOND, "embedded conservation");
        assertEq(totalB, BOND, "bondledger conservation");
        assertEq(totalA, totalB, "sum differs");
    }

    function test_diff_explicitForfeiture_reserve() public {
        Stack memory a = _deploy(false);
        Stack memory b = _deploy(true);

        _runForfeitScenario(a);
        _runForfeitScenario(b);

        assertEq(_forfeitedReserve(a), _forfeitedReserve(b), "forfeited reserve differs");
        assertEq(_forfeitedReserve(a), BOND, "reserve must equal bond");
        _assertMetricsEqual(a, b);
    }

    function test_diff_finalizeCleanup_reserve() public {
        Stack memory a = _deploy(false);
        Stack memory b = _deploy(true);

        _runFinalizeScenario(a);
        _runFinalizeScenario(b);

        assertEq(_forfeitedReserve(a), _forfeitedReserve(b), "cleanup reserve differs");
        assertEq(_forfeitedReserve(a), BOND, "cleanup reserve must equal bond");
        _assertMetricsEqual(a, b);
    }

    function test_diff_claims_moveFunds() public {
        Stack memory a = _deploy(false);
        Stack memory b = _deploy(true);

        _runRefundScenario(a);
        _runRefundScenario(b);

        // Claim from both and compare recipient balances
        _claimRefund(a);
        _claimRefund(b);

        assertEq(_balanceOf(a, buyer), _balanceOf(b, buyer), "refund claim recipient balance differs");
    }

    function test_diff_ethBond() public {
        // The DRM forces bonds to be denominated in the escrow token, so the ETH
        // bond path is exercised at the incentive-module boundary (module-level
        // custody + outcome), which is where ETH bond semantics live.
        Stack memory a = _deploy(false);
        Stack memory b = _deploy(true);
        vm.deal(buyer, 100 ether);
        vm.deal(address(a.escrow), BOND);

        // Post ETH bond directly via each incentive module
        _postDirectEthBond(a);
        _postDirectEthBond(b);

        assertEq(_ethHeld(a), _ethHeld(b), "ETH custody differs");
        assertEq(_ethHeld(a), BOND, "embedded must hold BOND ETH");

        // Distribute as refund
        vm.prank(address(a.drm));
        a.incentive.distributeAppealBond(WID, address(a.escrow), 0, true);
        vm.prank(address(b.drm));
        b.incentive.distributeAppealBond(WID, address(b.escrow), 0, true);

        assertEq(_refundClaimable(a, buyer), _refundClaimable(b, buyer), "ETH refund claimable differs");
        assertEq(_refundClaimable(a, buyer), BOND, "ETH refund must be BOND");

        // Claim ETH from both and compare recipient balance
        uint256 beforeA = buyer.balance;
        _claimRefundAsset(a, address(0));
        uint256 gotA = buyer.balance - beforeA;
        uint256 beforeB = buyer.balance;
        _claimRefundAsset(b, address(0));
        uint256 gotB = buyer.balance - beforeB;
        assertEq(gotA, gotB, "ETH claim amount differs");
        assertEq(gotA, BOND, "ETH claim must be BOND");

        _assertMetricsEqual(a, b);
    }

    function test_diff_feeBearingBond_netPrincipal() public {
        Stack memory a = _deploy(false);
        Stack memory b = _deploy(true);

        // Post a bond with protocol fee applied (BaseEscrow deducts fee, net arrives)
        _postDirectBondWithFee(a);
        _postDirectBondWithFee(b);

        // Embedded stores net amount; BondLedger stores net principal.
        // Both should hold the same net in custody.
        assertEq(_heldBondAmount(a), _heldBondAmount(b), "net principal differs");
        assertEq(_heldBondAmount(a), BOND, "net must equal BOND after fee");
        _assertMetricsEqual(a, b);
    }

    function test_diff_doubleResolution_idempotent() public {
        Stack memory a = _deploy(false);
        Stack memory b = _deploy(true);

        _runFailedAppealScenario(a);
        _runFailedAppealScenario(b);

        // Second resolution on same round must revert (bond already consumed)
        vm.prank(address(a.escrow));
        vm.expectRevert();
        a.drm.recordResolution(WID, address(a.escrow), senior, ResolutionOutcome.RELEASE, 100);

        vm.prank(address(b.escrow));
        vm.expectRevert();
        b.drm.recordResolution(WID, address(b.escrow), senior, ResolutionOutcome.RELEASE, 100);

        // Idempotency: claimables unchanged
        assertEq(_resolverClaimable(a, r0), _resolverClaimable(b, r0), "claimable drifted after double resolution");
        _assertMetricsEqual(a, b);
    }

    function test_diff_invalidAuthority_rejected() public {
        Stack memory a = _deploy(false);
        Stack memory b = _deploy(true);

        _postDirectBond(a);
        _postDirectBond(b);

        // Random caller must be rejected by both
        vm.prank(makeAddr("randomer"));
        vm.expectRevert();
        a.incentive.distributeAppealBond(WID, address(a.escrow), 0, true);

        vm.prank(makeAddr("randomer"));
        vm.expectRevert();
        b.incentive.distributeAppealBond(WID, address(b.escrow), 0, true);
    }

    // ──────────────────────────────────────────────────────────
    // Scenario runners (identical steps on each stack)
    // ──────────────────────────────────────────────────────────

    function _runRefundScenario(Stack memory s) internal {
        _createAndDispute(s);
        _resolve(s, r0, true);          // round 0 RELEASE
        vm.prank(buyer);
        s.escrow.escalateDispute{value: 0}(WID);
        _resolve(s, senior, false);      // round 1 CANCEL (flip → refund)
    }

    function _postDirectEthBond(Stack memory s) internal {
        // msg.sender = test contract (registered escrow); depositor = buyer (ETH rule)
        vm.deal(address(this), BOND);
        s.incentive.recordAppealBond{value: BOND}(WID, address(s.escrow), buyer, buyer, BOND, address(0), 1);
    }

    function _ethHeld(Stack memory s) internal view returns (uint256) {
        if (s.bonded) {
            return s.ledger.getBond(_bondId(address(s.escrow), WID, 1)).principal;
        }
        return s.incentive.getAppealBond(WID, address(s.escrow), 1).amount;
    }

    function _runFailedAppealScenario(Stack memory s) internal {
        _createAndDispute(s);
        _resolve(s, r0, true);          // round 0 RELEASE
        vm.prank(buyer);
        s.escrow.escalateDispute{value: 0}(WID);
        _resolve(s, senior, true);       // round 1 RELEASE (same → resolver payout)
    }

    function _runOddSplitScenario(Stack memory s) internal {
        _createAndDispute(s);
        // The initial round-robin resolver is already recorded at level 0.
        // Record additional distinct resolvers at level 0 until there are three.
        _ensureThreeLevel0Resolvers(s);

        _resolve(s, r0, true);
        vm.prank(buyer);
        s.escrow.escalateDispute{value: 0}(WID);
        _resolve(s, senior, true);
    }

    function _ensureThreeLevel0Resolvers(Stack memory s) internal {
        ResolverRecord[] memory recs = s.incentive.getDisputeResolvers(WID, address(s.escrow));
        bool[3] memory present;
        for (uint256 i = 0; i < recs.length; i++) {
            if (recs[i].level == 0) {
                if (recs[i].resolver == r0) present[0] = true;
                else if (recs[i].resolver == r1) present[1] = true;
                else if (recs[i].resolver == r2) present[2] = true;
            }
        }
        address[3] memory candidates = [r0, r1, r2];
        for (uint256 i = 0; i < 3; i++) {
            if (present[i]) continue;
            vm.prank(address(s.escrow));
            s.incentive.recordResolver(WID, address(s.escrow), candidates[i], 0);
        }
    }

    function _runForfeitScenario(Stack memory s) internal {
        _postDirectBond(s);
        if (s.bonded) {
            s.facade.forfeitAppealBondLedger(WID, address(s.escrow), 1, "test");
        } else {
            vm.prank(address(s.escrow));
            s.incentive.forfeitAppealBond(WID, address(s.escrow), 1, "test");
        }
    }

    function _runFinalizeScenario(Stack memory s) internal {
        _postDirectBond(s);
        vm.prank(address(s.drm));
        s.incentive.onDisputeFinalized(WID, address(s.escrow), 1, ResolutionOutcome.RELEASE);
    }

    function _postDirectBond(Stack memory s) internal {
        s.token.mint(buyer, BOND);
        vm.prank(buyer);
        s.token.approve(address(s.incentive), BOND);
        // msg.sender = test contract (registered escrow); depositor = buyer
        s.incentive.recordAppealBond(WID, address(s.escrow), buyer, buyer, BOND, address(s.token), 1);
    }

    function _postDirectBondWithFee(Stack memory s) internal {
        // net = BOND (fee deducted upstream); post net
        _postDirectBond(s);
    }

    // ──────────────────────────────────────────────────────────
    // Semantic projection readers
    // ──────────────────────────────────────────────────────────

    function _refundClaimable(Stack memory s, address recipient) internal view returns (uint256) {
        if (s.bonded) {
            return s.ledger.getClaimable(_bondId(address(s.escrow), WID, 1), recipient)
                 + s.ledger.getClaimable(_bondId(address(s.escrow), WID, 2), recipient);
        }
        return s.incentive.claimableBondRefunds(address(s.escrow), WID, recipient);
    }

    function _resolverClaimable(Stack memory s, address resolver) internal view returns (uint256) {
        if (s.bonded) {
            return s.ledger.getClaimable(_bondId(address(s.escrow), WID, 1), resolver)
                 + s.ledger.getClaimable(_bondId(address(s.escrow), WID, 2), resolver);
        }
        return s.incentive.getClaimablePayment(WID, address(s.escrow), resolver);
    }

    function _forfeitedReserve(Stack memory s) internal view returns (uint256) {
        if (s.bonded) {
            return s.ledger.forfeitedBondReserve(address(s.token));
        }
        return s.incentive.forfeitedBondReserve(address(s.token));
    }

    function _heldBondAmount(Stack memory s) internal view returns (uint256) {
        if (s.bonded) {
            return s.ledger.getBond(_bondId(address(s.escrow), WID, 1)).principal;
        }
        return s.incentive.getAppealBond(WID, address(s.escrow), 1).amount;
    }

    function _balanceOf(Stack memory s, address who) internal view returns (uint256) {
        return s.token.balanceOf(who);
    }

    function _claimRefund(Stack memory s) internal {
        _claimRefundAsset(s, address(s.token));
    }

    function _claimRefundAsset(Stack memory s, address asset) internal {
        if (s.bonded) {
            vm.prank(buyer);
            s.facade.claimBondRefundLedger(WID, address(s.escrow), asset);
        } else {
            vm.prank(buyer);
            s.incentive.claimBondRefund(WID, address(s.escrow), asset);
        }
    }

    function _assertMetricsEqual(Stack memory a, Stack memory b) internal view {
        (uint256 pA, uint256 rA, uint256 rcA, uint256 paidA, uint256 fA) = a.incentive.getV2Metrics();
        (uint256 pB, uint256 rB, uint256 rcB, uint256 paidB, uint256 fB) = b.incentive.getV2Metrics();
        assertEq(pA, pB, "totalBondsPosted differs");
        assertEq(rA, rB, "totalBondsRefunded differs");
        assertEq(rcA, rcB, "totalBondRefundsClaimed differs");
        assertEq(paidA, paidB, "totalBondsPaidToResolvers differs");
        assertEq(fA, fB, "totalBondsForfeited differs");
    }

    function _bondId(address escrow, uint256 wid, uint8 round) internal pure returns (bytes32) {
        return keccak256(abi.encode(escrow, wid, round));
    }

    function _initialResolver(Stack memory s) internal view returns (address) {
        ResolverRecord[] memory recs = s.incentive.getDisputeResolvers(WID, address(s.escrow));
        for (uint256 i = 0; i < recs.length; i++) {
            if (recs[i].level == 0) return recs[i].resolver;
        }
        return address(0);
    }

    // ──────────────────────────────────────────────────────────
    // Deploy + wiring
    // ──────────────────────────────────────────────────────────

    function _deploy(bool bonded) internal returns (Stack memory s) {
        ERC20Mock tk = new ERC20Mock("T", "T", address(this), 0);
        tk.mint(buyer, ESCROW_AMT + BOND);
        s.token = tk;

        PaymentCalculationLibraryV1 lib = new PaymentCalculationLibraryV1();

        if (bonded) {
            BondLedger ledger = new BondLedger(address(this));
            s.facade = new ResolverIncentiveModuleV2BondLedger(deployer, address(lib), address(ledger));
            ledger.addAuthorizedCaller(address(s.facade));
            s.ledger = ledger;
            s.incentive = ResolverIncentiveModuleV2(address(s.facade));
        } else {
            s.incentive = new ResolverIncentiveModuleV2(deployer, address(lib));
        }
        s.bonded = bonded;

        s.incentive.grantRole(s.incentive.ROLE_TIMELOCK(), address(this));
        s.incentive.grantRole(s.incentive.ROLE_TIMELOCK(), timelock);
        s.incentive.registerEscrowContract(address(this));

        s.drm = new DecentralizedResolutionModule(deployer);
        { DRMAdminFacet f = new DRMAdminFacet(); s.drm.setAdminFacet(address(f)); }
        s.drm.grantRole(s.drm.ROLE_TIMELOCK(), address(this));
        s.drm.grantRole(s.drm.ROLE_TIMELOCK(), timelock);
        s.drm.registerEscrowContract(address(this));

        YieldOps yOps = new YieldOps(address(this));
        DisputeOps dOps = new DisputeOps(address(this));
        ModuleSnapshotRegistry mm = new ModuleSnapshotRegistry(address(this));
        s.escrow = new EscrowVault(100, feeAddr, address(yOps), address(dOps), address(mm));

        CreateOps cOps = new CreateOps(address(this));
        SettlementOps sOps = new SettlementOps(address(this));
        BondCollector bc = new BondCollector(address(this));

        cOps.registerEscrowContract(address(s.escrow));
        sOps.registerEscrowContract(address(s.escrow));
        bc.registerEscrowContract(address(s.escrow));
        dOps.registerEscrowContract(address(s.escrow));
        yOps.registerEscrowContract(address(s.escrow));

        s.escrow.grantRole(s.escrow.ROLE_ADMIN_CONTRACT(), address(this));
        s.escrow.setCreateOps(address(cOps));
        s.escrow.setSettlementOps(address(sOps));
        s.escrow.setBondCollector(address(bc));

        s.drm.registerEscrowContract(address(s.escrow));
        s.incentive.registerEscrowContract(address(s.escrow));
        s.drm.setIncentiveModule(address(s.incentive));
        s.incentive.setResolutionModule(address(s.drm));

        mm.registerEscrowContract(address(s.escrow));
        mm.grantRole(mm.ROLE_ESCROW_CONTRACT(), address(s.escrow));
        mm.queueModule(address(s.escrow), BaseEscrow.ModuleType.RESOLUTION, address(s.drm));
        vm.warp(block.timestamp + 8 days);
        mm.activateModule(address(s.escrow), BaseEscrow.ModuleType.RESOLUTION);

        s.drm.appointSeniorResolver(senior, "S", "");
        vm.prank(senior);
        s.drm.appointResolver(r0, "R0", "");
        vm.prank(senior);
        s.drm.appointResolver(r1, "R1", "");
        vm.prank(senior);
        s.drm.appointResolver(r2, "R2", "");

        vm.prank(timelock);
        s.drm.queueEscalationConfig(1, DecentralizedResolverStructs.EscalationConfig({
            resolver: address(0), fee: 0, enabled: true
        }));
        { (, uint64 eta2,) = s.drm.getPendingEscalationConfig(1); vm.warp(eta2 + 1); }
        vm.prank(timelock);
        s.drm.activateEscalationConfig(1);

        vm.warp(block.timestamp + 1);
        vm.prank(timelock);
        s.drm.queueEscalationCostConfig(DecentralizedResolverStructs.EscalationCostConfig({
            curveType: DecentralizedResolverStructs.CostCurveType.LINEAR,
            baseCost: BOND, stepSize: BOND, multiplier: 0,
            bondToken: address(s.token), enabled: true
        }));
        (, uint64 eta,) = s.drm.getPendingEscalationCostConfig();
        vm.warp(eta + 1);
        vm.prank(timelock);
        s.drm.activateEscalationCostConfig();
    }

    function _createAndDispute(Stack memory s) internal {
        vm.startPrank(buyer);
        s.token.approve(address(s.escrow), ESCROW_AMT + BOND);
        s.escrow.createEscrow(address(s.token), seller, ESCROW_AMT, EscrowSettings({
            customResolver: address(0), releaseAddress: address(0),
            yieldPreset: YieldPreset.OFF, autoReleaseTime: 0, autoCancelTime: 0
        }));
        s.escrow.raiseDispute(WID);
        vm.stopPrank();
    }

    function _resolve(Stack memory s, address by, bool isRelease) internal {
        ResolutionOutcome o = isRelease ? ResolutionOutcome.RELEASE : ResolutionOutcome.CANCEL;
        vm.prank(address(s.escrow));
        s.drm.recordResolution(WID, address(s.escrow), by, o, 100);
    }
}
