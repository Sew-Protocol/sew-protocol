// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import 'forge-std/Test.sol';
import 'contracts/core/BaseEscrow.sol';
import 'contracts/modules/DefaultReleaseStrategy.sol';
import 'contracts/types/EscrowTypes.sol';
import 'contracts/libraries/EscrowEncodingLibrary.sol';
import 'contracts/interfaces/IReleaseStrategy.sol';
import '@openzeppelin/contracts/utils/introspection/ERC165.sol';

/**
 * @title StrategyDrivenReleaseTest
 * @notice Unit tests for strategy-driven release mechanism
 * @dev Tests the new IReleaseStrategy interface with reason codes
 * @dev Does NOT test full e2e flow (requires module snapshot setup)
 * @dev DOES test:
 *      - Strategy interface (reason codes)
 *      - DefaultReleaseStrategy implementation
 *      - Behavior when strategy is consulted
 */
contract StrategyDrivenReleaseTest is Test {
    DefaultReleaseStrategy defaultStrategy;
    AlwaysRejectStrategy rejectStrategy;

    address sender = address(0x10);
    address recipient = address(0x20);
    address wrongAddress = address(0x99);

    function setUp() public {
        defaultStrategy = new DefaultReleaseStrategy();
        rejectStrategy = new AlwaysRejectStrategy();
    }

    // ============ Test 1: Strategy Interface - Reason Codes ============

    function test_strategy_canReleaseReturnsReasonCodes() public {
        bytes memory escrowData = EscrowEncodingLibrary.encodeEscrowTransferData(
            address(0x1111),  // token
            sender,           // sender
            recipient,        // recipient
            100 ether,        // amount
            address(0)        // releaseAddress (no delegated releaser for this test)
        );

        // Sender should get reason code 0 (allowed)
        (bool allowed, uint8 reasonCode) = defaultStrategy.canRelease(
            0,  // workflowId
            address(this),
            sender,
            escrowData
        );
        assertTrue(allowed, "Sender should be allowed");
        assertEq(reasonCode, 0, "Reason code should be 0 (allowed)");

        // Non-sender should get reason code 1 (not authorized)
        (allowed, reasonCode) = defaultStrategy.canRelease(
            0,
            address(this),
            wrongAddress,
            escrowData
        );
        assertFalse(allowed, "Non-sender should not be allowed");
        assertEq(reasonCode, 1, "Reason code should be 1 (not authorized)");
    }

    // ============ Test 2: Canonical escrowData Format ============

    function test_strategy_canonicalEscrowDataFormat() public {
        address token = address(0x2222);
        uint256 amount = 50 ether;
        address delegatedReleaser = address(0x123);

        // Build canonical escrowData with a delegated releaser
        bytes memory escrowData = EscrowEncodingLibrary.encodeEscrowTransferData(
            token,
            sender,
            recipient,
            amount,
            delegatedReleaser
        );

        // DefaultReleaseStrategy should be able to decode it correctly
        // We verify this by ensuring sender or delegated releaser can call it without revert
        (bool allowed, uint8 reasonCode) = defaultStrategy.canRelease(
            0,
            address(this),
            sender,
            escrowData
        );

        assertTrue(allowed, "Sender should successfully decode canonical format");
        assertEq(reasonCode, 0, "Decoding should succeed for sender");

        (allowed, reasonCode) = defaultStrategy.canRelease(
            0,
            address(this),
            delegatedReleaser,
            escrowData
        );
        assertTrue(allowed, "Delegated releaser should successfully decode canonical format");
        assertEq(reasonCode, 0, "Decoding should succeed for delegated releaser");
    }

    // ============ Test 3: DefaultReleaseStrategy Allows Sender and Delegated Releaser ============

    function test_strategy_defaultReleaseAllowsSenderAndDelegated() public {
        address delegatedReleaser = address(0x123);
        bytes memory escrowData = EscrowEncodingLibrary.encodeEscrowTransferData(
            address(0x3333),
            sender,
            recipient,
            75 ether,
            delegatedReleaser
        );

        // Sender can release
        (bool allowed, ) = defaultStrategy.canRelease(0, address(this), sender, escrowData);
        assertTrue(allowed, "Sender should be allowed");

        // Delegated releaser can release
        (allowed, ) = defaultStrategy.canRelease(0, address(this), delegatedReleaser, escrowData);
        assertTrue(allowed, "Delegated releaser should be allowed");

        // Recipient is rejected
        (allowed, ) = defaultStrategy.canRelease(0, address(this), recipient, escrowData);
        assertFalse(allowed, "Recipient should not be allowed");

        // Random address is rejected
        (allowed, ) = defaultStrategy.canRelease(0, address(this), wrongAddress, escrowData);
        assertFalse(allowed, "Random address should not be allowed");
    }

    // ============ Test 4: AlwaysRejectStrategy Rejects Everyone ============

    function test_strategy_alwaysRejectRejectsEveryone() public {
        bytes memory escrowData = EscrowEncodingLibrary.encodeEscrowTransferData(
            address(0x4444),
            sender,
            recipient,
            25 ether,
            address(0x123) // Delegated releaser, still rejected by rejectStrategy
        );

        // Even sender is rejected
        (bool allowed, uint8 reasonCode) = rejectStrategy.canRelease(
            0,
            address(this),
            sender,
            escrowData
        );

        assertFalse(allowed, "AlwaysReject should reject everyone");
        assertEq(reasonCode, 1, "Should return REASON_NOT_AUTHORIZED");
    }

    // ============ Test 5: executeRelease Reverts (v1) ============

    function test_strategy_executeReleaseReverts() public {
        // In v1, executeRelease is not implemented, should revert
        vm.expectRevert();
        defaultStrategy.executeRelease(0, address(this), "");
    }

    // ============ Test 6: Strategy Metadata ============

    function test_strategy_metadata() public {
        assertEq(defaultStrategy.moduleName(), "DefaultBuyerRelease");
        assertEq(defaultStrategy.strategyName(), "DefaultBuyerRelease");
        assertEq(defaultStrategy.moduleVersion(), "1.0.0");
    }

    // ============ Test 7: ERC-165 Interface Support ============

    function test_strategy_supportsIReleaseStrategy() public {
        assertTrue(
            defaultStrategy.supportsInterface(type(IReleaseStrategy).interfaceId),
            "Should support IReleaseStrategy"
        );
    }

    // ============ Test 8: Multiple escrows with different senders ============

    function test_strategy_multipleEscrows() public {
        address sender1 = address(0x100);
        address sender2 = address(0x200);
        address delegatedReleaser1 = address(0x101);
        address delegatedReleaser2 = address(0x201);

        bytes memory data1 = EscrowEncodingLibrary.encodeEscrowTransferData(
            address(0x5555),
            sender1,
            recipient,
            10 ether,
            delegatedReleaser1
        );

        bytes memory data2 = EscrowEncodingLibrary.encodeEscrowTransferData(
            address(0x6666),
            sender2,
            recipient,
            20 ether,
            delegatedReleaser2
        );

        // Escrow 1: only sender1 or delegatedReleaser1 allowed
        (bool allowed, ) = defaultStrategy.canRelease(0, address(this), sender1, data1);
        assertTrue(allowed, "Sender1 should be allowed for escrow1");

        (allowed, ) = defaultStrategy.canRelease(0, address(this), delegatedReleaser1, data1);
        assertTrue(allowed, "DelegatedReleaser1 should be allowed for escrow1");

        (allowed, ) = defaultStrategy.canRelease(0, address(this), sender2, data1);
        assertFalse(allowed, "Sender2 should not be allowed for escrow1");

        // Escrow 2: only sender2 or delegatedReleaser2 allowed
        (allowed, ) = defaultStrategy.canRelease(0, address(this), sender2, data2);
        assertTrue(allowed, "Sender2 should be allowed for escrow2");

        (allowed, ) = defaultStrategy.canRelease(0, address(this), delegatedReleaser2, data2);
        assertTrue(allowed, "DelegatedReleaser2 should be allowed for escrow2");

        (allowed, ) = defaultStrategy.canRelease(0, address(this), sender1, data2);
        assertFalse(allowed, "Sender1 should not be allowed for escrow2");
    }
}

// ============ Test Doubles ============

/**
 * @notice Test strategy that always rejects releases
 */
contract AlwaysRejectStrategy is ERC165, IReleaseStrategy {
    function canRelease(
        uint256,
        address,
        address,
        bytes calldata
    ) external pure override returns (bool allowed, uint8 reasonCode) {
        return (false, 1);  // Not authorized
    }

    function executeRelease(
        uint256,
        address,
        bytes calldata
    ) external pure override returns (bool success) {
        revert('AlwaysRejectStrategy: executeRelease not implemented');
    }

    function strategyName() external pure override returns (string memory) {
        return 'AlwaysReject';
    }

    function moduleName() external pure override returns (string memory) {
        return 'AlwaysReject';
    }

    function moduleVersion() external pure override returns (string memory) {
        return '1.0.0';
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC165, IERC165) returns (bool) {
        return interfaceId == type(IReleaseStrategy).interfaceId || super.supportsInterface(interfaceId);
    }
}
