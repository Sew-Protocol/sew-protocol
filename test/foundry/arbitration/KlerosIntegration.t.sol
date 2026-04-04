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
        vm.expectRevert('Not authorized');
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
}
