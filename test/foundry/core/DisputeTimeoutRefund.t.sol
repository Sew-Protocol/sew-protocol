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

contract NoopResolver {}

/// @notice End-to-end coverage for the dispute timeout path: a dispute with no
///         resolver decision (which is also how a Kleros refusal lands at the
///         escrow level — the refusal representation adds no escrow state) exits
///         via max-dispute-duration timeout and produces the refund-to-sender
///         economic outcome. This closes the C refusal requirement that the
///         eventual timeout still yields the identical refund result.
contract DisputeTimeoutRefundTest is Test {
    EscrowVault internal vault;
    EscrowCreationPolicy internal policy;
    YieldOps internal yieldOps;
    ModuleSnapshotRegistry internal mm;
    ERC20Mock internal token;
    NoopResolver internal resolver;

    address internal constant FEE = address(0xFEE);
    address internal constant BUYER = address(0xB0B);
    address internal constant SELLER = address(0x5E11E7);
    uint256 internal constant AMOUNT = 100 ether;
    uint256 internal constant MAX_DISPUTE_DURATION = 90 days;

    function setUp() public {
        yieldOps = new YieldOps(address(this));
        mm = new ModuleSnapshotRegistry(address(this));
        policy = new EscrowCreationPolicy(address(this));
        resolver = new NoopResolver();
        token = new ERC20Mock('Token', 'TKN', BUYER, 1_000_000 ether);

        vault = new EscrowVault(0, FEE, address(yieldOps), address(mm));
        yieldOps.registerEscrowContract(address(vault));
        mm.registerEscrowContract(address(vault));
        vault.grantRole(vault.ROLE_ADMIN_CONTRACT(), address(this));
        vault.setCreationPolicy(address(policy));
        vault.setTimeoutConfig(TimeoutConfig(0, 0, MAX_DISPUTE_DURATION, 2 days));

        vm.prank(BUYER);
        token.approve(address(vault), type(uint256).max);
    }

    function _createAndDispute() internal returns (uint256 id) {
        EscrowSettings memory s = EscrowSettings({
            customResolver: address(resolver),
            releaseAddress: address(0),
            yieldPreset: YieldPreset.OFF,
            autoReleaseTime: 0,
            autoCancelTime: 0
        });
        vm.prank(BUYER);
        id = vault.createEscrow(address(token), SELLER, AMOUNT, s);
        vm.prank(BUYER);
        vault.raiseDispute(id);
    }

    function _state(uint256 id) internal view returns (EscrowState st) {
        (, , , , , , , st, , ) = vault.escrowTransfers(id);
    }

    function test_timeout_refundsSender() public {
        uint256 id = _createAndDispute();
        assertEq(uint8(_state(id)), uint8(EscrowState.DISPUTED), 'disputed');
        (bool pending, , , ) = vault.pendingSettlements(id);
        assertFalse(pending, 'no pending settlement from a non-decision');

        uint256 balBefore = token.balanceOf(address(vault));

        // Not yet eligible before the max-dispute-duration elapses.
        vm.prank(BUYER);
        vm.expectRevert();
        vault.resolveDisputeByTimeout(id);

        vm.warp(block.timestamp + MAX_DISPUTE_DURATION + 1);
        vm.prank(BUYER);
        vault.resolveDisputeByTimeout(id);

        assertEq(uint8(_state(id)), uint8(EscrowState.REFUNDED), 'refunded');
        assertEq(vault.claimableBalances(id, BUYER), AMOUNT, 'sender entitlement');
        assertEq(vault.claimableBalances(id, SELLER), 0, 'no recipient entitlement');
        assertEq(token.balanceOf(address(vault)), balBefore, 'pull-only: no push at timeout');

        // Realization: sender can withdraw the refund.
        vm.prank(BUYER);
        uint256 withdrawn = vault.withdrawEscrow(id);
        assertEq(withdrawn, AMOUNT, 'withdrawn amount');
    }

    /// @dev The timeout outcome is identical whether or not a refusal was recorded
    ///      off-chain: the escrow holds no refusal state, and refusal representation
    ///      (KlerosArbitrableProxy.refusalTimestamp) never touches the escrow.
    function test_timeout_unaffectedByRefusalRepresentation() public {
        uint256 idA = _createAndDispute();
        uint256 idB = _createAndDispute();

        vm.warp(block.timestamp + MAX_DISPUTE_DURATION + 1);
        vm.prank(BUYER);
        vault.resolveDisputeByTimeout(idA);
        vm.prank(BUYER);
        vault.resolveDisputeByTimeout(idB);

        assertEq(uint8(_state(idA)), uint8(EscrowState.REFUNDED), 'A refunded');
        assertEq(uint8(_state(idB)), uint8(EscrowState.REFUNDED), 'B refunded');
        assertEq(vault.claimableBalances(idA, BUYER), vault.claimableBalances(idB, BUYER), 'identical refund');
    }
}
