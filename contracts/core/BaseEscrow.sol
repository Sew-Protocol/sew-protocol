// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.37;

/**
 * @title BaseEscrow
 * @notice Authoritative escrow orchestration and state-machine root shared by the
 *         token- and vault-backed escrow products.
 *
 * @dev ARCHITECTURAL INTENT — deliberate, not an incomplete refactor:
 *
 *      BaseEscrow is the single authoritative owner of escrow workflow state and
 *      coordinates the domain components that derive or execute its lifecycle
 *      transitions. Cohesive, low-coupling concerns live in inherited,
 *      storage-free support components. Everything that defines what an escrow
 *      *is* — the authoritative state transitions — stays in this contract so it
 *      is locally auditable.
 *
 *      Inherited support components (declare no storage of their own):
 *        - EscrowConfiguration : governance-controlled policy and ops wiring
 *        - EscrowCreation      : creation entrypoint, settings, module snapshots
 *        - EscrowYield         : yield module deposit/unwind
 *        - EscrowAccounting    : claimable entitlements and pull withdrawals
 *        - EscrowSettlement    : pending-settlement execution and mutual splits
 *
 *      Retained directly in BaseEscrow, on purpose:
 *        - Lifecycle orchestration (release, cancel, timed actions)
 *        - Dispute orchestration (opening, resolver authorization, timeout)
 *        - Appeal / Kleros authority transitions
 *        - Shared transition helpers and canonical escrow data
 *        - Framework views and product adapter hooks
 *
 *      Rationale: an auditor should be able to read this file and see every
 *      authoritative state transition — especially the atomic appeal -> Kleros
 *      handoff -> resolver mutation sequence — in one place. Splitting the
 *      orchestration across superclasses would trade auditability for a smaller
 *      file. Apply this rule before extracting anything further: extract a
 *      concern only if it reduces the number of concepts a reader must hold
 *      simultaneously WITHOUT adding indirection required to understand an
 *      authoritative state transition.
 *
 *      The section banners below indicate the intended reading order.
 */

import '@openzeppelin/contracts/utils/Context.sol';
import '@openzeppelin/contracts/utils/Pausable.sol';
import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import '@openzeppelin/contracts/utils/Address.sol';
import '../interfaces/IResolver.sol';
import '../interfaces/ICancellationStrategy.sol';
import '../interfaces/IReleaseStrategy.sol';
import '../interfaces/IEscrowLifecycle.sol';
import '../interfaces/IEscrowDispute.sol';
import '../interfaces/IEscrowAppeal.sol';
import '../interfaces/IEscrowSettlement.sol';
import '../interfaces/IEscrowViews.sol';
import '../shared/interfaces/IResolutionModule.sol';
import '../interfaces/IYieldModule.sol';
import '../libraries/EscrowEncodingLibrary.sol';
import '../arbitration/IKlerosArbitrableProxy.sol';
import '../modules/decentralized-resolution-module/IKlerosHandoffResolutionModule.sol';
import '../libraries/ResolverLogicLibrary.sol';
import '../libraries/StateManagementLibrary.sol';
import '../libraries/DisputeInitializationLibrary.sol';
import '../libraries/DisputeRaiseLibrary.sol';
import '../libraries/DisputeEscalationLibrary.sol';
import '../types/EscrowTypes.sol';
import '../types/YieldPresets.sol';
import '../libraries/YieldPresetLibrary.sol';
import '../ops/YieldOps.sol';
import '../ops/CreateOps.sol';
import '../shared/interfaces/IIncentiveModule.sol';
import './BondCollector.sol';
import '../libraries/ModuleSnapshotLibrary.sol';
import '../libraries/BondHandlingLibrary.sol';
import '../libraries/EscrowSettlementLogic.sol';
import '../libraries/EscrowDisputeLogic.sol';
import './EscrowStorage.sol';
import './EscrowConfiguration.sol';
import './EscrowCreation.sol';
import './EscrowYield.sol';
import './EscrowAccounting.sol';
import './EscrowSettlement.sol';
import './EscrowDisputes.sol';
import './EscrowAppeals.sol';
import './EscrowLifecycle.sol';

enum FailureReason {
    UNKNOWN, CALL_FAILED, MALFORMED_RETURN_DATA, MODULE_NOT_SET, MODULE_NOT_CONTRACT,
    CONTRACT_INSUFFICIENT_BALANCE, TRANSFER_FAILED, PUSH_FAILED_FALLBACK_TO_PULL,
    DEPOSIT_FAILED, WITHDRAWAL_FAILED, LESS_THAN_PRINCIPAL, TIMEOUT
}

// EscrowTransferAutoResult reasonCode meanings:
// - If success == true: reasonCode is an action code (NOT a FailureReason).
//   - 0 = push transfer succeeded
//   - 1 = auto-release executed
//   - 2 = auto-cancel executed
//   - 3 = pending settlement executed
// - If success == false: reasonCode is a FailureReason value.

bytes4 constant SEL_FINALIZE_DISPUTE = IResolutionModule.finalizeDispute.selector;
bytes4 constant SEL_RECORD_RESOLUTION = IResolutionModule.recordResolution.selector;
bytes4 constant SEL_CLOSE_BY_MUTUAL_AGREEMENT = bytes4(keccak256("closeByMutualAgreement(uint256)"));
bytes4 constant SEL_DECREMENT_RESOLVER = bytes4(keccak256("decrementResolverActiveDisputes(address)"));

error InvalidWorkflowId(uint256 workflowId, uint256 maxWorkflowId);
error TransferNotPending(uint256 workflowId, EscrowState currentStatus);
error ReleaseStrategyNotSet(uint256 workflowId);
error ReleaseNotAllowed(uint256 workflowId, uint8 reasonCode);
error YieldWithdrawalUnreasonable(uint256 actualAmount, uint256 maxAmount);
error NotAuthorizedResolver(address caller, address expectedResolver);
error TransferNotInDispute(uint256 workflowId, EscrowState currentStatus);
error NotSender(uint256 workflowId, address caller, address expectedSender);
error NotAuthorizedToCancelYet(uint256 workflowId, address caller);
error NotRecipient(uint256 workflowId, address caller, address expectedRecipient);
error InvalidEscrowFee(uint256 fee, uint256 maxFee);
error FeeExceedsMaximum(uint256 feeBps, uint256 maxFeeBps);


