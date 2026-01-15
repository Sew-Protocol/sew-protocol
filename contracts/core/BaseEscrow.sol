// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import '@openzeppelin/contracts/utils/Context.sol';
import '@openzeppelin/contracts/access/AccessControl.sol';
import '@openzeppelin/contracts/utils/ReentrancyGuard.sol';
import '@openzeppelin/contracts/utils/Pausable.sol';
import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import '@openzeppelin/contracts/utils/Address.sol';
import '@openzeppelin/contracts/utils/introspection/IERC165.sol';
import '@openzeppelin/contracts/utils/introspection/ERC165.sol';
import '../interfaces/IResolver.sol';
import '../interfaces/IReleaseStrategy.sol';
import '../shared/interfaces/IResolutionModule.sol';
import '../interfaces/IYieldGenerationModule.sol';
import '../interfaces/IYieldDistributionModule.sol';
import '../libraries/SettingsValidationLibrary.sol';
import '../libraries/EscrowCreationLibrary.sol';
import '../libraries/EscrowEncodingLibrary.sol';
import '../libraries/ResolverLogicLibrary.sol';
import '../libraries/RecoveryLibrary.sol';
import '../libraries/ModuleProposalLibrary.sol';
import '../libraries/ResolverActionLibrary.sol';
import '../libraries/StateManagementLibrary.sol';
import '../libraries/DisputeInitializationLibrary.sol';
import '../libraries/DisputeManagementLibrary.sol';
import '../types/EscrowTypes.sol';
import '../governance/SlowLaneQueueActivate.sol';
import '../YieldOps.sol';
import '../DisputeOps.sol';
import '../decentralized-resolution-module/IIncentiveModule.sol';

error InsufficientTokenBalance(uint256 balance, uint256 required);
error InvalidWorkflowId(uint256 workflowId, uint256 maxWorkflowId);
error TransferNotPending(uint256 workflowId, EscrowState currentStatus);
error NotAuthorizedResolver(address caller, address expectedResolver);
error ResolutionModuleNotReady(uint256 currentTime, uint256 eta);
error ResolutionModuleReturnedZeroAddress();
error ResolutionModuleCallFailed();
error ResolutionModuleNotConfigured();
error TransferNotInDispute(uint256 workflowId, EscrowState currentStatus);
error NotParticipant(uint256 workflowId, address caller, address sender, address recipient);
error NotSender(uint256 workflowId, address caller, address expectedSender);
error NotRecipient(uint256 workflowId, address caller, address expectedRecipient);
error TransferAlreadyCancelled(uint256 workflowId);
error TransferAlreadyReleased(uint256 workflowId);
error TransferAlreadyResolved(uint256 workflowId);
error AmountExceedsTransfer(uint256 workflowId, uint256 requestedAmount, uint256 availableAmount);
error NotFeeAddress(address caller, address expectedFeeAddress);
error NoFeesToWithdraw(address token, uint256 availableFees);
error InvalidEscrowFee(uint256 fee, uint256 maxFee);
error ExceedsMaxRange(uint256 requestedRange, uint256 maxRange);

