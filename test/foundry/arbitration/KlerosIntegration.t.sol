// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import 'forge-std/Test.sol';
import '../../../contracts/arbitration/KlerosArbitrableProxy.sol';
import '../../../contracts/arbitration/mocks/MockKlerosArbitrator.sol';

contract MockEscrow {
    mapping(uint256 => bool) public released;
    mapping(uint256 => bool) public cancelled;

    function releaseAsDisputeResolver(uint256 workflowId, bytes32 /* resolutionHash */) external returns (bool) {
        released[workflowId] = true;
        return true;
    }

    function cancelAsDisputeResolver(uint256 workflowId, bytes32 /* resolutionHash */) external returns (bool) {
        cancelled[workflowId] = true;
        return true;
    }

    // Required to receive ETH refunds in test_createDispute_refundsExcess
    receive() external payable {}
}

// Used in test_propagateRuling_escrowReverts_thenRetrySucceeds:
// starts reverting, then toggles to accepting
contract ToggleEscrow {
    bool public shouldRevert = true;
    mapping(uint256 => bool) public released;
    mapping(uint256 => bool) public cancelled;

    function setShouldRevert(bool v) external { shouldRevert = v; }

    function releaseAsDisputeResolver(uint256 workflowId, bytes32) external returns (bool) {
        if (shouldRevert) revert('Escrow paused');
        released[workflowId] = true;
        return true;
    }

    function cancelAsDisputeResolver(uint256 workflowId, bytes32) external returns (bool) {
        if (shouldRevert) revert('Escrow paused');
        cancelled[workflowId] = true;
        return true;
    }

    receive() external payable {}
}

// Used in test_settlementReturnsFalse_notRevert
contract SettlementReturnsFalseEscrow {
    function releaseAsDisputeResolver(uint256, bytes32) external returns (bool) { return false; }
    function cancelAsDisputeResolver(uint256, bytes32) external returns (bool) { return false; }
    receive() external payable {}
}

// Used in test_refundFailure_reverts_createDispute: no receive() = can't get ETH back
contract NoReceiveEscrow {
    mapping(uint256 => bool) public released;
    mapping(uint256 => bool) public cancelled;

    function releaseAsDisputeResolver(uint256 workflowId, bytes32) external returns (bool) {
        released[workflowId] = true;
        return true;
    }

    function cancelAsDisputeResolver(uint256 workflowId, bytes32) external returns (bool) {
        cancelled[workflowId] = true;
        return true;
    }

    // Intentionally no receive() — reject ETH refunds
}

// Used in test_reentrancy_blocked_duringRule
contract ReentrantEscrow {
    KlerosArbitrableProxy public proxy;
    bool public reentrancyWasBlocked;

    constructor(KlerosArbitrableProxy _proxy) {
        proxy = _proxy;
    }

    function releaseAsDisputeResolver(uint256, bytes32) external returns (bool) {
        (bool success, ) = address(proxy).call(
            abi.encodeWithSignature('propagateRuling(uint256,address)', 999, address(0))
        );
        reentrancyWasBlocked = !success;
        return true;
    }

    receive() external payable {}
}

/**
 * @title KlerosIntegration Tests
 * @notice Comprehensive test suite for Kleros arbitration integration
 * @dev Ported from test/hardhat/KlerosIntegration.test.ts
 */
