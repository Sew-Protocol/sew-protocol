// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import 'forge-std/Test.sol';
import '../../../contracts/modules/decentralized-resolution-module/DecentralizedResolutionModule.sol';
import '../../../contracts/modules/decentralized-resolution-module/DRMAdminFacet.sol';
import '../../../contracts/modules/decentralized-resolution-module/DecentralizedResolverStructs.sol';
import '../../../contracts/core/EscrowVault.sol';
import '../../../contracts/core/BaseEscrow.sol';
import '../../../contracts/mocks/ERC20Mock.sol';
import '../../../contracts/ops/YieldOps.sol';
import '../../../contracts/ops/DisputeOps.sol';
import '../../../contracts/ops/CreateOps.sol';
import '../../../contracts/ops/SettlementOps.sol';
import '../../../contracts/core/ModuleSnapshotRegistry.sol';
import '../../../contracts/admin/EscrowGovernanceTimelock.sol';
import '../../../contracts/core/BondCollector.sol';
import '../../../contracts/types/EscrowTypes.sol';

/**
 * @title DisputeCapacityExhaustionTest
 * @notice Tests for resolver capacity enforcement and the capacity-counter decrement fix.
 *
 * Prior to the fix, `currentDisputes` was incremented on every `initializeDispute` call
 * but never decremented. Once a resolver reached its `maxConcurrentDisputes` limit it
 * was permanently blocked from receiving new disputes. These tests verify:
 *
 *   - Capacity enforcement fires (ResolverCapacityExceeded, ResolverNotAcceptingDisputes)
 *   - The counter increments when a dispute is opened via the escrow
 *   - The counter decrements when a dispute is finalized via executePendingSettlement
 *   - Capacity is freed after finalization, allowing a new dispute to be opened
 *   - decrementResolverActiveDisputes is access-controlled
 */