error InvalidState(uint256 workflowId, uint8 expected, uint8 actual);
error InvalidConfig(uint8 code, uint256 value);
// InvalidAddress already defined in EscrowTypes.sol
error TransferFailed(uint8 kind, address token, address to, uint256 amount);
error ResolutionModuleError(uint8 code);
error PendingDecisionAlreadyExists(uint256 workflowId);
error EscalationNotAllowed();
error AppealBondQueryFailed(uint256 workflowId);
error InvalidBondMsgValue(uint256 workflowId, uint256 required, uint256 provided);
error UnauthorizedTimedExecutor(address caller);
error AppealsNotEnabledInV1();
error DisputeAmountBelowMinimum(uint256 workflowId, uint256 amount, uint256 minimum);
error DisputeRateLimitExceeded(address sender, uint32 count, uint32 maxCount);
error EscalationCooldownActive(address sender, uint256 availableAt);
error AlreadyPausedCannotRepause();
error MaxPauseCyclesExceeded(uint256 currentCount, uint256 maxCycles);
error PauseDurationExceeded(uint256 duration, uint256 maxDuration);
error PausedNotSupported();
    error EscalationResultMismatch(uint8 expectedLevel, uint8 actualLevel, address expectedResolver, address actualResolver);
    error AppealsUnsupportedForCustomResolver(uint256 workflowId, address customResolver);

// Errors used by child contracts (EscrowVault, EscrowableERC20)
error BalanceUnderflow(address token, uint256 currentBalance, uint256 requestedAmount);
error NotFeeAddress(address caller, address expectedFeeAddress);
error NoFeesToWithdraw(address token, uint256 availableFees);
error InsufficientContractBalance(address token, uint256 required, uint256 available);
error AmountExceedsAvailable(address token, uint256 requestedAmount, uint256 availableAmount);
error ZeroAddress(uint8 which);
error AccountingDeficit(address token, uint256 deficit);
error ResolutionConfigUnavailable(address resolutionModule, uint256 version);
error ResolutionConfigWithCustomResolver(address customResolver);

/// @notice Resolution mode for dispute handling
enum ResolutionMode {
    CUSTOM_RESOLVER,     // Uses custom resolver set in EscrowSettings
    RESOLUTION_MODULE,   // Uses default resolution module
    DIRECT               // No resolver configured (fallback)
}


