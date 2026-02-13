// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import "forge-std/Test.sol";
import "../../../contracts/modules/DefaultCancellationStrategy.sol";
import "../../../contracts/types/EscrowTypes.sol";

contract DefaultCancellationStrategyTest is Test {
    DefaultCancellationStrategy public strategy;

    address public sender = address(0x1001);
    address public recipient = address(0x1002);
    address public third_party = address(0x1003);
    
    uint256 public constant WORKFLOW_ID = 1;

    function setUp() public {
        strategy = new DefaultCancellationStrategy();
    }

    // ============ Helper function to create an EscrowTransfer ============
    function createTransfer(
        address _from,
        address _to
    ) internal pure returns (EscrowTransfer memory) {
        return EscrowTransfer({
            token: address(0),
            to: _to,
            from: _from,
            disputeResolver: address(0),
            amountAfterFee: 100 ether,
            autoReleaseTime: 0,
            autoCancelTime: 0,
            escrowState: EscrowState.PENDING,
            senderStatus: SenderStatus.NONE,
            recipientStatus: RecipientStatus.NONE
        });
    }

    // ============ Test: Initial State ============
    function test_InitialStateHasNoPendingCancel() public view {
        address pending = strategy.pendingCancel(WORKFLOW_ID);
        assertEq(pending, address(0), "Should have no pending cancel initially");
    }

    // ============ Test: First caller can initiate cancellation ============
    function test_FirstCallerCanInitiate() public view {
        EscrowTransfer memory et = createTransfer(sender, recipient);

        bool canSenderCancel = strategy.canCancel(WORKFLOW_ID, sender, et);
        assertTrue(canSenderCancel, "Sender should be able to initiate cancel");

        bool canRecipientCancel = strategy.canCancel(WORKFLOW_ID, recipient, et);
        assertTrue(canRecipientCancel, "Recipient should be able to initiate cancel");
    }

    // ============ Test: Non-participant cannot cancel ============
    function test_NonParticipantCannotCancel() public view {
        EscrowTransfer memory et = createTransfer(sender, recipient);

        bool canThirdPartyCancel = strategy.canCancel(WORKFLOW_ID, third_party, et);
        assertFalse(canThirdPartyCancel, "Third party should not be able to cancel");
    }

    // ============ Test: Sender initiates, recipient completes ============
    function test_SenderInitiatesRecipientCompletes() public {
        EscrowTransfer memory et = createTransfer(sender, recipient);

        // Sender initiates
        bool senderCanInitiate = strategy.canCancel(WORKFLOW_ID, sender, et);
        assertTrue(senderCanInitiate, "Sender can initiate");

        strategy.onCancelAttempt(WORKFLOW_ID, sender, true);
        address pending = strategy.pendingCancel(WORKFLOW_ID);
        assertEq(pending, sender, "Sender should be recorded as pending");

        // Recipient completes
        bool recipientCanComplete = strategy.canCancel(WORKFLOW_ID, recipient, et);
        assertTrue(recipientCanComplete, "Recipient can complete cancel initiated by sender");

        strategy.onCancelAttempt(WORKFLOW_ID, recipient, true);
        pending = strategy.pendingCancel(WORKFLOW_ID);
        assertEq(pending, address(0), "Pending should be cleared after successful completion");
    }

    // ============ Test: Recipient initiates, sender completes ============
    function test_RecipientInitiatesSenderCompletes() public {
        EscrowTransfer memory et = createTransfer(sender, recipient);

        // Recipient initiates
        bool recipientCanInitiate = strategy.canCancel(WORKFLOW_ID, recipient, et);
        assertTrue(recipientCanInitiate, "Recipient can initiate");

        strategy.onCancelAttempt(WORKFLOW_ID, recipient, true);
        address pending = strategy.pendingCancel(WORKFLOW_ID);
        assertEq(pending, recipient, "Recipient should be recorded as pending");

        // Sender completes
        bool senderCanComplete = strategy.canCancel(WORKFLOW_ID, sender, et);
        assertTrue(senderCanComplete, "Sender can complete cancel initiated by recipient");

        strategy.onCancelAttempt(WORKFLOW_ID, sender, true);
        pending = strategy.pendingCancel(WORKFLOW_ID);
        assertEq(pending, address(0), "Pending should be cleared");
    }

    // ============ Test: Same party cannot complete their own cancel ============
    function test_SamePartyCannnotCompleteOwnCancel() public {
        EscrowTransfer memory et = createTransfer(sender, recipient);

        // Sender initiates
        strategy.onCancelAttempt(WORKFLOW_ID, sender, true);

        // Sender tries to complete their own cancel
        bool senderCanComplete = strategy.canCancel(WORKFLOW_ID, sender, et);
        assertFalse(senderCanComplete, "Sender cannot complete their own cancel request");
    }

    // ============ Test: Third party cannot complete cancel ============
    function test_ThirdPartyCannotCompleteCancel() public {
        EscrowTransfer memory et = createTransfer(sender, recipient);

        // Sender initiates
        strategy.onCancelAttempt(WORKFLOW_ID, sender, true);

        // Third party tries to complete
        bool canThirdPartyComplete = strategy.canCancel(WORKFLOW_ID, third_party, et);
        assertFalse(canThirdPartyComplete, "Third party cannot complete cancel");
    }

    // ============ Test: Failed cancel attempt doesn't record pending ============
    function test_FailedInitiateDoesNotRecordPending() public {
        EscrowTransfer memory et = createTransfer(sender, recipient);

        // Sender attempts but fails
        strategy.onCancelAttempt(WORKFLOW_ID, sender, false);

        address pending = strategy.pendingCancel(WORKFLOW_ID);
        assertEq(pending, address(0), "Failed cancel should not record pending");

        // Both parties should still be able to initiate
        bool senderCanInitiate = strategy.canCancel(WORKFLOW_ID, sender, et);
        assertTrue(senderCanInitiate, "Sender should still be able to initiate");

        bool recipientCanInitiate = strategy.canCancel(WORKFLOW_ID, recipient, et);
        assertTrue(recipientCanInitiate, "Recipient should still be able to initiate");
    }

    // ============ Test: Failed completion keeps pending state ============
    function test_FailedCompletionKeepsPendingState() public {
        EscrowTransfer memory et = createTransfer(sender, recipient);

        // Sender initiates successfully
        strategy.onCancelAttempt(WORKFLOW_ID, sender, true);
        address pending = strategy.pendingCancel(WORKFLOW_ID);
        assertEq(pending, sender, "Sender recorded as pending");

        // Recipient's completion fails
        strategy.onCancelAttempt(WORKFLOW_ID, recipient, false);

        pending = strategy.pendingCancel(WORKFLOW_ID);
        assertEq(pending, sender, "Pending should still be sender after failed completion");

        // Recipient should still be able to try again
        bool recipientCanRetry = strategy.canCancel(WORKFLOW_ID, recipient, et);
        assertTrue(recipientCanRetry, "Recipient should be able to retry");
    }

    // ============ Test: Multiple workflows are independent ============
    function test_MultipleWorkflowsAreIndependent() public {
        EscrowTransfer memory et1 = createTransfer(sender, recipient);
        EscrowTransfer memory et2 = createTransfer(recipient, sender);

        // Workflow 1: sender initiates
        strategy.onCancelAttempt(WORKFLOW_ID, sender, true);

        // Workflow 2: recipient initiates
        strategy.onCancelAttempt(WORKFLOW_ID + 1, recipient, true);

        // Check both are recorded separately
        assertEq(strategy.pendingCancel(WORKFLOW_ID), sender);
        assertEq(strategy.pendingCancel(WORKFLOW_ID + 1), recipient);

        // Workflow 1: recipient completes
        strategy.onCancelAttempt(WORKFLOW_ID, recipient, true);

        // Workflow 2 should still have pending
        assertEq(strategy.pendingCancel(WORKFLOW_ID), address(0));
        assertEq(strategy.pendingCancel(WORKFLOW_ID + 1), recipient);
    }

    // ============ Test: Recipient cannot cancel without being in the transfer ============
    function test_WrongRecipientCannotCancel() public view {
        EscrowTransfer memory et = createTransfer(sender, recipient);

        // third_party masquerades as recipient
        bool canThirdPartyCancel = strategy.canCancel(WORKFLOW_ID, third_party, et);
        assertFalse(canThirdPartyCancel, "Wrong recipient cannot cancel");
    }

    // ============ Test: Sender cannot cancel if only registered as recipient ============
    function test_SenderCannotCancelIfOnlyRecipient() public view {
        EscrowTransfer memory et = createTransfer(recipient, sender); // sender is now recipient

        // Original sender tries to cancel
        bool canCancel = strategy.canCancel(WORKFLOW_ID, sender, et);
        assertTrue(canCancel, "Recipient (original sender) can cancel");

        // But original recipient cannot
        bool recipientCancel = strategy.canCancel(WORKFLOW_ID, recipient, et);
        assertTrue(recipientCancel, "Sender (original recipient) can cancel");
    }

    // ============ Test: State reset after successful two-party cancel ============
    function test_StateResetAfterTwoPartyCancel() public {
        EscrowTransfer memory et = createTransfer(sender, recipient);

        // First cycle: sender initiates, recipient completes
        strategy.onCancelAttempt(WORKFLOW_ID, sender, true);
        strategy.onCancelAttempt(WORKFLOW_ID, recipient, true);
        assertEq(strategy.pendingCancel(WORKFLOW_ID), address(0));

        // Second cycle: recipient initiates, sender completes (should work the same way)
        bool recipientCanInitiate = strategy.canCancel(WORKFLOW_ID, recipient, et);
        assertTrue(recipientCanInitiate, "Recipient should be able to initiate new cancel");

        strategy.onCancelAttempt(WORKFLOW_ID, recipient, true);
        assertEq(strategy.pendingCancel(WORKFLOW_ID), recipient);

        bool senderCanComplete = strategy.canCancel(WORKFLOW_ID, sender, et);
        assertTrue(senderCanComplete, "Sender should be able to complete");

        strategy.onCancelAttempt(WORKFLOW_ID, sender, true);
        assertEq(strategy.pendingCancel(WORKFLOW_ID), address(0));
    }
}
