// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.37;

import 'forge-std/Test.sol';
import '../../mocks/legacy/DisputeOpsReference.sol';
import '../../../contracts/libraries/EscrowDisputeLogic.sol';
import '../../../contracts/shared/interfaces/IResolutionModule.sol';
import '../../../contracts/types/EscrowTypes.sol';

/// @notice Configurable resolution module for exercising quote branches.
contract DisputeQuoteModule {
    address internal resolver;
    uint8 internal level;
    bool internal revertResolver;
    bool internal revertQuote;
    IResolutionModule.ResolutionAppealQuote internal quote;

    function setResolverResult(address r, uint8 l) external {
        resolver = r;
        level = l;
    }

    function setRevertFlags(bool r, bool q) external {
        revertResolver = r;
        revertQuote = q;
    }

    function setQuote(IResolutionModule.ResolutionAppealQuote calldata q) external {
        quote = q;
    }

    function getDisputeResolver(uint256, address, bytes calldata) external view returns (address, uint8) {
        require(!revertResolver, 'resolver revert');
        return (resolver, level);
    }

    function quoteAppealTransition(uint256, address, bytes calldata)
        external
        view
        returns (IResolutionModule.ResolutionAppealQuote memory)
    {
        require(!revertQuote, 'quote revert');
        return quote;
    }
}

