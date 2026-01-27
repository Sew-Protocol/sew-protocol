// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import '@openzeppelin/contracts/utils/Context.sol';
import '@openzeppelin/contracts/access/AccessControl.sol';
import '@openzeppelin/contracts/utils/ReentrancyGuard.sol';
import '@openzeppelin/contracts/utils/Pausable.sol';
import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import '@openzeppelin/contracts/utils/Address.sol';
import '../interfaces/IResolver.sol';
import '../interfaces/IReleaseStrategy.sol';
import '../shared/interfaces/IResolutionModule.sol';
import '../interfaces/IYieldGenerationModule.sol';
import '../interfaces/IYieldDistributionModule.sol';
import '../libraries/SettingsValidationLibrary.sol';
import '../libraries/EscrowEncodingLibrary.sol';
import '../libraries/ResolverLogicLibrary.sol';
import '../libraries/RecoveryLibrary.sol';
import '../libraries/ModuleProposalLibrary.sol';
import '../libraries/ResolverActionLibrary.sol';
import '../libraries/StateManagementLibrary.sol';
import '../libraries/DisputeInitializationLibrary.sol';
import '../libraries/DisputeManagementLibrary.sol';
import '../libraries/DisputeRaiseLibrary.sol';
import '../libraries/DisputeEscalationLibrary.sol';
import '../types/EscrowTypes.sol';
import '../types/YieldPresets.sol';
import '../libraries/YieldPresetLibrary.sol';
import '../YieldOps.sol';
import '../DisputeOps.sol';
import '../SettlementOps.sol';
import '../CreateOps.sol';
import '../decentralized-resolution-module/IIncentiveModule.sol';
import './BondCollector.sol';
import '../libraries/ModuleSnapshotLibrary.sol';
import '../libraries/BondHandlingLibrary.sol';

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

bytes4 constant SEL_FINALIZE_DISPUTE = bytes4(keccak256("finalizeDispute(uint256)"));
bytes4 constant SEL_RECORD_RESOLUTION = bytes4(keccak256("recordResolution(uint256,address,uint8,uint256)"));

error InvalidWorkflowId(uint256 workflowId, uint256 maxWorkflowId);
error TransferNotPending(uint256 workflowId, EscrowState currentStatus);
error NotAuthorizedResolver(address caller, address expectedResolver);
error TransferNotInDispute(uint256 workflowId, EscrowState currentStatus);
error NotParticipant(uint256 workflowId, address caller, address sender, address recipient);
error NotSender(uint256 workflowId, address caller, address expectedSender);
error NotRecipient(uint256 workflowId, address caller, address expectedRecipient);
error InvalidEscrowFee(uint256 fee, uint256 maxFee);
error FeeExceedsMaximum(uint256 feeBps, uint256 maxFeeBps);
error NoClaimableBalance(uint256 workflowId, address recipient, address token);
error TransferNotFinalized(uint256 workflowId, EscrowState currentState);
error NoPendingSettlement(uint256 workflowId);
error AppealWindowNotExpired(uint256 workflowId, uint256 appealDeadline, uint256 currentTime);
error NotInDisputedState(uint256 workflowId, EscrowState currentState);
error ExcessRefundTransferFailed(uint256 workflowId, address recipient, uint256 amount);

error InvalidState(uint256 workflowId, uint8 expected, uint8 actual);
error InvalidConfig(uint8 code, uint256 value);
// InvalidAddress already defined in EscrowTypes.sol
error TransferFailed(uint8 kind, address token, address to, uint256 amount);
error ResolutionModuleError(uint8 code);
error ZeroBondCollector();
error EscalationNotAllowed();
error AppealBondQueryFailed(uint256 workflowId);
error InvalidBondMsgValue(uint256 workflowId, uint256 required, uint256 provided);

// Errors used by child contracts (EscrowVault, EscrowableERC20)
error BalanceUnderflow(address token, uint256 currentBalance, uint256 requestedAmount);
error NotFeeAddress(address caller, address expectedFeeAddress);
error NoFeesToWithdraw(address token, uint256 availableFees);
error InsufficientContractBalance(address token, uint256 required, uint256 available);
error AmountExceedsAvailable(address token, uint256 requestedAmount, uint256 availableAmount);
error AccountingDeficit(address token, uint256 deficit);

