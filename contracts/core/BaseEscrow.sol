// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.33;

import "@openzeppelin/contracts/utils/Context.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import "@openzeppelin/contracts/utils/introspection/ERC165.sol";
// IERC20Permit removed for contract size reduction - see docs/PERMIT_FUNCTIONALITY_REMOVED.md
import "../interfaces/IResolver.sol";
import "../shared/interfaces/IResolutionModule.sol";
import "../interfaces/IYieldGenerationModule.sol";
import "../interfaces/IYieldDistributionModule.sol";
import "../libraries/SettingsValidationLibrary.sol";
// YieldDistributionLibrary removed - yield distribution now handled entirely by module
import "../libraries/EscrowEncodingLibrary.sol";
import "../libraries/ResolverLogicLibrary.sol";
import "../libraries/RecoveryLibrary.sol";
import "../libraries/ModuleProposalLibrary.sol";
import "../libraries/ResolverActionLibrary.sol";
import "../libraries/StateManagementLibrary.sol";
import "../libraries/DisputeInitializationLibrary.sol";
import "../types/EscrowTypes.sol";
import "../governance/SlowLaneQueueActivate.sol";
import "../YieldOps.sol";

// Aave interfaces and types have been moved to AaveYieldGenerationModule
// BaseEscrow no longer needs direct Aave integration

// Custom errors for better user experience
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
// Errors moved to EscrowTypes.sol: InvalidAddress, InvalidAmount, ArrayLengthMismatch, CannotSetBothAutoTimes
error MaxAttachmentsReached(uint256 currentCount, uint256 maxAttachments);
error NotSender(uint256 workflowId, address caller, address expectedSender);
error NotRecipient(uint256 workflowId, address caller, address expectedRecipient);
error TransferAlreadyCancelled(uint256 workflowId);
error TransferAlreadyReleased(uint256 workflowId);
error TransferAlreadyResolved(uint256 workflowId);
error AmountExceedsTransfer(uint256 workflowId, uint256 requestedAmount, uint256 availableAmount);
error NotFeeAddress(address caller, address expectedFeeAddress);
error NoFeesToWithdraw(address token, uint256 availableFees);
error InvalidEscrowFee(uint256 fee, uint256 maxFee);
// Errors moved to EscrowTypes.sol: InvalidAutoTime, CannotSetBothAutoTimes, AutoTimeExceedsMaxLimit, InvalidAddress, InvalidAmount, ArrayLengthMismatch
error ExceedsMaxRange(uint256 requestedRange, uint256 maxRange);
// Aave-specific errors have been moved to AaveYieldGenerationModule
// Permit errors removed - see docs/PERMIT_FUNCTIONALITY_REMOVED.md

// EscrowState, SenderStatus, RecipientStatus, and EscrowTransfer moved to EscrowTypes.sol

/**
 * @title BaseEscrow
 * @notice Abstract base contract containing shared escrow logic
 * @dev This contract contains common functionality for both EscrowableERC20 and EscrowVault
 */
