// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.37;

import 'forge-std/Test.sol';
import '../../../contracts/core/EscrowVault.sol';
import '../../../contracts/core/EscrowCreationPolicy.sol';
import '../../../contracts/core/ModuleSnapshotRegistry.sol';
import '../../../contracts/ops/YieldOps.sol';
import '../../../contracts/mocks/ERC20Mock.sol';
import '../../../contracts/types/EscrowTypes.sol';
import '../../../contracts/types/YieldPresets.sol';

contract DummyResolver {}

/// @notice Enforced property: `resolutionHash` is reserved, non-binding metadata.
///         Varying it must not change authorization, finality, pending-settlement
///         creation, deadlines, or custody disposition.
contract ResolutionHashNonBindingTest is Test {
    EscrowVault internal vault;
    EscrowCreationPolicy internal policy;
    YieldOps internal yieldOps;
    ModuleSnapshotRegistry internal mm;
    ERC20Mock internal token;
    DummyResolver internal resolver;

    address internal constant FEE = address(0xFEE);
    address internal constant BUYER = address(0xB0B);
    address internal constant SELLER = address(0x5E11E7);
    uint256 internal constant AMOUNT = 100 ether;

    function setUp() public {
        yieldOps = new YieldOps(address(this));
        mm = new ModuleSnapshotRegistry(address(this));
        policy = new EscrowCreationPolicy(address(this));
        resolver = new DummyResolver();
        token = new ERC20Mock('Token', 'TKN', BUYER, 1_000_000 ether);

        vault = _newVault(2 days);

        vm.prank(BUYER);
        token.approve(address(vault), type(uint256).max);
    }

    function _newVault(uint256 appealWindow) internal returns (EscrowVault v) {
        v = new EscrowVault(0, FEE, address(yieldOps), address(mm));
        yieldOps.registerEscrowContract(address(v));
        mm.registerEscrowContract(address(v));
        v.grantRole(v.ROLE_ADMIN_CONTRACT(), address(this));
        v.setCreationPolicy(address(policy));
        v.setTimeoutConfig(TimeoutConfig(0, 0, 90 days, appealWindow));
    }

    function _settings() internal view returns (EscrowSettings memory s) {
        s = EscrowSettings({
            customResolver: address(resolver),
            releaseAddress: address(0),
            yieldPreset: YieldPreset.OFF,
            autoReleaseTime: 0,
            autoCancelTime: 0
        });
    }

    function _createAndDispute(EscrowVault v) internal returns (uint256 id) {
        vm.prank(BUYER);
        id = v.createEscrow(address(token), SELLER, AMOUNT, _settings());
        vm.prank(BUYER);
        v.raiseDispute(id);
    }

    function _state(EscrowVault v, uint256 id) internal view returns (EscrowState st) {
        (, , , , , , , st, , ) = v.escrowTransfers(id);
    }

    // ---- Pending-settlement path: hashes differ, everything authoritative is identical ----

    function test_hashNonBinding_pendingSettlement() public {
        uint256 idA = _createAndDispute(vault);
        uint256 idB = _createAndDispute(vault);

        uint256 balBefore = token.balanceOf(address(vault));

        vm.prank(address(resolver));
        vault.releaseAsDisputeResolver(idA, keccak256('hash-A'));
        vm.prank(address(resolver));
        vault.releaseAsDisputeResolver(idB, keccak256('hash-B'));

        (bool existsA, bool isReleaseA, uint256 deadlineA, bytes32 hashA) = vault.pendingSettlements(idA);
        (bool existsB, bool isReleaseB, uint256 deadlineB, bytes32 hashB) = vault.pendingSettlements(idB);

        assertTrue(existsA && existsB, 'pending settlement must exist');
        assertEq(isReleaseA, isReleaseB, 'isRelease must not depend on hash');
        assertEq(deadlineA, deadlineB, 'finality deadline must not depend on hash');
        assertTrue(hashA != hashB, 'stored hashes should differ');
        assertEq(hashA, keccak256('hash-A'), 'hashA stored');
        assertEq(hashB, keccak256('hash-B'), 'hashB stored');

        // No custody movement at decision time.
        assertEq(token.balanceOf(address(vault)), balBefore, 'no token movement on decision');
        assertEq(vault.claimableBalances(idA, SELLER), 0, 'no entitlement yet A');
        assertEq(vault.claimableBalances(idB, SELLER), 0, 'no entitlement yet B');

        // Realization is identical regardless of hash.
        vm.warp(deadlineA + 1);
        vm.prank(BUYER);
        vault.executePendingSettlement(idA);
        vm.prank(BUYER);
        vault.executePendingSettlement(idB);

        assertEq(uint8(_state(vault, idA)), uint8(EscrowState.RELEASED), 'A released');
        assertEq(uint8(_state(vault, idB)), uint8(EscrowState.RELEASED), 'B released');
        assertEq(vault.claimableBalances(idA, SELLER), AMOUNT, 'A entitlement');
        assertEq(vault.claimableBalances(idB, SELLER), AMOUNT, 'B entitlement');
    }

    // ---- Immediate path: finality independent of hash ----

    function test_hashNonBinding_immediateFinality() public {
        EscrowVault v = _newVault(0); // no appeal window → executes immediately
        vm.prank(BUYER);
        token.approve(address(v), type(uint256).max);

        uint256 idA = _createAndDispute(v);
        uint256 idB = _createAndDispute(v);

        vm.prank(address(resolver));
        v.releaseAsDisputeResolver(idA, keccak256('one'));
        vm.prank(address(resolver));
        v.releaseAsDisputeResolver(idB, bytes32(0)); // even zero hash

        assertFalse(_hasPending(v, idA), 'no pending for immediate A');
        assertFalse(_hasPending(v, idB), 'no pending for immediate B');
        assertEq(uint8(_state(v, idA)), uint8(EscrowState.RELEASED), 'A immediate release');
        assertEq(uint8(_state(v, idB)), uint8(EscrowState.RELEASED), 'B immediate release');
        assertEq(v.claimableBalances(idA, SELLER), AMOUNT, 'A entitlement');
        assertEq(v.claimableBalances(idB, SELLER), AMOUNT, 'B entitlement');
    }

    function _hasPending(EscrowVault v, uint256 id) internal view returns (bool exists) {
        (exists, , , ) = v.pendingSettlements(id);
    }

    // ---- Authorization independent of hash ----

    function test_hashNonBinding_authorization() public {
        EscrowVault v = _newVault(0); // immediate settlement
        vm.prank(BUYER);
        token.approve(address(v), type(uint256).max);
        uint256 id = _createAndDispute(v);

        vm.prank(address(0xBAD));
        vm.expectRevert();
        v.releaseAsDisputeResolver(id, keccak256('anything'));

        vm.prank(address(0xBAD));
        vm.expectRevert();
        v.cancelAsDisputeResolver(id, bytes32(0));

        // Authorized resolver succeeds with any hash (here: zero).
        vm.prank(address(resolver));
        v.cancelAsDisputeResolver(id, bytes32(0));
        assertEq(uint8(_state(v, id)), uint8(EscrowState.REFUNDED), 'authorized cancel');
        assertEq(v.claimableBalances(id, BUYER), AMOUNT, 'refund entitlement');
    }
}