abstract contract BaseEscrow is AccessControl, ReentrancyGuard, Pausable, SlowLaneQueueActivate {
    using SafeERC20 for IERC20;
    using Address for address;

    bytes32 public constant ROLE_TIMELOCK = keccak256('ROLE_TIMELOCK');
    bytes32 public constant ROLE_GUARDIAN = keccak256('ROLE_GUARDIAN');

    // Interface ID for resolution functions (V1)
    bytes4 public constant RESOLUTION_INTERFACE_V1 =
        bytes4(keccak256('cancelAsDisputeResolver(uint256,bytes32)')) ^
            bytes4(keccak256('releaseAsDisputeResolver(uint256,bytes32)'));

    uint256 public escrowFee;
    uint256 public constant ESCROW_FEE_DENOMINATOR = 10000;
    uint256 public constant MAX_AUTOMATION_RANGE = 100;
    EscrowTransfer[] public escrowTransfers; // Array index IS the escrowId
    address public escrowFeeAddress;

    address public disputeResolutionModule;

    // ============ Timeout Configuration ============
    TimeoutConfig public timeoutConfig;

    mapping(uint256 => uint256) public disputeRaisedTimestamp;
    mapping(uint256 => EscrowSettings) public escrowSettings;

    // Pull model: claimable balances (escrowId => recipient => token => amount)
    mapping(uint256 => mapping(address => mapping(address => uint256))) public claimable;

    // Phase 1: Pending settlement storage (appeal window enforcement)
    struct PendingSettlement {
        bool exists;
        bool isRelease;
        uint256 appealDeadline;
        bytes32 resolutionHash;
    }
    mapping(uint256 => PendingSettlement) public pendingSettlements;

    mapping(uint256 => address) internal snapshotResolutionModules;
    mapping(uint256 => address) internal snapshotReleaseStrategies;
    mapping(uint256 => address) internal snapshotYieldGenerationModules;
    mapping(uint256 => address) internal snapshotYieldDistributionModules;

    enum ModuleType {
        RESOLUTION,
        RELEASE,
        YIELD_GEN,
        YIELD_DIST
    }

    YieldOps public yieldOps;
    DisputeOps public disputeOps;

    PendingAddress private _pendingFeeRecipient;
    PendingUint private _pendingEscrowFee;
    PendingUint private _pendingAppealWindowDuration;

    mapping(ModuleType => PendingAddress) private _pendingModules;

    event EscrowStateChanged(
        uint256 indexed escrowId,
        EscrowState oldStatus,
        EscrowState newStatus
    );
    event EscrowTransferDisputed(
        uint256 indexed escrowId,
        address indexed from,
        address indexed to,
        uint256 amount
    );
    event EscrowTransferResolved(
        uint256 indexed escrowId,
        address indexed from,
        address indexed to,
        uint256 amount
    );
    event EscrowResolved(
        uint256 indexed escrowId,
        address indexed disputeResolver,
        bytes32 resolutionHash
    );
    event DisputeEscalated(
        uint256 indexed escrowId,
        uint8 fromLevel,
        uint8 toLevel,
        address indexed newDisputeResolver,
        address indexed escalatedBy
    );
    event EscalationFeeCollected(
        uint256 indexed escrowId,
        uint256 fee,
        address indexed feeRecipient
    );
    event EscrowTransferAutoReleased(uint256 indexed escrowId, address indexed to, uint256 amount);
    event EscrowTransferAutoCancelled(
        uint256 indexed escrowId,
        address indexed from,
        uint256 amount
    );
    event MaxDisputeDurationUpdated(uint256 newDuration);
    event DisputeAutoCancelled(
        uint256 indexed escrowId,
        address indexed from,
        uint256 amount,
        string reason
    );
    event CancelRequested(uint256 indexed escrowId, address indexed by);
    event CancelConfirmed(uint256 indexed escrowId, address indexed by);
    event DisputeOpened(
        uint256 indexed escrowId,
        address indexed by,
        address indexed disputeResolver
    );
    event TimeoutExecuted(uint256 indexed escrowId, uint8 action);
    event EscrowFeeUpdated(uint256 oldFee, uint256 newFee);
    event EscrowFeeAddressUpdated(address oldAddress, address newAddress);
    event ResolutionModuleQueued(address indexed oldModule, address indexed newModule, uint64 eta);
    event ResolutionModuleActivated(address indexed oldModule, address indexed newModule);
    event EscrowSettingsUpdated(uint256 indexed escrowId, EscrowSettings settings);
    event EscrowModuleSnapshot(
        uint256 indexed escrowId,
        address resolutionModule,
        address releaseStrategy,
        address yieldGenerationModule,
        address yieldDistributionModule
    );
    event NativeETHRecovered(address indexed recipient, uint256 amount);
    event ERC20Recovered(address indexed token, address indexed recipient, uint256 amount);
    event ClaimableBalanceSet(
        uint256 indexed escrowId,
        address indexed recipient,
        address indexed token,
        uint256 amount
    );
    event EscrowWithdrawn(
        uint256 indexed escrowId,
        address indexed recipient,
        address indexed token,
        uint256 amount
    );
    event PendingSettlementSet(uint256 indexed escrowId, bool isRelease, uint256 appealDeadline);
    event PendingSettlementCancelled(uint256 indexed escrowId);
    event PendingSettlementExecuted(uint256 indexed escrowId, bool isRelease);
    event AppealWindowDurationUpdated(uint256 newDuration);
    event TimeoutConfigUpdated(TimeoutConfig config);
    event DefaultAutoReleaseTimeUpdated(uint256 newTime);
    event DefaultAutoCancelTimeUpdated(uint256 newTime);
    event EscrowFinalized(uint256 indexed escrowId, address indexed recipient, uint256 amount);

    // ============ Pause/Unpause ============
    /**
     * @notice Pause all escrow operations
     * @dev Only ROLE_GUARDIAN can pause. Prevents new escrow creation and most operations.
     */
    function pause() public onlyRole(ROLE_GUARDIAN) {
        _pause();
    }

    /**
     * @notice Unpause escrow operations
     * @dev Only ROLE_TIMELOCK can unpause. Restores normal operation.
     */
    function unpause() public onlyRole(ROLE_TIMELOCK) {
        _unpause();
    }

    // ============ Fee Management ============
    /**
     * @notice Queue a new escrow fee recipient address
     * @param a New fee recipient address to queue
     * @dev Uses slow lane activation pattern. Requires ROLE_TIMELOCK.
     */
    function queueEscrowFeeAddress(address a) public onlyRole(ROLE_TIMELOCK) {
        _queueAddress(_pendingFeeRecipient, a);
    }

    /**
     * @notice Activate the queued fee recipient address
     * @dev Activates after timelock delay. Requires ROLE_TIMELOCK.
     */
    function activateEscrowFeeAddress() public onlyRole(ROLE_TIMELOCK) {
        escrowFeeAddress = _activateAddress(_pendingFeeRecipient);
    }

    /**
     * @notice Get pending fee recipient address information
     * @return value Pending fee recipient address
     * @return eta Timestamp when activation becomes available
     * @return exists Whether a pending address exists
     */
    function getPendingFeeRecipient() public view returns (address value, uint64 eta, bool exists) {
        return getPendingAddress(_pendingFeeRecipient);
    }

    /**
     * @notice Queue a new escrow fee percentage
     * @param f New fee in basis points (e.g., 100 = 1%)
     * @dev Uses slow lane activation pattern. Requires ROLE_TIMELOCK.
     */
    function queueEscrowFee(uint256 f) public virtual onlyRole(ROLE_TIMELOCK) {
        _queueUint(_pendingEscrowFee, f);
    }

    /**
     * @notice Activate the queued escrow fee
     * @dev Activates after timelock delay. Requires ROLE_TIMELOCK.
     */
    function activateEscrowFee() public virtual onlyRole(ROLE_TIMELOCK) {
        escrowFee = _activateUint(_pendingEscrowFee);
    }

    /**
     * @notice Get pending escrow fee information
     * @return value Pending fee in basis points
     * @return eta Timestamp when activation becomes available
     * @return exists Whether a pending fee exists
     */
    function getPendingEscrowFee()
        public
        view
        virtual
        returns (uint256 value, uint64 eta, bool exists)
    {
        return getPendingUint(_pendingEscrowFee);
    }

    // ============ Timeout Configuration ============
    /**
     * @notice Update timeout configuration atomically
     * @param config New timeout configuration
     * @dev Validates all fields and updates atomically
     */
    function setTimeoutConfig(TimeoutConfig calldata config) external onlyRole(ROLE_TIMELOCK) {
        // Validate bounds
        require(
            config.maxDisputeDuration >= 7 days && config.maxDisputeDuration <= 365 days,
            'Invalid maxDisputeDuration: must be 7-365 days'
        );
        require(
            config.appealWindowDuration >= 1 days && config.appealWindowDuration <= 7 days,
            'Invalid appealWindowDuration: must be 1-7 days'
        );

        // Validate auto times (if set)
        SettingsValidationLibrary.validateAutoRelease(config.defaultAutoReleaseTime);
        SettingsValidationLibrary.validateAutoCancel(config.defaultAutoCancelTime);

        // Store old values for event emission
        uint256 oldDefaultAutoReleaseTime = timeoutConfig.defaultAutoReleaseTime;
        uint256 oldDefaultAutoCancelTime = timeoutConfig.defaultAutoCancelTime;
        uint256 oldMaxDisputeDuration = timeoutConfig.maxDisputeDuration;
        uint256 oldAppealWindowDuration = timeoutConfig.appealWindowDuration;

        // Update struct atomically
        timeoutConfig = config;

        // Emit events
        emit TimeoutConfigUpdated(config);
        if (config.maxDisputeDuration != oldMaxDisputeDuration) {
            emit MaxDisputeDurationUpdated(config.maxDisputeDuration);
        }
        if (config.appealWindowDuration != oldAppealWindowDuration) {
            emit AppealWindowDurationUpdated(config.appealWindowDuration);
        }
        if (config.defaultAutoReleaseTime != oldDefaultAutoReleaseTime) {
            emit DefaultAutoReleaseTimeUpdated(config.defaultAutoReleaseTime);
        }
        if (config.defaultAutoCancelTime != oldDefaultAutoCancelTime) {
            emit DefaultAutoCancelTimeUpdated(config.defaultAutoCancelTime);
        }
    }

    /**
     * @notice Set default auto-cancel time for new escrows
     * @param time Timestamp for auto-cancel (0 = disabled)
     * @dev Individual escrows can override with custom settings. Requires ROLE_TIMELOCK.
     */
    function setDefaultAutoCancelTime(uint256 time) public onlyRole(ROLE_TIMELOCK) {
        SettingsValidationLibrary.validateAutoCancel(time);
        timeoutConfig.defaultAutoCancelTime = time;
        emit DefaultAutoCancelTimeUpdated(time);
    }

    /**
     * @notice Set default auto-release time for new escrows
     * @param time Timestamp for auto-release (0 = disabled)
     * @dev Individual escrows can override with custom settings. Requires ROLE_TIMELOCK.
     */
    function setDefaultAutoReleaseTime(uint256 time) public onlyRole(ROLE_TIMELOCK) {
        SettingsValidationLibrary.validateAutoRelease(time);
        timeoutConfig.defaultAutoReleaseTime = time;
        emit DefaultAutoReleaseTimeUpdated(time);
    }

    /**
     * @notice Set maximum dispute duration
     * @param duration Maximum duration in seconds (must be 7-365 days)
     * @dev Disputes that exceed this duration can be auto-cancelled. Requires ROLE_TIMELOCK.
     */
    function setMaxDisputeDuration(uint256 duration) external onlyRole(ROLE_TIMELOCK) {
        require(duration >= 7 days && duration <= 365 days, 'Invalid duration: must be 7-365 days');
        timeoutConfig.maxDisputeDuration = duration;
        emit MaxDisputeDurationUpdated(duration);
    }

    /**
     * @notice Set appeal window duration after resolution
     * @param duration Appeal window in seconds (must be 1-7 days)
     * @dev Time period during which resolutions can be appealed. Requires ROLE_TIMELOCK.
     */
    function setAppealWindowDuration(uint256 duration) external onlyRole(ROLE_TIMELOCK) {
        require(duration >= 1 days && duration <= 7 days, 'Invalid duration: must be 1-7 days');
        timeoutConfig.appealWindowDuration = duration;
        emit AppealWindowDurationUpdated(duration);
    }

    /**
     * @notice Get current timeout configuration
     * @return Current timeout configuration
     */
    function getTimeoutConfig() external view returns (TimeoutConfig memory) {
        return timeoutConfig;
    }

    // ============ Backward Compatibility Getters ============

    /**
     * @notice Get default auto-release time (backward compatibility)
     * @return Default auto-release timestamp (0 = disabled)
     * @dev Use getTimeoutConfig() for new code
     */
    function defaultAutoReleaseTime() external view returns (uint256) {
        return timeoutConfig.defaultAutoReleaseTime;
    }

    /**
     * @notice Get default auto-cancel time (backward compatibility)
     * @return Default auto-cancel timestamp (0 = disabled)
     * @dev Use getTimeoutConfig() for new code
     */
    function defaultAutoCancelTime() external view returns (uint256) {
        return timeoutConfig.defaultAutoCancelTime;
    }

    /**
     * @notice Get max dispute duration (backward compatibility)
     * @return Max dispute duration in seconds
     * @dev Use getTimeoutConfig() for new code
     */
    function maxDisputeDuration() external view returns (uint256) {
        return timeoutConfig.maxDisputeDuration;
    }

    /**
     * @notice Get appeal window duration (backward compatibility)
     * @return Appeal window duration in seconds
     * @dev Use getTimeoutConfig() for new code
     */
    function appealWindowDuration() external view returns (uint256) {
        return timeoutConfig.appealWindowDuration;
    }

    // ============ Module Management ============
    /**
     * @notice Queue a new resolution module
     * @param m Address of the new resolution module to queue
     * @dev Uses slow lane activation pattern. Requires ROLE_TIMELOCK.
     */
    function queueResolutionModule(address m) public onlyRole(ROLE_TIMELOCK) {
        _queueAddress(_pendingModules[ModuleType.RESOLUTION], m);
        emit ResolutionModuleQueued(
            disputeResolutionModule,
            m,
            _pendingModules[ModuleType.RESOLUTION].eta
        );
    }

    /**
     * @notice Activate the queued resolution module
     * @dev Activates after timelock delay. Requires ROLE_TIMELOCK.
     */
    function activateResolutionModule() public onlyRole(ROLE_TIMELOCK) {
        address oldModule = disputeResolutionModule;
        disputeResolutionModule = _activateAddress(_pendingModules[ModuleType.RESOLUTION]);
        emit ResolutionModuleActivated(oldModule, disputeResolutionModule);
    }

    /**
     * @notice Get pending resolution module information
     * @return value Pending resolution module address
     * @return eta Timestamp when activation becomes available
     * @return exists Whether a pending module exists
     */
    function getPendingResolutionModule()
        public
        view
        returns (address value, uint64 eta, bool exists)
    {
        return getPendingAddress(_pendingModules[ModuleType.RESOLUTION]);
    }

    // ============ Escrow Creation ============
    /**
     * @notice Create a new escrow transfer
     * @param token Token address (ERC20 for EscrowVault, address(this) for EscrowableERC20)
     * @param to Recipient address
     * @param amount Total amount to escrow (fee will be deducted)
     * @param settings Escrow configuration (resolver, yield, auto-times, etc.)
     * @return escrowId The escrow ID (array index)
     * @dev The escrow ID is the array index. Fee is deducted from amount.
     */
    function createEscrow(
        address token,
        address to,
        uint256 amount,
        EscrowSettings memory settings
    ) public nonReentrant whenNotPaused returns (uint256) {
        if (amount == 0) revert InvalidAmount('Amount > 0');
        _validateEscrowSettings(settings);

        uint256 workflowId = escrowTransfers.length; // Array index IS the workflowId
        uint256 fee = (amount * escrowFee) / ESCROW_FEE_DENOMINATOR;
        uint256 amountAfterFee = amount - fee;

        _pullTokens(token, _msgSender(), amount);

        address defaultResolver = _getDisputeResolverForNewEscrow(
            workflowId,
            token,
            _msgSender(),
            to,
            amountAfterFee
        );

        escrowTransfers.push(
            EscrowCreationLibrary.createEscrowTransferStruct(
                token,
                to,
                _msgSender(),
                amountAfterFee,
                defaultResolver
            )
        );

        _updateEscrowBalance(token, amountAfterFee, true);
        _recordFee(token, fee);
        _applyEscrowSettings(workflowId, settings); // calldata -> memory conversion happens automatically
        _snapshotModulesForEscrow(workflowId);

        if (settings.yieldEnabled) {
            IYieldGenerationModule genModule = _getYieldGenerationModule(workflowId);
            if (address(genModule) != address(0) && genModule.isTokenSupported(token))
                _depositForYield(genModule, workflowId, token, amountAfterFee);
        }

        emit EscrowStateChanged(workflowId, EscrowState.PENDING, EscrowState.PENDING);
        _emitEscrowTransferCreated(workflowId, token, _msgSender(), to, amount);

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
        address relStrat = address(_getReleaseStrategy(workflowId));
        address genMod = address(_getYieldGenerationModule(workflowId));
        address distMod = address(_getYieldDistributionModule(workflowId));

        snapshotResolutionModules[workflowId] = resModule;
        snapshotReleaseStrategies[workflowId] = relStrat;
        snapshotYieldGenerationModules[workflowId] = genMod;
        snapshotYieldDistributionModules[workflowId] = distMod;

        emit EscrowModuleSnapshot(workflowId, resModule, relStrat, genMod, distMod);
    }

    // ============ Escrow Actions ============
    /**
     * @notice Automatically execute timed actions (auto-release or auto-cancel)
     * @param workflowId The escrow ID
     * @return executed Whether an action was executed
     * @dev Checks if auto-release or auto-cancel time has passed and executes if so.
     *      Can be called by anyone to trigger automatic actions.
     */
    function automateTimedActions(uint256 workflowId) public nonReentrant returns (bool) {
        _validateWorkflowId(workflowId);
        EscrowTransfer storage et = escrowTransfers[workflowId];

        // Check for pending settlement execution (appeal window enforcement)
        PendingSettlement storage pending = pendingSettlements[workflowId];
        if (
            pending.exists &&
            block.timestamp >= pending.appealDeadline &&
            et.escrowState == EscrowState.DISPUTED
        ) {
            // Execute pending settlement
            bool isRelease = pending.isRelease;
            delete pendingSettlements[workflowId];

            // Optionally finalize dispute in resolution module
            IResolutionModule resolutionModule = _getResolutionModule(workflowId);
            if (address(resolutionModule) != address(0)) {
                (bool success, ) = address(resolutionModule).call(
                    abi.encodeWithSignature('finalizeDispute(uint256)', workflowId)
                );
                success; // Ignore failure
            }

            // Execute the settlement
            if (isRelease) {
                _releaseEscrowTransfer(workflowId);
            } else {
                _cancelAndRefund(workflowId);
            }

            emit PendingSettlementExecuted(workflowId, isRelease);
            return true;
        }

        // Check for auto-release/auto-cancel (only for PENDING state)
        if (et.escrowState != EscrowState.PENDING) return false;
        if (et.autoReleaseTime > 0 && block.timestamp >= et.autoReleaseTime) {
            _releaseEscrowTransfer(workflowId);
            emit TimeoutExecuted(workflowId, 0);
            emit EscrowTransferAutoReleased(workflowId, et.to, et.amountAfterFee);
            return true;
        } else if (et.autoCancelTime > 0 && block.timestamp >= et.autoCancelTime) {
            _cancelAndRefund(workflowId);
            emit TimeoutExecuted(workflowId, 1);
            emit EscrowTransferAutoCancelled(workflowId, et.from, et.amountAfterFee);
            return true;
        }
        return false;
    }

    function _cancelWorkflow(uint256 id, address caller, bool isSender) internal returns (bool) {
        EscrowTransfer storage et = escrowTransfers[id];
        if (isSender) et.senderStatus = SenderStatus.AGREE_TO_CANCEL;
        else et.recipientStatus = RecipientStatus.AGREE_TO_CANCEL;
        emit CancelRequested(id, caller);
        if (
            et.senderStatus == SenderStatus.AGREE_TO_CANCEL &&
            et.recipientStatus == RecipientStatus.AGREE_TO_CANCEL
        ) {
            emit CancelConfirmed(id, caller);
            _cancelAndRefund(id);
        }
        return true;
    }

    /**
     * @notice Recipient requests to cancel the escrow
     * @param workflowId The escrow ID
     * @return success Whether the cancel request was processed
     * @dev Requires both sender and recipient to agree for cancellation to execute.
     */
    function recipientCancel(uint256 workflowId) public returns (bool) {
        _validateWorkflowId(workflowId);
        EscrowTransfer storage et = escrowTransfers[workflowId];
        if (et.to != _msgSender()) revert NotRecipient(workflowId, _msgSender(), et.to);
        if (et.escrowState != EscrowState.PENDING)
            revert TransferNotPending(workflowId, et.escrowState);
        return _cancelWorkflow(workflowId, _msgSender(), false);
    }

    /**
     * @notice Sender requests to cancel the escrow
     * @param workflowId The escrow ID
     * @return success Whether the cancel request was processed
     * @dev Requires both sender and recipient to agree for cancellation to execute.
     */
    function senderCancel(uint256 workflowId) public returns (bool) {
        _validateWorkflowId(workflowId);
        EscrowTransfer storage et = escrowTransfers[workflowId];
        if (et.from != _msgSender()) revert NotSender(workflowId, _msgSender(), et.from);
        if (et.escrowState != EscrowState.PENDING)
            revert TransferNotPending(workflowId, et.escrowState);
        return _cancelWorkflow(workflowId, _msgSender(), true);
    }

    // ============ Dispute Management ============
    /**
     * @notice Automatically cancel a disputed escrow that has timed out
     * @param workflowId The escrow ID
     * @return success Whether the auto-cancel was executed
     * @dev Can be called by anyone once maxDisputeDuration has passed.
     *      Refunds the full amount to the sender.
     */
    function autoCancelDisputedEscrow(uint256 workflowId) external nonReentrant returns (bool) {
        _validateWorkflowId(workflowId);
        EscrowTransfer storage et = escrowTransfers[workflowId];
        require(et.escrowState == EscrowState.DISPUTED, 'Not in dispute');
        uint256 ts = disputeRaisedTimestamp[workflowId];
        require(ts > 0 && block.timestamp >= ts + timeoutConfig.maxDisputeDuration, 'T');
        address from = et.from;
        uint256 amt = et.amountAfterFee;
        _cancelAndRefund(workflowId);
        et.escrowState = EscrowState.RESOLVED;
        delete disputeRaisedTimestamp[workflowId];
        emit EscrowStateChanged(workflowId, EscrowState.DISPUTED, EscrowState.RESOLVED);
        emit DisputeAutoCancelled(workflowId, from, amt, 'Timeout');
        emit EscrowTransferResolved(workflowId, from, et.to, amt);
        return true;
    }

    /**
     * @notice Check if a dispute has timed out
     * @param workflowId The escrow ID
     * @return isTimedOut Whether the dispute has exceeded maxDisputeDuration
     * @return timeRemaining Seconds remaining until timeout (0 if already timed out)
     */
    function isDisputeTimedOut(
        uint256 workflowId
    ) external view returns (bool isTimedOut, uint256 timeRemaining) {
        _validateWorkflowId(workflowId);
        (bool timedOut, uint256 remaining) = DisputeManagementLibrary.isTimedOut(
            workflowId,
            escrowTransfers[workflowId].escrowState,
            disputeRaisedTimestamp[workflowId],
            timeoutConfig.maxDisputeDuration
        );
        return (timedOut, remaining);
    }

    /**
     * @notice Raise a dispute for an escrow
     * @param workflowId The escrow ID
     * @return success Whether the dispute was raised successfully
     * @dev Can be called by either sender or recipient. Transitions escrow to DISPUTED state.
     */
    function raiseDispute(uint256 workflowId) public returns (bool) {
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
        emit EscrowTransferDisputed(workflowId, et.from, et.to, et.amountAfterFee);
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

        // Call incentive module onDisputeOpened hook
        IResolutionModule resolutionModule = _getResolutionModule(workflowId);
        if (address(resolutionModule) != address(0)) {
            // Try to get incentive module from resolution module (DecentralizedResolutionModule has it as public)
            try this._getIncentiveModuleFromResolution(address(resolutionModule)) returns (
                IIncentiveModule incentiveMod
            ) {
                if (address(incentiveMod) != address(0)) {
                    // Calculate escrow fee: fee = amount * escrowFee / ESCROW_FEE_DENOMINATOR
                    // Original amount = amountAfterFee + fee, so: fee = (amountAfterFee * escrowFee) / (ESCROW_FEE_DENOMINATOR - escrowFee)
                    uint256 originalAmount = et.amountAfterFee +
                        ((et.amountAfterFee * escrowFee) / (ESCROW_FEE_DENOMINATOR - escrowFee));
                    uint256 escrowFeeAmount = (originalAmount * escrowFee) / ESCROW_FEE_DENOMINATOR;
                    try
                        incentiveMod.onDisputeOpened(
                            workflowId,
                            et.token,
                            originalAmount,
                            escrowFeeAmount,
                            0
                        )
                    {} catch {
                        /* Non-critical: Continue if incentive module call fails */
                    }
                }
            } catch {
                /* Non-critical: Continue if resolution module doesn't expose incentive module */
            }
        }

        return true;
    }

    /**
     * @notice Helper function to get incentive module from resolution module
     * @dev Used to access public incentiveModule variable from DecentralizedResolutionModule
     */
    function _getIncentiveModuleFromResolution(
        address resolutionModule
    ) external view returns (IIncentiveModule) {
        // DecentralizedResolutionModule has incentiveModule as public, so we can read it
        (bool success, bytes memory data) = resolutionModule.staticcall(
            abi.encodeWithSignature('incentiveModule()')
        );
        if (success && data.length >= 32) {
            address incentiveModuleAddr = abi.decode(data, (address));
            return IIncentiveModule(incentiveModuleAddr);
        }
        return IIncentiveModule(address(0));
    }

    /**
     * @notice Escalate a dispute to a higher resolution level
     * @param workflowId The escrow ID
     * @return success Whether escalation succeeded
     * @return newDisputeResolver Address of the new resolver
     * @return newLevel New escalation level
     * @dev Requires payment of escalation fee (if applicable). Most modules now use bonds instead.
     */
    function escalateDispute(
        uint256 workflowId
    )
        public
        payable
        nonReentrant
        returns (bool success, address newDisputeResolver, uint8 newLevel)
    {
        _validateWorkflowId(workflowId);
        EscrowTransfer storage et = escrowTransfers[workflowId];
        if (address(disputeOps) == address(0)) revert('!Ops');
        IResolutionModule resolutionModule = _getResolutionModule(workflowId);

        // Cancel pending settlement if exists
        if (pendingSettlements[workflowId].exists) {
            delete pendingSettlements[workflowId];
            emit PendingSettlementCancelled(workflowId);
        }

        // Get escalation info via disputeOps (which calls canEscalate and executeEscalation)
        // Note: Escalation now uses bonds instead of fees, so executeEscalation should succeed if bond is deposited
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
        if (!result.success) revert(result.failureReason);

        // Legacy fee handling (for backward compatibility with modules that still use fees)
        // Most modules now use escalation bonds instead of fees
        (bool feeValid, uint256 excess) = disputeOps.validateEscalationFee(
            result.escalationFee,
            msg.value
        );
        if (!feeValid) revert InvalidAmount('Fee');

        // Handle escalation bond (DR v2) - bond amount is returned as escalationFee when bonds are enabled
        bool bondCollected = false;
        if (result.escalationFee > 0) {
            // Check if this is a bond (via getRequiredAppealBond) or legacy fee
            try
                resolutionModule.getRequiredAppealBond(
                    workflowId,
                    result.currentLevel,
                    EscrowEncodingLibrary.encodeEscrowTransferData(
                        et.token,
                        et.from,
                        et.to,
                        et.amountAfterFee
                    )
                )
            returns (uint256 bondAmount, address bondToken) {
                if (bondAmount > 0 && bondAmount == result.escalationFee) {
                    // This is a bond, not a fee - record it in incentive module
                    bondCollected = true;
                    // Transfer bond to incentive module (or escrow contract holds it)
                    // For now, we'll record the bond and the incentive module will handle custody
                    try this._getIncentiveModuleFromResolution(address(resolutionModule)) returns (
                        IIncentiveModule incentiveMod
                    ) {
                        if (address(incentiveMod) != address(0)) {
                            // Bond token is ETH (address(0)) or ERC20
                            if (bondToken == address(0)) {
                                // ETH bond - send with call (recordAppealBond is now payable)
                                // Extract exact bond amount from msg.value
                                uint256 ethToSend = bondAmount;
                                if (msg.value > bondAmount) {
                                    ethToSend = bondAmount; // Use exact amount, refund excess later
                                }
                                if (ethToSend > 0) {
                                    // Call recordAppealBond with ETH value
                                    // Note: We need to use a low-level call to forward msg.value
                                    (bool s, ) = address(incentiveMod).call{value: ethToSend}(
                                        abi.encodeWithSelector(
                                            IIncentiveModule.recordAppealBond.selector,
                                            workflowId,
                                            _msgSender(),
                                            ethToSend,
                                            bondToken,
                                            result.newLevel
                                        )
                                    );
                                    if (!s) {
                                        // If call fails, try legacy pattern (transfer then call)
                                        (bool transferSuccess, ) = payable(address(incentiveMod))
                                            .call{value: ethToSend}('');
                                        if (transferSuccess) {
                                            try
                                                incentiveMod.recordAppealBond(
                                                    workflowId,
                                                    _msgSender(),
                                                    ethToSend,
                                                    bondToken,
                                                    result.newLevel
                                                )
                                            {} catch {}
                                        }
                                    }
                                }
                            } else {
                                // ERC20 bond - transfer to incentive module first, then record
                                // Escrow contract transfers tokens to incentive module
                                IERC20(bondToken).safeTransfer(address(incentiveMod), bondAmount);
                                // Then record (function will verify balance increase)
                                try
                                    incentiveMod.recordAppealBond(
                                        workflowId,
                                        _msgSender(),
                                        bondAmount,
                                        bondToken,
                                        result.newLevel
                                    )
                                {} catch {}
                            }
                        }
                    } catch {}
                }
            } catch {}

            // Legacy fee handling (if not a bond)
            if (!bondCollected && result.escalationFee > 0) {
                if (escrowFeeAddress == address(0)) revert InvalidAddress('Fee', address(0));
                (bool s, ) = payable(escrowFeeAddress).call{value: result.escalationFee}('');
                require(s, 'F');
                emit EscalationFeeCollected(workflowId, result.escalationFee, escrowFeeAddress);

                // Mark escalation fee as paid in resolution module (for legacy modules)
                // Use low-level call since not all modules implement this function
                // Note: Return value ignored as this is optional functionality
                (bool callSuccess, ) = address(resolutionModule).call(
                    abi.encodeWithSignature(
                        'markEscalationFeePaid(uint256,uint256)',
                        workflowId,
                        result.escalationFee
                    )
                );
                callSuccess; // Silence unused variable warning
            }
        }

        // computeEscalation already called executeEscalation internally and succeeded
        // Use the result from computeEscalation instead of calling again
        address newResolver = result.newResolver;
        uint8 newLevel_ = result.newLevel;

        // Update escrow state with new resolver
        et.disputeResolver = newResolver;
        if (excess > 0) {
            (bool s, ) = payable(_msgSender()).call{value: excess}('');
            require(s, 'R');
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

        // Authorization check
        if (!_isAuthorizedDisputeResolver(workflowId, _msgSender()))
            revert NotAuthorizedResolver(_msgSender(), et.disputeResolver);

        // State check
        if (et.escrowState != EscrowState.DISPUTED)
            revert TransferNotInDispute(workflowId, et.escrowState);

        // Record resolution first (sets appeal deadline in module)
        // Note: Always use et.amountAfterFee (full resolution only) - used in _releaseEscrowTransfer/_cancelAndRefund
        _recordResolutionOutcome(workflowId, _msgSender(), isRelease, resolutionHash);
        emit EscrowResolved(workflowId, _msgSender(), resolutionHash);

        // Query appeal deadline from resolution module
        // For DecentralizedResolutionModule, this is stored in DisputeMetadata.appealDeadline[currentRound]
        // For other modules, fall back to timeoutConfig.appealWindowDuration
        uint256 appealDeadline = 0;
        bool isFinalRound = false;
        IResolutionModule resolutionModule = _getResolutionModule(workflowId);

        if (address(resolutionModule) != address(0)) {
            // Try to get appeal deadline and current round from module
            // Use staticcall to query view function
            (bool success, bytes memory data) = address(resolutionModule).staticcall(
                abi.encodeWithSignature('getAppealDeadlineAndRound(uint256)', workflowId)
            );

            if (success && data.length > 0) {
                // Decode return values: (uint256 appealDeadline, uint8 currentRound, bool isFinalRound)
                (appealDeadline, , isFinalRound) = abi.decode(data, (uint256, uint8, bool));
            } else {
                // Module doesn't support getAppealDeadlineAndRound - fallback to global config
                appealDeadline = block.timestamp + timeoutConfig.appealWindowDuration;
            }
        } else {
            // No resolution module - use global appeal window duration
            appealDeadline = block.timestamp + timeoutConfig.appealWindowDuration;
        }

        // If final round (MAX_ROUND), execute immediately (no appeal window)
        if (isFinalRound || appealDeadline == 0) {
            // Execute immediately - no appeal window for final round
            if (isRelease) {
                _releaseEscrowTransfer(workflowId);
            } else {
                _cancelAndRefund(workflowId);
            }
            return true;
        }

        // Store pending settlement (appeal window enforcement)
        // Transfer will be executed after appeal window expires via executePendingSettlement()
        pendingSettlements[workflowId] = PendingSettlement({
            exists: true,
            isRelease: isRelease,
            appealDeadline: appealDeadline,
            resolutionHash: resolutionHash
        });

        // Keep state as DISPUTED (not RESOLVED yet - will be finalized after appeal window)
        emit PendingSettlementSet(workflowId, isRelease, appealDeadline);

        return true;
    }

    /**
     * @notice Execute pending settlement after appeal window expires
     * @param workflowId The escrow workflow ID
     * @dev Can be called by anyone once appeal window has expired
     *      Executes the pending release or cancel that was stored during resolution
     *      Optionally finalizes the dispute in the resolution module if not already finalized
     */
    function executePendingSettlement(uint256 workflowId) external nonReentrant {
        _validateWorkflowId(workflowId);
        EscrowTransfer storage et = escrowTransfers[workflowId];
        PendingSettlement storage pending = pendingSettlements[workflowId];

        // Verify pending settlement exists
        require(pending.exists, 'No pending settlement');

        // Verify appeal window has expired
        require(block.timestamp >= pending.appealDeadline, 'Appeal window not expired');

        // Verify state is still DISPUTED (not already executed or escalated)
        require(et.escrowState == EscrowState.DISPUTED, 'Not in disputed state');

        // Clear pending settlement before execution (prevent reentrancy)
        bool isRelease = pending.isRelease;
        delete pendingSettlements[workflowId];

        // Optionally finalize dispute in resolution module if supported
        // This ensures appeal bonds are distributed
        IResolutionModule resolutionModule = _getResolutionModule(workflowId);
        if (address(resolutionModule) != address(0)) {
            // Try to call finalizeDispute if it exists (DecentralizedResolutionModule)
            // This is a best-effort call - if it fails, we still execute the settlement
            (bool success, ) = address(resolutionModule).call(
                abi.encodeWithSignature('finalizeDispute(uint256)', workflowId)
            );
            // Ignore failure - settlement will execute regardless
            success;
        }

        // Execute the settlement
        if (isRelease) {
            _releaseEscrowTransfer(workflowId);
        } else {
            _cancelAndRefund(workflowId);
        }

        emit PendingSettlementExecuted(workflowId, isRelease);
    }

    /**
     * @notice Get pending settlement information
     * @param workflowId The escrow workflow ID
     * @return exists Whether a pending settlement exists
     * @return isRelease True if pending release, false if pending cancel
     * @return appealDeadline Timestamp when appeal window expires
     * @return canExecute True if appeal window has expired and settlement can be executed
     */
    function getPendingSettlement(
        uint256 workflowId
    ) external view returns (bool exists, bool isRelease, uint256 appealDeadline, bool canExecute) {
        PendingSettlement storage pending = pendingSettlements[workflowId];
        exists = pending.exists;
        if (exists) {
            isRelease = pending.isRelease;
            appealDeadline = pending.appealDeadline;
            canExecute = block.timestamp >= appealDeadline;
        }
    }

    /**
     * @notice Cancel dispute resolution - refund full amount to sender
     * @param workflowId The escrow workflow ID
     * @param resolutionHash Hash of resolution details (for offchain verification)
     * @return success True if resolution executed successfully
     */
    function cancelAsDisputeResolver(
        uint256 workflowId,
        bytes32 resolutionHash
    ) public nonReentrant returns (bool) {
        return _executeResolution(workflowId, false, resolutionHash);
    }

    /**
     * @notice Release dispute resolution - release full amount to recipient
     * @param workflowId The escrow workflow ID
     * @param resolutionHash Hash of resolution details (for offchain verification)
     * @return success True if resolution executed successfully
     */
    function releaseAsDisputeResolver(
        uint256 workflowId,
        bytes32 resolutionHash
    ) public nonReentrant returns (bool) {
        return _executeResolution(workflowId, true, resolutionHash);
    }

    function _isAuthorizedDisputeResolver(
        uint256 workflowId,
        address disputeResolver
    ) internal view returns (bool) {
        EscrowTransfer storage et = escrowTransfers[workflowId];
        address snap = snapshotResolutionModules[workflowId];
        if (snap != address(0)) {
            try
                IResolutionModule(snap).isAuthorizedDisputeResolver(
                    workflowId,
                    disputeResolver,
                    EscrowEncodingLibrary.encodeEscrowTransferData(
                        et.token,
                        et.from,
                        et.to,
                        et.amountAfterFee
                    )
                )
            returns (bool authorized, uint8) {
                if (authorized) return true;
            } catch {}
        }
        return disputeResolver == et.disputeResolver;
    }

    function _getDisputeResolverForNewEscrow(
        uint256 workflowId,
        address token,
        address from,
        address to,
        uint256 amount
    ) internal view virtual returns (address) {
        IResolutionModule module = _getResolutionModule(workflowId);
        if (address(module) == address(0)) revert ResolutionModuleNotConfigured();
        try
            module.getDisputeResolver(
                workflowId,
                EscrowEncodingLibrary.encodeEscrowTransferData(token, from, to, amount)
            )
        returns (address disputeResolver, uint8) {
            if (disputeResolver == address(0)) revert ResolutionModuleReturnedZeroAddress();
            return disputeResolver;
        } catch {
            revert ResolutionModuleCallFailed();
        }
    }

    function _applyEscrowSettings(uint256 workflowId, EscrowSettings memory settings) internal {
        EscrowTransfer storage et = escrowTransfers[workflowId];
        if (settings.customResolver != address(0)) et.disputeResolver = settings.customResolver;
        bool def = (settings.autoReleaseTime == 0 && settings.autoCancelTime == 0);
        et.autoReleaseTime = settings.autoReleaseTime > 0
            ? uint64(settings.autoReleaseTime)
            : (def ? uint64(timeoutConfig.defaultAutoReleaseTime) : 0);
        et.autoCancelTime = settings.autoCancelTime > 0
            ? uint64(settings.autoCancelTime)
            : (def ? uint64(timeoutConfig.defaultAutoCancelTime) : 0);
        escrowSettings[workflowId] = settings;
        emit EscrowSettingsUpdated(workflowId, settings);
    }

    // ============ Escrow Settings ============
    /**
     * @notice Get default escrow settings
     * @return Default escrow settings (all zeros/defaults)
     */
    function getDefaultSettings() public pure returns (EscrowSettings memory) {
        return SettingsValidationLibrary.getDefaultSettings();
    }

    /**
     * @notice Update escrow settings for an existing escrow
     * @param workflowId The escrow ID
     * @param settings New escrow settings
     * @dev Can only be called by sender or ROLE_TIMELOCK. Escrow must be PENDING.
     */
    function updateEscrowSettings(uint256 workflowId, EscrowSettings memory settings) public {
        _validateWorkflowId(workflowId);
        EscrowTransfer storage et = escrowTransfers[workflowId];
        if (et.from != _msgSender() && !hasRole(ROLE_TIMELOCK, _msgSender()))
            revert NotParticipant(workflowId, _msgSender(), et.from, et.to);
        if (et.escrowState != EscrowState.PENDING)
            revert TransferNotPending(workflowId, et.escrowState);
        _validateEscrowSettings(settings);
        _applyEscrowSettings(workflowId, settings);
    }

    /**
     * @notice Get escrow settings for an escrow
     * @param workflowId The escrow ID
     * @return Escrow settings
     */
    function getEscrowSettings(uint256 workflowId) public view returns (EscrowSettings memory) {
        _validateWorkflowId(workflowId);
        return escrowSettings[workflowId];
    }

    /**
     * @notice Get total amount deposited (after fee) for an escrow
     * @param workflowId The escrow ID
     * @return Total amount deposited after fee deduction
     */
    function getTotalDeposited(uint256 workflowId) public view returns (uint256) {
        _validateWorkflowId(workflowId);
        return escrowTransfers[workflowId].amountAfterFee;
    }

    // ============ View Functions ============
    /**
     * @notice Get full escrow transfer data
     * @param id The escrow ID
     * @return Complete escrow transfer struct
     */
    function getEscrowTransfer(uint256 id) public view returns (EscrowTransfer memory) {
        return escrowTransfers[id];
    }

    /**
     * @notice Get total number of escrows created
     * @return Total count of escrows
     */
    function getEscrowCount() public view returns (uint256) {
        return escrowTransfers.length;
    }

    /**
     * @notice Get escrow status information
     * @param workflowId The escrow ID
     * @return status Current escrow state
     * @return isActive Whether escrow is active (PENDING or DISPUTED)
     * @return isPending Whether escrow is pending
     */
    function getEscrowStatusInfo(
        uint256 workflowId
    ) public view returns (EscrowState status, bool isActive, bool isPending) {
        if (workflowId >= escrowTransfers.length) {
            return (EscrowState.NONE, false, false);
        }
        status = escrowTransfers[workflowId].escrowState;
        isPending = (status == EscrowState.PENDING);
        isActive = (status == EscrowState.PENDING || status == EscrowState.DISPUTED);
    }
    /**
     * @notice Get escrow participant addresses
     * @param workflowId The escrow ID
     * @return from Sender address
     * @return to Recipient address
     */
    function getEscrowParticipants(
        uint256 workflowId
    ) public view returns (address from, address to) {
        return (escrowTransfers[workflowId].from, escrowTransfers[workflowId].to);
    }

    /**
     * @notice Get snapshotted resolution module for an escrow
     * @param id The escrow ID
     * @return Resolution module address at time of escrow creation
     */
    function getSnapshotResolutionModule(uint256 id) public view returns (address) {
        return snapshotResolutionModules[id];
    }

    /**
     * @notice Get snapshotted release strategy for an escrow
     * @param id The escrow ID
     * @return Release strategy address at time of escrow creation
     */
    function getSnapshotReleaseStrategy(uint256 id) public view returns (address) {
        return snapshotReleaseStrategies[id];
    }

    /**
     * @notice Get snapshotted yield generation module for an escrow
     * @param id The escrow ID
     * @return Yield generation module address at time of escrow creation
     */
    function getSnapshotYieldGenerationModule(uint256 id) public view returns (address) {
        return snapshotYieldGenerationModules[id];
    }

    /**
     * @notice Get snapshotted yield distribution module for an escrow
     * @param id The escrow ID
     * @return Yield distribution module address at time of escrow creation
     */
    function getSnapshotYieldDistributionModule(uint256 id) public view returns (address) {
        return snapshotYieldDistributionModules[id];
    }
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return
            interfaceId == RESOLUTION_INTERFACE_V1 ||
            interfaceId == type(IERC165).interfaceId ||
            super.supportsInterface(interfaceId);
    }

    // ============ Withdrawal ============
    /**
     * @notice Withdraw claimable escrow funds (pull model)
     * @param workflowId The escrow ID
     * @return amount Amount withdrawn
     * @dev Pull model: Parties call this to withdraw funds after escrow is finalized
     *      Idempotent: Sets claimable to 0 before transfer (checks-effects-interactions pattern)
     *      Uses escrow's token (single token per escrow)
     */
    function withdrawEscrow(uint256 workflowId) external nonReentrant returns (uint256) {
        _validateWorkflowId(workflowId);
        EscrowTransfer storage et = escrowTransfers[workflowId];

        // Verify escrow is finalized (or released/cancelled)
        require(
            et.escrowState == EscrowState.RESOLVED ||
                et.escrowState == EscrowState.RELEASED ||
                et.escrowState == EscrowState.REFUNDED,
            'Not finalized'
        );

        address token = et.token; // Single token per escrow
        uint256 amount = claimable[workflowId][msg.sender][token];
        require(amount > 0, 'No claimable balance');

        // Idempotent: set to 0 before transfer (checks-effects-interactions)
        claimable[workflowId][msg.sender][token] = 0;

        // Note: Balance already updated during finalization, don't double-subtract
        _transferTokens(token, msg.sender, amount);

        emit EscrowWithdrawn(workflowId, msg.sender, token, amount);
        return amount;
    }

    // ============ Recovery ============
    /**
     * @notice Recover native ETH sent to the contract
     * @param recipient Address to receive the recovered ETH
     * @param amount Amount of ETH to recover
     * @return success Whether recovery succeeded
     * @dev Only ROLE_TIMELOCK can recover. Use for emergency recovery of stuck funds.
     */
    function recoverNativeETH(
        address recipient,
        uint256 amount
    ) external onlyRole(ROLE_TIMELOCK) nonReentrant returns (bool) {
        uint256 rec = RecoveryLibrary.recoverNativeETH(recipient, amount, address(this).balance);
        emit NativeETHRecovered(recipient, rec);
        return true;
    }

    /**
     * @notice Recover ERC20 tokens sent to the contract
     * @param token Token address to recover
     * @param recipient Address to receive the recovered tokens
     * @param amount Amount of tokens to recover
     * @return success Whether recovery succeeded
     * @dev Only ROLE_TIMELOCK can recover. Use for emergency recovery of stuck funds.
     */
    function recoverERC20(
        address token,
        address recipient,
        uint256 amount
    ) external virtual onlyRole(ROLE_TIMELOCK) nonReentrant returns (bool) {
        uint256 rec = RecoveryLibrary.recoverERC20(
            token,
            recipient,
            amount,
            IERC20(token).balanceOf(address(this))
        );
        emit ERC20Recovered(token, recipient, rec);
        return true;
    }

    // ============ Internal Helpers ============
    function _validateWorkflowId(uint256 workflowId) internal view {
        if (workflowId >= escrowTransfers.length) {
            revert InvalidWorkflowId(workflowId, escrowTransfers.length);
        }
    }

    function _requirePending(uint256 workflowId) internal view {
        _validateWorkflowId(workflowId);
        if (escrowTransfers[workflowId].escrowState != EscrowState.PENDING) {
            revert TransferNotPending(workflowId, EscrowState.PENDING);
        }
    }

    function _validateEscrowSettings(EscrowSettings memory settings) internal view {
        SettingsValidationLibrary.validateEscrowSettings(settings, block.timestamp);
    }

    function _cancelAndRefund(uint256 workflowId) internal {
        EscrowTransfer storage et = escrowTransfers[workflowId];
        uint256 amount = et.amountAfterFee;
        address from = et.from;
        address token = et.token;
        EscrowState oldStatus = StateManagementLibrary.transitionToRefunded(et, workflowId);
        emit EscrowStateChanged(workflowId, oldStatus, EscrowState.REFUNDED);
        if (address(yieldOps) != address(0)) {
            IYieldGenerationModule genModule = _getYieldGenerationModule(workflowId);
            IYieldDistributionModule distModule = _getYieldDistributionModule(workflowId);
            try
                yieldOps.handleFullYield(genModule, distModule, workflowId, token, amount)
            {} catch {}
        }
        _updateEscrowBalance(token, amount, false);
        // Pull model: Set claimable balance instead of transferring tokens
        claimable[workflowId][from][token] += amount;
        emit ClaimableBalanceSet(workflowId, from, token, amount);
        _emitEscrowTransferCancelled(workflowId, token, from, amount);
    }

    function _releaseEscrowTransfer(uint256 workflowId) internal {
        EscrowTransfer storage et = escrowTransfers[workflowId];
        uint256 amount = et.amountAfterFee;
        address to = et.to;
        address token = et.token;
        EscrowState oldStatus = StateManagementLibrary.transitionToReleased(et, workflowId);
        emit EscrowStateChanged(workflowId, oldStatus, EscrowState.RELEASED);
        if (address(yieldOps) != address(0)) {
            IYieldGenerationModule genModule = _getYieldGenerationModule(workflowId);
            IYieldDistributionModule distModule = _getYieldDistributionModule(workflowId);
            try
                yieldOps.handleFullYield(genModule, distModule, workflowId, token, amount)
            {} catch {}
        }
        _updateEscrowBalance(token, amount, false);
        // Pull model: Set claimable balance instead of transferring tokens
        claimable[workflowId][to][token] += amount;
        emit ClaimableBalanceSet(workflowId, to, token, amount);
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
        // BaseEscrow: return snapshotted module if exists, otherwise base-level module
        address snap = snapshotResolutionModules[workflowId];
        if (snap != address(0)) {
            return IResolutionModule(snap);
        }
        return IResolutionModule(disputeResolutionModule);
    }

    // Resolution outcome enum (matches DecentralizedResolverStructs.ResolutionOutcome)
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
        // Note: resolutionHash is available via EscrowResolved event if modules need it
        // Current module interface doesn't include it, but can be added in future versions
        ResolutionOutcome outcome = isRelease
            ? ResolutionOutcome.RELEASE
            : ResolutionOutcome.CANCEL;
        uint256 resolutionTime = block.timestamp;
        (bool success, ) = module.call(
            abi.encodeWithSignature(
                'recordResolution(uint256,address,uint8,uint256)',
                workflowId,
                disputeResolver,
                uint8(outcome),
                resolutionTime
            )
        );
        success;
    }
}
