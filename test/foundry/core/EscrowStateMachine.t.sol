// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import "forge-std/Test.sol";

import { EscrowVault } from "../../../contracts/core/EscrowVault.sol";
import { BaseEscrow } from "../../../contracts/core/BaseEscrow.sol";
import { ERC20Mock } from "../../../contracts/mocks/ERC20Mock.sol";
import { DefaultResolutionModule } from "../../../contracts/core/modules/DefaultResolutionModule.sol";
import { EscrowSettings, EscrowState, SenderStatus, RecipientStatus } from "../../../contracts/types/EscrowTypes.sol";
import { YieldPreset } from "../../../contracts/types/YieldPresets.sol";
import { YieldOps } from "../../../contracts/ops/YieldOps.sol";
import { DisputeOps } from "../../../contracts/ops/DisputeOps.sol";
import { SettlementOps } from "../../../contracts/ops/SettlementOps.sol";
import { CreateOps } from "../../../contracts/ops/CreateOps.sol";
import { BondCollector } from "../../../contracts/core/BondCollector.sol";
import { ModuleSnapshotRegistry } from "../../../contracts/core/ModuleSnapshotRegistry.sol";
import { DefaultReleaseStrategy } from "../../../contracts/modules/DefaultReleaseStrategy.sol";
import { EscrowGovernanceTimelock } from "../../../contracts/admin/EscrowGovernanceTimelock.sol";
import { SettingsValidationLibrary } from "../../../contracts/libraries/SettingsValidationLibrary.sol";

/**
 * @title EscrowStateMachineTest
 * @notice Focused state machine tests: state/status at each step + expected reverts when invalid.
 * @dev This suite targets "expected state at expected time" and "invalid action => correct revert".
 */