/// @notice Differential coverage: EscrowDisputeLogic must match the legacy
///         externally deployed DisputeOpsReference for all derived values and revert
///         behavior, not just happy paths.
contract DisputeLogicEquivalenceTest is Test {
    DisputeOpsReference internal ops;

    function setUp() public {
        ops = new DisputeOpsReference(address(this));
        ops.registerEscrowContract(address(this));
    }

    function _assertOpeningEq(
        DisputeOpsReference.DisputeOpeningResult memory a,
        EscrowDisputeLogic.DisputeOpeningResult memory b
    ) internal pure {
        assertEq(a.success, b.success, 'opening.success');
        assertEq(a.updatedResolver, b.updatedResolver, 'opening.updatedResolver');
        assertEq(a.callIncentiveHook, b.callIncentiveHook, 'opening.callIncentiveHook');
        assertEq(a.incentiveModule, b.incentiveModule, 'opening.incentiveModule');
        assertEq(keccak256(bytes(a.failureReason)), keccak256(bytes(b.failureReason)), 'opening.failureReason');
    }

    function _assertEscalationEq(
        DisputeOpsReference.EscalationResult memory a,
        EscrowDisputeLogic.EscalationResult memory b
    ) internal pure {
        assertEq(a.success, b.success, 'esc.success');
        assertEq(a.newResolver, b.newResolver, 'esc.newResolver');
        assertEq(a.newLevel, b.newLevel, 'esc.newLevel');
        assertEq(a.currentLevel, b.currentLevel, 'esc.currentLevel');
        assertEq(a.bondAmount, b.bondAmount, 'esc.bondAmount');
        assertEq(a.bondToken, b.bondToken, 'esc.bondToken');
        assertEq(a.incentiveModule, b.incentiveModule, 'esc.incentiveModule');
        assertEq(a.bondToRecord, b.bondToRecord, 'esc.bondToRecord');
        assertEq(a.protocolFeeAmount, b.protocolFeeAmount, 'esc.protocolFeeAmount');
        assertEq(a.predecessorResolver, b.predecessorResolver, 'esc.predecessorResolver');
        assertEq(a.appealDeadline, b.appealDeadline, 'esc.appealDeadline');
        assertEq(a.appealedDecisionRoot, b.appealedDecisionRoot, 'esc.appealedDecisionRoot');
        assertEq(a.resolutionQuoteRoot, b.resolutionQuoteRoot, 'esc.resolutionQuoteRoot');
        assertEq(keccak256(bytes(a.failureReason)), keccak256(bytes(b.failureReason)), 'esc.failureReason');
    }

    // ---------------- Dispute opening ----------------

    function testFuzz_equiv_opening(
        uint8 stateRaw,
        uint8 callerPick,
        address module,
        address currentResolver,
        address incentiveModule
    ) public {
        EscrowState state = EscrowState(stateRaw % 6);
        address from = address(0xA11CE);
        address to = address(0xB0B);
        address caller = callerPick % 3 == 0 ? from : (callerPick % 3 == 1 ? to : address(0xCAFE));

        DisputeOpsReference.DisputeOpeningResult memory a = ops.computeDisputeOpening(
            module, address(this), incentiveModule, 1, caller, from, to, address(0x7011), 100, state, currentResolver
        );
        EscrowDisputeLogic.DisputeOpeningResult memory b = EscrowDisputeLogic.computeDisputeOpening(
            module, address(this), incentiveModule, 1, caller, from, to, address(0x7011), 100, state, currentResolver
        );
        _assertOpeningEq(a, b);
    }

    function testFuzz_equiv_opening_moduleResolver(
        address fuzzResolver,
        uint8 level,
        uint8 stateRaw,
        address currentResolver
    ) public {
        DisputeQuoteModule m = new DisputeQuoteModule();
        m.setResolverResult(fuzzResolver, level);
        EscrowState state = EscrowState(stateRaw % 6);
        address from = address(0xA11CE);
        address to = address(0xB0B);

        DisputeOpsReference.DisputeOpeningResult memory a = ops.computeDisputeOpening(
            address(m), address(this), address(0x1), 1, from, from, to, address(0x7011), 100, state, currentResolver
        );
        EscrowDisputeLogic.DisputeOpeningResult memory b = EscrowDisputeLogic.computeDisputeOpening(
            address(m), address(this), address(0x1), 1, from, from, to, address(0x7011), 100, state, currentResolver
        );
        _assertOpeningEq(a, b);
    }

    function testFuzz_equiv_opening_moduleResolverReverts(uint8 stateRaw) public {
        DisputeQuoteModule m = new DisputeQuoteModule();
        m.setRevertFlags(true, false);
        EscrowState state = EscrowState(stateRaw % 6);
        address from = address(0xA11CE);
        address to = address(0xB0B);

        DisputeOpsReference.DisputeOpeningResult memory a = ops.computeDisputeOpening(
            address(m), address(this), address(0x1), 1, from, from, to, address(0x7011), 100, state, address(0x9)
        );
        EscrowDisputeLogic.DisputeOpeningResult memory b = EscrowDisputeLogic.computeDisputeOpening(
            address(m), address(this), address(0x1), 1, from, from, to, address(0x7011), 100, state, address(0x9)
        );
        _assertOpeningEq(a, b);
    }

    // ---------------- Escalation ----------------

    function _callOpsEsc(
        address module,
        address caller,
        address from,
        address to,
        EscrowState state,
        address incentiveModule
    ) external returns (DisputeOpsReference.EscalationResult memory) {
        return ops.computeEscalation(
            module, address(this), incentiveModule, 500, address(0xFEE), 1, caller, from, to, address(0x7011), 100, state
        );
    }

    function _callLibEsc(
        address module,
        address caller,
        address from,
        address to,
        EscrowState state,
        address incentiveModule
    ) external returns (EscrowDisputeLogic.EscalationResult memory) {
        return EscrowDisputeLogic.computeEscalation(
            module, address(this), incentiveModule, 500, address(0xFEE), 1, caller, from, to, address(0x7011), 100, state
        );
    }

    /// @dev Calls both implementations, comparing revert-vs-success and, when
    ///      both succeed, every derived field.
    function _cmpEsc(
        address module,
        address caller,
        address from,
        address to,
        EscrowState state,
        address incentiveModule
    ) internal {
        bool opsReverted;
        bool libReverted;
        DisputeOpsReference.EscalationResult memory a;
        EscrowDisputeLogic.EscalationResult memory b;

        try this._callOpsEsc(module, caller, from, to, state, incentiveModule) returns (
            DisputeOpsReference.EscalationResult memory r
        ) {
            a = r;
        } catch {
            opsReverted = true;
        }

        try this._callLibEsc(module, caller, from, to, state, incentiveModule) returns (
            EscrowDisputeLogic.EscalationResult memory r
        ) {
            b = r;
        } catch {
            libReverted = true;
        }

        assertEq(opsReverted, libReverted, 'revert mismatch');
        if (!opsReverted) _assertEscalationEq(a, b);
    }

    function testFuzz_equiv_escalation_invalidCallerState(uint8 stateRaw, uint8 callerPick, address module) public {
        EscrowState state = EscrowState(stateRaw % 6);
        address from = address(0xA11CE);
        address to = address(0xB0B);
        address caller = callerPick % 3 == 0 ? from : (callerPick % 3 == 1 ? to : address(0xCAFE));
        _cmpEsc(module, caller, from, to, state, address(0x1));
    }

    function testFuzz_equiv_escalation_noModule(uint8 stateRaw) public {
        EscrowState state = EscrowState(stateRaw % 6);
        _cmpEsc(address(0), address(0xA11CE), address(0xA11CE), address(0xB0B), state, address(0x1));
    }

    function test_equiv_escalation_quoteReverts() public {
        DisputeQuoteModule m = new DisputeQuoteModule();
        m.setRevertFlags(false, true);
        _cmpEsc(address(m), address(0xA11CE), address(0xA11CE), address(0xB0B), EscrowState.DISPUTED, address(0x1));
    }

    function _quote(
        bool appealable,
        uint8 predRound,
        uint8 succRound,
        address predResolver,
        address succResolver,
        ResolutionOutcome decision,
        uint256 deadline,
        address bondAsset,
        uint256 bondAmount,
        bytes32 appealedRoot,
        bytes32 quoteRoot
    ) internal pure returns (IResolutionModule.ResolutionAppealQuote memory q) {
        q = IResolutionModule.ResolutionAppealQuote({
            appealable: appealable,
            predecessorRound: predRound,
            successorRound: succRound,
            predecessorResolver: predResolver,
            successorResolver: succResolver,
            appealedDecision: decision,
            appealDeadline: deadline,
            finalRound: false,
            baseBondAsset: bondAsset,
            baseBondAmount: bondAmount,
            appealedDecisionRoot: appealedRoot,
            resolutionQuoteRoot: quoteRoot
        });
    }

    function testFuzz_equiv_escalation_quote(
        bool appealable,
        uint8 predRound,
        uint8 succRound,
        address predResolver,
        address succResolver,
        uint8 decisionRaw,
        uint256 deadline,
        address bondAsset,
        uint256 bondAmount,
        bytes32 appealedRoot,
        bytes32 quoteRoot,
        bool callerIsFrom
    ) public {
        DisputeQuoteModule m = new DisputeQuoteModule();
        ResolutionOutcome decision = ResolutionOutcome(decisionRaw % 3);
        m.setQuote(
            _quote(
                appealable, predRound, succRound, predResolver, succResolver, decision,
                deadline, bondAsset, bondAmount, appealedRoot, quoteRoot
            )
        );
        address from = address(0xA11CE);
        address to = address(0xB0B);
        address caller = callerIsFrom ? from : to;
        _cmpEsc(address(m), caller, from, to, EscrowState.DISPUTED, address(0x1));
    }

    function testFuzz_equiv_escalation_bondWithoutIncentive(
        bool appealable,
        uint8 decisionRaw,
        address succResolver,
        uint256 bondAmount
    ) public {
        DisputeQuoteModule m = new DisputeQuoteModule();
        ResolutionOutcome decision = ResolutionOutcome(decisionRaw % 3);
        m.setQuote(
            _quote(
                appealable, 0, 1, address(0x9999), succResolver, decision,
                block.timestamp + 1 days, address(0xB0BD), bondAmount, bytes32(uint256(1)), bytes32(uint256(2))
            )
        );
        _cmpEsc(address(m), address(0xA11CE), address(0xA11CE), address(0xB0B), EscrowState.DISPUTED, address(0));
    }
}
