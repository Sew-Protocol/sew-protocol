// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.37;

import "forge-std/Test.sol";
import "./AppealWindowEnforcement.t.sol";
import "../../../contracts/shared/interfaces/IResolutionModule.sol";
import "../../../contracts/libraries/EscrowEncodingLibrary.sol";

/// @dev Focused closure tests for the quote-bound BaseEscrow appeal composition.
contract AppealAuthoritativePathTest is AppealWindowEnforcementTest {
    uint256 private constant FEE_DENOMINATOR = 10_000;
    uint256 private constant MAX_PROTOCOL_FEE_BPS = 3_000;
    uint32 private constant MAX_FUZZ_ESCALATION_COUNT = 100;
    uint256 private constant MAX_FUZZ_BASE_BOND = 1e30;

    bytes32 private constant TRANSITION_EVENT =
        keccak256("AppealTransitionDerived(uint256,bytes32,bytes32,bytes32,bytes32,uint256,uint256,uint256,address)");

    struct Transition {
        bytes32 requestRoot;
        bytes32 transitionRoot;
        bytes32 quoteRoot;
        bytes32 decisionRoot;
        uint256 gross;
        uint256 fee;
        uint256 net;
        address feeRecipient;
    }

    // Test-only mirrors of the four production preimages. Keeping these pure makes
    // each mutation check independent of the stateful appeal path.
    function _appealedDecisionRoot(
        uint256 chainId,
        address module,
        address escrowContract,
        uint256 workflowId,
        uint8 predecessorRound,
        address predecessorResolver,
        ResolutionOutcome decision,
        uint256 decidedAt,
        uint256 deadline
    ) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                "APPEALED_DECISION_V1",
                chainId,
                module,
                escrowContract,
                workflowId,
                predecessorRound,
                predecessorResolver,
                decision,
                decidedAt,
                deadline
            )
        );
    }

    function _resolutionQuoteRoot(
        uint256 chainId,
        address module,
        address escrowContract,
        uint256 workflowId,
        bytes32 decisionRoot,
        bool appealable,
        uint8 predecessorRound,
        uint8 successorRound,
        address predecessorResolver,
        address successorResolver,
        uint256 deadline,
        bool finalRound,
        address bondAsset,
        uint256 bondAmount
    ) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                "RESOLUTION_APPEAL_QUOTE_V1",
                chainId,
                module,
                escrowContract,
                workflowId,
                decisionRoot,
                appealable,
                predecessorRound,
                successorRound,
                predecessorResolver,
                successorResolver,
                deadline,
                finalRound,
                bondAsset,
                bondAmount
            )
        );
    }

    function _policyRoot(uint256 feeBps, address feeRecipient, uint32 priorEscalationCount)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode("ESCROW_APPEAL_POLICY_V1", feeBps, feeRecipient, priorEscalationCount));
    }

    function _transitionRoot(
        bytes32 requestRoot,
        bytes32 quoteRoot,
        uint8 currentLevel,
        uint8 newLevel,
        address predecessorResolver,
        address newResolver,
        address bondToken,
        uint256 grossBond,
        uint256 fee,
        uint256 netBond,
        bytes32 policy
    ) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                "APPEAL_TRANSITION_V1",
                requestRoot,
                quoteRoot,
                currentLevel,
                newLevel,
                predecessorResolver,
                newResolver,
                bondToken,
                grossBond,
                fee,
                netBond,
                policy
            )
        );
    }

    function _assertMutated(bytes32 canonical, bytes32 mutated) internal pure {
        assert(canonical != mutated);
    }

    /// @dev Test-only mirror of BaseEscrow's appeal bond scale, floor-fee, and net calculation.
    function _appealBondAmounts(uint256 baseBond, uint32 escalationCount, uint256 feeBps)
        internal
        pure
        returns (uint256 grossBond, uint256 protocolFee, uint256 netBond)
    {
        grossBond = baseBond;
        if (escalationCount > 1) {
            uint256 scale100 = 100 + 10 * uint256(escalationCount - 1);
            grossBond = baseBond * scale100 / 100;
        }
        protocolFee = grossBond * feeBps / FEE_DENOMINATOR;
        netBond = grossBond - protocolFee;
    }

    function testFuzz_appealBondScaleFloorFeeAndNetArithmetic(
        uint256 baseBond,
        uint32 escalationCount,
        uint256 feeBps
    ) public pure {
        baseBond = bound(baseBond, 0, MAX_FUZZ_BASE_BOND);
        escalationCount = uint32(bound(escalationCount, 1, MAX_FUZZ_ESCALATION_COUNT));
        feeBps = bound(feeBps, 0, MAX_PROTOCOL_FEE_BPS);

        (uint256 grossBond, uint256 protocolFee, uint256 netBond) =
            _appealBondAmounts(baseBond, escalationCount, feeBps);
        uint256 scale100 = 100 + 10 * uint256(escalationCount - 1);

        assertEq(grossBond, baseBond * scale100 / 100, "gross uses BaseEscrow scale");
        assertEq(protocolFee, grossBond * feeBps / FEE_DENOMINATOR, "fee is floored");
        assertLe(protocolFee * FEE_DENOMINATOR, grossBond * feeBps, "fee does not round up");
        assertGt((protocolFee + 1) * FEE_DENOMINATOR, grossBond * feeBps, "fee is the floor");
        assertEq(grossBond, protocolFee + netBond, "gross equals fee plus net");

        (uint256 nextGross, uint256 nextFee, uint256 nextNet) =
            _appealBondAmounts(baseBond, escalationCount + 1, feeBps);
        assertGe(nextGross, grossBond, "gross is monotonic in escalation count");
        assertGe(nextFee, protocolFee, "fee is monotonic in escalation count");
        assertGe(nextNet, netBond, "net is monotonic in escalation count");

        uint256 higherFeeBps = feeBps == MAX_PROTOCOL_FEE_BPS ? feeBps : feeBps + 1;
        (, uint256 higherFee, uint256 lowerNet) = _appealBondAmounts(baseBond, escalationCount, higherFeeBps);
        assertGe(higherFee, protocolFee, "fee is monotonic in fee bps");
        assertLe(lowerNet, netBond, "net decreases as fee bps increase");
    }

    function test_appealBondScaleFloorFeeAndNetArithmetic_boundaries() public pure {
        (uint256 grossBond, uint256 protocolFee, uint256 netBond) = _appealBondAmounts(1, 1, 0);
        assertEq(grossBond, 1, "first escalation uses the base bond");
        assertEq(protocolFee, 0, "zero bps has zero fee");
        assertEq(netBond, 1, "zero bps retains the full bond");

        (grossBond, protocolFee, netBond) = _appealBondAmounts(1, 2, MAX_PROTOCOL_FEE_BPS);
        assertEq(grossBond, 1, "scale division floors");
        assertEq(protocolFee, 0, "sub-wei max-rate fee floors to zero");
        assertEq(netBond, 1, "net retains rounding dust");

        (grossBond, protocolFee, netBond) = _appealBondAmounts(100, 2, MAX_PROTOCOL_FEE_BPS);
        assertEq(grossBond, 110, "second escalation scales by 110 percent");
        assertEq(protocolFee, 33, "max fee is floored after scaling");
        assertEq(netBond, 77, "net subtracts the floored fee");

        (grossBond, protocolFee, netBond) = _appealBondAmounts(10_001, 1, MAX_PROTOCOL_FEE_BPS);
        assertEq(grossBond, 10_001, "first escalation remains unscaled");
        assertEq(protocolFee, 3_000, "max fee boundary is exact");
        assertEq(netBond, 7_001, "exact max-rate net is preserved");
    }

    function _escrowData(uint256 workflowId) internal view returns (bytes memory) {
        workflowId;
        return EscrowEncodingLibrary.encodeEscrowTransferData(address(token), buyer, seller, ESCROW_AMOUNT, address(0));
    }

    function _decideRoundZero(uint256 workflowId) internal {
        bytes memory data = _escrowData(workflowId);
        (address resolver,) = resolutionModule.getDisputeResolver(workflowId, address(escrow), data);
        vm.prank(resolver);
        escrow.releaseAsDisputeResolver(workflowId, bytes32(0));
    }

    function _transitionFromLogs(Vm.Log[] memory logs) internal pure returns (Transition memory transition) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == TRANSITION_EVENT) {
                (
                    transition.quoteRoot,
                    transition.decisionRoot,
                    transition.gross,
                    transition.fee,
                    transition.net,
                    transition.feeRecipient
                ) = abi.decode(logs[i].data, (bytes32, bytes32, uint256, uint256, uint256, address));
                transition.requestRoot = logs[i].topics[2];
                transition.transitionRoot = logs[i].topics[3];
                return transition;
            }
        }
        revert("transition event missing");
    }

    function _prepareAppeal() internal returns (uint256 workflowId, uint256 bond) {
        workflowId = createEscrow();
        raiseDispute(workflowId);
        _decideRoundZero(workflowId);
        (bond,) = resolutionModule.getRequiredAppealBond(workflowId, address(escrow), 0, _escrowData(workflowId));
        vm.prank(buyer);
        token.approve(address(escrow), bond);
    }

    function test_wrapperAndExplicitRequest_haveIdenticalTransition() public {
        (uint256 workflowId,) = _prepareAppeal();
        uint256 snapshot = vm.snapshotState();

        vm.recordLogs();
        vm.prank(buyer);
        (bool wrapperSuccess, address wrapperResolver, uint8 wrapperRound) = escrow.escalateDispute(workflowId);
        Transition memory wrapper = _transitionFromLogs(vm.getRecordedLogs());
        assertTrue(wrapperSuccess);
        assertEq(wrapper.gross, wrapper.fee + wrapper.net);
        assertEq(incentiveModule.getAppealBond(workflowId, address(escrow), wrapperRound).amount, wrapper.net);

        vm.revertToState(snapshot);
        vm.recordLogs();
        vm.prank(buyer);
        (bool explicitSuccess, address explicitResolver, uint8 explicitRound) =
            escrow.appealDispute(workflowId, BaseEscrow.AppealRequest(buyer, buyer, buyer));
        Transition memory explicitRequest = _transitionFromLogs(vm.getRecordedLogs());

        assertTrue(explicitSuccess);
        assertEq(explicitResolver, wrapperResolver);
        assertEq(explicitRound, wrapperRound);
        assertEq(explicitRequest.requestRoot, wrapper.requestRoot);
        assertEq(explicitRequest.transitionRoot, wrapper.transitionRoot);
        assertEq(explicitRequest.quoteRoot, wrapper.quoteRoot);
        assertEq(explicitRequest.decisionRoot, wrapper.decisionRoot);
        assertEq(explicitRequest.gross, wrapper.gross);
        assertEq(explicitRequest.fee, wrapper.fee);
        assertEq(explicitRequest.net, wrapper.net);
        assertEq(explicitRequest.feeRecipient, wrapper.feeRecipient);
        assertEq(incentiveModule.getAppealBond(workflowId, address(escrow), explicitRound).amount, explicitRequest.net);
    }

    function test_staleQuote_revertsAfterSuccessorResolverChanges() public {
        (uint256 workflowId,) = _prepareAppeal();
        bytes memory data = _escrowData(workflowId);
        IResolutionModule.ResolutionAppealQuote memory quote =
            resolutionModule.quoteAppealTransition(workflowId, address(escrow), data);

        // The successor is selected from active capacity. Removing it changes the authoritative quote.
        vm.prank(timelock);
        resolutionModule.setResolverCapacity(quote.successorResolver, 0, false);
        IResolutionModule.ResolutionAppealQuote memory changed =
            resolutionModule.quoteAppealTransition(workflowId, address(escrow), data);
        assertTrue(changed.resolutionQuoteRoot != quote.resolutionQuoteRoot);

        vm.expectRevert(bytes("Stale appeal quote"));
        vm.prank(address(escrow));
        resolutionModule.executeEscalationWithQuote(workflowId, address(escrow), data, quote.resolutionQuoteRoot);
    }

    function test_collectionFailure_rollsBackQuoteComposedAppeal() public {
        (uint256 workflowId, uint256 bond) = _prepareAppeal();
        bytes memory data = _escrowData(workflowId);
        (address predecessor, uint8 priorRound) = resolutionModule.getDisputeResolver(workflowId, address(escrow), data);
        uint256 feeBefore = escrow.claimableBondProtocolFees(address(token), feeAddress);

        vm.prank(buyer);
        token.approve(address(escrow), bond - 1);
        vm.expectRevert();
        vm.prank(buyer);
        escrow.escalateDispute(workflowId);

        (address resolverAfter, uint8 roundAfter) =
            resolutionModule.getDisputeResolver(workflowId, address(escrow), data);
        assertEq(resolverAfter, predecessor);
        assertEq(roundAfter, priorRound);
        assertEq(escrow.addressEscalationCount(buyer), 0);
        assertEq(escrow.claimableBondProtocolFees(address(token), feeAddress), feeBefore);
        assertEq(incentiveModule.getAppealBond(workflowId, address(escrow), priorRound + 1).amount, 0);
    }

    function test_requestRoot_bindsOnlyV1IntentIdentity() public {
        (uint256 workflowId,) = _prepareAppeal();
        bytes32 decisionRoot =
            resolutionModule.quoteAppealTransition(workflowId, address(escrow), _escrowData(workflowId))
        .appealedDecisionRoot;
        bytes32 root = keccak256(
            abi.encode(
                "APPEAL_REQUEST_V1", block.chainid, address(escrow), workflowId, decisionRoot, buyer, buyer, buyer
            )
        );

        assertTrue(
            root
                != keccak256(
                    abi.encode(
                        "APPEAL_REQUEST_V2",
                        block.chainid,
                        address(escrow),
                        workflowId,
                        decisionRoot,
                        buyer,
                        buyer,
                        buyer
                    )
                )
        );
        assertTrue(
            root
                != keccak256(
                    abi.encode(
                        "APPEAL_REQUEST_V1",
                        block.chainid + 1,
                        address(escrow),
                        workflowId,
                        decisionRoot,
                        buyer,
                        buyer,
                        buyer
                    )
                )
        );
        assertTrue(
            root
                != keccak256(
                    abi.encode(
                        "APPEAL_REQUEST_V1", block.chainid, address(this), workflowId, decisionRoot, buyer, buyer, buyer
                    )
                )
        );
        assertTrue(
            root
                != keccak256(
                    abi.encode(
                        "APPEAL_REQUEST_V1",
                        block.chainid,
                        address(escrow),
                        workflowId + 1,
                        decisionRoot,
                        buyer,
                        buyer,
                        buyer
                    )
                )
        );
        assertTrue(
            root
                != keccak256(
                    abi.encode(
                        "APPEAL_REQUEST_V1",
                        block.chainid,
                        address(escrow),
                        workflowId,
                        bytes32(uint256(decisionRoot) + 1),
                        buyer,
                        buyer,
                        buyer
                    )
                )
        );
        assertTrue(
            root
                != keccak256(
                    abi.encode(
                        "APPEAL_REQUEST_V1",
                        block.chainid,
                        address(escrow),
                        workflowId,
                        decisionRoot,
                        seller,
                        buyer,
                        buyer
                    )
                )
        );
        assertTrue(
            root
                != keccak256(
                    abi.encode(
                        "APPEAL_REQUEST_V1",
                        block.chainid,
                        address(escrow),
                        workflowId,
                        decisionRoot,
                        buyer,
                        seller,
                        buyer
                    )
                )
        );
        assertTrue(
            root
                != keccak256(
                    abi.encode(
                        "APPEAL_REQUEST_V1",
                        block.chainid,
                        address(escrow),
                        workflowId,
                        decisionRoot,
                        buyer,
                        buyer,
                        seller
                    )
                )
        );
    }

    function test_transitionRoot_bindsQuotePolicyAndBondDecomposition() public {
        (uint256 workflowId,) = _prepareAppeal();
        vm.recordLogs();
        vm.prank(buyer);
        escrow.escalateDispute(workflowId);
        Transition memory transition = _transitionFromLogs(vm.getRecordedLogs());
        bytes32 policy = _policyRoot(0, feeAddress, 0);
        bytes32 expected = _transitionRoot(
            transition.requestRoot,
            transition.quoteRoot,
            0,
            1,
            resolver1,
            seniorResolver,
            address(token),
            transition.gross,
            transition.fee,
            transition.net,
            policy
        );
        assertEq(transition.transitionRoot, expected);
        assertEq(transition.gross, transition.fee + transition.net);
        assertTrue(
            expected
                != keccak256(
                    abi.encode(
                        "APPEAL_TRANSITION_V1",
                        bytes32(uint256(transition.requestRoot) + 1),
                        transition.quoteRoot,
                        uint8(0),
                        uint8(1),
                        resolver1,
                        seniorResolver,
                        address(token),
                        transition.gross,
                        transition.fee,
                        transition.net,
                        policy
                    )
                )
        );
        assertTrue(
            expected
                != keccak256(
                    abi.encode(
                        "APPEAL_TRANSITION_V1",
                        transition.requestRoot,
                        bytes32(uint256(transition.quoteRoot) + 1),
                        uint8(0),
                        uint8(1),
                        resolver1,
                        seniorResolver,
                        address(token),
                        transition.gross,
                        transition.fee,
                        transition.net,
                        policy
                    )
                )
        );
        assertTrue(
            expected
                != keccak256(
                    abi.encode(
                        "APPEAL_TRANSITION_V1",
                        transition.requestRoot,
                        transition.quoteRoot,
                        uint8(0),
                        uint8(1),
                        resolver1,
                        seniorResolver,
                        address(token),
                        transition.gross + 1,
                        transition.fee,
                        transition.net,
                        policy
                    )
                )
        );
        assertTrue(
            expected
                != keccak256(
                    abi.encode(
                        "APPEAL_TRANSITION_V1",
                        transition.requestRoot,
                        transition.quoteRoot,
                        uint8(0),
                        uint8(1),
                        resolver1,
                        seniorResolver,
                        address(token),
                        transition.gross,
                        transition.fee + 1,
                        transition.net,
                        policy
                    )
                )
        );
        assertTrue(
            expected
                != keccak256(
                    abi.encode(
                        "APPEAL_TRANSITION_V1",
                        transition.requestRoot,
                        transition.quoteRoot,
                        uint8(0),
                        uint8(1),
                        resolver1,
                        seniorResolver,
                        address(token),
                        transition.gross,
                        transition.fee,
                        transition.net + 1,
                        policy
                    )
                )
        );
        assertTrue(
            expected
                != keccak256(
                    abi.encode(
                        "APPEAL_TRANSITION_V1",
                        transition.requestRoot,
                        transition.quoteRoot,
                        uint8(0),
                        uint8(1),
                        resolver1,
                        seniorResolver,
                        address(token),
                        transition.gross,
                        transition.fee,
                        transition.net,
                        keccak256(abi.encode("ESCROW_APPEAL_POLICY_V1", uint256(1), feeAddress, uint32(0)))
                    )
                )
        );
    }

    function test_appealedDecisionRoot_isCanonicalStableAndBindsEveryField() public {
        (uint256 workflowId,) = _prepareAppeal();
        IResolutionModule.ResolutionAppealQuote memory quote =
            resolutionModule.quoteAppealTransition(workflowId, address(escrow), _escrowData(workflowId));
        DecentralizedResolutionModule.DisputeMetadata memory metadata =
            resolutionModule.getDisputeMetadata(workflowId, address(escrow));
        bytes32 root = _appealedDecisionRoot(
            block.chainid,
            address(resolutionModule),
            address(escrow),
            workflowId,
            quote.predecessorRound,
            quote.predecessorResolver,
            quote.appealedDecision,
            metadata.decidedAtRound[quote.predecessorRound],
            quote.appealDeadline
        );
        assertEq(root, quote.appealedDecisionRoot);
        assertEq(
            root,
            _appealedDecisionRoot(
                block.chainid,
                address(resolutionModule),
                address(escrow),
                workflowId,
                quote.predecessorRound,
                quote.predecessorResolver,
                quote.appealedDecision,
                metadata.decidedAtRound[quote.predecessorRound],
                quote.appealDeadline
            )
        );
        _assertMutated(
            root,
            keccak256(
                abi.encode(
                    "APPEALED_DECISION_V2",
                    block.chainid,
                    address(resolutionModule),
                    address(escrow),
                    workflowId,
                    quote.predecessorRound,
                    quote.predecessorResolver,
                    quote.appealedDecision,
                    metadata.decidedAtRound[quote.predecessorRound],
                    quote.appealDeadline
                )
            )
        );
        _assertMutated(
            root,
            _appealedDecisionRoot(
                block.chainid + 1,
                address(resolutionModule),
                address(escrow),
                workflowId,
                quote.predecessorRound,
                quote.predecessorResolver,
                quote.appealedDecision,
                metadata.decidedAtRound[quote.predecessorRound],
                quote.appealDeadline
            )
        );
        _assertMutated(
            root,
            _appealedDecisionRoot(
                block.chainid,
                address(this),
                address(escrow),
                workflowId,
                quote.predecessorRound,
                quote.predecessorResolver,
                quote.appealedDecision,
                metadata.decidedAtRound[quote.predecessorRound],
                quote.appealDeadline
            )
        );
        _assertMutated(
            root,
            _appealedDecisionRoot(
                block.chainid,
                address(resolutionModule),
                address(this),
                workflowId,
                quote.predecessorRound,
                quote.predecessorResolver,
                quote.appealedDecision,
                metadata.decidedAtRound[quote.predecessorRound],
                quote.appealDeadline
            )
        );
        _assertMutated(
            root,
            _appealedDecisionRoot(
                block.chainid,
                address(resolutionModule),
                address(escrow),
                workflowId + 1,
                quote.predecessorRound,
                quote.predecessorResolver,
                quote.appealedDecision,
                metadata.decidedAtRound[quote.predecessorRound],
                quote.appealDeadline
            )
        );
        _assertMutated(
            root,
            _appealedDecisionRoot(
                block.chainid,
                address(resolutionModule),
                address(escrow),
                workflowId,
                quote.predecessorRound + 1,
                quote.predecessorResolver,
                quote.appealedDecision,
                metadata.decidedAtRound[quote.predecessorRound],
                quote.appealDeadline
            )
        );
        _assertMutated(
            root,
            _appealedDecisionRoot(
                block.chainid,
                address(resolutionModule),
                address(escrow),
                workflowId,
                quote.predecessorRound,
                address(this),
                quote.appealedDecision,
                metadata.decidedAtRound[quote.predecessorRound],
                quote.appealDeadline
            )
        );
        _assertMutated(
            root,
            _appealedDecisionRoot(
                block.chainid,
                address(resolutionModule),
                address(escrow),
                workflowId,
                quote.predecessorRound,
                quote.predecessorResolver,
                ResolutionOutcome.CANCEL,
                metadata.decidedAtRound[quote.predecessorRound],
                quote.appealDeadline
            )
        );
        _assertMutated(
            root,
            _appealedDecisionRoot(
                block.chainid,
                address(resolutionModule),
                address(escrow),
                workflowId,
                quote.predecessorRound,
                quote.predecessorResolver,
                quote.appealedDecision,
                metadata.decidedAtRound[quote.predecessorRound] + 1,
                quote.appealDeadline
            )
        );
        _assertMutated(
            root,
            _appealedDecisionRoot(
                block.chainid,
                address(resolutionModule),
                address(escrow),
                workflowId,
                quote.predecessorRound,
                quote.predecessorResolver,
                quote.appealedDecision,
                metadata.decidedAtRound[quote.predecessorRound],
                quote.appealDeadline + 1
            )
        );
    }

    function test_resolutionQuoteRoot_isCanonicalStableAndBindsEveryField() public {
        (uint256 workflowId,) = _prepareAppeal();
        IResolutionModule.ResolutionAppealQuote memory q =
            resolutionModule.quoteAppealTransition(workflowId, address(escrow), _escrowData(workflowId));
        bytes32 root = _resolutionQuoteRoot(
            block.chainid,
            address(resolutionModule),
            address(escrow),
            workflowId,
            q.appealedDecisionRoot,
            q.appealable,
            q.predecessorRound,
            q.successorRound,
            q.predecessorResolver,
            q.successorResolver,
            q.appealDeadline,
            q.finalRound,
            q.baseBondAsset,
            q.baseBondAmount
        );
        assertEq(root, q.resolutionQuoteRoot);
        assertEq(
            root,
            _resolutionQuoteRoot(
                block.chainid,
                address(resolutionModule),
                address(escrow),
                workflowId,
                q.appealedDecisionRoot,
                q.appealable,
                q.predecessorRound,
                q.successorRound,
                q.predecessorResolver,
                q.successorResolver,
                q.appealDeadline,
                q.finalRound,
                q.baseBondAsset,
                q.baseBondAmount
            )
        );
        _assertMutated(
            root,
            keccak256(
                abi.encode(
                    "RESOLUTION_APPEAL_QUOTE_V2",
                    block.chainid,
                    address(resolutionModule),
                    address(escrow),
                    workflowId,
                    q.appealedDecisionRoot,
                    q.appealable,
                    q.predecessorRound,
                    q.successorRound,
                    q.predecessorResolver,
                    q.successorResolver,
                    q.appealDeadline,
                    q.finalRound,
                    q.baseBondAsset,
                    q.baseBondAmount
                )
            )
        );
        _assertMutated(
            root,
            _resolutionQuoteRoot(
                block.chainid + 1,
                address(resolutionModule),
                address(escrow),
                workflowId,
                q.appealedDecisionRoot,
                q.appealable,
                q.predecessorRound,
                q.successorRound,
                q.predecessorResolver,
                q.successorResolver,
                q.appealDeadline,
                q.finalRound,
                q.baseBondAsset,
                q.baseBondAmount
            )
        );
        _assertMutated(
            root,
            _resolutionQuoteRoot(
                block.chainid,
                address(this),
                address(escrow),
                workflowId,
                q.appealedDecisionRoot,
                q.appealable,
                q.predecessorRound,
                q.successorRound,
                q.predecessorResolver,
                q.successorResolver,
                q.appealDeadline,
                q.finalRound,
                q.baseBondAsset,
                q.baseBondAmount
            )
        );
        _assertMutated(
            root,
            _resolutionQuoteRoot(
                block.chainid,
                address(resolutionModule),
                address(this),
                workflowId,
                q.appealedDecisionRoot,
                q.appealable,
                q.predecessorRound,
                q.successorRound,
                q.predecessorResolver,
                q.successorResolver,
                q.appealDeadline,
                q.finalRound,
                q.baseBondAsset,
                q.baseBondAmount
            )
        );
        _assertMutated(
            root,
            _resolutionQuoteRoot(
                block.chainid,
                address(resolutionModule),
                address(escrow),
                workflowId + 1,
                q.appealedDecisionRoot,
                q.appealable,
                q.predecessorRound,
                q.successorRound,
                q.predecessorResolver,
                q.successorResolver,
                q.appealDeadline,
                q.finalRound,
                q.baseBondAsset,
                q.baseBondAmount
            )
        );
        _assertMutated(
            root,
            _resolutionQuoteRoot(
                block.chainid,
                address(resolutionModule),
                address(escrow),
                workflowId,
                bytes32(uint256(q.appealedDecisionRoot) + 1),
                q.appealable,
                q.predecessorRound,
                q.successorRound,
                q.predecessorResolver,
                q.successorResolver,
                q.appealDeadline,
                q.finalRound,
                q.baseBondAsset,
                q.baseBondAmount
            )
        );
        _assertMutated(
            root,
            _resolutionQuoteRoot(
                block.chainid,
                address(resolutionModule),
                address(escrow),
                workflowId,
                q.appealedDecisionRoot,
                !q.appealable,
                q.predecessorRound,
                q.successorRound,
                q.predecessorResolver,
                q.successorResolver,
                q.appealDeadline,
                q.finalRound,
                q.baseBondAsset,
                q.baseBondAmount
            )
        );
        _assertMutated(
            root,
            _resolutionQuoteRoot(
                block.chainid,
                address(resolutionModule),
                address(escrow),
                workflowId,
                q.appealedDecisionRoot,
                q.appealable,
                q.predecessorRound + 1,
                q.successorRound,
                q.predecessorResolver,
                q.successorResolver,
                q.appealDeadline,
                q.finalRound,
                q.baseBondAsset,
                q.baseBondAmount
            )
        );
        _assertMutated(
            root,
            _resolutionQuoteRoot(
                block.chainid,
                address(resolutionModule),
                address(escrow),
                workflowId,
                q.appealedDecisionRoot,
                q.appealable,
                q.predecessorRound,
                q.successorRound + 1,
                q.predecessorResolver,
                q.successorResolver,
                q.appealDeadline,
                q.finalRound,
                q.baseBondAsset,
                q.baseBondAmount
            )
        );
        _assertMutated(
            root,
            _resolutionQuoteRoot(
                block.chainid,
                address(resolutionModule),
                address(escrow),
                workflowId,
                q.appealedDecisionRoot,
                q.appealable,
                q.predecessorRound,
                q.successorRound,
                address(this),
                q.successorResolver,
                q.appealDeadline,
                q.finalRound,
                q.baseBondAsset,
                q.baseBondAmount
            )
        );
        _assertMutated(
            root,
            _resolutionQuoteRoot(
                block.chainid,
                address(resolutionModule),
                address(escrow),
                workflowId,
                q.appealedDecisionRoot,
                q.appealable,
                q.predecessorRound,
                q.successorRound,
                q.predecessorResolver,
                address(this),
                q.appealDeadline,
                q.finalRound,
                q.baseBondAsset,
                q.baseBondAmount
            )
        );
        _assertMutated(
            root,
            _resolutionQuoteRoot(
                block.chainid,
                address(resolutionModule),
                address(escrow),
                workflowId,
                q.appealedDecisionRoot,
                q.appealable,
                q.predecessorRound,
                q.successorRound,
                q.predecessorResolver,
                q.successorResolver,
                q.appealDeadline + 1,
                q.finalRound,
                q.baseBondAsset,
                q.baseBondAmount
            )
        );
        _assertMutated(
            root,
            _resolutionQuoteRoot(
                block.chainid,
                address(resolutionModule),
                address(escrow),
                workflowId,
                q.appealedDecisionRoot,
                q.appealable,
                q.predecessorRound,
                q.successorRound,
                q.predecessorResolver,
                q.successorResolver,
                q.appealDeadline,
                !q.finalRound,
                q.baseBondAsset,
                q.baseBondAmount
            )
        );
        _assertMutated(
            root,
            _resolutionQuoteRoot(
                block.chainid,
                address(resolutionModule),
                address(escrow),
                workflowId,
                q.appealedDecisionRoot,
                q.appealable,
                q.predecessorRound,
                q.successorRound,
                q.predecessorResolver,
                q.successorResolver,
                q.appealDeadline,
                q.finalRound,
                address(this),
                q.baseBondAmount
            )
        );
        _assertMutated(
            root,
            _resolutionQuoteRoot(
                block.chainid,
                address(resolutionModule),
                address(escrow),
                workflowId,
                q.appealedDecisionRoot,
                q.appealable,
                q.predecessorRound,
                q.successorRound,
                q.predecessorResolver,
                q.successorResolver,
                q.appealDeadline,
                q.finalRound,
                q.baseBondAsset,
                q.baseBondAmount + 1
            )
        );
    }

    function test_policyAndTransitionRoots_bindEveryField() public {
        (uint256 workflowId,) = _prepareAppeal();
        vm.recordLogs();
        vm.prank(buyer);
        escrow.escalateDispute(workflowId);
        Transition memory t = _transitionFromLogs(vm.getRecordedLogs());
        bytes32 policy = _policyRoot(0, feeAddress, 0);
        assertEq(policy, _policyRoot(0, feeAddress, 0));
        _assertMutated(policy, keccak256(abi.encode("ESCROW_APPEAL_POLICY_V2", uint256(0), feeAddress, uint32(0))));
        _assertMutated(policy, _policyRoot(1, feeAddress, 0));
        _assertMutated(policy, _policyRoot(0, address(this), 0));
        _assertMutated(policy, _policyRoot(0, feeAddress, 1));
        bytes32 root = _transitionRoot(
            t.requestRoot, t.quoteRoot, 0, 1, resolver1, seniorResolver, address(token), t.gross, t.fee, t.net, policy
        );
        assertEq(root, t.transitionRoot);
        assertEq(
            root,
            _transitionRoot(
                t.requestRoot,
                t.quoteRoot,
                0,
                1,
                resolver1,
                seniorResolver,
                address(token),
                t.gross,
                t.fee,
                t.net,
                policy
            )
        );
        _assertMutated(
            root,
            keccak256(
                abi.encode(
                    "APPEAL_TRANSITION_V2",
                    t.requestRoot,
                    t.quoteRoot,
                    uint8(0),
                    uint8(1),
                    resolver1,
                    seniorResolver,
                    address(token),
                    t.gross,
                    t.fee,
                    t.net,
                    policy
                )
            )
        );
        _assertMutated(
            root,
            _transitionRoot(
                bytes32(uint256(t.requestRoot) + 1),
                t.quoteRoot,
                0,
                1,
                resolver1,
                seniorResolver,
                address(token),
                t.gross,
                t.fee,
                t.net,
                policy
            )
        );
        _assertMutated(
            root,
            _transitionRoot(
                t.requestRoot,
                bytes32(uint256(t.quoteRoot) + 1),
                0,
                1,
                resolver1,
                seniorResolver,
                address(token),
                t.gross,
                t.fee,
                t.net,
                policy
            )
        );
        _assertMutated(
            root,
            _transitionRoot(
                t.requestRoot,
                t.quoteRoot,
                1,
                1,
                resolver1,
                seniorResolver,
                address(token),
                t.gross,
                t.fee,
                t.net,
                policy
            )
        );
        _assertMutated(
            root,
            _transitionRoot(
                t.requestRoot,
                t.quoteRoot,
                0,
                2,
                resolver1,
                seniorResolver,
                address(token),
                t.gross,
                t.fee,
                t.net,
                policy
            )
        );
        _assertMutated(
            root,
            _transitionRoot(
                t.requestRoot,
                t.quoteRoot,
                0,
                1,
                address(this),
                seniorResolver,
                address(token),
                t.gross,
                t.fee,
                t.net,
                policy
            )
        );
        _assertMutated(
            root,
            _transitionRoot(
                t.requestRoot,
                t.quoteRoot,
                0,
                1,
                resolver1,
                address(this),
                address(token),
                t.gross,
                t.fee,
                t.net,
                policy
            )
        );
        _assertMutated(
            root,
            _transitionRoot(
                t.requestRoot,
                t.quoteRoot,
                0,
                1,
                resolver1,
                seniorResolver,
                address(this),
                t.gross,
                t.fee,
                t.net,
                policy
            )
        );
        _assertMutated(
            root,
            _transitionRoot(
                t.requestRoot,
                t.quoteRoot,
                0,
                1,
                resolver1,
                seniorResolver,
                address(token),
                t.gross + 1,
                t.fee,
                t.net,
                policy
            )
        );
        _assertMutated(
            root,
            _transitionRoot(
                t.requestRoot,
                t.quoteRoot,
                0,
                1,
                resolver1,
                seniorResolver,
                address(token),
                t.gross,
                t.fee + 1,
                t.net,
                policy
            )
        );
        _assertMutated(
            root,
            _transitionRoot(
                t.requestRoot,
                t.quoteRoot,
                0,
                1,
                resolver1,
                seniorResolver,
                address(token),
                t.gross,
                t.fee,
                t.net + 1,
                policy
            )
        );
        _assertMutated(
            root,
            _transitionRoot(
                t.requestRoot,
                t.quoteRoot,
                0,
                1,
                resolver1,
                seniorResolver,
                address(token),
                t.gross,
                t.fee,
                t.net,
                bytes32(uint256(policy) + 1)
            )
        );
    }

    function test_feeRecipient_isSnapshottedPerWorkflow() public {
        address newRecipient = makeAddr("new fee recipient");
        escrow.setAppealBondProtocolFeeBps(1_000);
        (uint256 firstWorkflow,) = _prepareAppeal();
        escrow.setFeeRecipient(newRecipient);

        vm.recordLogs();
        vm.prank(buyer);
        escrow.escalateDispute(firstWorkflow);
        Transition memory first = _transitionFromLogs(vm.getRecordedLogs());
        assertEq(first.feeRecipient, feeAddress);
        assertGt(escrow.claimableBondProtocolFees(address(token), feeAddress), 0);
        assertEq(escrow.claimableBondProtocolFees(address(token), newRecipient), 0);

        (uint256 secondWorkflow,) = _prepareAppeal();
        uint256 baseGross =
            resolutionModule.quoteAppealTransition(secondWorkflow, address(escrow), _escrowData(secondWorkflow))
        .baseBondAmount;
        vm.prank(buyer);
        token.approve(address(escrow), baseGross * 110 / 100);
        vm.recordLogs();
        vm.prank(buyer);
        escrow.escalateDispute(secondWorkflow);
        Transition memory second = _transitionFromLogs(vm.getRecordedLogs());
        assertEq(second.feeRecipient, newRecipient);
        assertEq(second.gross, baseGross * 110 / 100);
        assertEq(second.fee, second.gross * 1_000 / 10_000);
        assertEq(second.net, second.gross - second.fee);
        assertGt(escrow.claimableBondProtocolFees(address(token), newRecipient), 0);
    }

    function test_customResolver_isRejectedBeforeQuoteOrCustody() public {
        vm.startPrank(buyer);
        token.approve(address(escrow), ESCROW_AMOUNT);
        uint256 workflowId = escrow.createEscrow(
            address(token),
            seller,
            ESCROW_AMOUNT,
            EscrowSettings({
                customResolver: address(this),
                releaseAddress: address(0),
                yieldPreset: YieldPreset.OFF,
                autoReleaseTime: 0,
                autoCancelTime: 0
            })
        );
        vm.stopPrank();
        raiseDispute(workflowId);

        vm.expectRevert(abi.encodeWithSelector(AppealsUnsupportedForCustomResolver.selector, workflowId, address(this)));
        vm.prank(buyer);
        escrow.escalateDispute(workflowId);

        assertEq(escrow.addressEscalationCount(buyer), 0);
        assertEq(escrow.claimableBondProtocolFees(address(token), feeAddress), 0);
        assertEq(token.balanceOf(address(bondCollector)), 0);
    }
}