contract EscrowStateMachineTest is Test {
    EscrowVault internal vault;
    ERC20Mock internal token;
    DefaultResolutionModule internal rm;
    DefaultReleaseStrategy internal defaultReleaseStrategy;
    YieldOps internal yieldOps;
    DisputeOps internal disputeOps;
    SettlementOps internal settlementOps;
    CreateOps internal createOps;
    BondCollector internal bondCollector;
    ModuleSnapshotRegistry internal moduleManagement;
    EscrowGovernanceTimelock internal adminContract;

    address internal sender = address(0x10);
    address internal recipient = address(0x20);
    address internal resolver = address(0x30);
    address internal feeAddress = address(0x40);

    uint256 internal constant ESCROW_FEE_BPS = 100; // 1%
    uint256 internal constant AMOUNT = 100 ether;

    function setUp() public {
        yieldOps = new YieldOps(address(this));
        disputeOps = new DisputeOps(address(this));
        settlementOps = new SettlementOps(address(this));
        createOps = new CreateOps(address(this));
        bondCollector = new BondCollector(address(this));
        moduleManagement = new ModuleSnapshotRegistry(address(this));
        adminContract = new EscrowGovernanceTimelock(address(this));
        defaultReleaseStrategy = new DefaultReleaseStrategy();

        vault = new EscrowVault(ESCROW_FEE_BPS, feeAddress, address(yieldOps), address(disputeOps), address(moduleManagement));
        moduleManagement.registerEscrowContract(address(vault));

        moduleManagement.queueModule(address(vault), BaseEscrow.ModuleType.RELEASE, address(defaultReleaseStrategy));
        vm.warp(block.timestamp + 8 days);
        moduleManagement.activateModule(address(vault), BaseEscrow.ModuleType.RELEASE);

        // Register escrow contract with all ops contracts
        yieldOps.registerEscrowContract(address(vault));
        disputeOps.registerEscrowContract(address(vault));
        settlementOps.registerEscrowContract(address(vault));
        createOps.registerEscrowContract(address(vault));
        bondCollector.registerEscrowContract(address(vault));

        // Wire required ops contracts on the vault
        vault.grantRole(vault.ROLE_ADMIN_CONTRACT(), address(this));
        vault.grantRole(vault.ROLE_ADMIN_CONTRACT(), address(adminContract));
        vault.setCreateOps(address(createOps));
        vault.setSettlementOps(address(settlementOps));
        vault.setBondCollector(address(bondCollector));

        // Resolution module (single resolver)
        rm = new DefaultResolutionModule(address(this), resolver);
        // Activate resolution module through admin contract slow lane (warp in tests)
        adminContract.grantRole(adminContract.ROLE_TIMELOCK(), address(this));
        adminContract.queueResolutionModule(address(vault), address(rm));
        vm.warp(block.timestamp + 7 days + 1);
        adminContract.activateResolutionModule(address(vault));

        token = new ERC20Mock("Test Token", "TEST", address(this), 1e30);
        token.transfer(sender, 1000 ether);
    }

    function _defaultSettings() internal pure returns (EscrowSettings memory s) {
        s = SettingsValidationLibrary.getDefaultSettings();
        s.yieldPreset = YieldPreset.OFF;
        s.customResolver = address(0);
        s.autoReleaseTime = 0;
        s.autoCancelTime = 0;
    }

    function _load(uint256 workflowId)
        internal
        view
        returns (
            address tkn,
            address to,
            address from,
            address disputeResolver,
            uint256 amountAfterFee,
            EscrowState st,
            SenderStatus ss,
            RecipientStatus rs
        )
    {
        (tkn, to, from, disputeResolver, amountAfterFee, , , st, ss, rs) = vault.escrowTransfers(workflowId);
    }

    function _create() internal returns (uint256 wid, uint256 amountAfterFee) {
        vm.startPrank(sender);
        token.approve(address(vault), AMOUNT);
        wid = vault.createEscrow(address(token), recipient, AMOUNT, _defaultSettings());
        vm.stopPrank();
        (, , , , amountAfterFee, , , ) = _load(wid);
    }

    function test_state_create_then_release_then_invalid_actions() public {
        (uint256 wid, uint256 aaf) = _create();

        // After create
        (, , address from, address disp, uint256 amountAfterFee, EscrowState st, SenderStatus ss, RecipientStatus rs) =
            _load(wid);
        assertEq(from, sender, "from mismatch");
        assertEq(disp, resolver, "disputeResolver should be snapshotted from DefaultResolutionModule");
        assertEq(amountAfterFee, aaf, "amountAfterFee mismatch");
        assertEq(uint8(st), uint8(EscrowState.PENDING), "state should be PENDING after create");
        assertEq(uint8(ss), uint8(SenderStatus.NONE), "senderStatus should be NONE after create");
        assertEq(uint8(rs), uint8(RecipientStatus.NONE), "recipientStatus should be NONE after create");

        // Invalid: non-sender cannot release
        vm.prank(recipient);
        vm.expectRevert(abi.encodeWithSignature("NotSender(uint256,address,address)", wid, recipient, sender));
        vault.release(wid);

        // Release creates claimable (no direct transfer)
        uint256 recipientBal0 = token.balanceOf(recipient);
        vm.prank(sender);
        vault.release(wid);
        uint256 recipientBal1 = token.balanceOf(recipient);
        assertEq(recipientBal1 - recipientBal0, 0, "settlement must not transfer directly");
        assertEq(vault.claimableBalances(wid, recipient), aaf, "recipient claimable mismatch");

        // After release
        (, , , , , st, ss, rs) = _load(wid);
        assertEq(uint8(st), uint8(EscrowState.RELEASED), "state should be RELEASED after release");
        // statuses should remain default for a non-dispute flow
        assertEq(uint8(ss), uint8(SenderStatus.NONE), "senderStatus should remain NONE");
        assertEq(uint8(rs), uint8(RecipientStatus.NONE), "recipientStatus should remain NONE");

        // Invalid: cannot cancel (requires PENDING)
        vm.prank(sender);
        vm.expectRevert(abi.encodeWithSignature("TransferNotPending(uint256,uint8)", wid, uint8(EscrowState.RELEASED)));
        vault.senderCancel(wid);

        // Invalid: cannot dispute (requires PENDING)
        vm.prank(sender);
        vm.expectRevert(abi.encodeWithSignature("TransferNotPending(uint256,uint8)", wid, uint8(EscrowState.RELEASED)));
        vault.raiseDispute(wid);
    }

    function test_state_two_party_cancel_refund_and_invalid_actions() public {
        (uint256 wid, uint256 aaf) = _create();

        // Sender requests cancel (still PENDING)
        vm.prank(sender);
        vault.senderCancel(wid);
        (, , , , , EscrowState st1, SenderStatus ss1, RecipientStatus rs1) = _load(wid);
        assertEq(uint8(st1), uint8(EscrowState.PENDING), "state should remain PENDING after one cancel");
        assertEq(uint8(ss1), uint8(SenderStatus.AGREE_TO_CANCEL), "senderStatus should be AGREE_TO_CANCEL");
        assertEq(uint8(rs1), uint8(RecipientStatus.NONE), "recipientStatus should still be NONE");

        // Invalid: random cannot cancel
        address attacker = address(0xDEAD);
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSignature("NotSender(uint256,address,address)", wid, attacker, sender));
        vault.senderCancel(wid);

        // Recipient confirms cancel -> REFUNDED + sender claimable
        uint256 senderBal0 = token.balanceOf(sender);
        vm.prank(recipient);
        vault.recipientCancel(wid);
        uint256 senderBal1 = token.balanceOf(sender);
        assertEq(senderBal1 - senderBal0, 0, "settlement must not transfer directly");
        assertEq(vault.claimableBalances(wid, sender), aaf, "sender claimable mismatch");

        (, , , , , EscrowState st2, , ) = _load(wid);
        assertEq(uint8(st2), uint8(EscrowState.REFUNDED), "state should be REFUNDED after 2-party cancel");

        // Invalid: cannot release or dispute from terminal state
        vm.prank(sender);
        vm.expectRevert(abi.encodeWithSignature("TransferNotPending(uint256,uint8)", wid, uint8(EscrowState.REFUNDED)));
        vault.release(wid);

        vm.prank(sender);
        vm.expectRevert(abi.encodeWithSignature("TransferNotPending(uint256,uint8)", wid, uint8(EscrowState.REFUNDED)));
        vault.raiseDispute(wid);

        // Sender can withdraw explicit claimable
        vm.prank(sender);
        uint256 withdrawn = vault.withdrawEscrow(wid);
        assertEq(withdrawn, aaf, "withdrawn refund mismatch");
    }

    function test_state_raise_dispute_sets_status_and_invalid_actions() public {
        (uint256 wid, ) = _create();

        // Sender raises dispute
        vm.prank(sender);
        vault.raiseDispute(wid);
        (, , , , , EscrowState st, SenderStatus ss, RecipientStatus rs) = _load(wid);
        assertEq(uint8(st), uint8(EscrowState.DISPUTED), "state should be DISPUTED after raiseDispute");
        assertEq(uint8(ss), uint8(SenderStatus.RAISE_DISPUTE), "senderStatus should be RAISE_DISPUTE");
        assertEq(uint8(rs), uint8(RecipientStatus.NONE), "recipientStatus should remain NONE");

        // Invalid: release/cancel/raiseDispute again should revert due to not PENDING
        vm.prank(sender);
        vm.expectRevert(abi.encodeWithSignature("TransferNotPending(uint256,uint8)", wid, uint8(EscrowState.DISPUTED)));
        vault.release(wid);

        vm.prank(sender);
        vm.expectRevert(abi.encodeWithSignature("TransferNotPending(uint256,uint8)", wid, uint8(EscrowState.DISPUTED)));
        vault.senderCancel(wid);

        vm.prank(sender);
        vm.expectRevert(abi.encodeWithSignature("TransferNotPending(uint256,uint8)", wid, uint8(EscrowState.DISPUTED)));
        vault.raiseDispute(wid);
    }

    function test_state_dispute_resolution_pending_then_execute_settlement_cancel() public {
        (uint256 wid, uint256 aaf) = _create();

        // Open dispute
        vm.prank(sender);
        vault.raiseDispute(wid);

        // Resolver cancels (refund) -> should store pending settlement (appeal window)
        vm.prank(resolver);
        vault.cancelAsDisputeResolver(wid, bytes32("cancel"));

        // Should still be DISPUTED until appeal window expires
        (, , , , , EscrowState st, , ) = _load(wid);
        assertEq(uint8(st), uint8(EscrowState.DISPUTED), "state should remain DISPUTED while pending settlement exists");
        (bool exists, bool isRelease, uint256 appealDeadline, ) = vault.pendingSettlements(wid);
        assertTrue(exists, "pending settlement should exist");
        assertTrue(!isRelease, "pending should be cancel/refund");
        assertGt(appealDeadline, block.timestamp, "appeal deadline should be in the future");

        // Invalid: execute pending settlement before deadline
        vm.expectRevert(
            abi.encodeWithSignature("AppealWindowNotExpired(uint256,uint256,uint256)", wid, appealDeadline, block.timestamp)
        );
        vault.executePendingSettlement(wid);

        // Execute after deadline (creates claimable)
        vm.warp(appealDeadline + 1);
        uint256 senderBal0 = token.balanceOf(sender);
        vault.executePendingSettlement(wid);
        uint256 senderBal1 = token.balanceOf(sender);
        assertEq(senderBal1 - senderBal0, 0, "settlement must not transfer directly");
        assertEq(vault.claimableBalances(wid, sender), aaf, "refund claimable mismatch");

        (, , , , , EscrowState st2, , ) = _load(wid);
        assertEq(uint8(st2), uint8(EscrowState.REFUNDED), "state should be REFUNDED after executing pending settlement");
        (exists, , , ) = vault.pendingSettlements(wid);
        assertTrue(!exists, "pending settlement should be cleared");
    }

    function test_invalid_withdraw_before_finalized_and_invalid_executePending_no_pending() public {
        (uint256 wid, ) = _create();

        // Invalid: withdraw while PENDING (no claimable balance)
        vm.prank(recipient);
        vm.expectRevert(abi.encodeWithSignature("NoClaimableBalance(uint256,address,address)", wid, recipient, address(token)));
        vault.withdrawEscrow(wid);

        // Invalid: executePendingSettlement when none exists
        vm.expectRevert(abi.encodeWithSignature("NoPendingSettlement(uint256)", wid));
        vault.executePendingSettlement(wid);
    }

    function test_cancellation_mutex_terminal_states() public {
        // Terminal states must have both senderStatus and recipientStatus as NONE.
        // This mirrors the simulation's :cancellation-mutex invariant.

        // --- Test 1: RELEASED terminal state ---
        (uint256 wid1, ) = _create();
        vm.prank(sender);
        vault.release(wid1);
        (, , , , , EscrowState st1, SenderStatus ss1, RecipientStatus rs1) = _load(wid1);
        assertEq(uint8(st1), uint8(EscrowState.RELEASED), "state should be RELEASED after release");
        assertEq(uint8(ss1), uint8(SenderStatus.NONE), "senderStatus must be NONE in RELEASED state");
        assertEq(uint8(rs1), uint8(RecipientStatus.NONE), "recipientStatus must be NONE in RELEASED state");

        // --- Test 2: REFUNDED terminal state (mutual cancel) ---
        (uint256 wid2, ) = _create();
        vm.prank(sender);
        vault.senderCancel(wid2);
        vm.prank(recipient);
        vault.recipientCancel(wid2);
        (, , , , , EscrowState st2, SenderStatus ss2, RecipientStatus rs2) = _load(wid2);
        assertEq(uint8(st2), uint8(EscrowState.REFUNDED), "state should be REFUNDED after mutual cancel");
        assertEq(uint8(ss2), uint8(SenderStatus.NONE), "senderStatus must be NONE in REFUNDED state");
        assertEq(uint8(rs2), uint8(RecipientStatus.NONE), "recipientStatus must be NONE in REFUNDED state");
    }

    function test_status_leak_agree_cancel_over_dispute() public {
        // Regression: S22 - agree-to-cancel status must be cleared when dispute is raised.
        // If recipient set AGREE_TO_CANCEL, then sender raises dispute, the recipient's
        // status must be cleared to NONE (not left stale as AGREE_TO_CANCEL).

        (uint256 wid, ) = _create();

        // Step 1: Recipient initiates cancel -> recipientStatus = AGREE_TO_CANCEL
        vm.prank(recipient);
        vault.recipientCancel(wid);
        (, , , , , EscrowState st1, SenderStatus ss1, RecipientStatus rs1) = _load(wid);
        assertEq(uint8(st1), uint8(EscrowState.PENDING), "state should remain PENDING after one cancel");
        assertEq(uint8(ss1), uint8(SenderStatus.NONE), "senderStatus should still be NONE");
        assertEq(uint8(rs1), uint8(RecipientStatus.AGREE_TO_CANCEL), "recipientStatus should be AGREE_TO_CANCEL");

        // Step 2: Sender raises dispute - must clear recipient's AGREE_TO_CANCEL
        vm.prank(sender);
        vault.raiseDispute(wid);
        (, , , , , EscrowState st2, SenderStatus ss2, RecipientStatus rs2) = _load(wid);
        assertEq(uint8(st2), uint8(EscrowState.DISPUTED), "state should be DISPUTED after raiseDispute");
        assertEq(uint8(ss2), uint8(SenderStatus.RAISE_DISPUTE), "senderStatus should be RAISE_DISPUTE");
        // The fix: counterparty's AGREE_TO_CANCEL must be cleared
        assertEq(uint8(rs2), uint8(RecipientStatus.NONE), "recipientStatus must be NONE (AGREE_TO_CANCEL cleared on dispute)");

        // Step 3: Verify the reverse - sender sets AGREE_TO_CANCEL, recipient raises dispute
        (uint256 wid2, ) = _create();

        vm.prank(sender);
        vault.senderCancel(wid2);
        (, , , , , EscrowState st3, SenderStatus ss3, RecipientStatus rs3) = _load(wid2);
        assertEq(uint8(ss3), uint8(SenderStatus.AGREE_TO_CANCEL), "senderStatus should be AGREE_TO_CANCEL");

        vm.prank(recipient);
        vault.raiseDispute(wid2);
        (, , , , , EscrowState st4, SenderStatus ss4, RecipientStatus rs4) = _load(wid2);
        assertEq(uint8(st4), uint8(EscrowState.DISPUTED), "state should be DISPUTED");
        assertEq(uint8(rs4), uint8(RecipientStatus.RAISE_DISPUTE), "recipientStatus should be RAISE_DISPUTE");
        assertEq(uint8(ss4), uint8(SenderStatus.NONE), "senderStatus must be NONE (AGREE_TO_CANCEL cleared on dispute)");
    }

    function test_auto_cancel_time_protects_against_frivolous_dispute() public {
        // Griefing vector: a dispute raised before auto-cancel-time orphans the
        // deadline because auto-cancel only fires for PENDING escrows.
        // FIX: auto-cancel-time on a DISPUTED escrow now fires auto-cancel-on-disputed
        // via the new ACTION_AUTO_CANCEL_DISPUTED dispatch in automateTimedActions.

        uint256 amount = 100e18;
        uint256 autoCancelTime = block.timestamp + 5 days;

        vm.startPrank(sender);
        token.approve(address(vault), amount);
        EscrowSettings memory settings = _defaultSettings();
        settings.autoCancelTime = autoCancelTime;
        uint256 wid = vault.createEscrow(address(token), recipient, amount, settings);
        vm.stopPrank();

        // Dispute raised BEFORE auto-cancel-time (the attack vector)
        vm.prank(sender);
        vault.raiseDispute(wid);
        (, , , , , EscrowState st1, , ) = _load(wid);
        assertEq(uint8(st1), uint8(EscrowState.DISPUTED), "state should be DISPUTED after raiseDispute");

        // Before auto-cancel-time arrives → automateTimedActions should NOT fire
        vm.warp(autoCancelTime - 1);
        assertFalse(vault.automateTimedActions(wid), "should not fire before auto-cancel-time");
        (, , , , , EscrowState st2, , ) = _load(wid);
        assertEq(uint8(st2), uint8(EscrowState.DISPUTED), "should still be DISPUTED before deadline");

        // At auto-cancel-time → FIX: automateTimedActions fires auto-cancel-on-disputed
        vm.warp(autoCancelTime);
        assertTrue(vault.automateTimedActions(wid), "automateTimedActions should fire when auto-cancel-time reached on DISPUTED");
        (, , , , , EscrowState st3, , ) = _load(wid);
        assertEq(uint8(st3), uint8(EscrowState.REFUNDED), "escrow must be REFUNDED after auto-cancel-on-disputed");

        // Verify claimable entitlement (no direct push transfer)
        uint256 fee = (amount * ESCROW_FEE_BPS) / 10000;
        uint256 expected = amount - fee;
        assertEq(vault.claimableBalances(wid, sender), expected, "sender must have claimable refund entitlement");
    }
}