abstract contract BaseEscrow is EscrowLifecycle {
    using SafeERC20 for IERC20;

    // Kept here as a source/API compatibility type; it has no storage impact.
    enum ModuleType { RESOLUTION, RELEASE, CANCELLATION, YIELD_GEN, YIELD_DIST }


    event EscrowResolved(
        uint256 indexed workflowId,
        address indexed disputeResolver,
        bytes32 resolutionHash
    );
    event DisputeEscalated(
        uint256 indexed workflowId,
        uint8 fromLevel,
        uint8 toLevel,
        address indexed newDisputeResolver,
        address indexed escalatedBy
    );
    event AppealRequested(
        uint256 indexed workflowId,
        bytes32 indexed requestRoot,
        address indexed operator,
        address funder,
        address refundRecipient
    );
    event AppealTransitionDerived(
        uint256 indexed workflowId,
        bytes32 indexed requestRoot,
        bytes32 indexed transitionRoot,
        bytes32 resolutionQuoteRoot,
        bytes32 appealedDecisionRoot,
        uint256 grossBond,
        uint256 protocolFee,
        uint256 netBond,
        address feeRecipient
    );
    event DisputeAutoCancelled(
        uint256 indexed workflowId,
        address indexed from,
        uint256 amount,
        uint8 reasonCode
    );
    event DisputeOpened(
        uint256 indexed workflowId,
        address indexed by,
        address indexed disputeResolver
    );

    /// @notice Emitted when a time-based action is triggered (auto-release/cancel/settle)
    /// @param workflowId The escrow ID
    /// @param actionType 1=Release, 2=Cancel, 3=Settlement
    /// @param source Authority source (USER, KEEPER, GOVERNANCE)
    /// @param executor Address that triggered the transaction
    event TimedActionTriggered(
        uint256 indexed workflowId,
        uint8 actionType,
        ExecutionSource source,
        address indexed executor
    );

    // Consolidated auto-transfer event (replaces AutoCompleted + AutoFailed to save bytecode)
    event EscrowTransferAutoResult(
        uint256 indexed workflowId,
        address indexed recipient,
        address indexed token,
        uint256 amount,
        bool success,
        uint8 reasonCode
    );
    // Consolidated: ProtocolFeeCollected now handles both yield and bond fees
    event ProtocolFeeCollected(
        uint8 indexed kind, // 0 = yield, 1 = appeal bond
        uint256 indexed workflowId,
        address indexed token,
        uint256 grossAmount,
        uint256 feeBps,
        uint256 feeAmount
    );
    event BondProtocolFeeClaimableCredited(
        address indexed token,
        address indexed feeRecipient,
        uint256 amount,
        uint256 indexed workflowId
    );
    event ExcessEthRefundCredited(uint256 indexed workflowId, address indexed account, uint256 amount);

    // op codes (append-only):
    // 1 = yield deposit
    // 2 = yield withdraw/distribute
    // 3 = incentive module hook
    // 4 = reserved (legacy auto-transfer push path removed)
    event OperationFailure(
        uint8 indexed op,
        uint256 indexed workflowId,
        address indexed target,
        bytes4 selector,
        uint8 reasonCode
    );

    // Monitoring & Safety Events (v1)
    event IncidentPauseTriggered(
        string reason,
        uint256 timestamp,
        uint256 pauseCycleCount
    );
    event SystemResumed(
        uint256 timestamp
    );
    event EscrowPartiallyReleased(
        uint256 indexed workflowId,
        address indexed token,
        address indexed to,
        uint256 amount,
        uint256 totalReleased,
        uint256 totalAmount
    );

    // emergencyUnwindAavePosition REMOVED - now handled by GuardianOps contract

    // =====================================================================
    // PRODUCT ADAPTER HOOKS
    // Implemented by concrete escrow products (EscrowVault, EscrowableERC20).
    // =====================================================================
    function _pullTokens(address token, address from, uint256 amount) internal virtual override;
    function _recordFee(address token, uint256 amount) internal virtual override;
    function _emitEscrowTransferCreated(
        uint256 workflowId,
        address token,
        address from,
        address to,
        uint256 amount
    ) internal virtual override {}
    function _emitEscrowStateChanged(uint256 workflowId, EscrowState oldStatus, EscrowState newStatus) internal virtual override {
        emit EscrowStateChanged(workflowId, oldStatus, newStatus);
    }

    // =====================================================================
    // AUTHORITATIVE LIFECYCLE
    // Timed actions and participant-initiated cancellation.
    // =====================================================================

    function automateTimedActions(uint256 workflowId) external nonReentrant returns (bool) {
        _validateWorkflowId(workflowId);
        EscrowTransfer storage et = escrowTransfers[workflowId];
        (ExecutionSource source, address caller) = _authorizeTimedActionAndSource(et);
        ModuleSnapshot storage snap = moduleSnapshots[workflowId];
        EscrowSettlementLogic.SettlementPendingSettlement memory pendingMem = _convertPendingSettlement(pendingSettlements[workflowId]);

        // Use snapshotted timeout config
        TimeoutConfig memory snappedTimeoutConfig = TimeoutConfig({
            defaultAutoReleaseDelay: snap.defaultAutoReleaseDelay,
            defaultAutoCancelDelay: snap.defaultAutoCancelDelay,
            maxDisputeDuration: snap.maxDisputeDuration,
            appealWindowDuration: snap.appealWindowDuration
        });

        EscrowTimeoutPolicySnapshot memory timeoutPolicy = timeoutPolicySnapshots[workflowId];
        (uint8 actionType, bool isRelease) = EscrowSettlementLogic.computeTimedActions(
            workflowId,
            et,
            pendingMem,
            snappedTimeoutConfig,
            timeoutPolicy.pendingAutoCancelEnabled,
            disputeRaisedTimestamp[workflowId]
        );
        if (actionType == ACTION_NONE) return false;

        if (actionType == ACTION_EXECUTE_PENDING) {
            delete pendingSettlements[workflowId];
            _finalizeDisputeInModule(workflowId);
            if (isRelease) _releaseEscrowTransfer(workflowId);
            else _cancelAndRefund(workflowId);
            emit PendingSettlementExecuted(workflowId, isRelease);
            emit TimedActionTriggered(workflowId, ACTION_EXECUTE_PENDING, source, caller);
            return true;
        } else if (actionType == ACTION_AUTO_RELEASE) {
            _releaseEscrowTransfer(workflowId);
            emit TimedActionTriggered(workflowId, ACTION_AUTO_RELEASE, source, caller);
            return true;
        } else if (actionType == ACTION_AUTO_CANCEL) {
            _cancelAndRefund(workflowId);
            emit TimedActionTriggered(workflowId, ACTION_AUTO_CANCEL, source, caller);
            return true;
        } else if (actionType == ACTION_AUTO_CANCEL_DISPUTED) {
            _finalizeDisputeInModule(workflowId);
            _cancelAndRefund(workflowId);
            delete disputeRaisedTimestamp[workflowId];
            emit DisputeAutoCancelled(workflowId, escrowTransfers[workflowId].from,
                                      escrowTransfers[workflowId].amountAfterFee,
                                      uint8(FailureReason.TIMEOUT));
            emit TimedActionTriggered(workflowId, ACTION_AUTO_CANCEL_DISPUTED, source, caller);
            return true;
        } else if (actionType == ACTION_DISPUTE_TIMEOUT) {
            address from = et.from;
            uint256 amt = et.amountAfterFee;
            _finalizeDisputeInModule(workflowId);
            _cancelAndRefund(workflowId);
            delete disputeRaisedTimestamp[workflowId];
            emit DisputeAutoCancelled(workflowId, from, amt, uint8(FailureReason.TIMEOUT));
            emit TimedActionTriggered(workflowId, ACTION_DISPUTE_TIMEOUT, source, caller);
            return true;
        }

        return false;
    }

    function recipientCancel(uint256 workflowId) external nonReentrant returns (bool) {
        _validateWorkflowId(workflowId);
        EscrowTransfer storage et = escrowTransfers[workflowId];
        if (et.to != _msgSender()) revert NotRecipient(workflowId, _msgSender(), et.to);
        if (et.escrowState != EscrowState.PENDING)
            revert TransferNotPending(workflowId, et.escrowState);

        ModuleSnapshot storage snap = moduleSnapshots[workflowId];

        bool unilateralCancel = false;

        // Use cancellation strategy if configured
        if (snap.cancellationStrategy != address(0)) {
            ICancellationStrategy strategy = ICancellationStrategy(snap.cancellationStrategy);
            if (!strategy.canCancel(workflowId, _msgSender(), et)) {
                revert NotAuthorizedToCancelYet(workflowId, _msgSender());
            }
            unilateralCancel = strategy.canCancelUnilaterally(workflowId, _msgSender(), et);
            strategy.onCancelAttempt(workflowId, _msgSender(), true);
        }

        // If strategy allows unilateral cancellation, cancel immediately
        if (unilateralCancel) {
            _cancelAndRefund(workflowId);
            return true;
        }

        // Otherwise require mutual consent
        et.recipientStatus = RecipientStatus.AGREE_TO_CANCEL;
        if (et.senderStatus == SenderStatus.AGREE_TO_CANCEL) {
            _cancelAndRefund(workflowId);
        }
        return true;
    }

    function senderCancel(uint256 workflowId) external nonReentrant returns (bool) {
        _validateWorkflowId(workflowId);
        EscrowTransfer storage et = escrowTransfers[workflowId];
        if (et.from != _msgSender()) revert NotSender(workflowId, _msgSender(), et.from);
        if (et.escrowState != EscrowState.PENDING)
            revert TransferNotPending(workflowId, et.escrowState);

        ModuleSnapshot storage snap = moduleSnapshots[workflowId];

        bool unilateralCancel = false;

        // Use cancellation strategy if configured
        if (snap.cancellationStrategy != address(0)) {
            ICancellationStrategy strategy = ICancellationStrategy(snap.cancellationStrategy);
            if (!strategy.canCancel(workflowId, _msgSender(), et)) {
                revert NotAuthorizedToCancelYet(workflowId, _msgSender());
            }
            unilateralCancel = strategy.canCancelUnilaterally(workflowId, _msgSender(), et);
            // Notify strategy of attempt
            strategy.onCancelAttempt(workflowId, _msgSender(), true);
        }

        // If strategy allows unilateral cancellation, cancel immediately
        if (unilateralCancel) {
            _cancelAndRefund(workflowId);
            return true;
        }

        // Otherwise require mutual consent
        et.senderStatus = SenderStatus.AGREE_TO_CANCEL;
        if (et.recipientStatus == RecipientStatus.AGREE_TO_CANCEL) {
            _cancelAndRefund(workflowId);
        }
        return true;
    }

    // slither-disable-next-line reentrancy-no-eth
    // =====================================================================
    // DISPUTES
    // Dispute opening, resolver authorization, timeout and ruling execution.
    // =====================================================================

    function autoCancelDisputedEscrow(uint256 workflowId) external {
        resolveDisputeByTimeout(workflowId);
    }

    // slither-disable-next-line reentrancy-no-eth
    function resolveDisputeByTimeout(uint256 workflowId) public nonReentrant {
        _validateWorkflowId(workflowId);
        EscrowTransfer storage et = escrowTransfers[workflowId];
        (ExecutionSource source, address caller) = _authorizeTimedActionAndSource(et);
        ModuleSnapshot storage snap = moduleSnapshots[workflowId];
        EscrowTimeoutPolicySnapshot memory timeoutPolicy = timeoutPolicySnapshots[workflowId];
        if (!timeoutPolicy.disputedTimeoutEnabled) {
            revert InvalidState(workflowId, uint8(EscrowState.DISPUTED), uint8(et.escrowState));
        }
        if (et.escrowState != EscrowState.DISPUTED) {
            revert TransferNotInDispute(workflowId, et.escrowState);
        }

        // CRIT-3: Prevent overriding a resolver's decision that is pending settlement
        if (pendingSettlements[workflowId].exists) {
            revert InvalidState(workflowId, uint8(EscrowState.DISPUTED), uint8(et.escrowState)); // Has pending settlement
        }

        uint256 ts = disputeRaisedTimestamp[workflowId];
        if (ts == 0 || block.timestamp < ts + snap.maxDisputeDuration) {
            revert InvalidState(workflowId, uint8(EscrowState.DISPUTED), uint8(et.escrowState)); // Dispute timeout not exceeded
        }
        address from = et.from;
        uint256 amt = et.amountAfterFee;
        _finalizeDisputeInModule(workflowId);
        _cancelAndRefund(workflowId);
        delete disputeRaisedTimestamp[workflowId];
        emit DisputeAutoCancelled(workflowId, from, amt, uint8(FailureReason.TIMEOUT));

        emit TimedActionTriggered(workflowId, ACTION_AUTO_CANCEL_DISPUTED, source, caller);
    }

    // slither-disable-next-line reentrancy-no-eth
    function raiseDispute(uint256 workflowId) external nonReentrant {
        _validateWorkflowId(workflowId);
        EscrowTransfer storage et = escrowTransfers[workflowId];
        ModuleSnapshot storage snap = moduleSnapshots[workflowId];

        // Fix 1: Reject dust disputes below governance-configured minimum
        uint256 minValue = minDisputeEscrowValue;
        if (minValue > 0 && et.amountAfterFee < minValue) {
            revert DisputeAmountBelowMinimum(workflowId, et.amountAfterFee, minValue);
        }

        // Fix 2: Per-sender dispute rate limit
        uint32 maxPerDay = maxDisputesPerSenderPerDay;
        if (maxPerDay > 0) {
            address raiser = _msgSender();
            uint64 windowStart = senderDisputeWindowStart[raiser];
            if (block.timestamp >= uint256(windowStart) + 1 days) {
                senderDisputeWindowStart[raiser] = uint64(block.timestamp);
                senderDisputeCount[raiser] = 1;
            } else {
                uint32 newCount = senderDisputeCount[raiser] + 1;
                if (newCount > maxPerDay) revert DisputeRateLimitExceeded(raiser, newCount, maxPerDay);
                senderDisputeCount[raiser] = newCount;
            }
        }

        EscrowDisputeLogic.DisputeOpeningResult memory result = EscrowDisputeLogic.computeDisputeOpening(
            address(_getResolutionModule(workflowId)),
            address(this),
            snap.incentiveModule,
            workflowId,
            _msgSender(),
            et.from,
            et.to,
            et.token,
            et.amountAfterFee,
            et.escrowState,
            et.disputeResolver
        );

        if (!result.success) revert TransferNotPending(workflowId, et.escrowState);

        StateManagementLibrary.transitionToDisputed(et, workflowId, (_msgSender() == et.from));
        disputeRaisedTimestamp[workflowId] = block.timestamp;

        emit EscrowStateChanged(workflowId, EscrowState.PENDING, EscrowState.DISPUTED);
        emit DisputeOpened(workflowId, _msgSender(), result.updatedResolver);

        if (result.updatedResolver != et.disputeResolver) {
            et.disputeResolver = result.updatedResolver;
        }

        uint256 configVersion = DisputeInitializationLibrary.initializeInModule(
            snap.resolutionModule,
            workflowId,
            et.disputeResolver,
            workflowResolutionConfigVersion[workflowId],
            EscrowEncodingLibrary.encodeEscrowTransferData(et.token, et.from, et.to, et.amountAfterFee, escrowSettings[workflowId].releaseAddress)
        );
        if (configVersion != 0 && configVersion != workflowResolutionConfigVersion[workflowId]) revert();
        DisputeInitializationLibrary.callResolverCallback(et.disputeResolver, workflowId);

        if (result.callIncentiveHook) {
            if (DisputeRaiseLibrary.callIncentiveModuleHook(
                result.incentiveModule,
                workflowId,
                et.token,
                et.amountAfterFee,
                snap.escrowFeeBps,
                ESCROW_FEE_DENOMINATOR
            )) {
                emit OperationFailure(3, workflowId, result.incentiveModule, IIncentiveModule.onDisputeOpened.selector, uint8(FailureReason.CALL_FAILED));
            }
        }
    }

    /**
     * @notice Helper function to get incentive module from resolution module
     * @dev Used to access public incentiveModule variable from DecentralizedResolutionModule
     */

    /**
     * @notice Validate and prepare escalation, canceling any pending settlement
     * @param workflowId The escrow ID
     * @return et EscrowTransfer storage reference
     * @return resolutionModule Resolution module for this escrow
     */
    // =====================================================================
    // APPEALS & AUTHORITY TRANSITIONS
    // Appeal quote, payment, and the atomic Kleros handoff / resolver mutation.
    // =====================================================================

    function _validateAndPrepareEscalation(
        uint256 workflowId
    ) internal returns (EscrowTransfer storage et, IResolutionModule resolutionModule) {
        _validateWorkflowId(workflowId);
        et = escrowTransfers[workflowId];
        resolutionModule = _getResolutionModule(workflowId);

        if (pendingSettlements[workflowId].exists) {
            delete pendingSettlements[workflowId];
            emit PendingSettlementCancelled(workflowId);
        }
    }

    // DEPRECATED: _collectEscalationBond removed - use BondCollector instead


    /**
     * @notice Escalate a dispute to the next resolution level
     * @dev V1: Appeals are disabled. This function will revert if called for v1 escrows
     *      (incentiveModule snapshot is null).
     *      resolution module + incentive module swap through governance.
     *
     *      Requires payment of an appeal bond (amount/token determined by resolution module).
     *      Bonds are recorded in the snapshotted incentive module for later distribution.
     *
     * @param workflowId The escrow workflow ID to escalate
     * @return success True if escalation succeeded
     * @return newDisputeResolver Address of the resolver assigned to the next level
     * @return newLevel New escalation level
     */
    struct AppealRequest {
        address funder;
        address operator;
        address refundRecipient;
    }

    error InvalidAppealRequestRole(uint8 role, address provided, address expected);
    error InvalidKlerosArbitrationFee(uint256 workflowId, uint256 required, uint256 supplied);

    function escalateDispute(uint256 workflowId)
        external payable nonReentrant returns (bool success, address newDisputeResolver, uint8 newLevel)
    {
        AppealRequest memory request = AppealRequest({
            funder: _msgSender(), operator: _msgSender(), refundRecipient: _msgSender()
        });
        return _appealDispute(workflowId, request);
    }

    function appealDispute(uint256 workflowId, AppealRequest calldata request)
        external payable nonReentrant returns (bool success, address newDisputeResolver, uint8 newLevel)
    {
        return _appealDispute(workflowId, request);
    }

    function _appealDispute(uint256 workflowId, AppealRequest memory request)
        internal returns (bool success, address newDisputeResolver, uint8 newLevel)
    {
        address caller = _msgSender();
        if (request.operator != caller) revert InvalidAppealRequestRole(1, request.operator, caller);
        if (request.funder != caller) revert InvalidAppealRequestRole(2, request.funder, caller);
        if (request.refundRecipient == address(0)) revert InvalidAppealRequestRole(3, request.refundRecipient, address(1));
        if (request.refundRecipient != request.operator) revert InvalidAppealRequestRole(3, request.refundRecipient, request.operator);
        (EscrowTransfer storage et, IResolutionModule resolutionModule) = _validateAndPrepareEscalation(workflowId);
        if (escrowSettings[workflowId].customResolver != address(0)) {
            revert AppealsUnsupportedForCustomResolver(workflowId, escrowSettings[workflowId].customResolver);
        }
        ModuleSnapshot storage snap = moduleSnapshots[workflowId];
        address feeRecipient = appealBondFeeRecipients[workflowId];
        if (feeRecipient == address(0)) feeRecipient = escrowFeeAddress;

        EscrowDisputeLogic.EscalationResult memory result = EscrowDisputeLogic.computeEscalation(
            address(resolutionModule),
            address(this),
            snap.incentiveModule,
            snap.appealBondProtocolFeeBps,
            feeRecipient,
            workflowId,
            request.operator,
            et.from,
            et.to,
            et.token,
            et.amountAfterFee,
            et.escrowState
        );
        if (!result.success) revert EscalationNotAllowed();
        bytes32 requestRoot = keccak256(abi.encode(
            "APPEAL_REQUEST_V1",
            block.chainid,
            address(this),
            workflowId,
            result.appealedDecisionRoot,
            request.operator,
            request.funder,
            request.refundRecipient
        ));

        // Deadline safety: do not hard-block escalation with a global cooldown.
        // Keep per-address tracking and linear bond scaling, but allow valid
        // within-window appeals to progress across rounds.
        address escalator = request.operator;
        uint32 priorEscCount = addressEscalationCount[escalator];
        uint32 escCount = priorEscCount + 1;
        addressEscalationCount[escalator] = escCount;
        lastEscalationTimestamp[escalator] = uint64(block.timestamp);
        if (result.bondAmount > 0) {
            if (escCount > 1) {
                uint256 scale100 = 100 + 10 * uint256(escCount - 1);
                result.bondAmount = result.bondAmount * scale100 / 100;
            }
            result.protocolFeeAmount =
                (result.bondAmount * snap.appealBondProtocolFeeBps) / ESCROW_FEE_DENOMINATOR;
            result.bondToRecord = result.bondAmount - result.protocolFeeAmount;
        }
        bytes32 policyRoot = keccak256(abi.encode(
            "ESCROW_APPEAL_POLICY_V1", snap.appealBondProtocolFeeBps, feeRecipient, priorEscCount
        ));
        bytes32 transitionRoot = keccak256(abi.encode(
            "APPEAL_TRANSITION_V1", requestRoot, result.resolutionQuoteRoot,
            result.currentLevel, result.newLevel, result.predecessorResolver, result.newResolver,
            result.bondToken, result.bondAmount, result.protocolFeeAmount, result.bondToRecord, policyRoot
        ));

        // Kleros is an external execution cost, not appeal-bond principal. Requote
        // immediately before invoking it so a fee change cannot leave a phantom round.
        bytes memory escrowData = EscrowEncodingLibrary.encodeEscrowTransferData(
            et.token, et.from, et.to, et.amountAfterFee, escrowSettings[workflowId].releaseAddress
        );
        uint256 klerosCost;
        bytes32 klerosConfigRoot;
        if (result.newLevel == 2) {
            try IKlerosArbitrableProxy(result.newResolver).getArbitrationCost('') returns (uint256 cost) {
                klerosCost = cost;
            } catch {
                revert EscalationNotAllowed();
            }
            klerosConfigRoot = IKlerosArbitrableProxy(result.newResolver).getKlerosHandoffConfigRoot();
        }

        // Validate independent bond and external arbitration payments.
        uint256 bondValue = result.bondToken == address(0) ? result.bondAmount : 0;
        if (msg.value < bondValue + klerosCost) {
            uint256 suppliedKlerosCost = msg.value > bondValue ? msg.value - bondValue : 0;
            revert InvalidKlerosArbitrationFee(workflowId, klerosCost, suppliedKlerosCost);
        }
        (bool msgValueValid, ) = DisputeEscalationLibrary.validateBondMsgValue(
            result.bondToken, result.bondAmount, result.bondToken == address(0) ? msg.value : 0
        );
        if (!msgValueValid) revert InvalidBondMsgValue(workflowId, result.bondAmount, msg.value);

        if (result.bondAmount > 0) {
            if (result.protocolFeeAmount > 0) {
                // Pull-only protocol fee handling: credit claimable ledger instead of auto-push.
                claimableBondProtocolFees[result.bondToken][feeRecipient] += result.protocolFeeAmount;
                emit BondProtocolFeeClaimableCredited(result.bondToken, feeRecipient, result.protocolFeeAmount, workflowId);
                emit ProtocolFeeCollected(1, workflowId, result.bondToken, result.bondAmount, snap.appealBondProtocolFeeBps, result.protocolFeeAmount);
            }

            IIncentiveModule incentiveMod = IIncentiveModule(result.incentiveModule);
            if (result.bondToken == address(0)) {
                BondHandlingLibrary.handleETHBond(incentiveMod, workflowId, request.operator,
                    result.bondToRecord, result.bondToken, result.newLevel,
                    feeRecipient, result.protocolFeeAmount);
            } else {
                if (address(bondCollector) == address(0)) revert ZeroBondCollector();
                uint256 balBefore = IERC20(result.bondToken).balanceOf(address(this));
                _pullTokens(result.bondToken, request.funder, result.bondAmount);
                uint256 received = IERC20(result.bondToken).balanceOf(address(this)) - balBefore;
                if (received < result.bondAmount) revert AccountingDeficit(result.bondToken, result.bondAmount - received);
                BondHandlingLibrary.handleERC20BondAfterPull(incentiveMod, bondCollector, workflowId,
                    request.operator, result.bondToken, result.bondToRecord, result.newLevel,
                    feeRecipient, result.protocolFeeAmount);
            }
        }

        bytes32 handoffRoot;
        if (result.newLevel == 2) {
            handoffRoot = IKlerosHandoffResolutionModule(address(resolutionModule)).prepareKlerosHandoff(
                workflowId, address(this), escrowData, result.resolutionQuoteRoot, klerosConfigRoot
            );
        }

        // Kleros remains only a prepared successor while this call runs. A failure
        // anywhere below rolls back both the preparation and external dispute.
        uint256 klerosDisputeId;
        if (klerosCost > 0 || result.newLevel == 2) {
            klerosDisputeId = IKlerosArbitrableProxy(result.newResolver).createDispute{value: klerosCost}(
                workflowId, address(this), 2, '', escrowData
            );
        }

        (bool modSuccess, address newRes, uint8 newLvl) = result.newLevel == 2
            ? IKlerosHandoffResolutionModule(address(resolutionModule)).commitKlerosHandoff(
                workflowId, address(this), escrowData, result.resolutionQuoteRoot, handoffRoot, klerosConfigRoot, klerosDisputeId
            )
            : resolutionModule.executeEscalationWithQuote(workflowId, address(this), escrowData, result.resolutionQuoteRoot);
        if (!modSuccess || newRes == address(0)) revert EscalationNotAllowed();
        if (newLvl != result.newLevel || newRes != result.newResolver) {
            revert EscalationResultMismatch(result.newLevel, newLvl, result.newResolver, newRes);
        }

        et.disputeResolver = newRes;

        if (msg.value > bondValue + klerosCost) {
            uint256 excess = msg.value - bondValue - klerosCost;
            claimableExcessEthRefunds[_msgSender()] += excess;
            emit ExcessEthRefundCredited(workflowId, _msgSender(), excess);
        }

        emit DisputeEscalated(workflowId, result.currentLevel, newLvl, newRes, _msgSender());
        emit AppealRequested(workflowId, requestRoot, request.operator, request.funder, request.refundRecipient);
        emit AppealTransitionDerived(
            workflowId, requestRoot, transitionRoot, result.resolutionQuoteRoot, result.appealedDecisionRoot,
            result.bondAmount, result.protocolFeeAmount, result.bondToRecord, feeRecipient
        );
        return (true, newRes, newLvl);
    }

    /// @notice Return module-authoritative appeal facts with the frozen escrow economics.
    /// @dev The quote deliberately does not pre-authorize a caller: authorization and
    ///      module quote revalidation remain part of appeal execution.
    function getAppealQuote(uint256 workflowId, address operator)
        external view returns (IEscrowAppeal.AppealQuote memory quote)
    {
        _validateWorkflowId(workflowId);
        if (escrowSettings[workflowId].customResolver != address(0)) return quote;

        IResolutionModule resolutionModule = _getResolutionModule(workflowId);
        if (address(resolutionModule) == address(0)) return quote;

        EscrowTransfer storage et = escrowTransfers[workflowId];
        bytes memory escrowData = EscrowEncodingLibrary.encodeEscrowTransferData(
            et.token, et.from, et.to, et.amountAfterFee, escrowSettings[workflowId].releaseAddress
        );
        IResolutionModule.ResolutionAppealQuote memory resolutionQuote =
            resolutionModule.quoteAppealTransition(workflowId, address(this), escrowData);
        ModuleSnapshot storage snap = moduleSnapshots[workflowId];
        uint256 bondAmount = resolutionQuote.baseBondAmount;
        uint32 priorEscalationCount = addressEscalationCount[operator];

        // Execution increments the operator's count before applying this same scale.
        if (bondAmount > 0 && priorEscalationCount > 0) {
            bondAmount = bondAmount * (100 + 10 * uint256(priorEscalationCount)) / 100;
        }

        address feeRecipient = appealBondFeeRecipients[workflowId];
        if (feeRecipient == address(0)) feeRecipient = escrowFeeAddress;
        uint256 protocolFeeAmount = bondAmount * snap.appealBondProtocolFeeBps / ESCROW_FEE_DENOMINATOR;

        quote = IEscrowAppeal.AppealQuote({
            supported: true,
            appealable: resolutionQuote.appealable,
            predecessorRound: resolutionQuote.predecessorRound,
            successorRound: resolutionQuote.successorRound,
            predecessorResolver: resolutionQuote.predecessorResolver,
            successorResolver: resolutionQuote.successorResolver,
            appealedDecision: resolutionQuote.appealedDecision,
            appealDeadline: resolutionQuote.appealDeadline,
            finalRound: resolutionQuote.finalRound,
            bondAsset: resolutionQuote.baseBondAsset,
            baseBondAmount: resolutionQuote.baseBondAmount,
            bondAmount: bondAmount,
            protocolFeeAmount: protocolFeeAmount,
            bondToRecord: bondAmount - protocolFeeAmount,
            protocolFeeBps: snap.appealBondProtocolFeeBps,
            protocolFeeRecipient: feeRecipient,
            appealedDecisionRoot: resolutionQuote.appealedDecisionRoot,
            resolutionQuoteRoot: resolutionQuote.resolutionQuoteRoot
        });
    }

    /// @notice Returns the resolution module snapshotted for a workflow.
    /// @dev External resolvers use this to verify workflow-specific handoff bindings.
    // =====================================================================
    // RESOLUTION EXECUTION & RESOLVER AUTHORIZATION
    // =====================================================================

    function getResolutionModule(uint256 workflowId) external view returns (address) {
        _validateWorkflowId(workflowId);
        return moduleSnapshots[workflowId].resolutionModule;
    }

    // ============ Resolution ============
    /**
     * @notice Shared internal function for executing resolution actions (always full resolution)
     * @param workflowId The escrow workflow ID
     * @param isRelease True to release to recipient, false to cancel/refund to sender
     * @param resolutionHash Hash of resolution details (for offchain verification)
     * @return success True if resolution executed successfully
     */
    function _executeResolution(
        uint256 workflowId,
        bool isRelease,
        bytes32 resolutionHash
    ) internal returns (bool) {
        _validateWorkflowId(workflowId);
        EscrowTransfer storage et = escrowTransfers[workflowId];

        if (!_isAuthorizedDisputeResolver(workflowId, _msgSender()))
            revert NotAuthorizedResolver(_msgSender(), et.disputeResolver);
        if (et.escrowState != EscrowState.DISPUTED)
            revert TransferNotInDispute(workflowId, et.escrowState);

        _recordResolutionOutcome(workflowId, _msgSender(), isRelease, resolutionHash);
        emit EscrowResolved(workflowId, _msgSender(), resolutionHash);

        IResolutionModule resolutionModule = _getResolutionModule(workflowId);
        address snap = moduleSnapshots[workflowId].resolutionModule;
        if (snap != address(0) && address(resolutionModule) != snap) {
            resolutionModule = IResolutionModule(snap);
        }
        if (address(resolutionModule) != address(0) && address(resolutionModule).code.length == 0) {
            revert NotAContract(1, address(resolutionModule));
        }

        // Use snapshotted appeal window so governance changes do not retroactively affect
        // in-flight escrows.  Mirrors the approach in automateTimedActions().
        ModuleSnapshot storage modSnap = moduleSnapshots[workflowId];
        TimeoutConfig memory snappedTimeoutConfig = TimeoutConfig({
            defaultAutoReleaseDelay: modSnap.defaultAutoReleaseDelay,
            defaultAutoCancelDelay: modSnap.defaultAutoCancelDelay,
            maxDisputeDuration: modSnap.maxDisputeDuration,
            appealWindowDuration: modSnap.appealWindowDuration
        });

        EscrowSettlementLogic.ResolutionResult memory result = EscrowSettlementLogic.computeResolutionExecution(
            address(resolutionModule),
            workflowId,
            isRelease,
            snappedTimeoutConfig,
            address(this)
        );

        if (result.shouldExecute) {
            _finalizeDisputeInModule(workflowId);
            if (isRelease) _releaseEscrowTransfer(workflowId);
            else _cancelAndRefund(workflowId);
            return true;
        }
        if (pendingSettlements[workflowId].exists) {
            revert PendingDecisionAlreadyExists(workflowId);
        }
        pendingSettlements[workflowId] = PendingSettlement({exists: true, isRelease: isRelease, appealDeadline: result.appealDeadline, resolutionHash: resolutionHash});
        emit PendingSettlementSet(workflowId, isRelease, result.appealDeadline);
        return true;
    }

    function _authorizeTimedActionAndSource(
        EscrowTransfer storage et
    ) internal view returns (ExecutionSource source, address caller) {
        caller = _msgSender();
        if (caller == et.from || caller == et.to) {
            return (ExecutionSource.USER, caller);
        }
        if (hasRole(ROLE_KEEPER, caller)) {
            return (ExecutionSource.KEEPER, caller);
        }
        if (!hasRole(ROLE_TIMELOCK, caller)) revert UnauthorizedTimedExecutor(caller);
        return (ExecutionSource.GOVERNANCE, caller);
    }

    function _authorizeTimedAction(EscrowTransfer storage et) internal view override {
        address caller = _msgSender();
        if (caller == et.from || caller == et.to) return;
        if (hasRole(ROLE_KEEPER, caller)) return;
        if (!hasRole(ROLE_TIMELOCK, caller)) revert UnauthorizedTimedExecutor(caller);
    }

    /// @notice Release escrow to recipient (core settlement action)
    /// @param workflowId Unique escrow identifier
    /// @dev Consults the release strategy to determine eligibility
    /// @dev Transitions PENDING → RELEASED
    /// @dev Creates claimable entitlement only (no automatic payout delivery)
    /// @dev Part of IEscrowCore interface for wallet adoption
    /// @dev Callable even when paused (release strategy may further restrict)
    // =====================================================================
    // AUTHORITATIVE LIFECYCLE (TERMINAL RELEASE)
    // Release strategy evaluation followed by escrow terminalization.
    // =====================================================================

    function release(uint256 workflowId) public nonReentrant {
        _validateWorkflowId(workflowId);
        EscrowTransfer storage et = escrowTransfers[workflowId];

        // Only PENDING escrows can be released
        if (et.escrowState != EscrowState.PENDING) {
            revert TransferNotPending(workflowId, et.escrowState);
        }

        // Encode escrow data once (canonical format: token, sender, recipient, amountAfterFee, releaseAddress)
        bytes memory escrowData = EscrowEncodingLibrary.encodeEscrowTransferData(
            et.token,
            et.from,
            et.to,
            et.amountAfterFee,
            escrowSettings[workflowId].releaseAddress
        );

        // Load release strategy from snapshot
        IReleaseStrategy strategy = _getReleaseStrategy(workflowId);

        // Check strategy is configured (revert if not; don't silently bypass policy)
        if (address(strategy) == address(0)) {
            revert ReleaseStrategyNotSet(workflowId);
        }

        // Consult strategy for eligibility
        (bool allowed, uint8 reasonCode) = strategy.canRelease(
            workflowId,
            address(this),
            _msgSender(),
            escrowData
        );

        // Require strategy allows the release
        if (!allowed) {
            // reasonCode 1 = not authorized, 2 = wrong state, etc.
            // For wallet-friendly error, use a compact error that maps to the code
            if (reasonCode == 1) {
                revert NotSender(workflowId, _msgSender(), et.from);
            } else {
                revert ReleaseNotAllowed(workflowId, reasonCode);
            }
        }

        // Release the escrow (entitlement-only settlement)
        _releaseEscrowTransfer(workflowId);
    }

    function cancelAsDisputeResolver(uint256 workflowId, bytes32 resolutionHash) public nonReentrant returns (bool) {
        return _executeResolution(workflowId, false, resolutionHash);
    }

    function releaseAsDisputeResolver(uint256 workflowId, bytes32 resolutionHash) public nonReentrant returns (bool) {
        return _executeResolution(workflowId, true, resolutionHash);
    }

    function _isAuthorizedDisputeResolver(
        uint256 workflowId,
        address disputeResolver
    ) internal view returns (bool) {
        EscrowTransfer storage et = escrowTransfers[workflowId];

        // If a customResolver is set for this escrow, it is the only authorized resolver.
        // Governance or module-level resolver changes must NOT override this per-escrow choice.
        EscrowSettings memory settings = escrowSettings[workflowId];
        if (settings.customResolver != address(0)) {
            return disputeResolver == settings.customResolver;
        }

        // S26 Governance Sandwich mitigation:
        // Once a resolver is assigned to a dispute (et.disputeResolver != address(0)), it becomes
        // the sole authority for that dispute. Consulting the module's live state would allow
        // governance to inject a replacement resolver mid-dispute via setResolver(), creating a
        // race condition where a malicious incoming resolver could finalize before the legitimate
        // outgoing one. The per-escrow assignment is immutable for the lifetime of the dispute;
        // escalation (escalateDispute) explicitly updates et.disputeResolver to the new level's
        // resolver, so this check remains correct across all escalation rounds.
        if (et.disputeResolver != address(0)) {
            return disputeResolver == et.disputeResolver;
        }

        // No per-escrow resolver assigned yet: consult the module as a fallback.
        address snap = moduleSnapshots[workflowId].resolutionModule;
        if (snap != address(0)) {
            bytes memory escrowData = EscrowEncodingLibrary.encodeEscrowTransferData(
                et.token,
                et.from,
                et.to,
                et.amountAfterFee,
                escrowSettings[workflowId].releaseAddress
            );
            (bool success, bytes memory data) = snap.staticcall(
                abi.encodeWithSelector(IResolutionModule.isAuthorizedDisputeResolver.selector, workflowId, address(this), disputeResolver, escrowData)
            );
            if (success && data.length >= 64) {
                (bool authorized, ) = abi.decode(data, (bool, uint8));
                if (authorized) return true;
            }
        }
        return false;
    }

    // =====================================================================
    // SHARED TRANSITION HELPERS
    // Terminal-state finalization used by the orchestration paths above.
    // =====================================================================

    function _finalizeDisputeInModule(uint256 workflowId) internal override {
        IResolutionModule resolutionModule = _getResolutionModule(workflowId);
        if (address(resolutionModule) == address(0)) return;
        (bool success, ) = address(resolutionModule).call(abi.encodeWithSelector(SEL_FINALIZE_DISPUTE, workflowId, address(this)));
        if (!success) {
            emit OperationFailure(1, workflowId, address(resolutionModule), SEL_FINALIZE_DISPUTE, 0);
        }

        // Decrement the resolver's concurrent-dispute counter so capacity is freed.
        // Separate call so modules that don't implement this function don't block finalization.
        address resolver = escrowTransfers[workflowId].disputeResolver;
        if (resolver != address(0)) {
            (bool dSuccess, ) = address(resolutionModule).call(
                abi.encodeWithSelector(SEL_DECREMENT_RESOLVER, resolver)
            );
            if (!dSuccess) {
                emit OperationFailure(2, workflowId, address(resolutionModule), SEL_DECREMENT_RESOLVER, 0);
            }
        }
    }

    function _closeDisputeByMutualAgreement(uint256 workflowId) internal override {
        IResolutionModule resolutionModule = _getResolutionModule(workflowId);
        if (address(resolutionModule) != address(0)) {
            (bool success, ) = address(resolutionModule).call(
                abi.encodeWithSelector(SEL_CLOSE_BY_MUTUAL_AGREEMENT, workflowId)
            );
            success; // Ignore failure — module may not support mutual agreement closure
        }
        // Finalize dispute and free resolver capacity (same as all other terminal paths)
        _finalizeDisputeInModule(workflowId);
    }


    function _validateWorkflowId(uint256 workflowId) internal view virtual override {
        if (workflowId >= escrowTransfers.length) {
            revert InvalidWorkflowId(workflowId, escrowTransfers.length);
        }
    }

    /**
     * @notice Get the total number of escrows created
     * @return count Total number of escrows
     * @dev Added for EscrowViewContract to check bounds without reverting
     */
    // =====================================================================
    // FRAMEWORK VIEWS
    // =====================================================================

    function getEscrowCount() external view returns (uint256 count) {
        return escrowTransfers.length;
    }

    /// @notice Check the configured release strategy for a workflow.
    function canRelease(uint256 workflowId, address caller) external view returns (bool allowed) {
        if (workflowId >= escrowTransfers.length) return false;
        EscrowTransfer storage et = escrowTransfers[workflowId];
        if (et.escrowState != EscrowState.PENDING) return false;
        IReleaseStrategy strategy = _getReleaseStrategy(workflowId);
        if (address(strategy) == address(0)) return false;
        bytes memory escrowData = EscrowEncodingLibrary.encodeEscrowTransferData(
            et.token,
            et.from,
            et.to,
            et.amountAfterFee,
            escrowSettings[workflowId].releaseAddress
        );
        (allowed, ) = strategy.canRelease(workflowId, address(this), caller, escrowData);
    }

    // Stub for backwards compatibility - returns state directly
    function getEscrowState(uint256 workflowId) external view returns (EscrowState state) {
        _validateWorkflowId(workflowId);
        return escrowTransfers[workflowId].escrowState;
    }

    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return interfaceId == type(IEscrowLifecycle).interfaceId
            || interfaceId == type(IEscrowDispute).interfaceId
            || interfaceId == type(IEscrowAppeal).interfaceId
            || interfaceId == type(IEscrowSettlement).interfaceId
            || interfaceId == type(IEscrowViews).interfaceId
            || super.supportsInterface(interfaceId);
    }

    // - getResolutionMode()
    // - getActiveDisputeHandler()
    // - canRelease()
    // - getActionStatus()

    function _requirePending(uint256 workflowId) internal view {
        _validateWorkflowId(workflowId);
        EscrowState st = escrowTransfers[workflowId].escrowState;
        if (st != EscrowState.PENDING) {
            revert TransferNotPending(workflowId, st);
        }
    }

    function _cancelAndRefund(uint256 workflowId) internal override {
        EscrowTransfer storage et = escrowTransfers[workflowId];
        uint256 released = amountReleased[workflowId];
        uint256 amount = released >= et.amountAfterFee ? 0 : et.amountAfterFee - released;
        address from = et.from;
        address token = et.token;

        _clearPendingSettlementIfExists(workflowId);

        // Clear statuses to NONE for terminal state consistency (cancellation-mutex invariant)
        et.senderStatus = SenderStatus.NONE;
        et.recipientStatus = RecipientStatus.NONE;

        EscrowState oldStatus = StateManagementLibrary.transitionToRefunded(et, workflowId);
        emit EscrowStateChanged(workflowId, oldStatus, EscrowState.REFUNDED);

        delete disputeRaisedTimestamp[workflowId];
        delete amountReleased[workflowId];

        _finalizeClaimableSettlement(workflowId, token, amount, from);
        _emitEscrowTransferCancelled(workflowId, token, from, amount);
    }

    function _releaseEscrowTransfer(uint256 workflowId) internal override {
        EscrowTransfer storage et = escrowTransfers[workflowId];
        uint256 released = amountReleased[workflowId];
        uint256 amount = released >= et.amountAfterFee ? 0 : et.amountAfterFee - released;
        address to = et.to;
        address token = et.token;

        _clearPendingSettlementIfExists(workflowId);

        EscrowState oldStatus = StateManagementLibrary.transitionToReleased(et, workflowId);
        emit EscrowStateChanged(workflowId, oldStatus, EscrowState.RELEASED);

        delete disputeRaisedTimestamp[workflowId];
        delete amountReleased[workflowId];

        _finalizeClaimableSettlement(workflowId, token, amount, to);
        _emitEscrowTransferReleased(workflowId, token, to, amount);
    }

    function _emitEscrowTransferCancelled(
        uint256 workflowId,
        address token,
        address from,
        uint256 amount
    ) internal virtual {}
    function _emitEscrowTransferReleased(
        uint256 workflowId,
        address token,
        address to,
        uint256 amount
    ) internal virtual {}
    // =====================================================================
    // MODULE RESOLUTION HOOKS
    // Snapshot-first module lookup with registry-default fallback.
    // =====================================================================

    function _getYieldGenerationModule(
        uint256 workflowId
    ) internal view virtual override returns (IYieldModule);
    function _getYieldDistributionModule(
        uint256 workflowId
    ) internal view virtual override returns (IYieldDistributionModule);
    function _getReleaseStrategy(
        uint256 workflowId
    ) internal view virtual override returns (IReleaseStrategy);
    function _getCancellationStrategy(
        uint256 workflowId
    ) internal view virtual override returns (address);
    function _getResolutionModule(
        uint256 workflowId
    ) internal view virtual override returns (IResolutionModule) {
        address snap = moduleSnapshots[workflowId].resolutionModule;
        if (snap != address(0)) {
            return IResolutionModule(snap);
        }
        return IResolutionModule(disputeResolutionModule);
    }

    // ResolutionOutcome enum removed - using version from EscrowTypes.sol

    function _recordResolutionOutcome(
        uint256 workflowId,
        address disputeResolver,
        bool isRelease,
        bytes32 /* resolutionHash */
    ) internal {
        address module = address(_getResolutionModule(workflowId));
        if (module == address(0)) return;
        ResolutionOutcome outcome = isRelease
            ? ResolutionOutcome.RELEASE
            : ResolutionOutcome.CANCEL;
        uint256 resolutionTime = block.timestamp;
        (bool success, ) = module.call(
            abi.encodeWithSelector(
                SEL_RECORD_RESOLUTION,
                workflowId,
                address(this),
                disputeResolver,
                uint8(outcome),
                resolutionTime
            )
        );
        success;
    }
}
