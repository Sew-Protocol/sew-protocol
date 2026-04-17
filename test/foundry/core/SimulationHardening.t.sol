// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import 'forge-std/Test.sol';
import '../../../contracts/core/EscrowVault.sol';
import '../../../contracts/mocks/ERC20Mock.sol';
import '../../../contracts/core/modules/DefaultResolutionModule.sol';
import '../../../contracts/types/EscrowTypes.sol';
import '../../../contracts/types/YieldPresets.sol';
import '../../../contracts/ops/YieldOps.sol';
import '../../../contracts/ops/DisputeOps.sol';
import '../../../contracts/ops/SettlementOps.sol';
import '../../../contracts/ops/CreateOps.sol';
import '../../../contracts/core/BondCollector.sol';
import '../../../contracts/core/ModuleSnapshotRegistry.sol';
import '../../../contracts/libraries/SettingsValidationLibrary.sol';

/**
 * @title SimulationHardeningTest
 * @notice Tests for the two fixes introduced in fix/simulation-hardening:
 *
 *   1. F3 (Governance Sandwich) — resolver captured at raiseDispute is the sole
 *      authority for the dispute's lifetime. A governance rotation of
 *      DefaultResolutionModule.resolver after a dispute opens must NOT authorise
 *      the new resolver to resolve the in-flight dispute.
 *
 *   2. Double-cancel idempotency — senderCancel / recipientCancel are known to
 *      return true silently on a repeated signal (no bytecode budget to fix).
 *      These tests document the current behaviour so any future regression is
 *      caught immediately.
 *
 * Evidence for F3: sew-simulation docs/evidence/detailed/F3-governance-sandwich.md
 */