contract DisputeCapacityExhaustionTest is Test {
    // ─── Contracts ──────────────────────────────────────────────────────────────
    EscrowVault public escrow;
    DecentralizedResolutionModule public drm;
    DRMAdminFacet public drmAdmin;
    ERC20Mock public token;
    YieldOps public yieldOps;
    DisputeOps public disputeOps;
    CreateOps public createOps;
    SettlementOps public settlementOps;
    BondCollector public bondCollector;
    ModuleSnapshotRegistry public moduleManagement;
    EscrowGovernanceTimelock public adminContract;

    // ─── Roles ──────────────────────────────────────────────────────────────────
    bytes32 public constant ROLE_TIMELOCK = keccak256('ROLE_TIMELOCK');

    // ─── Addresses ──────────────────────────────────────────────────────────────
    address public deployer;
    address public timelock;
    address public seniorResolver;
    address public resolver1;
    address public buyer;
    address public seller;
    address public feeRecipient;

    uint256 public constant AMOUNT = 1000e18;
    uint256 public constant FEE_BPS = 100;

    // ─── Setup ──────────────────────────────────────────────────────────────────

    function setUp() public {
        deployer = address(this);
        timelock = makeAddr('timelock');
        seniorResolver = makeAddr('seniorResolver');
        resolver1 = makeAddr('resolver1');
        buyer = makeAddr('buyer');
        seller = makeAddr('seller');
        feeRecipient = makeAddr('feeRecipient');

        // Token
        token = new ERC20Mock('Test', 'TEST', deployer, 0);
        token.mint(buyer, 100_000e18);

        // Ops
        yieldOps = new YieldOps(deployer);
        disputeOps = new DisputeOps(deployer);
        createOps = new CreateOps(deployer);
        settlementOps = new SettlementOps(deployer);
        bondCollector = new BondCollector(deployer);
        moduleManagement = new ModuleSnapshotRegistry(deployer);
        adminContract = new EscrowGovernanceTimelock(deployer);

        // DRM
        drm = new DecentralizedResolutionModule(deployer);
        drmAdmin = new DRMAdminFacet();
        drm.setAdminFacet(address(drmAdmin));

        // Escrow vault
        escrow = new EscrowVault(FEE_BPS, feeRecipient, address(yieldOps), address(disputeOps), address(moduleManagement));

        // Wire ops
        disputeOps.registerEscrowContract(address(escrow));
        createOps.registerEscrowContract(address(escrow));
        settlementOps.registerEscrowContract(address(escrow));
        bondCollector.registerEscrowContract(address(escrow));

        escrow.grantRole(escrow.ROLE_ADMIN_CONTRACT(), deployer);
        escrow.grantRole(escrow.ROLE_ADMIN_CONTRACT(), address(adminContract));
        escrow.setCreateOps(address(createOps));
        escrow.setSettlementOps(address(settlementOps));
        escrow.setBondCollector(address(bondCollector));

        // DRM roles & escrow registration
        drm.grantRole(ROLE_TIMELOCK, timelock);
        vm.startPrank(timelock);
        drm.registerEscrowContract(address(escrow));
        drm.registerEscrowContract(address(disputeOps));
        vm.stopPrank();

        // Also register this test contract for direct DRM unit tests
        vm.prank(timelock);
        drm.registerEscrowContract(address(this));

        // Appoint resolvers
        vm.prank(timelock);
        drm.appointSeniorResolver(seniorResolver, 'Senior', 'Test');
        vm.prank(seniorResolver);
        drm.appointResolver(resolver1, 'Resolver1', 'Test resolver');

        // Activate resolvers (capacity set per-test)
        vm.startPrank(timelock);
        drm.setResolverActive(seniorResolver, true);
        drm.setResolverActive(resolver1, true);
        vm.stopPrank();

        // Wire DRM into escrow via governance timelock (7-day queue)
        escrow.grantRole(escrow.ROLE_TIMELOCK(), deployer);
        adminContract.grantRole(adminContract.ROLE_TIMELOCK(), deployer);
        adminContract.queueResolutionModule(address(escrow), address(drm));
        vm.warp(block.timestamp + 7 days + 1);
        adminContract.activateResolutionModule(address(escrow));
    }

    // ─── Helpers ────────────────────────────────────────────────────────────────

    function _createEscrow() internal returns (uint256 wid) {
        vm.startPrank(buyer);
        token.approve(address(escrow), AMOUNT);
        wid = escrow.createEscrow(
            address(token),
            seller,
            AMOUNT,
            EscrowSettings({
                customResolver: address(0),
                releaseAddress: address(0),
                yieldPreset: YieldPreset.OFF,
                autoReleaseTime: 0,
                autoCancelTime: 0
            })
        );
        vm.stopPrank();
    }

    function _openDispute(uint256 wid) internal {
        vm.prank(buyer);
        escrow.raiseDispute(wid);
    }

    function _resolveAndFinalize(uint256 wid) internal {
        (,,, address resolver,,,,,, ) = escrow.escrowTransfers(wid);
        vm.prank(resolver);
        escrow.releaseAsDisputeResolver(wid, bytes32(0));

        // Advance past appeal window (default 2 days)
        vm.warp(block.timestamp + 3 days);

        escrow.executePendingSettlement(wid);
    }

    function _disputeResolver(uint256 wid) internal view returns (address resolver) {
        (,,, resolver,,,,,, ) = escrow.escrowTransfers(wid);
    }

    function _currentDisputes(address resolver) internal view returns (uint256) {
        (, uint256 cur, ) = drm.resolverCapacity(resolver);
        return cur;
    }

    // ============================================================
    // DRM unit tests — direct calls, no escrow
    // ============================================================

    function test_DRM_InitDispute_RevertsWhenCapacityFull() public {
        // Set capacity to 1
        vm.prank(timelock);
        drm.setResolverCapacity(resolver1, 1, true);

        // First dispute — succeeds, counter = 1
        drm.initializeDispute(1, address(this), resolver1, bytes32(0));
        assertEq(_currentDisputes(resolver1), 1);

        // Second dispute — must revert
        vm.expectRevert(
            abi.encodeWithSelector(
                DecentralizedResolutionModule.ResolverCapacityExceeded.selector,
                resolver1, 1, 1
            )
        );
        drm.initializeDispute(2, address(this), resolver1, bytes32(0));
    }

    function test_DRM_InitDispute_RevertsWhenNotAcceptingDisputes() public {
        // acceptsNewDisputes = false
        vm.prank(timelock);
        drm.setResolverCapacity(resolver1, 0, false);

        vm.expectRevert(
            abi.encodeWithSelector(
                DecentralizedResolutionModule.ResolverNotAcceptingDisputes.selector,
                resolver1
            )
        );
        drm.initializeDispute(1, address(this), resolver1, bytes32(0));
    }

    function test_DRM_DecrementReducesCounter() public {
        vm.prank(timelock);
        drm.setResolverCapacity(resolver1, 5, true);

        // Open two disputes directly
        drm.initializeDispute(1, address(this), resolver1, bytes32(0));
        drm.initializeDispute(2, address(this), resolver1, bytes32(0));
        assertEq(_currentDisputes(resolver1), 2);

        // Decrement once
        drm.decrementResolverActiveDisputes(resolver1);
        assertEq(_currentDisputes(resolver1), 1);

        // Decrement again
        drm.decrementResolverActiveDisputes(resolver1);
        assertEq(_currentDisputes(resolver1), 0);
    }

    function test_DRM_DecrementDoesNotUnderflow() public {
        vm.prank(timelock);
        drm.setResolverCapacity(resolver1, 5, true);

        // Counter is 0, decrement should be a no-op
        drm.decrementResolverActiveDisputes(resolver1);
        assertEq(_currentDisputes(resolver1), 0);
    }

    function test_DRM_DecrementRevertsForNonEscrowContract() public {
        vm.prank(makeAddr('unauthorized'));
        vm.expectRevert();
        drm.decrementResolverActiveDisputes(resolver1);
    }

    function test_DRM_CapacityFreedAllowsReuseAfterDecrement() public {
        vm.prank(timelock);
        drm.setResolverCapacity(resolver1, 1, true);

        // Fill capacity
        drm.initializeDispute(1, address(this), resolver1, bytes32(0));
        assertEq(_currentDisputes(resolver1), 1);

        // Decrement (simulates finalization)
        drm.decrementResolverActiveDisputes(resolver1);
        assertEq(_currentDisputes(resolver1), 0);

        // Can open a new dispute now
        drm.initializeDispute(2, address(this), resolver1, bytes32(0));
        assertEq(_currentDisputes(resolver1), 1);
    }

    // ============================================================
    // Integration tests — full escrow flow via EscrowVault
    // ============================================================

    function test_Integration_CounterIncrements_OnDisputeOpen() public {
        vm.prank(timelock);
        drm.setResolverCapacity(resolver1, 0, true); // unlimited

        uint256 wid = _createEscrow();
        assertEq(_currentDisputes(resolver1), 0);

        _openDispute(wid);

        // DRM must have incremented the counter for whichever resolver was assigned
        address assigned = _disputeResolver(wid);
        assertEq(_currentDisputes(assigned), 1);
    }

    function test_Integration_CounterDecrements_AfterFinalization() public {
        vm.prank(timelock);
        drm.setResolverCapacity(resolver1, 0, true); // unlimited

        uint256 wid = _createEscrow();
        _openDispute(wid);

        address assigned = _disputeResolver(wid);
        assertEq(_currentDisputes(assigned), 1, "counter should be 1 after dispute open");

        _resolveAndFinalize(wid);

        assertEq(_currentDisputes(assigned), 0, "counter should be 0 after finalization");
    }

    function test_Integration_CapacityFreed_AllowsNewDisputeAfterFinalization() public {
        // Capacity = 1: resolver can only hold one dispute at a time
        vm.prank(timelock);
        drm.setResolverCapacity(resolver1, 1, true);

        // First escrow: open, resolve, finalize
        uint256 wid1 = _createEscrow();
        _openDispute(wid1);

        address assigned = _disputeResolver(wid1);
        assertEq(_currentDisputes(assigned), 1);

        _resolveAndFinalize(wid1);
        assertEq(_currentDisputes(assigned), 0, "capacity must be freed after finalization");

        // Second escrow: opening a dispute should now succeed
        uint256 wid2 = _createEscrow();
        _openDispute(wid2); // must not revert
        assertEq(_currentDisputes(assigned), 1);
    }

    function test_Integration_CounterNotDecrementedBelowZero() public {
        vm.prank(timelock);
        drm.setResolverCapacity(resolver1, 0, true);

        uint256 wid = _createEscrow();
        _openDispute(wid);
        _resolveAndFinalize(wid);

        // A second finalization path should not underflow
        assertEq(_currentDisputes(resolver1), 0);
    }

    // ============================================================
    // Selection behaviour when capacity is exhausted
    // ============================================================

    function test_Selection_ReturnsFallbackResolver_WhenAllFull() public {
        // Set capacity = 1, fill it
        vm.prank(timelock);
        drm.setResolverCapacity(resolver1, 1, true);
        drm.initializeDispute(999, address(this), resolver1, bytes32(0));
        assertEq(_currentDisputes(resolver1), 1);

        // selectResolverWithQuality should return address(0) — no resolver available
        address selected = drm.selectResolverWithQuality(bytes32(0), false, false);
        assertEq(selected, address(0), "should return address(0) when all at capacity");
    }

    function test_Selection_ExcludesResolver_WhenNotAccepting() public {
        vm.prank(timelock);
        drm.setResolverCapacity(resolver1, 0, false); // closed for business

        address selected = drm.selectResolverWithQuality(bytes32(0), false, false);
        assertNotEq(selected, resolver1, "closed resolver must not be selected");
    }
}