abstract contract BaseEscrow is AccessControl, ReentrancyGuard, Pausable, SlowLaneQueueActivate {
    using SafeERC20 for IERC20;
    using Address for address;
    
    // Role constants for governance
    bytes32 public constant ROLE_TIMELOCK = keccak256("ROLE_TIMELOCK");
    bytes32 public constant ROLE_GUARDIAN = keccak256("ROLE_GUARDIAN");
    
    uint256 public escrowFee;
    uint256 public constant ESCROW_FEE_DENOMINATOR = 10000;
    uint256 public nextWorkflowId = 0;
    EscrowTransfer[] public escrowTransfers;
    address public escrowFeeAddress;
    uint256 public totalFees = 0;
    uint256 public totalEscrowsPending = 0;
    uint256 public maxAttachments = 10;
    uint256 public constant MAX_AUTOMATION_RANGE = 100; // Maximum escrows to process in one batch
    
    /// @notice Optional DAO address for governance-controlled upgrades (non-proxy).
    /// @dev For March 1 release you can transfer ownership to a multisig; this is an additional hook.
    /// @dev DAO address is set in constructor and cannot be changed after deployment.
    address public dao;

    /// @notice Optional dispute resolution module. When set, NEW escrows pin `disputeResolver` via module.getDisputeResolver().
    address public disputeResolutionModule;
    address public pendingDisputeResolutionModule;
    uint256 public pendingDisputeResolutionModuleEta;
    uint256 public disputeResolutionModuleDelay = 0;
    uint256 public defaultAutoReleaseTime = 0; // 0 means no auto release
    uint256 public defaultAutoCancelTime = 0; // 0 means no auto cancel
    uint256 public constant MAX_AUTO_TIME_DURATION = 10 * 365 * 24 * 60 * 60; // 10 years in seconds
    
    // Dispute safety mechanism: prevent permanently stuck escrows
    uint256 public maxDisputeDuration = 90 days; // Maximum time a dispute can remain unresolved
    mapping(uint256 => uint256) public disputeRaisedTimestamp; // workflowId => timestamp when dispute was raised

    // Per-escrow settings mapping (gas-efficient alternative to extending struct)
    mapping(uint256 => EscrowSettings) public escrowSettings;

    // Note: Aave state variables have been moved to AaveYieldGenerationModule
    // BaseEscrow now uses yield generation modules for all yield operations

    // Yield distribution removed - now handled entirely by yield distribution module
    
    // Phase 1 size optimization: External yield operations contract
    YieldOps public yieldOps;

    // Slow lane pending changes (Phase 3)
    PendingAddress private _pendingFeeRecipient;
    PendingUint private _pendingEscrowFee;
    // _pendingDao removed - DAO address is no longer updateable

    // Common events
    // Phase 1: Core lifecycle events (all have workflowId indexed for indexability)
    event EscrowStateChanged(uint256 indexed workflowId, EscrowState oldStatus, EscrowState newStatus);
    event EscrowTransferDisputed(uint256 indexed workflowId, address indexed from, address indexed to, uint256 amount);
    event EscrowTransferResolved(uint256 indexed workflowId, address indexed from, address indexed to, uint256 amount);
    event EscrowTransferResolvedWithPartialRelease(uint256 indexed workflowId, address indexed from, address indexed to, uint256 amount);
    event EscrowTransferResolvedWithPartialCancel(uint256 indexed workflowId, address indexed from, address indexed to, uint256 amount);
    // Phase 2: Standardized resolution event (ERC-ESCR-DISPUTE)
    event EscrowResolved(uint256 indexed workflowId, address indexed disputeResolver, bytes32 resolutionHash);
    // Escalation events
    event DisputeEscalated(uint256 indexed workflowId, uint8 fromLevel, uint8 toLevel, address indexed newDisputeResolver, address indexed escalatedBy);
    event EscalationFeeCollected(uint256 indexed workflowId, uint256 fee, address indexed feeRecipient);
    event EscrowTransferAutoReleased(uint256 indexed workflowId, address indexed to, uint256 amount);
    event EscrowTransferAutoCancelled(uint256 indexed workflowId, address indexed from, uint256 amount);
    
    // Dispute safety mechanism events
    event MaxDisputeDurationUpdated(uint256 newDuration);
    event DisputeAutoCancelled(uint256 indexed workflowId, address indexed from, uint256 amount, string reason);
    
    // Phase 1: Cancel lifecycle events
    event CancelRequested(uint256 indexed workflowId, address indexed by);
    event CancelConfirmed(uint256 indexed workflowId, address indexed by);
    
    // Phase 1: Dispute lifecycle events
    event DisputeOpened(uint256 indexed workflowId, address indexed by, address indexed disputeResolver);
    
    // Phase 1: Timeout execution events
    event TimeoutExecuted(uint256 indexed workflowId, uint8 action); // 0 = RELEASE, 1 = CANCEL
    
    // Evidence and attachments
    event EvidenceSubmitted(uint256 indexed workflowId, address indexed from, address indexed to, string evidence);
    event AttachmentAdded(uint256 indexed workflowId, string uri, bytes32 hash);
    // AttachmentSetAdded and release-with-attachment events removed - only single attachments supported
    
    // Configuration events
    event EscrowFeeUpdated(uint256 oldFee, uint256 newFee);
    event EscrowFeeAddressUpdated(address oldAddress, address newAddress);
    // DaoUpdated event removed - DAO address is no longer updateable
    event ResolutionModuleDelayUpdated(uint256 oldDelay, uint256 newDelay);
    event ResolutionModuleProposed(address indexed proposedModule, uint256 eta);
    event ResolutionModuleActivated(address indexed oldModule, address indexed newModule);
    event MaxAttachmentsUpdated(uint256 oldMax, uint256 newMax);
    event EscrowSettingsUpdated(uint256 indexed workflowId, EscrowSettings settings);
    
    // Phase 7: Module snapshot events
    event EscrowModuleSnapshot(
        uint256 indexed workflowId,
        address resolutionModule,
        address releaseStrategy,
        address yieldGenerationModule,
        address yieldDistributionModule
    );
    
    // Slow lane queue/activate events (Phase 3)
    event EscrowFeeAddressQueued(address indexed oldAddress, address indexed newAddress, uint64 eta);
    event EscrowFeeAddressActivated(address indexed oldAddress, address indexed newAddress);
    event EscrowFeeQueued(uint256 oldFee, uint256 newFee, uint64 eta);
    event EscrowFeeActivated(uint256 oldFee, uint256 newFee);
    // DaoQueued and DaoActivated events removed - DAO address is no longer updateable
    
    // Yield distribution events removed - now handled by yield distribution module
    
    // Recovery events
    event NativeETHRecovered(address indexed recipient, uint256 amount);
    event ERC20Recovered(address indexed token, address indexed recipient, uint256 amount);

    /**
     * @notice Set the default auto-cancel time for new escrows
     * @param time Timestamp when escrow should auto-cancel (0 means no auto-cancel)
     */
    function setDefaultAutoCancelTime(uint256 time) public onlyRole(ROLE_TIMELOCK) {
        SettingsValidationLibrary.validateAutoCancel(time);
        defaultAutoCancelTime = time;
    }

    /**
     * @notice Set the default auto-release time for new escrows
     * @param time Timestamp when escrow should auto-release (0 means no auto-release)
     */
    function setDefaultAutoReleaseTime(uint256 time) public onlyRole(ROLE_TIMELOCK) {
        SettingsValidationLibrary.validateAutoRelease(time);
        defaultAutoReleaseTime = time;
    }
    
    /**
     * @notice Set maximum dispute duration (safety mechanism to prevent permanently stuck escrows)
     * @param duration Maximum time a dispute can remain unresolved (in seconds)
     * @dev Only ROLE_TIMELOCK can set max dispute duration
     *      Must be between 7 days and 365 days
     *      After this duration, anyone can call autoCancelDisputedEscrow() to refund sender
     */
    function setMaxDisputeDuration(uint256 duration) external onlyRole(ROLE_TIMELOCK) {
        require(duration >= 7 days, "Too short");
        require(duration <= 365 days, "Too long");
        maxDisputeDuration = duration;
        emit MaxDisputeDurationUpdated(duration);
    }
    
    /**
     * @notice Auto-cancel disputed escrow if max duration exceeded (safety mechanism)
     * @param workflowId The escrow transfer ID
     * @return True if auto-cancel was successful
     * @dev Anyone can call this after maxDisputeDuration has passed
     *      Automatically cancels and refunds to sender (safest default)
     *      Prevents escrows from being permanently stuck if resolution module fails
     */
    function autoCancelDisputedEscrow(uint256 workflowId) external nonReentrant returns (bool) {
        _validateWorkflowId(workflowId);
        EscrowTransfer storage et = escrowTransfers[workflowId];
        
        require(et.escrowState == EscrowState.DISPUTED, "Not in dispute");
        
        uint256 disputeTimestamp = disputeRaisedTimestamp[workflowId];
        require(disputeTimestamp > 0, "Dispute timestamp not set");
        require(block.timestamp >= disputeTimestamp + maxDisputeDuration, "Not yet timed out");
        
        // Auto-cancel: refund to sender (safest default)
        address from = et.from;
        uint256 originalAmount = et.totalDeposited;
        
        _cancelAndRefund(workflowId);
        et.escrowState = EscrowState.RESOLVED;
        
        // Clear dispute timestamp
        delete disputeRaisedTimestamp[workflowId];
        
        emit EscrowStateChanged(workflowId, EscrowState.DISPUTED, EscrowState.RESOLVED);
        emit DisputeAutoCancelled(workflowId, from, originalAmount, "Max dispute duration exceeded");
        emit EscrowTransferResolved(workflowId, from, et.to, originalAmount);
        
        return true;
    }
    
    /**
     * @notice Check if disputed escrow has exceeded max duration
     * @param workflowId The escrow transfer ID
     * @return isTimedOut True if max duration exceeded
     * @return timeRemaining Seconds until timeout (0 if timed out or not in dispute)
     * @dev View function to check dispute timeout status
     */
    function isDisputeTimedOut(uint256 workflowId) external view returns (bool isTimedOut, uint256 timeRemaining) {
        _validateWorkflowId(workflowId);
        EscrowTransfer storage et = escrowTransfers[workflowId];
        if (et.escrowState != EscrowState.DISPUTED) {
            return (false, 0);
        }
        
        uint256 disputeTimestamp = disputeRaisedTimestamp[workflowId];
        if (disputeTimestamp == 0) {
            return (false, 0);
        }
        
        uint256 elapsed = block.timestamp - disputeTimestamp;
        if (elapsed >= maxDisputeDuration) {
            return (true, 0);
        }
        
        return (false, maxDisputeDuration - elapsed);
    }
    
    /**
     * @notice Queue a new escrow fee recipient address (Slow lane: 7-day delay)
     * @param feeAddress Address to receive fees (cannot be zero address)
     * @dev After 7 days, call activateEscrowFeeAddress() to apply the change
     */
    function queueEscrowFeeAddress(address feeAddress) public onlyRole(ROLE_TIMELOCK) {
        SettingsValidationLibrary.validateNonZero(feeAddress, "feeAddress");
        _queueAddress(_pendingFeeRecipient, feeAddress);
        emit EscrowFeeAddressQueued(escrowFeeAddress, feeAddress, _pendingFeeRecipient.eta);
    }

    /**
     * @notice Activate the queued escrow fee recipient address
     * @dev Reverts if no pending change or 7-day delay has not elapsed
     */
    function activateEscrowFeeAddress() public onlyRole(ROLE_TIMELOCK) {
        address oldAddress = escrowFeeAddress;
        escrowFeeAddress = _activateAddress(_pendingFeeRecipient);
        emit EscrowFeeAddressActivated(oldAddress, escrowFeeAddress);
        emit EscrowFeeAddressUpdated(oldAddress, escrowFeeAddress);
    }

    /**
     * @notice Get pending fee recipient change (if any)
     * @return value Pending address value
     * @return eta Timestamp when activation is allowed
     * @return exists Whether a pending change exists
     */
    function getPendingFeeRecipient() public view returns (address value, uint64 eta, bool exists) {
        return (getPendingAddress(_pendingFeeRecipient));
    }
    
    /**
     * @notice Queue a new escrow fee percentage (Slow lane: 7-day delay)
     * @param newFee New fee in basis points (e.g., 100 = 1%, max 10000 = 100%)
     * @dev After 7 days, call activateEscrowFee() to apply the change
     */
    function queueEscrowFee(uint256 newFee) public onlyRole(ROLE_TIMELOCK) {
        // Phase 6: Validate fee is within bounds (0 <= newFee <= 200 bps = 2%)
        // Note: ESCROW_FEE_DENOMINATOR is 10_000, but we limit to 200 bps (2%) for safety
        SettingsValidationLibrary.validateFeeBps(newFee);
        _queueUint(_pendingEscrowFee, newFee);
        emit EscrowFeeQueued(escrowFee, newFee, _pendingEscrowFee.eta);
    }

    /**
     * @notice Activate the queued escrow fee percentage
     * @dev Reverts if no pending change or 7-day delay has not elapsed
     */
    function activateEscrowFee() public onlyRole(ROLE_TIMELOCK) {
        uint256 oldFee = escrowFee;
        escrowFee = _activateUint(_pendingEscrowFee);
        emit EscrowFeeActivated(oldFee, escrowFee);
        emit EscrowFeeUpdated(oldFee, escrowFee);
    }

    /**
     * @notice Get pending escrow fee change (if any)
     * @return value Pending fee value
     * @return eta Timestamp when activation is allowed
     * @return exists Whether a pending change exists
     */
    function getPendingEscrowFee() public view returns (uint256 value, uint64 eta, bool exists) {
        return (getPendingUint(_pendingEscrowFee));
    }
    
    /**
     * @notice Set the maximum number of attachments allowed per escrow
     * @param newMax New maximum number of attachments
     * @dev Phase 6: Bounds enforced: 0 <= newMax <= 20
     */
    function setMaxAttachments(uint256 newMax) public onlyRole(ROLE_TIMELOCK) {
        SettingsValidationLibrary.validateMaxAttachments(newMax);
        uint256 oldMax = maxAttachments;
        maxAttachments = newMax;
        emit MaxAttachmentsUpdated(oldMax, newMax);
    }
    
    /**
     * @notice Pause all escrow operations (emergency stop)
     * @dev Guardian can pause immediately for emergency situations
     */
    function pause() public onlyRole(ROLE_GUARDIAN) {
        _pause();
    }
    
    /**
     * @notice Unpause escrow operations
     * @dev Only Timelock can unpause (not Guardian) to prevent abuse
     */
    function unpause() public onlyRole(ROLE_TIMELOCK) {
        _unpause();
    }

    /**
     * @notice Execute timeout for escrow(s) (auto-release or auto-cancel)
     * @param workflowIdOrStart Single workflow ID, or start of range (if rangeEnd provided)
     * @param rangeEnd Optional: end of range (exclusive). If 0, processes single escrow
     * @return True if timeout was executed, false otherwise
     * @dev As Ethereum can't trigger a timed action itself, this function needs to be called periodically.
     *      Single escrow: automateTimedActions(workflowId)
     *      Range: automateTimedActions(start, end)
     *      All: automateTimedActions(0, nextWorkflowId)
     */
    function automateTimedActions(uint256 workflowIdOrStart, uint256 rangeEnd) public nonReentrant returns (bool) {
        // If rangeEnd is 0, treat as single escrow
        if (rangeEnd == 0) {
            return _automateSingleTimedAction(workflowIdOrStart);
        }
        
        // Process range
        if (rangeEnd > nextWorkflowId) {
            rangeEnd = nextWorkflowId;
        }
        if (rangeEnd < workflowIdOrStart) {
            revert InvalidWorkflowId(workflowIdOrStart, nextWorkflowId);
        }
        uint256 range = rangeEnd - workflowIdOrStart;
        if (range > MAX_AUTOMATION_RANGE) {
            revert ExceedsMaxRange(range, MAX_AUTOMATION_RANGE);
        }
        for(uint256 i = workflowIdOrStart; i < rangeEnd; i++) {
            _automateSingleTimedAction(i);
        }
        return true;
    }
    
    /**
     * @dev Internal function to execute timeout for a single escrow
     */
    function _automateSingleTimedAction(uint256 workflowId) internal returns (bool) {
        _validateWorkflowId(workflowId);
        EscrowTransfer storage et = escrowTransfers[workflowId];
        
        // Only process if still pending
        if(et.escrowState != EscrowState.PENDING) {
            return false;
        }
        
        // Check release condition first (higher priority)
        // IMPORTANT: Release has priority over cancel - if both conditions are true, release
        if(et.autoReleaseTime > 0 && block.timestamp >= et.autoReleaseTime) {
            address to = et.to;
            _releaseEscrowTransfer(workflowId);
            // Phase 1: Emit timeout executed event (0 = RELEASE)
            emit TimeoutExecuted(workflowId, 0);
            // Amount is 0 after release (et.remainingBalance was set to 0 in _releaseEscrowTransfer)
            emit EscrowTransferAutoReleased(workflowId, to, 0);
            return true;
        } else if(et.autoCancelTime > 0 && block.timestamp >= et.autoCancelTime) {
            address from = et.from;
            _cancelAndRefund(workflowId);
            // Phase 1: Emit timeout executed event (1 = CANCEL)
            emit TimeoutExecuted(workflowId, 1);
            // Amount is 0 after cancel (et.remainingBalance was set to 0 in _cancelAndRefund)
            emit EscrowTransferAutoCancelled(workflowId, from, 0);
            return true;
        }
        return false;
    }

    // automateTimedActions overloads consolidated into single function with optional rangeEnd parameter

    /**
     * @notice Add a single attachment to an escrow transfer
     * @param workflowId The escrow transfer ID
     * @param uri URI of the attachment (e.g., IPFS hash, URL)
     * @param hash Hash of the attachment content for verification
     * @return True if attachment was added successfully
     * @dev Only sender or recipient can add attachments. Maximum attachments per escrow is limited by maxAttachments.
     */
    function addAttachment(uint256 workflowId, string memory uri, bytes32 hash) public returns (bool) {
        _validateWorkflowId(workflowId);
        EscrowTransfer storage et = escrowTransfers[workflowId];
        // Only sender or recipient can add attachments
        if (et.from != _msgSender() && et.to != _msgSender()) {
            revert NotParticipant(workflowId, _msgSender(), et.from, et.to);
        }
        if (et.attachmentURIs.length >= maxAttachments) {
            revert MaxAttachmentsReached(et.attachmentURIs.length, maxAttachments);
        }
        et.attachmentURIs.push(uri);
        et.attachmentHashes.push(hash);
        emit AttachmentAdded(workflowId, uri, hash);
        return true;
    }

    // addAttachmentSet() removed - only single attachments supported for contract size reduction

    /**
     * @notice Recipient requests to cancel an escrow transfer
     * @param workflowId The escrow transfer ID
     * @return True if cancel request was processed successfully
     * @dev Only the recipient can call this function. If both sender and recipient agree to cancel,
     *      the escrow is immediately cancelled and refunded to the sender. Escrow must be in PENDING state.
     */
    function recipientCancel(uint256 workflowId) public returns (bool) {
        _validateWorkflowId(workflowId);
        EscrowTransfer storage et = escrowTransfers[workflowId];
        if (et.to != _msgSender()) {
            revert NotRecipient(workflowId, _msgSender(), et.to);
        }
        if(et.escrowState == EscrowState.REFUNDED) {
            revert TransferAlreadyCancelled(workflowId);
        }
        if(et.escrowState == EscrowState.DISPUTED) {
            revert TransferNotInDispute(workflowId, et.escrowState);
        }
        if(et.escrowState == EscrowState.RELEASED) {
            revert TransferAlreadyReleased(workflowId);
        }
        if(et.escrowState == EscrowState.RESOLVED) {
            revert TransferAlreadyResolved(workflowId);
        }
        if(et.escrowState != EscrowState.PENDING) {
            revert TransferNotPending(workflowId, et.escrowState);
        }
        et.recipientStatus = RecipientStatus.AGREE_TO_CANCEL;

        // Phase 1: Emit cancel requested event
        emit CancelRequested(workflowId, _msgSender());

        if (et.senderStatus == SenderStatus.AGREE_TO_CANCEL) {
            // Phase 1: Emit cancel confirmed event (both parties agreed)
            emit CancelConfirmed(workflowId, _msgSender());
            _cancelAndRefund(workflowId);
        }
        return true;
    }

    /**
     * @notice Sender requests to cancel an escrow transfer
     * @param workflowId The escrow transfer ID
     * @return True if cancel request was processed successfully
     * @dev Only the sender can call this function. If both sender and recipient agree to cancel,
     *      the escrow is immediately cancelled and refunded to the sender. Escrow must be in PENDING state.
     */
    function senderCancel(uint256 workflowId) public returns (bool) {
        _validateWorkflowId(workflowId);
        EscrowTransfer storage et = escrowTransfers[workflowId];
        if (et.from != _msgSender()) {
            revert NotSender(workflowId, _msgSender(), et.from);
        }
        if(et.escrowState != EscrowState.PENDING) {
            revert TransferNotPending(workflowId, et.escrowState);
        }
        
        et.senderStatus = SenderStatus.AGREE_TO_CANCEL;
        
        // Phase 1: Emit cancel requested event
        emit CancelRequested(workflowId, _msgSender());
        
        if (et.recipientStatus == RecipientStatus.AGREE_TO_CANCEL) {
            // Phase 1: Emit cancel confirmed event (both parties agreed)
            emit CancelConfirmed(workflowId, _msgSender());
            _cancelAndRefund(workflowId);
        }
        return true;
    }

    // setAuthorizedResolver removed - deprecated function eliminated for size reduction
    // onlyDaoOrOwner modifier removed - deprecated, kept only in derived contracts if needed

    // queueDao, activateDao, and getPendingDao removed - DAO address is no longer updateable
    // DAO address must be set in constructor and cannot be changed after deployment

    /**
     * @notice Set the delay (in seconds) between proposing and activating a new resolution module.
     * @param newDelay Delay in seconds
     * @dev Phase 6: Bounds enforced: 48h <= newDelay <= 30 days
     */
    function setResolutionModuleDelay(uint256 newDelay) external onlyRole(ROLE_TIMELOCK) {
        SettingsValidationLibrary.validateResolutionDelay(newDelay);
        uint256 oldDelay = disputeResolutionModuleDelay;
        disputeResolutionModuleDelay = newDelay;
        emit ResolutionModuleDelayUpdated(oldDelay, newDelay);
    }

    /**
     * @notice Propose a new dispute resolution module. After the delay, it can be activated.
     * @dev New escrows will pin their disputeResolver using the active module.
     */
    function proposeResolutionModule(address newModule) external onlyRole(ROLE_TIMELOCK) {
        ModuleProposalLibrary.validateProposal(newModule, disputeResolutionModule);
        uint256 eta = ModuleProposalLibrary.calculateProposalEta(disputeResolutionModuleDelay);
        pendingDisputeResolutionModule = newModule;
        pendingDisputeResolutionModuleEta = eta;
        emit ResolutionModuleProposed(newModule, eta);
    }

    /**
     * @notice Activate the previously proposed resolution module after the delay has elapsed.
     */
    function activateResolutionModule() external onlyRole(ROLE_TIMELOCK) {
        ModuleProposalLibrary.validateActivation(pendingDisputeResolutionModule, pendingDisputeResolutionModuleEta);
        address oldModule = disputeResolutionModule;
        disputeResolutionModule = pendingDisputeResolutionModule;
        pendingDisputeResolutionModule = address(0);
        pendingDisputeResolutionModuleEta = 0;
        emit ResolutionModuleActivated(oldModule, disputeResolutionModule);
    }

    /**
     * @notice Resolver cancels a disputed escrow transfer and refunds to sender
     * @param workflowId The escrow transfer ID
     * @return True if cancellation was successful
     * @dev Only authorized dispute resolver can call this. Escrow must be in DISPUTED state.
     *      After cancellation, escrow state changes to RESOLVED and funds are refunded to sender.
     */
    function cancelAsDisputeResolver(uint256 workflowId) public nonReentrant returns (bool) {
        _validateWorkflowId(workflowId);
        EscrowTransfer storage et = escrowTransfers[workflowId];
        if (!_isAuthorizedDisputeResolver(workflowId, _msgSender())) {
            revert NotAuthorizedResolver(_msgSender(), et.disputeResolver);
        }
        if(et.escrowState != EscrowState.DISPUTED) {
            revert TransferNotInDispute(workflowId, et.escrowState);
        }
        
        // Phase 1: Capture old status for state change event
        EscrowState oldStatus = et.escrowState;
        uint256 originalAmount = et.totalDeposited;
        
        _cancelAndRefund(workflowId);
        et.escrowState = EscrowState.RESOLVED;
        
        // Phase 1: Emit state change event (DISPUTE -> RESOLVER_OVERRIDDEN)
        emit EscrowStateChanged(workflowId, oldStatus, EscrowState.RESOLVED);
        
        // Note: Aave tracking is already cleared by _cancelAndRefund -> _withdrawFromAave
        
        // Record resolution outcome in resolution module (for reversal tracking)
        _recordResolutionOutcome(workflowId, _msgSender(), false); // false = CANCEL
        
        // Clear dispute timestamp (dispute resolved)
        delete disputeRaisedTimestamp[workflowId];
        
        emit EscrowTransferResolved(workflowId, et.from, et.to, originalAmount);
        return true;
    }

    /**
     * @notice Resolver releases a disputed escrow transfer to recipient
     * @param workflowId The escrow transfer ID
     * @return True if release was successful
     * @dev Only authorized dispute resolver can call this. Escrow must be in DISPUTED state.
     *      After release, escrow state changes to RESOLVED and funds are transferred to recipient.
     *      If escrow was generating yield via Aave, yield is distributed according to configured distribution.
     */
    function releaseAsDisputeResolver(uint256 workflowId) public nonReentrant returns (bool) {
        _validateWorkflowId(workflowId);
        EscrowTransfer storage et = escrowTransfers[workflowId];
        if (!_isAuthorizedDisputeResolver(workflowId, _msgSender())) {
            revert NotAuthorizedResolver(_msgSender(), et.disputeResolver);
        }
        if(et.escrowState != EscrowState.DISPUTED) {
            revert TransferNotInDispute(workflowId, et.escrowState);
        }
        
        // Save values before state changes
        EscrowState oldStatus = et.escrowState;
        uint256 amount = et.remainingBalance;
        address token = et.token;
        address to = et.to;
        address from = et.from;
        uint256 originalEscrowAmount = et.totalDeposited;
        
        // State changes BEFORE external calls (checks-effects-interactions)
        et.remainingBalance = 0;
        et.escrowState = EscrowState.RESOLVED;
        _updateEscrowBalance(token, amount, false);
        totalEscrowsPending--;
        emit EscrowStateChanged(workflowId, oldStatus, EscrowState.RESOLVED);
        
        // Handle yield via YieldOps (Phase 1 size optimization)
        // Non-blocking: yield failures won't prevent release (try/catch pattern)
        if (address(yieldOps) != address(0)) {
            try yieldOps.handleFullYield(
                _getYieldGenerationModule(workflowId),
                _getYieldDistributionModule(workflowId),
                workflowId,
                token,
                amount
            ) {} catch {}
        }
        
        _transferTokens(token, to, amount);
        _recordResolutionOutcome(workflowId, _msgSender(), true);
        delete disputeRaisedTimestamp[workflowId];
        emit EscrowTransferResolved(workflowId, from, to, originalEscrowAmount);
        return true;
    }

    /**
     * @notice Resolver partially releases a disputed escrow transfer to recipient
     * @param workflowId The escrow transfer ID
     * @param amount Amount to release to recipient (must be less than or equal to escrow amount)
     * @return True if partial release was successful
     * @dev Only authorized dispute resolver can call this. Escrow must be in DISPUTED state.
     *      If amount equals remaining escrow amount, escrow state changes to RESOLVED.
     *      If escrow was generating yield via Aave, proportional yield is distributed.
     */
    function partialReleaseAsDisputeResolver(uint256 workflowId, uint256 amount) public nonReentrant returns (bool) {
        _validateWorkflowId(workflowId);
        EscrowTransfer storage et = escrowTransfers[workflowId];
        if (!_isAuthorizedDisputeResolver(workflowId, _msgSender())) {
            revert NotAuthorizedResolver(_msgSender(), et.disputeResolver);
        }
        if(et.escrowState != EscrowState.DISPUTED) {
            revert TransferNotInDispute(workflowId, et.escrowState);
        }

        if (amount == 0) {
            revert InvalidAmount("Amount must be greater than zero");
        }
        if (amount > et.remainingBalance) {
            revert AmountExceedsTransfer(workflowId, amount, et.remainingBalance);
        }
        
        // Save values before state changes
        address releaseTo = et.to;
        address from = et.from;
        uint256 originalAmount = et.totalDeposited;
        address token = et.token;
        
        // Execute action using library
        IYieldGenerationModule genModule = _getYieldGenerationModule(workflowId);
        ResolverActionLibrary.ActionParams memory params = ResolverActionLibrary.ActionParams({
            workflowId: workflowId,
            amount: amount,
            isRelease: true,
            isPartial: true,
            recipient: releaseTo,
            token: token,
            remainingBalance: et.remainingBalance,
            totalDeposited: et.totalDeposited
        });
        
        ResolverActionLibrary.ActionResult memory result = ResolverActionLibrary.executeAction(params, genModule);
        
        // State changes
        et.remainingBalance -= amount;
        result.isComplete = (et.remainingBalance == 0);
        if (result.isComplete) {
            et.escrowState = EscrowState.RESOLVED;
            totalEscrowsPending--;
            delete disputeRaisedTimestamp[workflowId];
        }
        
        // Update escrow balance
        _updateEscrowBalance(token, amount, false);
        
        // Distribute yield if any (via YieldOps - Phase 1 size optimization)
        // Non-blocking: yield failures won't prevent partial release
        if (result.yieldToDistribute > 0 && address(yieldOps) != address(0)) {
            try yieldOps.handlePartialYield(
                _getYieldGenerationModule(workflowId),
                _getYieldDistributionModule(workflowId),
                workflowId,
                token,
                amount,
                params.remainingBalance,
                params.totalDeposited
            ) {} catch {}
        }
        
        // Transfer tokens
        _transferTokens(token, releaseTo, amount);
        emit EscrowTransferResolvedWithPartialRelease(workflowId, from, releaseTo, amount);
        if (result.isComplete) {
            emit EscrowTransferResolved(workflowId, from, releaseTo, originalAmount);
        }
        return true;
    }

    /**
     * @notice Resolver partially cancels a disputed escrow transfer and refunds to sender
     * @param workflowId The escrow transfer ID
     * @param amount Amount to refund to sender (must be less than or equal to escrow amount)
     * @return True if partial cancel was successful
     * @dev Only authorized dispute resolver can call this. Escrow must be in DISPUTED state.
     *      If amount equals remaining escrow amount, escrow state changes to RESOLVED.
     *      If escrow was generating yield via Aave, proportional yield is distributed.
     */
    function partialCancelAsDisputeResolver(uint256 workflowId, uint256 amount) public nonReentrant returns (bool) {
        _validateWorkflowId(workflowId);
        EscrowTransfer storage et = escrowTransfers[workflowId];
        if (!_isAuthorizedDisputeResolver(workflowId, _msgSender())) {
            revert NotAuthorizedResolver(_msgSender(), et.disputeResolver);
        }
        if(et.escrowState != EscrowState.DISPUTED) {
            revert TransferNotInDispute(workflowId, et.escrowState);
        }

        if (amount == 0) {
            revert InvalidAmount("Amount must be greater than zero");
        }
        if (amount > et.remainingBalance) {
            revert AmountExceedsTransfer(workflowId, amount, et.remainingBalance);
        }
        
        // Save values before state changes
        address refundTo = et.from;
        address to = et.to;
        uint256 originalAmount = et.totalDeposited;
        address token = et.token;
        
        // Execute action using library
        IYieldGenerationModule genModule = _getYieldGenerationModule(workflowId);
        ResolverActionLibrary.ActionParams memory params = ResolverActionLibrary.ActionParams({
            workflowId: workflowId,
            amount: amount,
            isRelease: false,
            isPartial: true,
            recipient: refundTo,
            token: token,
            remainingBalance: et.remainingBalance,
            totalDeposited: et.totalDeposited
        });
        
        ResolverActionLibrary.ActionResult memory result = ResolverActionLibrary.executeAction(params, genModule);
        
        // State changes
        et.remainingBalance -= amount;
        result.isComplete = (et.remainingBalance == 0);
        if (result.isComplete) {
            EscrowState oldStatus = et.escrowState;
            et.escrowState = EscrowState.RESOLVED;
            totalEscrowsPending--;
            emit EscrowStateChanged(workflowId, oldStatus, EscrowState.RESOLVED);
            delete disputeRaisedTimestamp[workflowId];
        }
        
        // Update escrow balance
        _updateEscrowBalance(token, amount, false);
        
        // Distribute yield if any (via YieldOps - Phase 1 size optimization)
        // Non-blocking: yield failures won't prevent partial cancel
        if (result.yieldToDistribute > 0 && address(yieldOps) != address(0)) {
            try yieldOps.handlePartialYield(
                _getYieldGenerationModule(workflowId),
                _getYieldDistributionModule(workflowId),
                workflowId,
                token,
                amount,
                params.remainingBalance,
                params.totalDeposited
            ) {} catch {}
        }
        
        // Transfer tokens
        _transferTokens(token, refundTo, amount);
        emit EscrowTransferResolvedWithPartialCancel(workflowId, refundTo, to, amount);
        if (result.isComplete) {
            emit EscrowTransferResolved(workflowId, refundTo, to, originalAmount);
        }
        return true;
    }

    /**
     * @dev Check if an address is the authorized dispute resolver for a specific escrow transfer.
     * @dev Authorization is pinned per escrow via EscrowTransfer.disputeResolver at escrow creation time.
     */
    function _isAuthorizedDisputeResolver(uint256 workflowId, address disputeResolver) internal view returns (bool) {
        EscrowTransfer storage et = escrowTransfers[workflowId];
        
        // Phase 7: Use snapshot resolution module (not current module)
        address snapshotModule = et.snapshotResolutionModule;
        
        // If snapshot resolution module exists, check authorization with snapshot module
        if (snapshotModule != address(0)) {
            bytes memory escrowData = _encodeResolutionData(
                et.token,
                et.from,
                et.to,
                et.remainingBalance,
                et.totalDeposited
            );
            
            try IResolutionModule(snapshotModule).isAuthorizedDisputeResolver(
                workflowId,
                disputeResolver,
                escrowData
            ) returns (bool authorized, uint8 /* role */) {
                if (authorized) {
                    return true;
                }
            } catch {
                // Module call failed, fall through to fallback check
            }
        }
        
        // Fallback: check against stored dispute resolver
        return disputeResolver == et.disputeResolver;
    }

    /**
     * @notice Encode escrow transfer data for resolution module calls
     * @param token Token address
     * @param from Sender address
     * @param to Recipient address
     * @param amount Escrow amount
     * @param originalAmount Original escrow amount (before any partial releases)
     * @return Encoded bytes data for resolution module
     * @dev Uses EscrowEncodingLibrary to encode data in a standardized format
     *      This encoded data is passed to resolution modules for dispute resolver selection
     */
    function _encodeResolutionData(
        address token,
        address from,
        address to,
        uint256 amount,
        uint256 originalAmount
    ) internal pure returns (bytes memory) {
        return EscrowEncodingLibrary.encodeEscrowTransferData(token, from, to, amount, originalAmount);
    }

    /**
     * @notice Determine the dispute resolver for a new escrow, pinning the resolver at creation time
     * @param workflowId The escrow transfer ID
     * @param token Token address
     * @param from Sender address
     * @param to Recipient address
     * @param amount Escrow amount
     * @param originalAmount Original escrow amount
     * @return disputeResolver Address of the dispute resolver assigned to this escrow
     * @dev This function is called during escrow creation to assign a dispute resolver.
     *      The resolver is then stored in EscrowTransfer.disputeResolver and cannot be changed.
     *      This ensures that future governance upgrades (module swaps) only affect NEW escrows.
     *      Calls the resolution module's getDisputeResolver() function with encoded escrow data.
     *      Reverts if resolution module is not configured or returns zero address.
     */
    function _getDisputeResolverForNewEscrow(
        uint256 workflowId,
        address token,
        address from,
        address to,
        uint256 amount,
        uint256 originalAmount
    ) internal view virtual returns (address) {
        // Always use resolution module
        if (disputeResolutionModule == address(0)) {
            revert ResolutionModuleNotConfigured();
        }

        bytes memory escrowData = _encodeResolutionData(token, from, to, amount, originalAmount);
        try IResolutionModule(disputeResolutionModule).getDisputeResolver(workflowId, escrowData) returns (address disputeResolver, uint8 /* escalationLevel */) {
            if (disputeResolver == address(0)) {
                revert ResolutionModuleReturnedZeroAddress();
            }
            return disputeResolver;
        } catch {
            revert ResolutionModuleCallFailed();
        }
    }

    /**
     * @notice Raise a dispute for an escrow transfer
     * @param workflowId The escrow transfer ID
     * @return True if dispute was raised successfully
     * @dev Only sender or recipient can raise a dispute. Escrow must be in PENDING state.
     *      After dispute is raised, escrow state changes to DISPUTED and can only be resolved by authorized dispute resolver.
     *      If a custom dispute resolver is configured, it will be notified via IResolver.onDisputeOpened callback.
     */
    function raiseDispute(uint256 workflowId) public returns (bool) {
        _validateWorkflowId(workflowId);
        EscrowTransfer storage et = escrowTransfers[workflowId];
        if(et.escrowState != EscrowState.PENDING) {
            revert TransferNotPending(workflowId, et.escrowState);
        }
        
        // Phase 1: Capture old status and dispute resolver for events
        EscrowState oldStatus = et.escrowState;
        address disputeResolver = et.disputeResolver;
        
        bool isSender = (et.from == _msgSender());
        if (!isSender && et.to != _msgSender()) {
            revert NotParticipant(workflowId, _msgSender(), et.from, et.to);
        }
        
        // Transition to disputed state
        StateManagementLibrary.transitionToDisputed(et, workflowId, isSender);
        disputeRaisedTimestamp[workflowId] = block.timestamp;
        emit EscrowStateChanged(workflowId, oldStatus, EscrowState.DISPUTED);
        emit DisputeOpened(workflowId, _msgSender(), disputeResolver);
        emit EscrowTransferDisputed(workflowId, et.from, et.to, et.remainingBalance);
        
        // Initialize dispute in resolution module and call dispute resolver callback
        bytes memory escrowData = _encodeResolutionData(et.token, et.from, et.to, et.remainingBalance, et.totalDeposited);
        address updatedDisputeResolver = DisputeInitializationLibrary.initializeInModule(
            disputeResolutionModule, workflowId, disputeResolver, escrowData
        );
        if (updatedDisputeResolver != disputeResolver) {
            et.disputeResolver = updatedDisputeResolver;
            disputeResolver = updatedDisputeResolver;
        }
        DisputeInitializationLibrary.callResolverCallback(disputeResolver, workflowId);
        
        return true;
    }
    
    // _initializeDisputeInModule removed - logic moved to DisputeInitializationLibrary
    
    /**
     * @notice Record resolution outcome in resolution module (for reversal tracking and quality metrics)
     * @param workflowId The escrow transfer ID
     * @param disputeResolver Dispute resolver address that made the resolution
     * @param isRelease True if RELEASE (funds to recipient), false if CANCEL (refund to sender)
     * @dev Optimized for contract size: minimal bytecode footprint.
     *      Calls recordResolution on the active resolution module if it supports the interface.
     *      This allows the resolution module to track:
     *      - Resolution outcomes for quality metrics
     *      - Resolution reversals (when escalations overturn decisions)
     *      - Dispute resolver performance statistics
     *      Uses low-level call to avoid increasing contract size with interface dependencies.
     *      Failures are silently ignored (non-critical operation).
     */
    function _recordResolutionOutcome(
        uint256 workflowId,
        address disputeResolver,
        bool isRelease
    ) internal {
        address module = disputeResolutionModule;
        if (module == address(0)) return;
        // ResolutionOutcome: 1 = RELEASE, 2 = CANCEL
        (bool success, ) = module.call(
            abi.encodeWithSignature(
                "recordResolution(uint256,address,uint8,bool,uint256)",
                workflowId, disputeResolver, isRelease ? 1 : 2, false, 0
            )
        );
        success; // Silence unused variable warning
    }
    
    // Category key generation removed - now handled by resolution module via autoCategorizeEscrow
    
    /**
     * @notice Escalate a dispute to the next resolution level
     * @param workflowId The escrow transfer ID
     * @return success True if escalation was successful
     * @return newDisputeResolver Address of the new dispute resolver
     * @return newLevel New escalation level
     * @dev Only participants (sender or recipient) can escalate. Escrow must be in DISPUTED state.
     *      Fee collection happens in BaseEscrow, escalation logic delegated to module.
     * 
     * @dev Escalation Flow:
     *      1. Validate caller is participant and escrow is in DISPUTED state
     *      2. Query module for current escalation level and fee requirements
     *      3. Validate escalation is allowed and sufficient fee provided
     *      4. Execute escalation via module (module handles resolver selection and state updates)
     *      5. If escalation fails: refund any fee sent and revert
     *      6. If escalation succeeds: collect fee, update escrow state, refund excess
     * 
     * @dev Fee Handling:
     *      - Fee is collected AFTER successful escalation (prevents loss if escalation fails)
     *      - Excess fee is automatically refunded to caller
     *      - Uses call() instead of transfer() to avoid 2300 gas limit
     * 
     * @dev Security:
     *      - Reentrancy protection via nonReentrant modifier
     *      - Module validates escalation eligibility and returns new resolver
     *      - BaseEscrow only updates its own state after module confirms success
     */
    function escalateDispute(uint256 workflowId) public payable nonReentrant returns (
        bool success,
        address newDisputeResolver,
        uint8 newLevel
    ) {
        _validateWorkflowId(workflowId);
        EscrowTransfer storage et = escrowTransfers[workflowId];
        
        // Minimal validation - participant and state checks
        if (et.from != _msgSender() && et.to != _msgSender()) {
            revert NotParticipant(workflowId, _msgSender(), et.from, et.to);
        }
        if (et.escrowState != EscrowState.DISPUTED) {
            revert TransferNotInDispute(workflowId, et.escrowState);
        }
        if (address(disputeResolutionModule) == address(0)) {
            revert ResolutionModuleNotConfigured();
        }
        
        // Get escalation info from module (validates escalation and returns fee)
        bytes memory escrowData = _encodeResolutionData(et.token, et.from, et.to, et.remainingBalance, et.totalDeposited);
        (, uint8 currentLevel) = IResolutionModule(disputeResolutionModule).getDisputeResolver(workflowId, escrowData);
        (bool canEscalate, , uint256 escalationFee) = IResolutionModule(disputeResolutionModule).canEscalate(
            workflowId, currentLevel, escrowData
        );
        
        if (!canEscalate) {
            revert InvalidAmount("Escalation not allowed");
        }
        if (escalationFee > 0 && msg.value < escalationFee) {
            revert InvalidAmount("Insufficient escalation fee");
        }
        
        // Validate fee address before proceeding
        if (escalationFee > 0 && escrowFeeAddress == address(0)) {
            revert InvalidAddress("Fee address not set", address(0));
        }
        
        // Delegate escalation execution to module (module handles all escalation logic)
        // Do this BEFORE fee transfer so we can refund if escalation fails
        (bool escalationSuccess, address newDisputeResolverAddress, uint8 newEscalationLevel) = 
            IResolutionModule(disputeResolutionModule).executeEscalation(workflowId, escrowData);
        
        if (!escalationSuccess) {
            // Refund any fee sent if escalation fails
            if (msg.value > 0) {
                (bool refundSuccess, ) = payable(_msgSender()).call{value: msg.value}("");
                require(refundSuccess, "ETH refund failed");
            }
            revert ResolutionModuleCallFailed();
        }
        
        // Collect fee AFTER successful escalation (ensures fee is only collected if escalation succeeds)
        if (escalationFee > 0) {
            (bool feeSuccess, ) = payable(escrowFeeAddress).call{value: escalationFee}("");
            require(feeSuccess, "Escalation fee transfer failed");
            emit EscalationFeeCollected(workflowId, escalationFee, escrowFeeAddress);
        }
        
        // Update dispute resolver in escrow (module returns new dispute resolver, BaseEscrow updates state)
        et.disputeResolver = newDisputeResolverAddress;
        
        // Refund excess fee
        if (msg.value > escalationFee) {
            (bool excessRefundSuccess, ) = payable(_msgSender()).call{value: msg.value - escalationFee}("");
            require(excessRefundSuccess, "Excess ETH refund failed");
        }
        
        emit DisputeEscalated(workflowId, currentLevel, newEscalationLevel, newDisputeResolverAddress, _msgSender());
        return (true, newDisputeResolverAddress, newEscalationLevel);
    }

    /**
     * @dev Validate that workflowId is valid (exists)
     * @param workflowId The escrow transfer ID
     * @dev Reverts if workflowId is invalid (>= nextWorkflowId)
     */
    function _validateWorkflowId(uint256 workflowId) internal view {
        if (workflowId >= nextWorkflowId) {
            revert InvalidWorkflowId(workflowId, nextWorkflowId);
        }
    }

    /**
     * @dev Require that escrow is in PENDING status
     * @param workflowId The escrow transfer ID
     * @dev Reverts if workflowId is invalid or escrow is not in PENDING state
     */
    function _requirePending(uint256 workflowId) internal view {
        _validateWorkflowId(workflowId);
        EscrowTransfer storage et = escrowTransfers[workflowId];
        if(et.escrowState != EscrowState.PENDING) {
            revert TransferNotPending(workflowId, et.escrowState);
        }
    }
    
    /**
     * @dev Require that escrow is in DISPUTED status
     * @param workflowId The escrow transfer ID
     * @dev Reverts if workflowId is invalid or escrow is not in DISPUTED state
     */
    function _requireDispute(uint256 workflowId) internal view {
        _validateWorkflowId(workflowId);
        EscrowTransfer storage et = escrowTransfers[workflowId];
        if(et.escrowState != EscrowState.DISPUTED) {
            revert TransferNotInDispute(workflowId, et.escrowState);
        }
    }
    
    /**
     * @dev Require that caller is a participant (sender or recipient)
     * @param workflowId The escrow transfer ID
     * @dev Reverts if workflowId is invalid or caller is not the sender or recipient
     */
    function _requireParticipant(uint256 workflowId) internal view {
        _validateWorkflowId(workflowId);
        EscrowTransfer storage et = escrowTransfers[workflowId];
        if (et.from != _msgSender() && et.to != _msgSender()) {
            revert NotParticipant(workflowId, _msgSender(), et.from, et.to);
        }
    }

    /**
     * @dev Validate a single auto time value
     * @param autoTime The auto time to validate (0 means no auto time, which is valid)
     * @param timeType Description of the time type for error messages
     * @dev Reverts if autoTime is in the past or exceeds MAX_AUTO_TIME_DURATION from current block timestamp
     */
    function _validateAutoTime(uint256 autoTime, string memory timeType) internal view {
        SettingsValidationLibrary.validateAutoTime(autoTime, block.timestamp, timeType);
    }

    /**
     * @dev Validate escrow settings
     * @param settings EscrowSettings struct to validate
     * @dev Reverts if settings are invalid (e.g., both auto times set, invalid times, etc.)
     */
    function _validateEscrowSettings(EscrowSettings memory settings) internal view {
        SettingsValidationLibrary.validateEscrowSettings(settings, block.timestamp);
    }

    /**
     * @dev Apply settings to an escrow transfer
     * @param workflowId The escrow transfer ID
     * @param settings Settings to apply (custom dispute resolver, auto times, etc.)
     * @dev Applies custom dispute resolver if set, auto times (or defaults if not set), and stores settings
     */
    function _applyEscrowSettings(uint256 workflowId, EscrowSettings memory settings) internal {
        EscrowTransfer storage et = escrowTransfers[workflowId];
        
        // Apply custom dispute resolver
        if (settings.customResolver != address(0)) {
            et.disputeResolver = settings.customResolver;
        }
        
        bool fromDefaultSettings = (settings.autoReleaseTime == 0 && settings.autoCancelTime == 0);
        et.autoReleaseTime = settings.autoReleaseTime > 0 ? settings.autoReleaseTime : 
            (fromDefaultSettings ? defaultAutoReleaseTime : 0);
        et.autoCancelTime = settings.autoCancelTime > 0 ? settings.autoCancelTime : 
            (fromDefaultSettings ? defaultAutoCancelTime : 0);
        
        // Store settings
        escrowSettings[workflowId] = settings;
        
        emit EscrowSettingsUpdated(workflowId, settings);
    }

    /**
     * @dev Get default escrow settings
     * @return Default settings struct with all fields set to default values (no custom dispute resolver, no yield, no auto times, STANDARD type)
     */
    function _getDefaultSettings() internal pure returns (EscrowSettings memory) {
        return SettingsValidationLibrary.getDefaultSettings();
    }

    /**
     * @notice Update escrow settings (only sender or owner can update)
     * @param workflowId The escrow transfer ID
     * @param settings New settings to apply
     */
    function updateEscrowSettings(uint256 workflowId, EscrowSettings memory settings) public {
        _validateWorkflowId(workflowId);
        
        EscrowTransfer storage et = escrowTransfers[workflowId];
        
        // Only sender or owner can update settings
        if (et.from != _msgSender() && !hasRole(ROLE_TIMELOCK, _msgSender())) {
            revert NotParticipant(workflowId, _msgSender(), et.from, et.to);
        }
        
        // Can only update if pending
        if (et.escrowState != EscrowState.PENDING) {
            revert TransferNotPending(workflowId, et.escrowState);
        }
        
        // Validate settings
        _validateEscrowSettings(settings);
        
        // Apply settings
        _applyEscrowSettings(workflowId, settings);
    }

    /**
     * @notice Get escrow settings
     * @param workflowId The escrow transfer ID
     * @return Settings for the escrow
     */
    function getEscrowSettings(uint256 workflowId) public view returns (EscrowSettings memory) {
        _validateWorkflowId(workflowId);
        return escrowSettings[workflowId];
    }

    // isEscrowInAave() removed - Phase 1 optimization: Query yield generation module directly instead
    // Use: yieldModule.calculateYield(workflowId, token) > 0 to check if generating yield
    // getEscrowATokenBalance removed - always returned 0, not useful

    /**
     * @notice Get the total amount originally deposited
     * @param workflowId The escrow transfer ID
     * @return Total amount originally deposited (before any releases/cancellations)
     * @dev Returns totalDeposited from EscrowTransfer struct.
     *      For yield tracking, query the yield generation module directly.
     */
    function getTotalDeposited(uint256 workflowId) public view returns (uint256) {
        _validateWorkflowId(workflowId);
        return escrowTransfers[workflowId].totalDeposited;
    }
    
    /**
     * @notice Get the remaining balance in escrow
     * @param workflowId The escrow transfer ID
     * @return Remaining balance (may be less than totalDeposited if partially released/cancelled)
     * @dev Returns remainingBalance from EscrowTransfer struct.
     */
    function getRemainingBalance(uint256 workflowId) public view returns (uint256) {
        _validateWorkflowId(workflowId);
        return escrowTransfers[workflowId].remainingBalance;
    }
    
    // getEscrowAmount removed - use getRemainingBalance() instead
    // getEscrowOriginalDeposit removed - use getTotalDeposited() instead

    /**
     * @dev Internal function to cancel and refund an escrow
     * @param workflowId The escrow transfer ID
     * @dev Cancels the escrow, changes state to REFUNDED, and transfers funds back to sender.
     *      If escrow was generating yield via Aave, withdraws from Aave first.
     *      Must be implemented by derived contracts to handle token transfers.
     * 
     * @dev Execution Flow:
     *      1. Read escrow data (token, amounts, participants) before state changes
     *      2. Withdraw yield from generation module (if enabled) - calculates actual amount including yield
     *      3. Distribute yield via distribution module (if configured)
     *      4. Transfer remaining balance (original + yield - fees) to sender
     *      5. Update state to REFUNDED and clear remaining balance
     * 
     * @dev Important: Amount is read BEFORE state transition to ensure correct value
     *      StateManagementLibrary.transitionToRefunded() sets remainingBalance to 0
     */
    function _cancelAndRefund(uint256 workflowId) internal {
        EscrowTransfer storage et = escrowTransfers[workflowId];
        
        // Read values BEFORE state transition (which sets remainingBalance to 0)
        uint256 amount = et.remainingBalance;
        address from = et.from;
        uint256 originalAmount = et.totalDeposited;
        address token = et.token;
        
        EscrowState oldStatus = StateManagementLibrary.transitionToRefunded(et, workflowId);
        
        totalEscrowsPending--;
        emit EscrowStateChanged(workflowId, oldStatus, EscrowState.REFUNDED);
        
        // Handle yield via YieldOps (Phase 1 size optimization)
        // Non-blocking: yield failures won't prevent refund
        if (address(yieldOps) != address(0)) {
            try yieldOps.handleFullYield(
                _getYieldGenerationModule(workflowId),
                _getYieldDistributionModule(workflowId),
                workflowId,
                token,
                amount
            ) {} catch {}
        }
        
        _updateEscrowBalance(token, amount, false);
        // Transfer amount to sender (yield distributed separately via YieldOps)
        _transferTokens(token, from, amount);
        _emitEscrowTransferCancelled(workflowId, token, from, originalAmount);
    }

    /**
     * @notice Internal function to release an escrow transfer to recipient
     * @param workflowId The escrow transfer ID
     * @dev Releases the escrow and transfers remaining balance to recipient.
     *      Handles yield withdrawal and distribution if escrow was generating yield.
     *      Updates escrow state to RELEASED and emits release events.
     *      This is called by both user-initiated releases and dispute resolver releases.
     * 
     * @dev Execution Flow:
     *      1. Read escrow data (token, amounts, participants) before state changes
     *      2. Withdraw yield from generation module (if enabled) - calculates actual amount including yield
     *      3. Distribute yield via distribution module (if configured)
     *      4. Transfer remaining balance (original + yield - fees) to recipient
     *      5. Update state to RELEASED and clear remaining balance
     * 
     * @dev Important: Amount is read BEFORE state transition to ensure correct value.
     *      StateManagementLibrary.transitionToReleased() sets remainingBalance to 0.
     *      Yield is handled separately and distributed according to module configuration.
     */
    function _releaseEscrowTransfer(uint256 workflowId) internal {
        EscrowTransfer storage et = escrowTransfers[workflowId];
        
        // Read values BEFORE state transition (which sets remainingBalance to 0)
        uint256 amount = et.remainingBalance;
        address to = et.to;
        uint256 originalAmount = et.totalDeposited;
        address token = et.token;
        
        EscrowState oldStatus = StateManagementLibrary.transitionToReleased(et, workflowId);
        
        totalEscrowsPending--;
        emit EscrowStateChanged(workflowId, oldStatus, EscrowState.RELEASED);
        
        // Handle yield via YieldOps (Phase 1 size optimization)
        // Non-blocking: yield failures won't prevent release
        if (address(yieldOps) != address(0)) {
            try yieldOps.handleFullYield(
                _getYieldGenerationModule(workflowId),
                _getYieldDistributionModule(workflowId),
                workflowId,
                token,
                amount
            ) {} catch {}
        }
        
        _updateEscrowBalance(token, amount, false);
        
        // Transfer amount (original escrow amount) to recipient
        // Yield has already been distributed to recipients via the distribution module
        _transferTokens(token, to, amount);
        _emitEscrowTransferReleased(workflowId, token, to, originalAmount);
    }

    /**
     * @dev Abstract function to transfer tokens - must be implemented by derived contracts
     * @param token Token address (or address(this) for EscrowableERC20)
     * @param to Recipient address
     * @param amount Amount to transfer
     * @dev Derived contracts must implement this to handle token transfers appropriately.
     *      For EscrowVault, transfers from contract balance. For EscrowableERC20, transfers from contract's token balance.
     */
    function _transferTokens(address token, address to, uint256 amount) internal virtual;

    /**
     * @dev Abstract function to update escrow balance tracking - must be implemented by derived contracts
     * @param token Token address
     * @param amount Amount to add (if add) or subtract (if !add)
     * @param add True to add to balance, false to subtract from balance
     * @dev Derived contracts must implement this to track total escrowed amounts per token.
     *      Used for accounting and ensuring sufficient balance for escrows.
     */
    function _updateEscrowBalance(address token, uint256 amount, bool add) internal virtual;

    /**
     * @dev Abstract function to emit EscrowTransferCancelled event - allows different event signatures
     * @param workflowId The escrow transfer ID
     * @param token Token address
     * @param from Sender address
     * @param originalAmount Original escrow amount
     * @dev Derived contracts can override to emit events with different signatures if needed.
     */
    function _emitEscrowTransferCancelled(uint256 workflowId, address token, address from, uint256 originalAmount) internal virtual;

    /**
     * @dev Abstract function to emit EscrowTransferReleased event - allows different event signatures
     * @param workflowId The escrow transfer ID
     * @param token Token address
     * @param to Recipient address
     * @param originalAmount Original escrow amount
     * @dev Derived contracts can override to emit events with different signatures if needed.
     */
    function _emitEscrowTransferReleased(uint256 workflowId, address token, address to, uint256 originalAmount) internal virtual;
    
    /**
     * @dev Get the yield generation module for an escrow (to be overridden by child contracts)
     * @param workflowId The escrow transfer ID
     * @return The yield generation module interface
     * @dev Derived contracts can override to return escrow-specific or contract-wide generation modules.
     */
    function _getYieldGenerationModule(uint256 workflowId) internal view virtual returns (IYieldGenerationModule);

    /**
     * @dev Get the yield distribution module for an escrow (to be overridden by child contracts)
     * @param workflowId The escrow transfer ID
     * @return The yield distribution module interface
     * @dev Derived contracts can override to return escrow-specific or contract-wide distribution modules.
     */
    function _getYieldDistributionModule(uint256 workflowId) internal view virtual returns (IYieldDistributionModule);

    /**
     * @notice Snapshot module addresses at escrow creation (Phase 7)
     * @param workflowId The escrow transfer ID
     * @param disputeResolutionModuleAddr Dispute resolution module address
     * @param releaseStrategyAddr Release strategy address
     * @param yieldGenerationModuleAddr Yield generation module address
     * @param yieldDistributionModuleAddr Yield distribution module address
     * @dev Stores current module addresses in escrow struct to ensure module changes only affect new escrows
     */
    function _snapshotModulesForEscrow(
        uint256 workflowId,
        address disputeResolutionModuleAddr,
        address releaseStrategyAddr,
        address yieldGenerationModuleAddr,
        address yieldDistributionModuleAddr
    ) internal {
        EscrowTransfer storage et = escrowTransfers[workflowId];
        
        // Snapshot current module addresses
        et.snapshotResolutionModule = disputeResolutionModuleAddr;
        et.snapshotReleaseStrategy = releaseStrategyAddr;
        et.snapshotYieldGenerationModule = yieldGenerationModuleAddr;
        et.snapshotYieldDistributionModule = yieldDistributionModuleAddr;
        
        emit EscrowModuleSnapshot(
            workflowId,
            disputeResolutionModuleAddr,
            releaseStrategyAddr,
            yieldGenerationModuleAddr,
            yieldDistributionModuleAddr
        );
    }

    // _distributeYield removed - use YieldHandlingLibrary.distributeYield() directly
    // Yield distribution setter/getter functions removed - now handled by yield distribution module

    // ============ Aave Configuration Functions ============
    // NOTE: Aave configuration functions have been moved to AaveYieldModule.
    // Use the yield module's configuration functions instead:
    // - AaveYieldModule.setAavePoolAddressesProvider()
    // - AaveYieldModule.setAaveEnabled()
    // - AaveYieldModule.registerTokenForAave()
    // - AaveYieldModule.batchRegisterTokensForAave()

    // Getter functions
    /**
     * @notice Get all attachments for an escrow transfer
     * @param workflowId The escrow transfer ID
     * @return uris Array of attachment URIs
     * @return hashes Array of attachment hashes
     * @dev Reverts if workflowId is invalid
     */
    function getAttachments(uint256 workflowId) public view returns (string[] memory uris, bytes32[] memory hashes) {
        _validateWorkflowId(workflowId);
        EscrowTransfer storage et = escrowTransfers[workflowId];
        return (et.attachmentURIs, et.attachmentHashes);
    }
    
    /**
     * @notice Get full escrow transfer details
     * @param workflowId The escrow transfer ID
     * @return Complete EscrowTransfer struct with all fields
     * @dev Reverts if workflowId is invalid
     */
    function getEscrowTransfer(uint256 workflowId) public view returns (EscrowTransfer memory) {
        _validateWorkflowId(workflowId);
        return escrowTransfers[workflowId];
    }
    
    /**
     * @notice Get total number of escrow transfers created
     * @return Total count of escrow transfers (nextWorkflowId)
     * @dev Returns the next workflow ID, which equals the total count of escrows created
     */
    function getEscrowCount() public view returns (uint256) {
        return nextWorkflowId;
    }
    
    /**
     * @notice Get the next workflow ID that will be assigned
     * @return The next workflow ID (equal to current escrow count)
     * @dev Allows off-chain systems to know the next ID before creating an escrow
     */
    function getNextWorkflowId() public view returns (uint256) {
        return nextWorkflowId;
    }
    
    /**
     * @notice Get escrow status information
     * @param workflowId The escrow transfer ID
     * @return status Current escrow state
     * @return isActive True if PENDING or DISPUTED
     * @return isPending True if PENDING
     * @dev Returns NONE status for invalid workflowId
     *      Replaces getEscrowStatus(), isEscrowActive(), and isEscrowPending()
     */
    function getEscrowStatusInfo(uint256 workflowId) public view returns (
        EscrowState status,
        bool isActive,
        bool isPending
    ) {
        if (workflowId >= nextWorkflowId) {
            return (EscrowState.NONE, false, false);
        }
        status = escrowTransfers[workflowId].escrowState;
        isPending = (status == EscrowState.PENDING);
        isActive = (status == EscrowState.PENDING || status == EscrowState.DISPUTED);
    }
    
    /**
     * @notice Get the sender and recipient addresses for an escrow transfer
     * @param workflowId The escrow transfer ID
     * @return from Sender address
     * @return to Recipient address
     * @dev Reverts if workflowId is invalid
     */
    function getEscrowParticipants(uint256 workflowId) public view returns (address from, address to) {
        _validateWorkflowId(workflowId);
        EscrowTransfer storage et = escrowTransfers[workflowId];
        return (et.from, et.to);
    }
    
    /**
     * @notice Get total number of escrows with a specific status
     * @param status The EscrowState to count
     * @return Count of escrows with the specified status
     * @dev Iterates through all escrows to count matching status. May consume significant gas for large escrow counts.
     */
    function getTotalEscrowsByStatus(EscrowState status) public view returns (uint256) {
        uint256 count = 0;
        for (uint256 i = 0; i < nextWorkflowId; i++) {
            if (escrowTransfers[i].escrowState == status) {
                count++;
            }
        }
        return count;
    }

    // Batch operations removed - moved to EscrowOps.sol for contract size reduction
    // Use EscrowOps contract for batch release and cancel operations

    /**
     * @notice ERC-165 interface detection
     * @param interfaceId The interface identifier
     * @return True if the contract implements the interface
     */
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return interfaceId == type(IERC165).interfaceId || super.supportsInterface(interfaceId);
    }

    /**
     * @notice Phase 2: Standardized resolve function with flexible payouts (ERC-ESCR-DISPUTE)
     * @param workflowId The escrow ID
     * @param payouts Array of payouts (recipient, amount) - must sum to available balance
     * @param resolutionHash Optional hash of resolution metadata for off-chain verification
     * @return True if resolution was successful
     * @dev Generalizes full release, full refund, partial splits, and multi-party payouts.
     *      Can be called by authorized dispute resolver or IResolver contract implementing the interface.
     *      Escrow must be in DISPUTED state. If escrow was generating yield via Aave, proportional yield is distributed.
     *      If all funds are distributed, escrow state changes to RESOLVED.
     */
    function resolve(
        uint256 workflowId,
        Payout[] calldata payouts,
        bytes32 resolutionHash
    ) public nonReentrant returns (bool) {
        _validateWorkflowId(workflowId);
        EscrowTransfer storage et = escrowTransfers[workflowId];
        address disputeResolver = _msgSender();
        if (!_isAuthorizedDisputeResolver(workflowId, disputeResolver)) {
            revert NotAuthorizedResolver(disputeResolver, et.disputeResolver);
        }

        // Now proceed with state changes (checks-effects-interactions pattern)
        if (et.escrowState != EscrowState.DISPUTED) {
            revert TransferNotInDispute(workflowId, et.escrowState);
        }

        uint256 totalPayout = ResolverLogicLibrary.validatePayouts(payouts, et.remainingBalance);

        EscrowState oldStatus = et.escrowState;

        uint256[] memory payoutAmounts = ResolverLogicLibrary.copyPayoutAmounts(payouts);
        
        IYieldGenerationModule genModule = _getYieldGenerationModule(workflowId);
        uint256 totalYield = address(genModule) == address(0) ? 0 : genModule.calculateYield(workflowId, et.token);
        uint256 yieldToDistribute = ResolverLogicLibrary.calculateTotalYieldToDistribute(totalYield, payoutAmounts, et.remainingBalance);
        
        uint256 originalDeposit = totalPayout;
        uint256 actualTotalPayout = totalPayout;
        if (address(genModule) != address(0)) {
            (bool success, uint256 amt) = genModule.withdrawProportional(workflowId, et.token, totalPayout, originalDeposit);
            if (success) actualTotalPayout = amt;
        }
        
        if (actualTotalPayout != totalPayout && totalPayout > 0) {
            payoutAmounts = ResolverLogicLibrary.adjustPayoutAmounts(payoutAmounts, actualTotalPayout, totalPayout);
            totalPayout = actualTotalPayout;
        }

        // State changes before external calls (checks-effects-interactions)
        et.remainingBalance -= totalPayout;
        _updateEscrowBalance(et.token, totalPayout, false);
        
        bool isComplete = (et.remainingBalance == 0);
        if (isComplete) {
            et.escrowState = EscrowState.RESOLVED;
            totalEscrowsPending--;
            
            // Note: Yield tracking is handled by the yield generation module
        }

        // Phase 2: Emit state change event
        if (isComplete) {
            emit EscrowStateChanged(workflowId, oldStatus, EscrowState.RESOLVED);
        }

        // Distribute yield if any (via YieldOps - Phase 1 size optimization)
        // Non-blocking: yield failures won't prevent dispute resolution
        if (yieldToDistribute > 0 && address(yieldOps) != address(0)) {
            // For resolveDispute with payouts, we handle this as proportional yield
            try yieldOps.handlePartialYield(
                _getYieldGenerationModule(workflowId),
                _getYieldDistributionModule(workflowId),
                workflowId,
                et.token,
                totalPayout,
                et.remainingBalance + totalPayout, // Before withdrawal
                et.totalDeposited
            ) {} catch {}
        }

        // External calls after state changes - execute payouts
        for (uint256 i = 0; i < payouts.length; i++) {
            _transferTokens(et.token, payouts[i].recipient, payoutAmounts[i]);
        }

        // Phase 2: Emit standardized resolution event
        emit EscrowResolved(workflowId, disputeResolver, resolutionHash);
        
        // Also emit legacy event for backward compatibility
        if (isComplete) {
            emit EscrowTransferResolved(workflowId, et.from, et.to, et.totalDeposited);
        }

        return true;
    }

    // _usePermit() removed for contract size reduction - see docs/PERMIT_FUNCTIONALITY_REMOVED.md
    
    /**
     * @notice Recover native ETH sent directly to the contract by mistake
     * @param recipient Address to receive the recovered ETH
     * @param amount Amount of ETH to recover (0 = recover all)
     * @dev Only ROLE_TIMELOCK can call this. Use this to recover ETH sent directly to the contract.
     *      This does NOT recover escrowed funds or fees - only ETH sent directly to the contract.
     */
    function recoverNativeETH(address recipient, uint256 amount) external onlyRole(ROLE_TIMELOCK) nonReentrant returns (bool) {
        uint256 balance = address(this).balance;
        uint256 recoverAmount = RecoveryLibrary.recoverNativeETH(recipient, amount, balance);
        emit NativeETHRecovered(recipient, recoverAmount);
        return true;
    }
    
    /**
     * @notice Recover ERC20 tokens sent directly to the contract by mistake
     * @param token ERC20 token address
     * @param recipient Address to receive the recovered tokens
     * @param amount Amount of tokens to recover (0 = recover all)
     * @dev Only ROLE_TIMELOCK can call this. Use this to recover tokens sent directly to the contract.
     *      This does NOT recover escrowed funds or fees - only tokens sent directly to the contract.
     *      For EscrowableERC20, this recovers tokens that are not part of any escrow.
     *      For EscrowVault, this recovers tokens that are not part of any escrow and not tracked as fees.
     */
    function recoverERC20(address token, address recipient, uint256 amount) external virtual onlyRole(ROLE_TIMELOCK) nonReentrant returns (bool) {
        IERC20 tokenContract = IERC20(token);
        uint256 balance = tokenContract.balanceOf(address(this));
        
        // For EscrowVault, check that we're not recovering tracked fees or escrowed amounts
        // This is handled by the derived contract if needed
        
        uint256 recoverAmount = RecoveryLibrary.recoverERC20(token, recipient, amount, balance);
        emit ERC20Recovered(token, recipient, recoverAmount);
        return true;
    }
}