contract SimulationHardeningTest is Test {
    EscrowVault    public vault;
    ERC20Mock      public token;
    DefaultResolutionModule public resolutionModule;
    YieldOps       public yieldOps;
    DisputeOps     public disputeOps;
    SettlementOps  public settlementOps;
    CreateOps      public createOps;
    BondCollector  public bondCollector;
    ModuleSnapshotRegistry public moduleManagement;

    address public owner     = address(this);
    address public feeAddr   = address(0xFEE);
    address public resolver  = address(0xAA01); // honest resolver at dispute creation
    address public malicious = address(0xBB02); // governance-rotated resolver
    address public buyer     = address(0x1001);
    address public seller    = address(0x1002);

    uint256 constant FEE_BPS = 100;
    uint256 constant AMOUNT  = 1000e18;

    // ─── setup ────────────────────────────────────────────────────────────────

    function setUp() public {
        yieldOps      = new YieldOps(owner);
        disputeOps    = new DisputeOps(owner);
        moduleManagement = new ModuleSnapshotRegistry(owner);
        createOps     = new CreateOps(owner);
        settlementOps = new SettlementOps(owner);
        bondCollector = new BondCollector(owner);
        resolutionModule = new DefaultResolutionModule(owner, resolver);

        vault = new EscrowVault(FEE_BPS, feeAddr, address(yieldOps), address(disputeOps), address(moduleManagement));

        yieldOps.registerEscrowContract(address(vault));
        disputeOps.registerEscrowContract(address(vault));
        moduleManagement.registerEscrowContract(address(vault));
        createOps.registerEscrowContract(address(vault));
        settlementOps.registerEscrowContract(address(vault));
        bondCollector.registerEscrowContract(address(vault));

        vault.grantRole(vault.ROLE_TIMELOCK(), owner);
        vault.grantRole(vault.ROLE_GUARDIAN(), owner);
        vault.grantRole(vault.ROLE_ADMIN_CONTRACT(), owner);

        vault.setCreateOps(address(createOps));
        vault.setSettlementOps(address(settlementOps));
        vault.setBondCollector(address(bondCollector));
        vault.setResolutionModule(address(resolutionModule));

        // Grant owner ROLE_TIMELOCK on the module so tests can simulate governance rotation
        resolutionModule.grantRole(resolutionModule.ROLE_TIMELOCK(), owner);

        // Allow EOA custom resolvers in tests (default policy requires contract; relax for simplicity)
        createOps.setResolverPolicy(false);

        token = new ERC20Mock('Test', 'TEST', owner, 0);
    }

    // ─── helpers ──────────────────────────────────────────────────────────────

    function _openDispute() internal returns (uint256 wid) {
        token.mint(buyer, AMOUNT);
        vm.startPrank(buyer);
        token.approve(address(vault), AMOUNT);
        wid = vault.createEscrow(address(token), seller, AMOUNT, SettingsValidationLibrary.getDefaultSettings());
        vault.raiseDispute(wid);
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // F3 — Governance Sandwich (mid-dispute resolver rotation)
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Honest resolver captured at raiseDispute can still resolve after
     *         governance rotates the module-level resolver to a different address.
     */
    function test_F3_originalResolver_canStillResolveAfterGovernanceRotation() public {
        uint256 wid = _openDispute();

        // Governance rotates the module resolver to `malicious` mid-dispute
        resolutionModule.setResolver(malicious);

        // Honest resolver (captured at dispute creation) must still be able to submit resolution.
        // The call succeeds (returns true) regardless of whether the appeal window defers
        // final state transition — the key assertion is that no revert occurs.
        vm.prank(resolver);
        bool ok = vault.releaseAsDisputeResolver(wid, bytes32(0));
        assertTrue(ok, 'honest resolver should still be authorised');

        // Either the escrow moved directly to RELEASED/REFUNDED, OR it is still DISPUTED
        // with a pending settlement waiting for the appeal window to expire.
        EscrowState state = vault.getEscrowState(wid);
        (bool settlementExists, , , ) = vault.pendingSettlements(wid);
        assertTrue(
            state == EscrowState.RELEASED || state == EscrowState.REFUNDED || settlementExists,
            'escrow should have progressed: either final state or pending settlement created'
        );
    }

    /**
     * @notice The governance-rotated (malicious) resolver must NOT be able to resolve
     *         a dispute that was opened before the rotation.
     */
    function test_F3_newGovernanceResolver_cannotResolveExistingDispute() public {
        uint256 wid = _openDispute();

        // Governance rotates to malicious mid-dispute
        resolutionModule.setResolver(malicious);

        // Malicious resolver tries to resolve — must be rejected
        vm.prank(malicious);
        vm.expectRevert(abi.encodeWithSelector(NotAuthorizedResolver.selector, malicious, resolver));
        vault.releaseAsDisputeResolver(wid, bytes32(0));
    }

    /**
     * @notice Same as above but using cancelAsDisputeResolver — the cancel path
     *         must also be locked to the originally captured resolver.
     */
    function test_F3_newGovernanceResolver_cannotCancelExistingDispute() public {
        uint256 wid = _openDispute();

        resolutionModule.setResolver(malicious);

        vm.prank(malicious);
        vm.expectRevert(abi.encodeWithSelector(NotAuthorizedResolver.selector, malicious, resolver));
        vault.cancelAsDisputeResolver(wid, bytes32(0));
    }

    /**
     * @notice Escrow created with a customResolver is immune to governance rotation
     *         regardless of the module resolver (unchanged from prior behaviour).
     */
    function test_F3_customResolver_immuneToGovernanceRotation() public {
        address customRes = address(0xCC03);

        token.mint(buyer, AMOUNT);
        vm.startPrank(buyer);
        token.approve(address(vault), AMOUNT);

        EscrowSettings memory s = EscrowSettings({
            customResolver: customRes,
            releaseAddress: address(0),
            yieldPreset: YieldPreset.OFF,
            autoReleaseTime: 0,
            autoCancelTime: 0
        });
        uint256 wid = vault.createEscrow(address(token), seller, AMOUNT, s);
        vault.raiseDispute(wid);
        vm.stopPrank();

        // Rotate module resolver — should have zero effect on this escrow
        resolutionModule.setResolver(malicious);

        // The module's current resolver is malicious — it must not resolve this escrow
        vm.prank(malicious);
        // et.disputeResolver is captured from the module at raiseDispute time (resolver), not customRes,
        // but the authorization check correctly rejects malicious via the customResolver guard.
        vm.expectRevert(abi.encodeWithSelector(NotAuthorizedResolver.selector, malicious, resolver));
        vault.releaseAsDisputeResolver(wid, bytes32(0));

        // The custom resolver can still resolve
        vm.prank(customRes);
        bool ok = vault.releaseAsDisputeResolver(wid, bytes32(0));
        assertTrue(ok, 'customResolver should be authorised');
    }

    /**
     * @notice Governance rotation BEFORE a dispute is opened legitimately changes
     *         which resolver is captured for any NEW dispute.
     */
    function test_F3_rotationBeforeDisputeAffectsNewDisputes() public {
        // Rotate BEFORE dispute is opened — this is the legitimate governance use case
        resolutionModule.setResolver(malicious);

        uint256 wid = _openDispute(); // dispute opened AFTER rotation

        // The rotated resolver should now be authorised for the new dispute
        vm.prank(malicious);
        bool ok = vault.releaseAsDisputeResolver(wid, bytes32(0));
        assertTrue(ok, 'rotated resolver should be authorised for disputes opened after rotation');

        // Old resolver should NOT be authorised for the new dispute
        uint256 wid2 = _openDispute();
        vm.prank(resolver);
        vm.expectRevert(abi.encodeWithSelector(NotAuthorizedResolver.selector, resolver, malicious));
        vault.releaseAsDisputeResolver(wid2, bytes32(0));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Double-cancel idempotency (known UX limitation — no bytecode budget to fix)
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Calling senderCancel twice while waiting for mutual consent returns
     *         true both times (idempotent no-op on the second call). This is a
     *         known UX limitation — the caller receives a false success signal but
     *         no funds are at risk. Documented here to catch any future regression.
     */
    function test_doubleSenderCancel_isIdempotent() public {
        uint256 wid = _createEscrowOnly();

        vm.prank(buyer);
        bool first = vault.senderCancel(wid);
        assertTrue(first, 'first call should return true');

        // Second call: still PENDING (no mutual consent yet) — returns true again
        vm.prank(buyer);
        bool second = vault.senderCancel(wid);
        assertTrue(second, 'second call returns true (known idempotent no-op)');

        // State should still be PENDING (no refund without recipient consent)
        assertEq(uint8(vault.getEscrowState(wid)), uint8(EscrowState.PENDING));
    }

    /**
     * @notice Calling recipientCancel twice while waiting for mutual consent returns
     *         true both times. Same known UX limitation as above.
     */
    function test_doubleRecipientCancel_isIdempotent() public {
        uint256 wid = _createEscrowOnly();

        vm.prank(seller);
        bool first = vault.recipientCancel(wid);
        assertTrue(first, 'first call should return true');

        vm.prank(seller);
        bool second = vault.recipientCancel(wid);
        assertTrue(second, 'second call returns true (known idempotent no-op)');

        assertEq(uint8(vault.getEscrowState(wid)), uint8(EscrowState.PENDING));
    }

    // ─── helper — create escrow without raising dispute ───────────────────────

    function _createEscrowOnly() internal returns (uint256 wid) {
        token.mint(buyer, AMOUNT);
        vm.startPrank(buyer);
        token.approve(address(vault), AMOUNT);
        wid = vault.createEscrow(address(token), seller, AMOUNT, SettingsValidationLibrary.getDefaultSettings());
        vm.stopPrank();
    }
}