contract KlerosIntegrationTest is Test {
    KlerosArbitrableProxy public klerosProxy;
    MockKlerosArbitrator public mockArbitrator;
    MockEscrow public mockEscrow;

    address public owner;
    address public sender;
    address public recipient;
    address public other;

    uint256 constant ARBITRATION_PRICE = 0.1 ether;
    uint256 constant AMOUNT = 1 ether;

    event DisputeCreated(uint256 indexed workflowId, uint256 indexed klerosDisputeId, IArbitrator indexed arbitrator);
    event EvidenceSubmitted(uint256 indexed workflowId, uint256 indexed klerosDisputeId, address indexed submitter, string evidence);
    event RulingExecuted(uint256 indexed workflowId, uint256 indexed klerosDisputeId, uint256 ruling);
    event Ruling(IArbitrator indexed arbitrator, uint256 indexed disputeID, uint256 ruling);

    function setUp() public {
        owner = address(this);
        sender = makeAddr('sender');
        recipient = makeAddr('recipient');
        other = makeAddr('other');
        mockEscrow = new MockEscrow();

        // Deploy MockKlerosArbitrator
        mockArbitrator = new MockKlerosArbitrator(ARBITRATION_PRICE);

        // Deploy KlerosArbitrableProxy
        klerosProxy = new KlerosArbitrableProxy(address(mockArbitrator), owner);

        // Grant ROLE_TIMELOCK to owner (test contract) for registration
        bytes32 ROLE_TIMELOCK = klerosProxy.ROLE_TIMELOCK();
        klerosProxy.grantRole(ROLE_TIMELOCK, owner);
        
        // Register mockEscrow
        klerosProxy.registerEscrowContract(address(mockEscrow));

        // Fund test addresses for dispute creation
        vm.deal(address(mockEscrow), 10 ether);
        vm.deal(sender, 10 ether);
        vm.deal(recipient, 10 ether);
        vm.deal(other, 10 ether);
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // DEPLOYMENT TESTS
    // ═══════════════════════════════════════════════════════════════════════════════

    function test_deployment_correctArbitrator() public {
        assertEq(address(klerosProxy.arbitrator()), address(mockArbitrator));
    }

    function test_deployment_hasMetadata() public {
        assertEq(klerosProxy.moduleName(), 'KlerosArbitrableProxy');
        assertEq(klerosProxy.moduleVersion(), '1.0.0');
    }

    function test_deployment_supportsERC165() public {
        assertTrue(klerosProxy.supportsInterface(0x01ffc9a7));
    }

    function test_deployment_rolesSet() public {
        bytes32 ROLE_TIMELOCK = klerosProxy.ROLE_TIMELOCK();
        assertTrue(klerosProxy.hasRole(ROLE_TIMELOCK, owner));
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // ESCROW REGISTRATION TESTS
    // ═══════════════════════════════════════════════════════════════════════════════

    function test_registerEscrowContract_success() public {
        address newEscrow = makeAddr('newEscrow');
        klerosProxy.registerEscrowContract(newEscrow);
        bytes32 ROLE = klerosProxy.ROLE_ESCROW_CONTRACT();
        assertTrue(klerosProxy.hasRole(ROLE, newEscrow));
    }

    function test_registerEscrowContract_rejectsNonAdmin() public {
        vm.prank(sender);
        vm.expectRevert();
        klerosProxy.registerEscrowContract(address(0x123));
    }

    function test_registerEscrowContract_rejectsZeroAddress() public {
        vm.expectRevert('Invalid escrow address');
        klerosProxy.registerEscrowContract(address(0));
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // DISPUTE CREATION TESTS
    // ═══════════════════════════════════════════════════════════════════════════════

    function test_createDispute_success() public {
        bytes memory escrowData = abi.encode(address(0), sender, recipient, AMOUNT, AMOUNT);

        vm.prank(address(mockEscrow));
        vm.expectEmit(true, true, true, false);
        emit DisputeCreated(1, 0, IArbitrator(address(mockArbitrator)));

        klerosProxy.createDispute{value: ARBITRATION_PRICE}(1, address(mockEscrow), 2, '0x', escrowData);
    }

    function test_createDispute_insufficientFee() public {
        bytes memory escrowData = abi.encode(address(0), sender, recipient, AMOUNT, AMOUNT);

        vm.prank(address(mockEscrow));
        vm.expectRevert('Insufficient arbitration fee');
        klerosProxy.createDispute{value: 0}(1, address(mockEscrow), 2, '0x', escrowData);
    }

    function test_createDispute_duplicate() public {
        bytes memory escrowData = abi.encode(address(0), sender, recipient, AMOUNT, AMOUNT);

        vm.prank(address(mockEscrow));
        klerosProxy.createDispute{value: ARBITRATION_PRICE}(1, address(mockEscrow), 2, '0x', escrowData);

        vm.prank(address(mockEscrow));
        vm.expectRevert('Dispute already exists');
        klerosProxy.createDispute{value: ARBITRATION_PRICE}(1, address(mockEscrow), 2, '0x', escrowData);
    }

    function test_createDispute_refundsExcess() public {
        bytes memory escrowData = abi.encode(address(0), sender, recipient, AMOUNT, AMOUNT);

        uint256 before = address(mockEscrow).balance;
        vm.prank(address(mockEscrow));
        klerosProxy.createDispute{value: ARBITRATION_PRICE * 2}(1, address(mockEscrow), 2, '0x', escrowData);
        uint256 balanceAfter = address(mockEscrow).balance;

        assertEq(before - balanceAfter, ARBITRATION_PRICE);
    }

    function test_createDispute_storesMetadata() public {
        bytes memory escrowData = abi.encode(address(0), sender, recipient, AMOUNT, AMOUNT);
        vm.prank(address(mockEscrow));
        klerosProxy.createDispute{value: ARBITRATION_PRICE}(1, address(mockEscrow), 2, '0x', escrowData);

        (, , , , bool resolved, uint256 ruling, address from, address to, uint256 amount) = klerosProxy.disputes(address(mockEscrow), 1);

        assertEq(from, sender);
        assertEq(to, recipient);
        assertFalse(resolved);
    }

    function test_createDispute_createsMappings() public {
        bytes memory escrowData = abi.encode(address(0), sender, recipient, AMOUNT, AMOUNT);
        vm.prank(address(mockEscrow));
        klerosProxy.createDispute{value: ARBITRATION_PRICE}(1, address(mockEscrow), 2, '0x', escrowData);

        assertEq(klerosProxy.workflowToKlerosDispute(address(mockEscrow), 1), 1);
        assertEq(klerosProxy.klerosDisputeToWorkflow(0), 1);
    }

    function test_createDispute_rejectsNonEscrow() public {
        bytes memory escrowData = abi.encode(address(0), sender, recipient, AMOUNT, AMOUNT);

        vm.prank(other);
        vm.expectRevert('Only registered escrow contracts');
        klerosProxy.createDispute{value: ARBITRATION_PRICE}(1, address(mockEscrow), 2, '0x', escrowData);
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // EVIDENCE TESTS
    // ═══════════════════════════════════════════════════════════════════════════════

    function test_submitEvidence_fromSender() public {
        bytes memory escrowData = abi.encode(address(0), sender, recipient, AMOUNT, AMOUNT);
        vm.prank(address(mockEscrow));
        klerosProxy.createDispute{value: ARBITRATION_PRICE}(1, address(mockEscrow), 2, '0x', escrowData);

        vm.prank(sender);
        vm.expectEmit(true, true, true, true);
        emit EvidenceSubmitted(1, 0, sender, 'ipfs://test');
        klerosProxy.submitEvidence(1, address(mockEscrow), 'ipfs://test');
    }

    function test_submitEvidence_fromRecipient() public {
        bytes memory escrowData = abi.encode(address(0), sender, recipient, AMOUNT, AMOUNT);
        vm.prank(address(mockEscrow));
        klerosProxy.createDispute{value: ARBITRATION_PRICE}(1, address(mockEscrow), 2, '0x', escrowData);

        vm.prank(recipient);
        vm.expectEmit(true, true, true, true);
        emit EvidenceSubmitted(1, 0, recipient, 'ipfs://test2');
        klerosProxy.submitEvidence(1, address(mockEscrow), 'ipfs://test2');
    }

    function test_submitEvidence_fromAnyone() public {
        bytes memory escrowData = abi.encode(address(0), sender, recipient, AMOUNT, AMOUNT);
        vm.prank(address(mockEscrow));
        klerosProxy.createDispute{value: ARBITRATION_PRICE}(1, address(mockEscrow), 2, '0x', escrowData);

        vm.prank(other);
        vm.expectEmit(true, true, true, true);
        emit EvidenceSubmitted(1, 0, other, 'ipfs://test3');
        klerosProxy.submitEvidence(1, address(mockEscrow), 'ipfs://test3');
    }

    function test_submitEvidence_multipleSubmissions() public {
        bytes memory escrowData = abi.encode(address(0), sender, recipient, AMOUNT, AMOUNT);
        vm.prank(address(mockEscrow));
        klerosProxy.createDispute{value: ARBITRATION_PRICE}(1, address(mockEscrow), 2, '0x', escrowData);

        vm.prank(sender);
        klerosProxy.submitEvidence(1, address(mockEscrow), '1');

        vm.prank(recipient);
        klerosProxy.submitEvidence(1, address(mockEscrow), '2');

        vm.prank(other);
        klerosProxy.submitEvidence(1, address(mockEscrow), '3');
    }

    function test_submitEvidence_rejectsNonExistent() public {
        vm.expectRevert('Dispute does not exist');
        klerosProxy.submitEvidence(999, address(mockEscrow), 'test');
    }

    function test_submitEvidence_rejectsAfterResolution() public {
        bytes memory escrowData = abi.encode(address(0), sender, recipient, AMOUNT, AMOUNT);
        vm.prank(address(mockEscrow));
        klerosProxy.createDispute{value: ARBITRATION_PRICE}(1, address(mockEscrow), 2, '0x', escrowData);

        mockArbitrator.giveRuling(0, 1);

        vm.expectRevert('Dispute already resolved');
        klerosProxy.submitEvidence(1, address(mockEscrow), 'late');
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // RULING TESTS
    // ═══════════════════════════════════════════════════════════════════════════════

    function test_rule_receiveRulingRelease() public {
        bytes memory escrowData = abi.encode(address(0), sender, recipient, AMOUNT, AMOUNT);
        vm.prank(address(mockEscrow));
        klerosProxy.createDispute{value: ARBITRATION_PRICE}(1, address(mockEscrow), 2, '0x', escrowData);

        vm.expectEmit(true, true, false, false);
        emit RulingExecuted(1, 0, 1);
        mockArbitrator.giveRuling(0, 1);
        
        assertTrue(mockEscrow.released(1));
    }

    function test_rule_receiveRulingCancel() public {
        bytes memory escrowData = abi.encode(address(0), sender, recipient, AMOUNT, AMOUNT);
        vm.prank(address(mockEscrow));
        klerosProxy.createDispute{value: ARBITRATION_PRICE}(1, address(mockEscrow), 2, '0x', escrowData);

        vm.expectEmit(true, true, false, false);
        emit RulingExecuted(1, 0, 2);
        mockArbitrator.giveRuling(0, 2);
        
        assertTrue(mockEscrow.cancelled(1));
    }

    function test_rule_storesRuling() public {
        bytes memory escrowData = abi.encode(address(0), sender, recipient, AMOUNT, AMOUNT);
        vm.prank(address(mockEscrow));
        klerosProxy.createDispute{value: ARBITRATION_PRICE}(1, address(mockEscrow), 2, '0x', escrowData);

        mockArbitrator.giveRuling(0, 1);

        (bool resolved, uint256 ruling) = klerosProxy.getRuling(1, address(mockEscrow));
        assertTrue(resolved);
        assertEq(ruling, 1);
    }

    function test_rule_updatesMetadata() public {
        bytes memory escrowData = abi.encode(address(0), sender, recipient, AMOUNT, AMOUNT);
        vm.prank(address(mockEscrow));
        klerosProxy.createDispute{value: ARBITRATION_PRICE}(1, address(mockEscrow), 2, '0x', escrowData);

        mockArbitrator.giveRuling(0, 2);

        (, , , , bool resolved, uint256 ruling, , , ) = klerosProxy.disputes(address(mockEscrow), 1);
        assertTrue(resolved);
        assertEq(ruling, 2);
    }

    function test_rule_rejectsNonArbitrator() public {
        bytes memory escrowData = abi.encode(address(0), sender, recipient, AMOUNT, AMOUNT);
        vm.prank(address(mockEscrow));
        klerosProxy.createDispute{value: ARBITRATION_PRICE}(1, address(mockEscrow), 2, '0x', escrowData);

        vm.prank(sender);
        vm.expectRevert('Only arbitrator can rule');
        klerosProxy.rule(0, 1);
    }

    function test_getRuling_beforeResolution() public {
        bytes memory escrowData = abi.encode(address(0), sender, recipient, AMOUNT, AMOUNT);
        vm.prank(address(mockEscrow));
        klerosProxy.createDispute{value: ARBITRATION_PRICE}(1, address(mockEscrow), 2, '0x', escrowData);

        (bool resolved, ) = klerosProxy.getRuling(1, address(mockEscrow));
        assertFalse(resolved);
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // IRESOLUTION MODULE TESTS
    // ═══════════════════════════════════════════════════════════════════════════════

    function test_getDisputeResolver() public {
        (address resolver, uint8 level) = klerosProxy.getDisputeResolver(1, address(mockEscrow), '0x');
        assertEq(resolver, address(klerosProxy));
        assertEq(level, 2);
    }

    function test_isAuthorizedDisputeResolver_self() public {
        (bool authorized, uint8 role) = klerosProxy.isAuthorizedDisputeResolver(
            1,
            address(mockEscrow),
            address(klerosProxy),
            '0x'
        );
        assertTrue(authorized);
        assertEq(role, 2);
    }

    function test_isAuthorizedDisputeResolver_others() public {
        (bool authorized, ) = klerosProxy.isAuthorizedDisputeResolver(1, address(mockEscrow), sender, '0x');
        assertFalse(authorized);
    }

    function test_canEscalate_prevention() public {
        (bool canEscalate, , ) = klerosProxy.canEscalate(1, address(mockEscrow), 2, '0x');
        assertFalse(canEscalate);
    }

    function test_executeEscalation_reverts() public {
        vm.expectRevert('No escalation from Kleros');
        klerosProxy.executeEscalation(1, address(mockEscrow), '0x');
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // COST TESTS
    // ═══════════════════════════════════════════════════════════════════════════════

    function test_getArbitrationCost_returns() public {
        uint256 cost = klerosProxy.getArbitrationCost('0x');
        assertEq(cost, ARBITRATION_PRICE);
    }

    function test_getArbitrationCost_updates() public {
        mockArbitrator.setArbitrationPrice(0.2 ether);
        uint256 cost = klerosProxy.getArbitrationCost('0x');
        assertEq(cost, 0.2 ether);
    }

    function test_getArbitrationCost_zero() public {
        mockArbitrator.setArbitrationPrice(0);
        uint256 cost = klerosProxy.getArbitrationCost('0x');
        assertEq(cost, 0);
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // MULTIPLE DISPUTES TESTS
    // ═══════════════════════════════════════════════════════════════════════════════

    function test_multipleDisputes_handleIndependently() public {
        bytes memory escrowData = abi.encode(address(0), sender, recipient, AMOUNT, AMOUNT);

        vm.prank(address(mockEscrow));
        klerosProxy.createDispute{value: ARBITRATION_PRICE}(1, address(mockEscrow), 2, '0x', escrowData);

        vm.prank(address(mockEscrow));
        klerosProxy.createDispute{value: ARBITRATION_PRICE}(2, address(mockEscrow), 2, '0x', escrowData);

        assertEq(klerosProxy.workflowToKlerosDispute(address(mockEscrow), 1), 1);
        assertEq(klerosProxy.workflowToKlerosDispute(address(mockEscrow), 2), 2);
    }

    function test_multipleDisputes_differentRulings() public {
        bytes memory escrowData = abi.encode(address(0), sender, recipient, AMOUNT, AMOUNT);

        vm.prank(address(mockEscrow));
        klerosProxy.createDispute{value: ARBITRATION_PRICE}(1, address(mockEscrow), 2, '0x', escrowData);

        vm.prank(address(mockEscrow));
        klerosProxy.createDispute{value: ARBITRATION_PRICE}(2, address(mockEscrow), 2, '0x', escrowData);

        mockArbitrator.giveRuling(0, 1);
        mockArbitrator.giveRuling(1, 2);

        (, uint256 r1) = klerosProxy.getRuling(1, address(mockEscrow));
        (, uint256 r2) = klerosProxy.getRuling(2, address(mockEscrow));

        assertEq(r1, 1);
        assertEq(r2, 2);
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // ACCESS CONTROL TESTS
    // ═══════════════════════════════════════════════════════════════════════════════

    function test_accessControl_enforceAdmin() public {
        vm.prank(sender);
        vm.expectRevert();
        klerosProxy.registerEscrowContract(address(0x123));
    }

    function test_accessControl_manageRoles() public {
        bytes32 ROLE = klerosProxy.ROLE_ESCROW_CONTRACT();

        klerosProxy.grantRole(ROLE, sender);
        assertTrue(klerosProxy.hasRole(ROLE, sender));

        klerosProxy.revokeRole(ROLE, sender);
        assertFalse(klerosProxy.hasRole(ROLE, sender));
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // EDGE CASE TESTS
    // ═══════════════════════════════════════════════════════════════════════════════

    function test_edgeCase_zeroWorkflow() public {
        (bool resolved, ) = klerosProxy.getRuling(0, address(mockEscrow));
        assertFalse(resolved);
    }

    function test_edgeCase_largeWorkflow() public {
        (bool resolved, ) = klerosProxy.getRuling(type(uint256).max, address(mockEscrow));
        assertFalse(resolved);
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // ROBUSTNESS TESTS (Sew-side failure modes even when Kleros works correctly)
    // ═══════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Ruling 0 = Kleros refuses to rule.
     *         _propagateRuling returns immediately. Escrow stays DISPUTED.
     *         Only the global maxDisputeDuration timeout can settle it.
     */
    function test_ruling_zero_refusedToRule() public {
        bytes memory escrowData = abi.encode(address(0), sender, recipient, AMOUNT, AMOUNT);
        vm.prank(address(mockEscrow));
        klerosProxy.createDispute{value: ARBITRATION_PRICE}(1, address(mockEscrow), 2, '0x', escrowData);

        mockArbitrator.giveRuling(0, 0);

        (bool resolved, uint256 ruling) = klerosProxy.getRuling(1, address(mockEscrow));
        assertTrue(resolved);
        assertEq(ruling, 0);

        // Escrow was NOT settled — stuck until global timeout
        assertFalse(mockEscrow.released(1));
        assertFalse(mockEscrow.cancelled(1));
    }

    /**
     * @notice Out-of-range ruling (3+) should never arrive from real Kleros, but if it does,
     *         _propagateRuling silently does nothing. Dispute appears resolved but escrow
     *         is never settled.
     */
    function test_ruling_outOfRange_silent() public {
        bytes memory escrowData = abi.encode(address(0), sender, recipient, AMOUNT, AMOUNT);
        vm.prank(address(mockEscrow));
        klerosProxy.createDispute{value: ARBITRATION_PRICE}(1, address(mockEscrow), 2, '0x', escrowData);

        // Use setRuling to bypass MockKlerosArbitrator's require(_ruling <= choices) guard
        mockArbitrator.setRuling(0, 3);

        klerosProxy.propagateRuling(1, address(mockEscrow));

        (bool resolved, uint256 ruling) = klerosProxy.getRuling(1, address(mockEscrow));
        assertTrue(resolved);
        assertEq(ruling, 3);

        // Ruling 3 is not 1 or 2 — no settlement happened
        assertFalse(mockEscrow.released(1));
        assertFalse(mockEscrow.cancelled(1));
    }

    /**
     * @notice Escrow settlement reverts → try/catch swallows it → propagateRuling retry
     *         works after the escrow state is fixed.
     */
    function test_propagateRuling_escrowReverts_thenRetrySucceeds() public {
        ToggleEscrow toggleEscrow = new ToggleEscrow();
        vm.deal(address(toggleEscrow), 10 ether);
        klerosProxy.registerEscrowContract(address(toggleEscrow));

        bytes memory escrowData = abi.encode(address(0), sender, recipient, AMOUNT, AMOUNT);
        vm.prank(address(toggleEscrow));
        klerosProxy.createDispute{value: ARBITRATION_PRICE}(1, address(toggleEscrow), 2, '0x', escrowData);

        // Auto-propagation fails because escrow reverts
        mockArbitrator.giveRuling(0, 1);

        // Dispute IS resolved in the proxy
        (bool resolved, ) = klerosProxy.getRuling(1, address(toggleEscrow));
        assertTrue(resolved);

        // But escrow NOT settled (auto-propagation failed silently)
        assertFalse(toggleEscrow.released(1));

        // Fix the escrow
        toggleEscrow.setShouldRevert(false);

        // Retry propagation
        klerosProxy.propagateRuling(1, address(toggleEscrow));

        // Now escrow IS settled
        assertTrue(toggleEscrow.released(1));
    }

    /**
     * @notice propagateRuling fallback: Kleros has a ruling but rule() was never called
     *         (e.g. out-of-gas, off-chain delivery). Anyone can call propagateRuling to
     *         read the ruling from the arbitrator and settle the escrow.
     * @dev getRuling() reads from the arbitrator directly and returns the ruling even
     *      before propagateRuling. Check the proxy's internal storage for resolved state.
     */
    function test_propagateRuling_fallback_afterMissingFirstCall() public {
        bytes memory escrowData = abi.encode(address(0), sender, recipient, AMOUNT, AMOUNT);
        vm.prank(address(mockEscrow));
        klerosProxy.createDispute{value: ARBITRATION_PRICE}(1, address(mockEscrow), 2, '0x', escrowData);

        // Set ruling without calling rule() — simulates Kleros having a ruling but
        // the callback was never delivered
        mockArbitrator.setRuling(0, 1);

        // Proxy's internal storage: dispute is NOT yet resolved (rule() was never called)
        (, , , , bool proxyResolved, , , , ) = klerosProxy.disputes(address(mockEscrow), 1);
        assertFalse(proxyResolved);

        // Verify the arbitrator does have a ruling available
        (bool arbitratorHasRuling, ) = klerosProxy.getRuling(1, address(mockEscrow));
        assertTrue(arbitratorHasRuling);
        assertEq(klerosProxy.workflowToKlerosDispute(address(mockEscrow), 1), 1);

        // Manual propagation reads from arbitrator and settles
        klerosProxy.propagateRuling(1, address(mockEscrow));

        // Now proxy storage shows resolved
        (, , , , proxyResolved, , , , ) = klerosProxy.disputes(address(mockEscrow), 1);
        assertTrue(proxyResolved);
        assertTrue(mockEscrow.released(1));
    }

    /**
     * @notice If msg.value > cost, the proxy refunds the excess to msg.sender.
     *         If msg.sender cannot receive ETH (no receive()), the refund fails
     *         and createDispute reverts atomically — the Kleros dispute is also rolled back.
     *         EVM atomicity protects against orphaned disputes.
     */
    function test_refundFailure_reverts_createDispute() public {
        NoReceiveEscrow noReceiveEscrow = new NoReceiveEscrow();
        vm.deal(address(noReceiveEscrow), 10 ether);
        klerosProxy.registerEscrowContract(address(noReceiveEscrow));

        bytes memory escrowData = abi.encode(address(0), sender, recipient, AMOUNT, AMOUNT);
        uint256 initialCount = mockArbitrator.getDisputeCount();

        vm.prank(address(noReceiveEscrow));
        vm.expectRevert('Refund failed');
        klerosProxy.createDispute{value: ARBITRATION_PRICE * 2}(1, address(noReceiveEscrow), 2, '0x', escrowData);

        // EVM atomicity: the Kleros dispute was rolled back with the refund failure
        assertEq(mockArbitrator.getDisputeCount(), initialCount);

        // Proxy has no record either
        assertEq(klerosProxy.workflowToKlerosDispute(address(noReceiveEscrow), 1), 0);
    }

    /**
     * @notice Sentinal overflow: workflowToKlerosDispute stores disputeId + 1 (0 = sentinel).
     *         If Kleros returns type(uint256).max, +1 overflows. Solidity 0.8.x catches
     *         this at runtime with an arithmetic overflow panic, reverting the entire
     *         createDispute before any state change.
     */
    function test_disputeIdSentinel_overflow_safe() public {
        bytes memory escrowData = abi.encode(address(0), sender, recipient, AMOUNT, AMOUNT);
        uint256 initialCount = mockArbitrator.getDisputeCount();

        // Tell mock to return max uint256 as the dispute ID
        mockArbitrator.setNextDisputeId(type(uint256).max);

        // Solidity 0.8.x catches the overflow in klerosDisputeId + 1
        vm.prank(address(mockEscrow));
        vm.expectRevert();
        klerosProxy.createDispute{value: ARBITRATION_PRICE}(1, address(mockEscrow), 2, '0x', escrowData);

        // No state was changed — atomic revert protects us
        assertEq(mockArbitrator.getDisputeCount(), initialCount);
        assertEq(klerosProxy.workflowToKlerosDispute(address(mockEscrow), 1), 0);
    }

    /**
     * @notice Reentrancy: rule() and propagateRuling share the same nonReentrant guard.
     *         If the escrow contract calls back into the proxy during settlement,
     *         the guard blocks the reentrant call.
     */
    function test_reentrancy_blocked_duringRule() public {
        ReentrantEscrow reentrantEscrow = new ReentrantEscrow(klerosProxy);
        vm.deal(address(reentrantEscrow), 10 ether);
        klerosProxy.registerEscrowContract(address(reentrantEscrow));

        bytes memory escrowData = abi.encode(address(0), sender, recipient, AMOUNT, AMOUNT);
        vm.prank(address(reentrantEscrow));
        klerosProxy.createDispute{value: ARBITRATION_PRICE}(1, address(reentrantEscrow), 2, '0x', escrowData);

        mockArbitrator.giveRuling(0, 1);

        // During the settlement callback, the escrow tried to re-enter via propagateRuling
        assertTrue(reentrantEscrow.reentrancyWasBlocked());
    }

    /**
     * @notice Settlement returns false: _propagateRuling uses try/catch so a false
     *         return does not cause a revert. The ruling is still recorded.
     */
    function test_settlementReturnsFalse_notRevert() public {
        SettlementReturnsFalseEscrow falseEscrow = new SettlementReturnsFalseEscrow();
        vm.deal(address(falseEscrow), 10 ether);
        klerosProxy.registerEscrowContract(address(falseEscrow));

        bytes memory escrowData = abi.encode(address(0), sender, recipient, AMOUNT, AMOUNT);
        vm.prank(address(falseEscrow));
        klerosProxy.createDispute{value: ARBITRATION_PRICE}(1, address(falseEscrow), 2, '0x', escrowData);

        // Should NOT revert even though settlement returns false
        mockArbitrator.giveRuling(0, 1);

        (bool resolved, uint256 ruling) = klerosProxy.getRuling(1, address(falseEscrow));
        assertTrue(resolved);
        assertEq(ruling, 1);
    }

    /**
     * @notice propagateRuling is idempotent: calling it after auto-propagation already
     *         succeeded does not revert. The second call re-settles but the try/catch
     *         protects against escrow-side failures.
     */
    function test_propagateRuling_idempotent_afterAutoPropagation() public {
        bytes memory escrowData = abi.encode(address(0), sender, recipient, AMOUNT, AMOUNT);
        vm.prank(address(mockEscrow));
        klerosProxy.createDispute{value: ARBITRATION_PRICE}(1, address(mockEscrow), 2, '0x', escrowData);

        // Auto-propagation succeeds
        mockArbitrator.giveRuling(0, 1);
        assertTrue(mockEscrow.released(1));

        // Second call — should not revert
        klerosProxy.propagateRuling(1, address(mockEscrow));

        // State unchanged
        assertTrue(mockEscrow.released(1));
        assertFalse(mockEscrow.cancelled(1));
    }

    /**
     * @notice Ruling delivery still works even after the escrow contract is unregistered.
     *         unregisterEscrowContract only blocks future createDispute calls.
     */
    function test_rule_afterEscrowUnregistered() public {
        bytes memory escrowData = abi.encode(address(0), sender, recipient, AMOUNT, AMOUNT);
        vm.prank(address(mockEscrow));
        klerosProxy.createDispute{value: ARBITRATION_PRICE}(1, address(mockEscrow), 2, '0x', escrowData);

        // Unregister the escrow (revoke the role directly — no unregisterEscrowContract fn)
        bytes32 escrowRole = klerosProxy.ROLE_ESCROW_CONTRACT();
        klerosProxy.revokeRole(escrowRole, address(mockEscrow));
        assertFalse(klerosProxy.hasRole(escrowRole, address(mockEscrow)));

        // Ruling delivery should still work (rule() checks arbitrator auth, not escrow role)
        mockArbitrator.giveRuling(0, 1);

        (bool resolved, uint256 ruling) = klerosProxy.getRuling(1, address(mockEscrow));
        assertTrue(resolved);
        assertEq(ruling, 1);
        assertTrue(mockEscrow.released(1));
    }
}