abstract contract BaseEscrow is AccessControl, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;


    bytes32 public constant ROLE_TIMELOCK = keccak256('ROLE_TIMELOCK');
    bytes32 public constant ROLE_GUARDIAN = keccak256('ROLE_GUARDIAN');
    bytes32 public constant ROLE_ADMIN_CONTRACT = keccak256('ROLE_ADMIN_CONTRACT');


    uint256 public escrowFee;
    uint256 public constant ESCROW_FEE_DENOMINATOR = 10000;
    uint256 public constant MAX_ESCROW_FEE_BPS = 200; // 2% maximum escrow fee
    uint256 public constant MAX_AUTOMATION_RANGE = 100;
    uint256 public constant MAX_PROTOCOL_FEE_BPS = 3000; // 30% maximum
    uint256 public constant DEFAULT_YIELD_PROTOCOL_FEE_BPS = 3000; // 30% default
    EscrowTransfer[] public escrowTransfers; // Array index IS the workflowId
    address public escrowFeeAddress;

    // Protocol fees (in basis points)
    uint256 public yieldProtocolFeeBps; // Protocol fee on yield (0-3000 bps = 0-30%)
    uint256 public appealBondProtocolFeeBps; // Protocol fee on appeal bonds (0-3000 bps = 0-30%)

    address public disputeResolutionModule;

    TimeoutConfig public timeoutConfig;

    mapping(uint256 => uint256) public disputeRaisedTimestamp;
    mapping(uint256 => EscrowSettings) public escrowSettings;

    mapping(uint256 => mapping(address => uint256)) public claimableBalances;

    // Phase 1: Pending settlement storage (appeal window enforcement)
    struct PendingSettlement {
        bool exists;
        bool isRelease;
        uint256 appealDeadline;
        bytes32 resolutionHash;
    }
    mapping(uint256 => PendingSettlement) public pendingSettlements;

    struct ModuleSnapshot {
        address resolutionModule;
        address releaseStrategy;
        address yieldGenerationModule;
        address yieldDistributionModule;
        address incentiveModule;
        uint256 yieldProtocolFeeBps;      // Snapshotted at creation - fee on yield generated
        uint256 appealBondProtocolFeeBps; // Snapshotted at creation - fee on appeal bonds
    }
    mapping(uint256 => ModuleSnapshot) internal moduleSnapshots;

    enum ModuleType {
        RESOLUTION,
        RELEASE,
        YIELD_GEN,
        YIELD_DIST
    }

    YieldOps public yieldOps;
    DisputeOps public disputeOps;
    SettlementOps public settlementOps;
    BondCollector public bondCollector;
    CreateOps public createOps;


    event EscrowStateChanged(
        uint256 indexed workflowId,
        EscrowState oldStatus,
        EscrowState newStatus
    );
    event EscrowCreated(
        uint256 indexed workflowId,
        address indexed token,
        address indexed from,
        address to,
        uint256 amount,
        uint256 amountAfterFee,
        uint256 fee
    );
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
    event DisputeAutoCancelled(
        uint256 indexed workflowId,
        address indexed from,
        uint256 amount,
        uint8 reasonCode
    );
    event CancelRequested(uint256 indexed workflowId, address indexed by);
    event CancelConfirmed(uint256 indexed workflowId, address indexed by);
    event DisputeOpened(
        uint256 indexed workflowId,
        address indexed by,
        address indexed disputeResolver
    );
    event ResolutionModuleActivated(address indexed oldModule, address indexed newModule);
    event EscrowSettingsUpdated(uint256 indexed workflowId, EscrowSettings settings);
    event ERC20Recovered(address indexed token, address indexed recipient, uint256 amount);
    event ClaimableBalanceSet(
        uint256 indexed workflowId,
        address indexed recipient,
        address indexed token,
        uint256 amount
    );
    event EscrowWithdrawn(
        uint256 indexed workflowId,
        address indexed recipient,
        address indexed token,
        uint256 amount
    );
    event PendingSettlementSet(uint256 indexed workflowId, bool isRelease, uint256 appealDeadline);
    event PendingSettlementCancelled(uint256 indexed workflowId);
    event PendingSettlementExecuted(uint256 indexed workflowId, bool isRelease);
    event TimeoutConfigUpdated(TimeoutConfig config);
    event EscrowFinalized(uint256 indexed workflowId, address indexed recipient, uint256 amount);
    // Consolidated auto-transfer event (replaces AutoCompleted + AutoFailed to save bytecode)
    event EscrowTransferAutoResult(
        uint256 indexed workflowId,
        address indexed recipient,
        address indexed token,
        uint256 amount,
        bool success,
        uint8 reasonCode
    );
    event YieldProtocolFeeBpsUpdated(uint256 oldFeeBps, uint256 newFeeBps);
    event AppealBondProtocolFeeBpsUpdated(uint256 oldFeeBps, uint256 newFeeBps);
    // Consolidated: ProtocolFeeCollected now handles both yield and bond fees
    event ProtocolFeeCollected(
        uint8 indexed kind, // 0 = yield, 1 = appeal bond
        uint256 indexed workflowId,
        address indexed token,
        uint256 grossAmount,
        uint256 feeBps,
        uint256 feeAmount
    );

    // op codes (append-only):
    // 1 = yield deposit
    // 2 = yield withdraw/distribute
    // 3 = incentive module hook
    // 4 = auto-transfer push (fallback to pull)
    event OperationFailure(
        uint8 indexed op,
        uint256 indexed workflowId,
        address indexed target,
        bytes4 selector,
        uint8 reasonCode
    );

    // ============ Pause/Unpause ============
    function pause() external onlyRole(ROLE_GUARDIAN) {
        _pause();
    }

    function unpause() external onlyRole(ROLE_TIMELOCK) {
        _unpause();
    }

    function setFeeRecipient(address newAddr) external onlyRole(ROLE_ADMIN_CONTRACT) {
        if (newAddr == address(0)) revert InvalidAddress(ADDR_FEE_RECIPIENT, newAddr);
        escrowFeeAddress = newAddr;
    }

    function setEscrowFeeBps(uint256 feeBps) external onlyRole(ROLE_ADMIN_CONTRACT) {
        escrowFee = feeBps;
    }

    function setYieldProtocolFeeBps(uint256 feeBps) external onlyRole(ROLE_ADMIN_CONTRACT) {
        if (feeBps > MAX_PROTOCOL_FEE_BPS) revert FeeExceedsMaximum(feeBps, MAX_PROTOCOL_FEE_BPS);
        
        // CRIT-2: Validate fee recipient is set when fees are non-zero
        // This ensures yield can be recovered if distribution fails
        if (feeBps > 0 && escrowFeeAddress == address(0)) {
            revert InvalidAddress(ADDR_FEE_RECIPIENT, address(0));
        }
        
        uint256 oldFee = yieldProtocolFeeBps;
        yieldProtocolFeeBps = feeBps;
        emit YieldProtocolFeeBpsUpdated(oldFee, feeBps);
    }

    function setAppealBondProtocolFeeBps(uint256 feeBps) external onlyRole(ROLE_ADMIN_CONTRACT) {
        if (feeBps > MAX_PROTOCOL_FEE_BPS) revert FeeExceedsMaximum(feeBps, MAX_PROTOCOL_FEE_BPS);
        
        if (feeBps > 0 && escrowFeeAddress == address(0)) revert InvalidAddress(ADDR_FEE_RECIPIENT, address(0));
        uint256 oldFee = appealBondProtocolFeeBps;
        appealBondProtocolFeeBps = feeBps;
        emit AppealBondProtocolFeeBpsUpdated(oldFee, feeBps);
    }

    function setResolutionModule(address module) external onlyRole(ROLE_ADMIN_CONTRACT) {
        if (module == address(0)) revert InvalidAddress(ADDR_GENERIC, module);
        if (module.code.length == 0) revert ModuleNotContract(module);
        address oldModule = disputeResolutionModule;
        disputeResolutionModule = module;
        emit ResolutionModuleActivated(oldModule, module);
    }

    function setTimeoutConfig(TimeoutConfig calldata config) external onlyRole(ROLE_ADMIN_CONTRACT) {
        timeoutConfig = config;
        emit TimeoutConfigUpdated(config);
    }

    // ============ Ops Contract Wiring (Governance-controlled) ============
    // These are operational wiring changes and should be callable directly by governance (Timelock).
    function setCreateOps(address ops) external onlyRole(ROLE_TIMELOCK) {
        if (ops == address(0)) revert ZeroCreateOps();
        createOps = CreateOps(ops);
    }

    function setSettlementOps(address ops) external onlyRole(ROLE_TIMELOCK) {
        if (ops == address(0)) revert ZeroSettlementOps();
        settlementOps = SettlementOps(ops);
    }

    function setBondCollector(address collector) external onlyRole(ROLE_TIMELOCK) {
        if (collector == address(0)) revert ZeroBondCollector();
        bondCollector = BondCollector(collector);
    }

    // emergencyUnwindAavePosition REMOVED - now handled by GuardianOps contract

    function createEscrow(
        address token,
        address to,
        uint256 amount,
        EscrowSettings memory settings
    ) public nonReentrant whenNotPaused returns (uint256) {
        uint256 workflowId = escrowTransfers.length; // Array index IS the workflowId
        
        // CreateOps is mandatory (removed inline fallback to save >1KB bytecode)
        if (address(createOps) == address(0)) revert ZeroCreateOps();
        IResolutionModule resolutionModule = _getResolutionModule(workflowId);
        CreateOps.CreateResult memory result = createOps.computeEscrowCreation(
            token,
            to,
            _msgSender(),
            amount,
            settings,
            escrowFee,
            workflowId,
            address(resolutionModule)
        );

        uint256 balBefore = IERC20(token).balanceOf(address(this));
        _pullTokens(token, _msgSender(), amount);
        uint256 received = IERC20(token).balanceOf(address(this)) - balBefore;
        if (received < amount) revert AccountingDeficit(token, amount - received);

        escrowTransfers.push(EscrowTransfer({
            token: token,
            to: to,
            from: _msgSender(),
            amountAfterFee: result.amountAfterFee,
            escrowState: EscrowState.PENDING,
            senderStatus: SenderStatus.NONE,
            recipientStatus: RecipientStatus.NONE,
            disputeResolver: result.resolver,
            autoReleaseTime: 0,
            autoCancelTime: 0
        }));

        _updateEscrowBalance(token, result.amountAfterFee, true);
        _recordFee(token, result.fee);
        _applyEscrowSettings(workflowId, settings);
        _snapshotModulesForEscrow(workflowId);

        if (result.yieldEnabled && result.shouldDepositYield) {
            _depositYieldForEscrow(workflowId, token, result.amountAfterFee);
        }

        emit EscrowCreated(workflowId, token, _msgSender(), to, amount, result.amountAfterFee, result.fee);
        emit EscrowStateChanged(workflowId, EscrowState.NONE, EscrowState.PENDING);
        _emitEscrowTransferCreated(workflowId, token, _msgSender(), to, amount);

        // CRIT-3: Note: If yield deposit fails, escrowInYield[workflowId][token] remains false
        // Users can check yield status via escrowInYield(workflowId, token) public getter
        // YieldDepositAttempted event will indicate success/failure

        return workflowId;
    }

    function _pullTokens(address token, address from, uint256 amount) internal virtual;
    function _recordFee(address token, uint256 amount) internal virtual;
    function _depositForYield(
        IYieldGenerationModule genModule,
        uint256 workflowId,
        address token,
        uint256 amount
    ) internal virtual;
    function _emitEscrowTransferCreated(
        uint256 workflowId,
        address token,
        address from,
        address to,
        uint256 amount
    ) internal virtual;

    function _snapshotModulesForEscrow(uint256 workflowId) internal {
        address resModule = address(_getResolutionModule(workflowId));
        address incentiveMod = ModuleSnapshotLibrary.getIncentiveModule(resModule);
        moduleSnapshots[workflowId] = ModuleSnapshot({
            resolutionModule: resModule,
            releaseStrategy: address(_getReleaseStrategy(workflowId)),
            yieldGenerationModule: address(_getYieldGenerationModule(workflowId)),
            yieldDistributionModule: address(_getYieldDistributionModule(workflowId)),
            incentiveModule: incentiveMod,
            yieldProtocolFeeBps: yieldProtocolFeeBps,
            appealBondProtocolFeeBps: appealBondProtocolFeeBps
        });
    }

    function automateTimedActions(uint256 workflowId) external nonReentrant returns (bool) {
        _validateWorkflowId(workflowId);
        EscrowTransfer storage et = escrowTransfers[workflowId];
        if (address(settlementOps) == address(0)) return false;
        SettlementOps.SettlementPendingSettlement memory pendingMem = _convertPendingSettlement(pendingSettlements[workflowId]);
        (uint8 actionType, bool isRelease) = settlementOps.computeTimedActions(workflowId, et, pendingMem, timeoutConfig);
        if (actionType == 0) return false;
        if (actionType == 3) {
            delete pendingSettlements[workflowId];
            _finalizeDisputeInModule(workflowId);
            emit PendingSettlementExecuted(workflowId, isRelease);
        }
        if (isRelease) _releaseEscrowTransfer(workflowId);
        else _cancelAndRefund(workflowId);
        return true;
    }

    function _cancelWorkflow(uint256 id, address caller, bool isSender) internal returns (bool) {
        EscrowTransfer storage et = escrowTransfers[id];
        if (isSender) et.senderStatus = SenderStatus.AGREE_TO_CANCEL;
        else et.recipientStatus = RecipientStatus.AGREE_TO_CANCEL;
        emit CancelRequested(id, caller);
        if (et.senderStatus == SenderStatus.AGREE_TO_CANCEL && et.recipientStatus == RecipientStatus.AGREE_TO_CANCEL) {
            emit CancelConfirmed(id, caller);
            _cancelAndRefund(id);
        }
        return true;
    }

    function recipientCancel(uint256 workflowId) external nonReentrant whenNotPaused returns (bool) {
        _validateWorkflowId(workflowId);
        EscrowTransfer storage et = escrowTransfers[workflowId];
        if (et.to != _msgSender()) revert NotRecipient(workflowId, _msgSender(), et.to);
        if (et.escrowState != EscrowState.PENDING)
            revert TransferNotPending(workflowId, et.escrowState);
        return _cancelWorkflow(workflowId, _msgSender(), false);
    }

    function senderCancel(uint256 workflowId) external nonReentrant whenNotPaused returns (bool) {
        _validateWorkflowId(workflowId);
        EscrowTransfer storage et = escrowTransfers[workflowId];
        if (et.from != _msgSender()) revert NotSender(workflowId, _msgSender(), et.from);
        if (et.escrowState != EscrowState.PENDING)
            revert TransferNotPending(workflowId, et.escrowState);
        return _cancelWorkflow(workflowId, _msgSender(), true);
    }

    // slither-disable-next-line reentrancy-no-eth
    function autoCancelDisputedEscrow(uint256 workflowId) external nonReentrant {
        _validateWorkflowId(workflowId);
        EscrowTransfer storage et = escrowTransfers[workflowId];
        if (et.escrowState != EscrowState.DISPUTED) {
            revert TransferNotInDispute(workflowId, et.escrowState);
        }
        uint256 ts = disputeRaisedTimestamp[workflowId];
        if (ts == 0 || block.timestamp < ts + timeoutConfig.maxDisputeDuration) {
            revert InvalidState(workflowId, uint8(EscrowState.DISPUTED), uint8(et.escrowState)); // Dispute timeout not exceeded
        }
        address from = et.from;
        uint256 amt = et.amountAfterFee;
        _cancelAndRefund(workflowId);
        delete disputeRaisedTimestamp[workflowId];
        emit DisputeAutoCancelled(workflowId, from, amt, uint8(FailureReason.TIMEOUT));
    }

    // slither-disable-next-line reentrancy-no-eth
    function raiseDispute(uint256 workflowId) external nonReentrant {
        _validateWorkflowId(workflowId);
        EscrowTransfer storage et = escrowTransfers[workflowId];
        if (et.escrowState != EscrowState.PENDING)
            revert TransferNotPending(workflowId, et.escrowState);
        address disputeResolver = et.disputeResolver;
        bool isSender = (et.from == _msgSender());
        if (!isSender && et.to != _msgSender())
            revert NotParticipant(workflowId, _msgSender(), et.from, et.to);
        StateManagementLibrary.transitionToDisputed(et, workflowId, isSender);
        disputeRaisedTimestamp[workflowId] = block.timestamp;
        emit EscrowStateChanged(workflowId, EscrowState.PENDING, EscrowState.DISPUTED);
        emit DisputeOpened(workflowId, _msgSender(), disputeResolver);
        address updated = DisputeInitializationLibrary.initializeInModule(
            address(_getResolutionModule(workflowId)),
            workflowId,
            disputeResolver,
            EscrowEncodingLibrary.encodeEscrowTransferData(
                et.token,
                et.from,
                et.to,
                et.amountAfterFee
            )
        );
        if (updated != disputeResolver) {
            et.disputeResolver = updated;
            disputeResolver = updated;
        }
        DisputeInitializationLibrary.callResolverCallback(disputeResolver, workflowId);

        address incentiveModAddr = moduleSnapshots[workflowId].incentiveModule;
        if (DisputeRaiseLibrary.callIncentiveModuleHook(
            incentiveModAddr,
            workflowId,
            et.token,
            et.amountAfterFee,
            escrowFee,
            ESCROW_FEE_DENOMINATOR
        )) {
            emit OperationFailure(3, workflowId, incentiveModAddr, IIncentiveModule.onDisputeOpened.selector, uint8(FailureReason.CALL_FAILED));
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
    function _validateAndPrepareEscalation(
        uint256 workflowId
    ) internal returns (EscrowTransfer storage et, IResolutionModule resolutionModule) {
        _validateWorkflowId(workflowId);
        et = escrowTransfers[workflowId];
        if (address(disputeOps) == address(0)) revert ZeroDisputeOps();
        resolutionModule = _getResolutionModule(workflowId);

        if (pendingSettlements[workflowId].exists) {
            delete pendingSettlements[workflowId];
            emit PendingSettlementCancelled(workflowId);
        }
    }

    // DEPRECATED: _collectEscalationBond removed - use BondCollector instead


    function escalateDispute(
        uint256 workflowId
    )
        external
        payable
        nonReentrant
        returns (bool success, address newDisputeResolver, uint8 newLevel)
    {
        (EscrowTransfer storage et, IResolutionModule resolutionModule) = _validateAndPrepareEscalation(workflowId);

        DisputeOps.EscalationResult memory result = disputeOps.computeEscalation(
            address(resolutionModule),
            workflowId,
            _msgSender(),
            et.from,
            et.to,
            et.token,
            et.amountAfterFee,
            et.escrowState
        );
        if (!result.success) revert EscalationNotAllowed();

        // Get required appeal bond from resolution module
        bytes memory escrowData = EscrowEncodingLibrary.encodeEscrowTransferData(
            et.token,
            et.from,
            et.to,
            et.amountAfterFee
        );
        (bool bondQuerySuccess, uint256 bondAmount, address bondToken) = DisputeEscalationLibrary.queryAppealBond(
            resolutionModule,
            workflowId,
            result.currentLevel,
            escrowData
        );
        if (!bondQuerySuccess) revert AppealBondQueryFailed(workflowId);

        (bool msgValueValid, ) = DisputeEscalationLibrary.validateBondMsgValue(bondToken, bondAmount, msg.value);
        if (!msgValueValid) {
            revert InvalidBondMsgValue(workflowId, bondAmount, msg.value);
        }

        if (bondAmount > 0) {
            address incentiveModAddr = moduleSnapshots[workflowId].incentiveModule;
            uint256 snapshottedBondFee = moduleSnapshots[workflowId].appealBondProtocolFeeBps;

            (BondHandlingLibrary.BondProcessingResult memory bondResult, IIncentiveModule incentiveMod) = 
                DisputeEscalationLibrary.processBondWithFeeCalculation(
                    bondAmount,
                    bondToken,
                    incentiveModAddr,
                    snapshottedBondFee,
                    escrowFeeAddress
                );

            if (bondResult.protocolFeeAmount > 0) {
                emit ProtocolFeeCollected(1, workflowId, bondToken, bondAmount, snapshottedBondFee, bondResult.protocolFeeAmount);
            }

            if (address(incentiveMod) != address(0)) {
                if (bondToken == address(0)) {
                    BondHandlingLibrary.handleETHBond(
                        incentiveMod,
                        workflowId,
                        _msgSender(),
                        bondResult.bondToRecord,
                        bondToken,
                        result.newLevel,
                        escrowFeeAddress,
                        bondResult.protocolFeeAmount
                    );
                } else {
                    if (address(bondCollector) == address(0)) revert ZeroBondCollector();
                    _pullTokens(bondToken, _msgSender(), bondAmount);
                    BondHandlingLibrary.handleERC20BondAfterPull(
                        incentiveMod,
                        bondCollector,
                        workflowId,
                        _msgSender(),
                        bondToken,
                        bondResult.bondToRecord,
                        result.newLevel,
                        escrowFeeAddress,
                        bondResult.protocolFeeAmount
                    );
                }
            }
        }

        address newResolver = result.newResolver;
        uint8 newLevel_ = result.newLevel;
        et.disputeResolver = newResolver;
        
        if (bondToken == address(0) && msg.value > bondAmount) {
            uint256 excess = msg.value - bondAmount;
            if (excess > 0) {
                (bool s, ) = payable(_msgSender()).call{value: excess}('');
                if (!s) revert ExcessRefundTransferFailed(workflowId, _msgSender(), excess);
            }
        }
        emit DisputeEscalated(
            workflowId,
            result.currentLevel,
            newLevel_,
            newResolver,
            _msgSender()
        );
        return (true, newResolver, newLevel_);
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

        if (address(settlementOps) == address(0)) revert ZeroSettlementOps();

        SettlementOps.ResolutionResult memory result = settlementOps.computeResolutionExecution(
            address(resolutionModule),
            workflowId,
            isRelease,
            timeoutConfig
        );
        
        if (result.shouldExecute) {
            if (isRelease) _releaseEscrowTransfer(workflowId);
            else _cancelAndRefund(workflowId);
            return true;
        }
        pendingSettlements[workflowId] = PendingSettlement({exists: true, isRelease: isRelease, appealDeadline: result.appealDeadline, resolutionHash: resolutionHash});
        emit PendingSettlementSet(workflowId, isRelease, result.appealDeadline);
        return true;
    }

    function executePendingSettlement(uint256 workflowId) external nonReentrant {
        _validateWorkflowId(workflowId);
        EscrowTransfer storage et = escrowTransfers[workflowId];
        PendingSettlement storage pending = pendingSettlements[workflowId];

        if (address(settlementOps) == address(0)) revert ZeroSettlementOps();
        SettlementOps.SettlementPendingSettlement memory pendingMem = _convertPendingSettlement(pending);
        (bool canExecute, bool isRelease) = settlementOps.computePendingSettlementExecution(workflowId, pendingMem, et.escrowState);
        if (!canExecute) {
            if (!pending.exists) revert NoPendingSettlement(workflowId);
            if (block.timestamp < pending.appealDeadline) revert AppealWindowNotExpired(workflowId, pending.appealDeadline, block.timestamp);
            revert NotInDisputedState(workflowId, et.escrowState);
        }
        delete pendingSettlements[workflowId];
        IResolutionModule resolutionModule = _getResolutionModule(workflowId);
        if (address(resolutionModule) != address(0)) _finalizeDisputeInModule(workflowId);
        if (isRelease) _releaseEscrowTransfer(workflowId);
        else _cancelAndRefund(workflowId);

        emit PendingSettlementExecuted(workflowId, isRelease);
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
        address snap = moduleSnapshots[workflowId].resolutionModule;
        if (snap != address(0)) {
            bytes memory escrowData = EscrowEncodingLibrary.encodeEscrowTransferData(
                et.token,
                et.from,
                et.to,
                et.amountAfterFee
            );
            (bool success, bytes memory data) = snap.staticcall(
                abi.encodeWithSelector(IResolutionModule.isAuthorizedDisputeResolver.selector, workflowId, disputeResolver, escrowData)
            );
            if (success && data.length >= 64) {
                (bool authorized, ) = abi.decode(data, (bool, uint8));
                if (authorized) return true;
            }
        }
        return disputeResolver == et.disputeResolver;
    }

    function _applyEscrowSettings(uint256 workflowId, EscrowSettings memory settings) internal {
        EscrowTransfer storage et = escrowTransfers[workflowId];
        if (settings.customResolver != address(0)) et.disputeResolver = settings.customResolver;
        bool def = (settings.autoReleaseTime == 0 && settings.autoCancelTime == 0);
        
        uint256 relTime = settings.autoReleaseTime > 0 ? settings.autoReleaseTime : (def ? timeoutConfig.defaultAutoReleaseTime : 0);
        if (relTime > type(uint64).max) revert InvalidAutoTime(AUTO_TIME_TOO_LARGE, relTime, block.timestamp);
        et.autoReleaseTime = uint64(relTime);

        uint256 cancTime = settings.autoCancelTime > 0 ? settings.autoCancelTime : (def ? timeoutConfig.defaultAutoCancelTime : 0);
        if (cancTime > type(uint64).max) revert InvalidAutoTime(AUTO_TIME_TOO_LARGE, cancTime, block.timestamp);
        et.autoCancelTime = uint64(cancTime);

        escrowSettings[workflowId] = settings;
        emit EscrowSettingsUpdated(workflowId, settings);
    }

    /**
     * @notice Convert PendingSettlement storage to memory (consolidated helper)
     * @param pending Storage reference
     * @return pendingMem Memory struct
     */
    function _convertPendingSettlement(PendingSettlement storage pending) internal view returns (SettlementOps.SettlementPendingSettlement memory pendingMem) {
        return SettlementOps.SettlementPendingSettlement({
            exists: pending.exists,
            isRelease: pending.isRelease,
            appealDeadline: pending.appealDeadline,
            resolutionHash: pending.resolutionHash
        });
    }

    function _finalizeDisputeInModule(uint256 workflowId) internal {
        IResolutionModule resolutionModule = _getResolutionModule(workflowId);
        if (address(resolutionModule) != address(0)) {
            (bool success, ) = address(resolutionModule).call(abi.encodeWithSelector(SEL_FINALIZE_DISPUTE, workflowId));
            success; // Ignore failure
        }
    }


    function withdrawEscrow(uint256 workflowId) external nonReentrant returns (uint256) {
        _validateWorkflowId(workflowId);
        EscrowTransfer storage et = escrowTransfers[workflowId];

        if (et.escrowState != EscrowState.RESOLVED &&
            et.escrowState != EscrowState.RELEASED &&
            et.escrowState != EscrowState.REFUNDED) {
            revert TransferNotFinalized(workflowId, et.escrowState);
        }

        address token = et.token; // Single token per escrow
        uint256 amount = claimableBalances[workflowId][msg.sender];
        if (amount == 0) revert NoClaimableBalance(workflowId, msg.sender, token);

        claimableBalances[workflowId][msg.sender] = 0;

        _transferTokens(token, msg.sender, amount);

        emit EscrowWithdrawn(workflowId, msg.sender, token, amount);
        return amount;
    }


    function recoverERC20(
        address token,
        address recipient,
        uint256 amount
    ) external virtual onlyRole(ROLE_TIMELOCK) nonReentrant {
        uint256 rec = RecoveryLibrary.recoverERC20(
            token,
            recipient,
            amount,
            IERC20(token).balanceOf(address(this))
        );
        emit ERC20Recovered(token, recipient, rec);
    }

    function _validateWorkflowId(uint256 workflowId) internal view {
        if (workflowId >= escrowTransfers.length) {
            revert InvalidWorkflowId(workflowId, escrowTransfers.length);
        }
    }

    /**
     * @notice Get the total number of escrows created
     * @return count Total number of escrows
     * @dev Added for EscrowViewContract to check bounds without reverting
     */
    function getEscrowCount() external view returns (uint256 count) {
        return escrowTransfers.length;
    }

    function _requirePending(uint256 workflowId) internal view {
        _validateWorkflowId(workflowId);
        EscrowState st = escrowTransfers[workflowId].escrowState;
        if (st != EscrowState.PENDING) {
            revert TransferNotPending(workflowId, st);
        }
    }

    /**
     * @notice Attempt automatic transfer with graceful fallback to claimable balance
     * @param workflowId The escrow ID
     * @param recipient Address to receive funds
     * @param token Token address
     * @param amount Amount to transfer
     * @return transferred True if transfer succeeded, false if fell back to claimable
     */
    function _attemptAutoTransfer(
        uint256 workflowId,
        address recipient,
        address token,
        uint256 amount
    ) internal returns (bool transferred) {
        if (amount == 0) {
            return false;
        }

        uint256 bal = IERC20(token).balanceOf(address(this));
        bool success = bal >= amount && _tryTransfer(token, recipient, amount);
        if (success) {
            emit EscrowTransferAutoResult(workflowId, recipient, token, amount, true, 0);
            return true;
        }
        claimableBalances[workflowId][recipient] += amount;
        emit ClaimableBalanceSet(workflowId, recipient, token, amount);
        uint8 reason = bal < amount ? uint8(FailureReason.CONTRACT_INSUFFICIENT_BALANCE) : uint8(FailureReason.PUSH_FAILED_FALLBACK_TO_PULL);
        emit EscrowTransferAutoResult(workflowId, recipient, token, amount, false, reason);
        emit OperationFailure(4, workflowId, token, IERC20.transfer.selector, reason);
        return false;
    }

    function _tryTransfer(address token, address to, uint256 amount) internal returns (bool success) {
        (success, ) = token.call(abi.encodeWithSelector(IERC20.transfer.selector, to, amount));
        if (success) {
            assembly {
                if returndatasize() {
                    returndatacopy(0, 0, returndatasize())
                    success := and(mload(0), 0xff)
                }
            }
        }
    }

    function _handleYieldAndGetActualAmount(
        uint256 workflowId,
        address token,
        uint256 amount
    ) internal returns (uint256 actualAmount) {
        EscrowSettings memory settings = escrowSettings[workflowId];
        bool yieldEnabled = settings.yieldPreset != YieldPreset.OFF;
        
        if (address(yieldOps) == address(0)) {
            if (yieldEnabled) emit OperationFailure(2, workflowId, address(0), YieldOps.handleYield.selector, uint8(FailureReason.MODULE_NOT_SET));
            return amount;
        }
        if (address(yieldOps).code.length == 0) {
            if (yieldEnabled) emit OperationFailure(2, workflowId, address(yieldOps), YieldOps.handleYield.selector, uint8(FailureReason.MODULE_NOT_CONTRACT));
            return amount;
        }
        
        IYieldGenerationModule genModule = _getYieldGenerationModule(workflowId);
        IYieldDistributionModule distModule = _getYieldDistributionModule(workflowId);
        uint256 snapshottedYieldFee = moduleSnapshots[workflowId].yieldProtocolFeeBps;
        EscrowTransfer memory et = escrowTransfers[workflowId];
        bytes memory distributionData = YieldPresetLibrary.deriveDistributionData(settings.yieldPreset, et.from, et.to);

        (bool ok, bytes memory ret) = address(yieldOps).call(
            abi.encodeWithSelector(YieldOps.handleYield.selector, genModule, distModule, workflowId, token, amount, snapshottedYieldFee, escrowFeeAddress, distributionData)
        );

        if (!ok || ret.length < 128) {
            if (yieldEnabled) emit OperationFailure(2, workflowId, address(yieldOps), YieldOps.handleYield.selector, uint8(FailureReason.CALL_FAILED));
            return amount;
        }

        YieldOps.YieldResult memory result = abi.decode(ret, (YieldOps.YieldResult));
        if (result.actualAmount > 0 && result.actualAmount >= amount) {
            // PUSH MODEL: If yield was generated, transfer it to YieldOps and distribute
            if (result.yield > 0) {
                // Transfer yield portion to YieldOps (PUSH)
                IERC20(token).safeTransfer(address(yieldOps), result.yield);
                
                // Call YieldOps to distribute the yield (best-effort, non-blocking)
                (bool distOk, bytes memory distRet) = address(yieldOps).call(
                    abi.encodeWithSelector(
                        YieldOps.distributeWithdrawnYield.selector,
                        distModule,
                        workflowId,
                        token,
                        result.yield,
                        snapshottedYieldFee,
                        escrowFeeAddress,
                        distributionData
                    )
                );
                
                // Decode distribution result (best-effort)
                // Note: Don't decode the struct in production as it causes issues
                // The distribution has already happened, we just need to know if it succeeded
                if (distOk) {
                    // Success - distribution happened
                    result.yieldDistributed = result.yield;
                    result.success = true;
                } else {
                    // Distribution call failed - yield is in YieldOps, emit failure
                    if (yieldEnabled) {
                        emit OperationFailure(2, workflowId, address(yieldOps), YieldOps.distributeWithdrawnYield.selector, uint8(FailureReason.CALL_FAILED));
                    }
                }
            }
            // PUSH MODEL: After yield is transferred out, return only principal
            // The yield has been sent to YieldOps, so vault only has principal remaining
            return amount;
        }
        if (result.actualAmount > 0 && result.actualAmount < amount && yieldEnabled) {
            emit OperationFailure(2, workflowId, address(yieldOps), YieldOps.handleYield.selector, uint8(FailureReason.LESS_THAN_PRINCIPAL));
        }
        return amount;
    }

    function _cancelAndRefund(uint256 workflowId) internal {
        EscrowTransfer storage et = escrowTransfers[workflowId];
        uint256 amount = et.amountAfterFee;
        address from = et.from;
        address token = et.token;
        EscrowState oldStatus = StateManagementLibrary.transitionToRefunded(et, workflowId);
        emit EscrowStateChanged(workflowId, oldStatus, EscrowState.REFUNDED);
        
        uint256 actualAmount = _handleYieldAndGetActualAmount(workflowId, token, amount);
        _updateEscrowBalance(token, amount, false);
        
        // Auto-transfer: Attempt automatic transfer, fallback to claimable if fails
        _attemptAutoTransfer(workflowId, from, token, actualAmount);
        _emitEscrowTransferCancelled(workflowId, token, from, amount);
    }

    function _releaseEscrowTransfer(uint256 workflowId) internal {
        EscrowTransfer storage et = escrowTransfers[workflowId];
        uint256 amount = et.amountAfterFee;
        address to = et.to;
        address token = et.token;
        EscrowState oldStatus = StateManagementLibrary.transitionToReleased(et, workflowId);
        emit EscrowStateChanged(workflowId, oldStatus, EscrowState.RELEASED);
        
        uint256 actualAmount = _handleYieldAndGetActualAmount(workflowId, token, amount);
        _updateEscrowBalance(token, amount, false);
        
        // Auto-transfer: Attempt automatic transfer, fallback to claimable if fails
        _attemptAutoTransfer(workflowId, to, token, actualAmount);
        _emitEscrowTransferReleased(workflowId, token, to, amount);
    }

    function _transferTokens(address token, address to, uint256 amount) internal virtual;
    function _updateEscrowBalance(address token, uint256 amount, bool add) internal virtual;
    function _emitEscrowTransferCancelled(
        uint256 workflowId,
        address token,
        address from,
        uint256 amount
    ) internal virtual;
    function _emitEscrowTransferReleased(
        uint256 workflowId,
        address token,
        address to,
        uint256 amount
    ) internal virtual;
    function _getYieldGenerationModule(
        uint256 workflowId
    ) internal view virtual returns (IYieldGenerationModule);
    function _getYieldDistributionModule(
        uint256 workflowId
    ) internal view virtual returns (IYieldDistributionModule);
    function _getReleaseStrategy(
        uint256 workflowId
    ) internal view virtual returns (IReleaseStrategy);
    function _getResolutionModule(
        uint256 workflowId
    ) internal view virtual returns (IResolutionModule) {
        address snap = moduleSnapshots[workflowId].resolutionModule;
        if (snap != address(0)) {
            return IResolutionModule(snap);
        }
        return IResolutionModule(disputeResolutionModule);
    }

    function _depositYieldForEscrow(uint256 workflowId, address token, uint256 amount) internal {
        IYieldGenerationModule genModule = _getYieldGenerationModule(workflowId);
        if (address(genModule) != address(0) && genModule.isTokenSupported(token)) {
            // Call _depositForYield which is overridden in child contracts (EscrowVault/EscrowableERC20)
            // This allows child contracts to set approvals before calling the module
            _depositForYield(genModule, workflowId, token, amount);
        }
    }

    enum ResolutionOutcome {
        NONE, // 0 - No resolution yet
        RELEASE, // 1 - Funds released to recipient
        CANCEL // 2 - Funds refunded to sender
    }

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
                disputeResolver,
                uint8(outcome),
                resolutionTime
            )
        );
        success;
    }
}
