// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

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
import "./interfaces/IResolver.sol";
import "./interfaces/IResolutionModule.sol";
import "./interfaces/IYieldGenerationModule.sol";
import "./interfaces/IYieldDistributionModule.sol";
import "./libraries/SettingsValidationLibrary.sol";
import "./libraries/YieldDistributionLibrary.sol";
import "./libraries/EscrowEncodingLibrary.sol";
import "./libraries/ResolverLogicLibrary.sol";
import "./types/EscrowTypes.sol";
import "./governance/SlowLaneQueueActivate.sol";

// Aave interfaces and types have been moved to AaveYieldGenerationModule
// BaseEscrow no longer needs direct Aave integration

// Custom errors for better user experience
error InsufficientTokenBalance(uint256 balance, uint256 required);
error InvalidWorkflowId(uint256 workflowId, uint256 maxWorkflowId);
error TransferNotPending(uint256 workflowId, EscrowState currentStatus);
error NotAuthorizedResolver(address caller, address expectedResolver);
error NotDaoOrOwner(address caller, address owner, address dao); // Deprecated - will be removed after migration
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

enum EscrowState {
    NONE,
    PENDING,
    RELEASED,
    REFUNDED,
    DISPUTED,
    RESOLVED
}

enum SenderStatus {
    NONE,
    AGREE_TO_CANCEL,
    RAISE_DISPUTE
}

enum RecipientStatus {
    NONE,
    AGREE_TO_CANCEL,
    RAISE_DISPUTE
}

// EscrowType, EscrowSettings, and YieldDistribution moved to EscrowTypes.sol

struct EscrowTransfer {
    uint256 workflowId;
    address token; // ERC20 token address (for EscrowVault) or address(this) for EscrowableERC20
    address to;
    address from;
    uint256 remainingBalance; // remaining balance held in escrow (may be less than totalDeposited if partially released/cancelled)
    uint256 totalDeposited; // total amount originally deposited (before any releases/cancellations)
    EscrowState escrowState;
    SenderStatus senderStatus;
    RecipientStatus recipientStatus;
    address disputeResolver;
    uint256 autoReleaseTime;
    uint256 autoCancelTime;
    string[] attachmentURIs;
    bytes32[] attachmentHashes;
    bytes metadata; // optional metadata (IPFS hash, JSON, custom data)
    // Phase 7: Module snapshots (ensures module changes only affect new escrows)
    address snapshotResolutionModule;    // Resolution module at creation time
    address snapshotReleaseStrategy;     // Release strategy at creation time
    address snapshotYieldGenerationModule;  // Yield generation module at creation time
    address snapshotYieldDistributionModule; // Yield distribution module at creation time
}

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
    
    // Phase 7: authorizedResolver deprecated - resolver gate eliminated for mainnet credibility.
    // Kept as address(0) for backward compatibility, but no longer used in authorization checks.
    address private _deprecatedAuthorizedResolver;
    /// @notice Optional DAO address for governance-controlled upgrades (non-proxy).
    /// @dev For March 1 release you can transfer ownership to a multisig; this is an additional hook.
    address public dao;

    /// @notice Optional dispute resolution module. When set, NEW escrows pin `disputeResolver` via module.getResolver().
    address public resolutionModule;
    address public pendingResolutionModule;
    uint256 public pendingResolutionModuleEta;
    uint256 public resolutionModuleDelay = 0;
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

    // Yield distribution (prepared for Phase 2)
    YieldDistribution public defaultYieldDistribution;
    mapping(uint256 => YieldDistribution) public escrowYieldDistribution;

    // Slow lane pending changes (Phase 3)
    PendingAddress private _pendingFeeRecipient;
    PendingUint private _pendingEscrowFee;
    PendingAddress private _pendingDao;

    // Common events
    // Phase 1: Core lifecycle events (all have workflowId indexed for indexability)
    event EscrowStateChanged(uint256 indexed workflowId, EscrowState oldStatus, EscrowState newStatus);
    event EscrowTransferDisputed(uint256 indexed workflowId, address indexed from, address indexed to, uint256 amount);
    event EscrowTransferResolved(uint256 indexed workflowId, address indexed from, address indexed to, uint256 amount);
    event EscrowTransferResolvedWithPartialRelease(uint256 indexed workflowId, address indexed from, address indexed to, uint256 amount);
    event EscrowTransferResolvedWithPartialCancel(uint256 indexed workflowId, address indexed from, address indexed to, uint256 amount);
    // Phase 2: Standardized resolution event (ERC-ESCR-DISPUTE)
    event EscrowResolved(uint256 indexed workflowId, address indexed resolver, bytes32 resolutionHash);
    // Escalation events
    event DisputeEscalated(uint256 indexed workflowId, uint8 fromLevel, uint8 toLevel, address indexed newResolver, address indexed escalatedBy);
    event EscrowTransferAutoReleased(uint256 indexed workflowId, address indexed to, uint256 amount);
    event EscrowTransferAutoCancelled(uint256 indexed workflowId, address indexed from, uint256 amount);
    
    // Dispute safety mechanism events
    event MaxDisputeDurationUpdated(uint256 newDuration);
    event DisputeAutoCancelled(uint256 indexed workflowId, address indexed from, uint256 amount, string reason);
    
    // Phase 1: Cancel lifecycle events
    event CancelRequested(uint256 indexed workflowId, address indexed by);
    event CancelConfirmed(uint256 indexed workflowId, address indexed by);
    
    // Phase 1: Dispute lifecycle events
    event DisputeOpened(uint256 indexed workflowId, address indexed by, address indexed resolver);
    
    // Phase 1: Timeout execution events
    event TimeoutExecuted(uint256 indexed workflowId, uint8 action); // 0 = RELEASE, 1 = CANCEL
    
    // Evidence and attachments
    event EvidenceSubmitted(uint256 indexed workflowId, address indexed from, address indexed to, string evidence);
    event AttachmentAdded(uint256 indexed workflowId, string uri, bytes32 hash);
    // AttachmentSetAdded and release-with-attachment events removed - only single attachments supported
    
    // Configuration events
    event EscrowFeeUpdated(uint256 oldFee, uint256 newFee);
    event EscrowFeeAddressUpdated(address oldAddress, address newAddress);
    // Phase 7: AuthorizedResolverUpdated event deprecated (resolver gate removed)
    event DaoUpdated(address indexed oldDao, address indexed newDao);
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
    event DaoQueued(address indexed oldDao, address indexed newDao, uint64 eta);
    event DaoActivated(address indexed oldDao, address indexed newDao);
    
    // Yield distribution events
    event YieldDistributed(uint256 indexed workflowId, address indexed recipient, uint256 amount);
    // Note: Aave-specific events have been moved to AaveYieldGenerationModule
    event DefaultYieldDistributionUpdated(address[] recipients, uint256[] percentages);
    event EscrowYieldDistributionUpdated(uint256 indexed workflowId, address[] recipients, uint256[] percentages);
    
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
     * @notice Execute timeout for a single escrow (auto-release or auto-cancel)
     * @param workflowId The escrow transfer ID
     * @return True if timeout was executed, false otherwise
     * @dev Alias for automateTimedActions for single escrow (Phase 1: Standard naming)
     */
    function executeTimeout(uint256 workflowId) public returns (bool) {
        return automateTimedActions(workflowId);
    }
    
    /**
     * @notice Execute timeout for a single escrow (auto-release or auto-cancel)
     * @param workflowId The escrow transfer ID
     * @return True if timeout was executed, false otherwise
     * @dev As Ethereum can't trigger a timed action itself, this function needs to be called periodically.
     *      Called by a server. Could add a small reward to incentivise timely actions and create resilience to the server being down.
     *      Only processes escrows in PENDING state. Returns false if escrow is not pending or no timeout conditions are met.
     */
    function automateTimedActions(uint256 workflowId) public nonReentrant returns (bool) {
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

    /**
     * @notice Execute timeouts for multiple escrows within a specified range
     * @param workflowIdRangeStart Starting workflow ID (inclusive)
     * @param workflowIdRangeEnd Ending workflow ID (exclusive, will be capped at nextWorkflowId)
     * @return True if batch processing completed successfully
     * @dev Defining a range is necessary to avoid hitting gas limitations with a large number of workflows.
     *      Maximum range is limited by MAX_AUTOMATION_RANGE constant. Calls automateTimedActions for each escrow in the range.
     */
    function automateTimedActions(uint256 workflowIdRangeStart, uint256 workflowIdRangeEnd) public returns (bool) {
        if (workflowIdRangeEnd > nextWorkflowId) {
            workflowIdRangeEnd = nextWorkflowId;
        }
        if (workflowIdRangeEnd < workflowIdRangeStart) {
            revert InvalidWorkflowId(workflowIdRangeStart, nextWorkflowId);
        }
        uint256 range = workflowIdRangeEnd - workflowIdRangeStart;
        if (range > MAX_AUTOMATION_RANGE) {
            revert ExceedsMaxRange(range, MAX_AUTOMATION_RANGE);
        }
        for(uint256 i = workflowIdRangeStart; i < workflowIdRangeEnd; i++) {
            automateTimedActions(i);
        }
        return true;
    }

    /**
     * @notice Execute timeouts for all escrows
     * @return True if batch processing completed successfully
     * @dev Processes all escrows from 0 to nextWorkflowId. Use with caution as it may consume significant gas.
     */
    function automateTimedActions() public returns (bool) {
        automateTimedActions(0, nextWorkflowId);
        return true;
    }

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

    /**
     * @notice Set the authorized resolver address for disputes
     * @param resolver Address of the authorized resolver
     * @dev Phase 7: DEPRECATED - This function is kept for backward compatibility but does nothing.
     *      Resolver gate removed for mainnet credibility. Resolution now uses module snapshots only.
     */
    /**
     * @notice DEPRECATED: This function has been removed in Phase 7
     * @dev The authorizedResolver gate was eliminated for mainnet credibility.
     *      Resolution is now handled entirely through resolution modules.
     *      This function always reverts to prevent accidental use.
     * @param resolver (unused) - kept for interface compatibility
     * @custom:deprecated This function will be removed in a future version. Use resolution modules instead.
     */
    function setAuthorizedResolver(address resolver) public view onlyRole(ROLE_TIMELOCK) {
        resolver; // Silence unused parameter warning
        // Phase 7: Function removed - resolver gate eliminated
        // Always revert to prevent accidental use
        revert("setAuthorizedResolver: Deprecated and removed. Use resolution modules instead.");
    }

    modifier onlyDaoOrOwner() {
        // Deprecated - kept for backward compatibility during migration
        // Will be removed after all contracts are migrated
        if (!hasRole(ROLE_TIMELOCK, _msgSender()) && _msgSender() != dao) {
            revert NotDaoOrOwner(_msgSender(), address(0), dao);
        }
        _;
    }

    /**
     * @notice Queue a new DAO address (Slow lane: 7-day delay)
     * @param newDao New DAO address
     * @dev After 7 days, call activateDao() to apply the change
     */
    function queueDao(address newDao) external onlyRole(ROLE_TIMELOCK) {
        _queueAddress(_pendingDao, newDao);
        emit DaoQueued(dao, newDao, _pendingDao.eta);
    }

    /**
     * @notice Activate the queued DAO address
     * @dev Reverts if no pending change or 7-day delay has not elapsed
     */
    function activateDao() external onlyRole(ROLE_TIMELOCK) {
        address oldDao = dao;
        dao = _activateAddress(_pendingDao);
        emit DaoActivated(oldDao, dao);
        emit DaoUpdated(oldDao, dao);
    }

    /**
     * @notice Get pending DAO change (if any)
     * @return value Pending DAO address
     * @return eta Timestamp when activation is allowed
     * @return exists Whether a pending change exists
     */
    function getPendingDao() public view returns (address value, uint64 eta, bool exists) {
        return (getPendingAddress(_pendingDao));
    }

    /**
     * @notice Set the delay (in seconds) between proposing and activating a new resolution module.
     * @param newDelay Delay in seconds
     * @dev Phase 6: Bounds enforced: 48h <= newDelay <= 30 days
     */
    function setResolutionModuleDelay(uint256 newDelay) external onlyRole(ROLE_TIMELOCK) {
        SettingsValidationLibrary.validateResolutionDelay(newDelay);
        uint256 oldDelay = resolutionModuleDelay;
        resolutionModuleDelay = newDelay;
        emit ResolutionModuleDelayUpdated(oldDelay, newDelay);
    }

    /**
     * @notice Propose a new dispute resolution module. After the delay, it can be activated.
     * @dev New escrows will pin their disputeResolver using the active module.
     */
    function proposeResolutionModule(address newModule) external onlyRole(ROLE_TIMELOCK) {
        pendingResolutionModule = newModule;
        pendingResolutionModuleEta = block.timestamp + resolutionModuleDelay;
        emit ResolutionModuleProposed(newModule, pendingResolutionModuleEta);
    }

    /**
     * @notice Activate the previously proposed resolution module after the delay has elapsed.
     */
    function activateResolutionModule() external onlyRole(ROLE_TIMELOCK) {
        if (block.timestamp < pendingResolutionModuleEta) {
            revert ResolutionModuleNotReady(block.timestamp, pendingResolutionModuleEta);
        }
        address oldModule = resolutionModule;
        resolutionModule = pendingResolutionModule;
        pendingResolutionModule = address(0);
        pendingResolutionModuleEta = 0;
        emit ResolutionModuleActivated(oldModule, resolutionModule);
    }

    /**
     * @notice Resolver cancels a disputed escrow transfer and refunds to sender
     * @param workflowId The escrow transfer ID
     * @return True if cancellation was successful
     * @dev Only authorized resolver can call this. Escrow must be in DISPUTED state.
     *      After cancellation, escrow state changes to RESOLVED and funds are refunded to sender.
     */
    function resolverCancel(uint256 workflowId) public nonReentrant returns (bool) {
        _validateWorkflowId(workflowId);
        if (!_isAuthorizedResolver(workflowId, _msgSender())) {
            revert NotAuthorizedResolver(_msgSender(), escrowTransfers[workflowId].disputeResolver);
        }
        EscrowTransfer storage et = escrowTransfers[workflowId];
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
     * @dev Only authorized resolver can call this. Escrow must be in DISPUTED state.
     *      After release, escrow state changes to RESOLVED and funds are transferred to recipient.
     *      If escrow was generating yield via Aave, yield is distributed according to configured distribution.
     */
    function resolverRelease(uint256 workflowId) public nonReentrant returns (bool) {
        _validateWorkflowId(workflowId);
        if (!_isAuthorizedResolver(workflowId, _msgSender())) {
            revert NotAuthorizedResolver(_msgSender(), escrowTransfers[workflowId].disputeResolver);
        }
        EscrowTransfer storage et = escrowTransfers[workflowId];
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
        // Update escrow state first to prevent reentrancy
        et.remainingBalance = 0;
        et.escrowState = EscrowState.RESOLVED;
        _updateEscrowBalance(token, amount, false);
        totalEscrowsPending--;
        
        // Emit state change event
        emit EscrowStateChanged(workflowId, oldStatus, EscrowState.RESOLVED);
        
        // Handle yield generation module withdrawal
        IYieldGenerationModule genModule = _getYieldGenerationModule(workflowId);
        if (address(genModule) != address(0)) {
            (bool success, uint256 amt, ) = genModule.withdrawWithYield(workflowId, token, amount);
            if (success && amt > amount) {
                uint256 yield = amt - amount;
                _distributeYield(workflowId, token, yield);
            }
        }
        
        _transferTokens(token, to, amount);
        
        // Record resolution outcome in resolution module (for reversal tracking)
        _recordResolutionOutcome(workflowId, _msgSender(), true); // true = RELEASE
        
        // Clear dispute timestamp (dispute resolved)
        delete disputeRaisedTimestamp[workflowId];
        
        emit EscrowTransferResolved(workflowId, from, to, originalEscrowAmount);
        return true;
    }

    /**
     * @notice Resolver partially releases a disputed escrow transfer to recipient
     * @param workflowId The escrow transfer ID
     * @param amount Amount to release to recipient (must be less than or equal to escrow amount)
     * @return True if partial release was successful
     * @dev Only authorized resolver can call this. Escrow must be in DISPUTED state.
     *      If amount equals remaining escrow amount, escrow state changes to RESOLVED.
     *      If escrow was generating yield via Aave, proportional yield is distributed.
     */
    function resolverPartialRelease(uint256 workflowId, uint256 amount) public nonReentrant returns (bool) {
        _validateWorkflowId(workflowId);
        if (!_isAuthorizedResolver(workflowId, _msgSender())) {
            revert NotAuthorizedResolver(_msgSender(), escrowTransfers[workflowId].disputeResolver);
        }
        EscrowTransfer storage et = escrowTransfers[workflowId];
        if(et.escrowState != EscrowState.DISPUTED) {
            revert TransferNotInDispute(workflowId, et.escrowState);
        }

        if (amount == 0) {
            revert InvalidAmount("Amount must be greater than zero");
        }
        if (amount > et.remainingBalance) {
            revert AmountExceedsTransfer(workflowId, amount, et.remainingBalance);
        }
        
        // Save values and calculate yield before state changes
        address releaseTo = et.to;
        address from = et.from;
        uint256 originalAmount = et.totalDeposited;
        address token = et.token;
        uint256 actualAmount = amount;
        uint256 yieldToDistribute = 0;
        
        IYieldGenerationModule genModule = _getYieldGenerationModule(workflowId);
        uint256 totalYield = address(genModule) == address(0) ? 0 : genModule.calculateYield(workflowId, token);
        yieldToDistribute = ResolverLogicLibrary.calculateProportionalYield(totalYield, amount, et.remainingBalance);
        
        et.remainingBalance -= amount;
        bool isComplete = (et.remainingBalance == 0);
        if (isComplete) {
            et.escrowState = EscrowState.RESOLVED;
            totalEscrowsPending--;
            // Clear dispute timestamp (dispute fully resolved)
            delete disputeRaisedTimestamp[workflowId];
        }
        
        uint256 proportionalOriginalDeposit = amount;
        // Use the original full deposit amount for proportional calculation, not the partial amount
        uint256 originalDeposit = et.totalDeposited;
        if (address(genModule) != address(0)) {
            (bool success, uint256 amt) = genModule.withdrawProportional(workflowId, token, amount, originalDeposit);
            if (success) actualAmount = amt;
        }
        
        // Update escrow balance AFTER yield withdrawal (tokens are now back in contract)
        // Use proportional original deposit (not actual amount with yield)
        _updateEscrowBalance(token, proportionalOriginalDeposit, false);
        
        // Distribute yield if any (after state changes to prevent reentrancy)
        // This transfers yield to distribution recipients
        if (yieldToDistribute > 0) {
            _distributeYield(workflowId, token, yieldToDistribute);
        }
        
        // External call after all state changes
        // Transfer original amount (not actualAmount which includes yield - yield was already distributed)
        _transferTokens(token, releaseTo, amount);
        emit EscrowTransferResolvedWithPartialRelease(workflowId, from, releaseTo, amount);
        if (isComplete) {
            emit EscrowTransferResolved(workflowId, from, releaseTo, originalAmount);
        }
        return true;
    }

    /**
     * @notice Resolver partially cancels a disputed escrow transfer and refunds to sender
     * @param workflowId The escrow transfer ID
     * @param amount Amount to refund to sender (must be less than or equal to escrow amount)
     * @return True if partial cancel was successful
     * @dev Only authorized resolver can call this. Escrow must be in DISPUTED state.
     *      If amount equals remaining escrow amount, escrow state changes to RESOLVED.
     *      If escrow was generating yield via Aave, proportional yield is distributed.
     */
    function resolverPartialCancel(uint256 workflowId, uint256 amount) public nonReentrant returns (bool) {
        _validateWorkflowId(workflowId);
        if (!_isAuthorizedResolver(workflowId, _msgSender())) {
            revert NotAuthorizedResolver(_msgSender(), escrowTransfers[workflowId].disputeResolver);
        }
        EscrowTransfer storage et = escrowTransfers[workflowId];
        if(et.escrowState != EscrowState.DISPUTED) {
            revert TransferNotInDispute(workflowId, et.escrowState);
        }

        if (amount == 0) {
            revert InvalidAmount("Amount must be greater than zero");
        }
        if (amount > et.remainingBalance) {
            revert AmountExceedsTransfer(workflowId, amount, et.remainingBalance);
        }
        
        // Save values and calculate yield before state changes
        address refundTo = et.from;
        address to = et.to;
        uint256 originalAmount = et.totalDeposited;
        address token = et.token;
        uint256 actualAmount = amount;
        uint256 yieldToDistribute = 0;
        
        IYieldGenerationModule genModule = _getYieldGenerationModule(workflowId);
        uint256 totalYield = address(genModule) == address(0) ? 0 : genModule.calculateYield(workflowId, token);
        yieldToDistribute = ResolverLogicLibrary.calculateProportionalYield(totalYield, amount, et.remainingBalance);
        
        et.remainingBalance -= amount;
        bool isComplete = (et.remainingBalance == 0);
        if (isComplete) {
            EscrowState oldStatus = et.escrowState;
            et.escrowState = EscrowState.RESOLVED;
            totalEscrowsPending--;
            emit EscrowStateChanged(workflowId, oldStatus, EscrowState.RESOLVED);
            // Clear dispute timestamp (dispute fully resolved)
            delete disputeRaisedTimestamp[workflowId];
        }
        
        uint256 proportionalOriginalDeposit = amount;
        // Use the original full deposit amount for proportional calculation, not the partial amount
        uint256 originalDeposit = et.totalDeposited;
        if (address(genModule) != address(0)) {
            (bool success, uint256 amt) = genModule.withdrawProportional(workflowId, token, amount, originalDeposit);
            if (success) actualAmount = amt;
        }
        
        // Update escrow balance AFTER yield withdrawal (tokens are now back in contract)
        // Use proportional original deposit (not actual amount with yield)
        _updateEscrowBalance(token, proportionalOriginalDeposit, false);
        
        // Distribute yield if any (after state changes to prevent reentrancy)
        // This transfers yield to distribution recipients
        if (yieldToDistribute > 0) {
            _distributeYield(workflowId, token, yieldToDistribute);
        }
        
        // External call after all state changes
        // Transfer original amount (not actualAmount which includes yield - yield was already distributed)
        _transferTokens(token, refundTo, amount);
        emit EscrowTransferResolvedWithPartialCancel(workflowId, refundTo, to, amount);
        if (isComplete) {
            emit EscrowTransferResolved(workflowId, refundTo, to, originalAmount);
        }
        return true;
    }

    /**
     * @dev Check if an address is the authorized resolver for a specific escrow transfer.
     * @dev Authorization is pinned per escrow via EscrowTransfer.disputeResolver at escrow creation time.
     */
    function _isAuthorizedResolver(uint256 workflowId, address resolver) internal view returns (bool) {
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
            
            try IResolutionModule(snapshotModule).isAuthorizedResolver(
                workflowId,
                resolver,
                escrowData
            ) returns (bool authorized, uint8 /* role */) {
                if (authorized) {
                    return true;
                }
            } catch {
                // Module call failed, fall through to fallback check
            }
        }
        
        // Fallback: check against stored resolver (Phase 7: removed authorizedResolver gate)
        return resolver == et.disputeResolver;
    }

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
     * @dev Determine the dispute resolver for a new escrow, pinning the resolver at creation time.
     *      This ensures that future governance upgrades only affect NEW escrows.
     */
    function _getDisputeResolverForNewEscrow(
        uint256 workflowId,
        address token,
        address from,
        address to,
        uint256 amount,
        uint256 originalAmount
    ) internal view virtual returns (address) {
        // Phase 7: Always use resolution module (authorizedResolver gate removed)
        if (resolutionModule == address(0)) {
            revert ResolutionModuleNotConfigured();
        }

        bytes memory escrowData = _encodeResolutionData(token, from, to, amount, originalAmount);
        try IResolutionModule(resolutionModule).getResolver(workflowId, escrowData) returns (address resolver, uint8 /* escalationLevel */) {
            if (resolver == address(0)) {
                revert ResolutionModuleReturnedZeroAddress();
            }
            return resolver;
        } catch {
            revert ResolutionModuleCallFailed();
        }
    }

    /**
     * @notice Raise a dispute for an escrow transfer
     * @param workflowId The escrow transfer ID
     * @return True if dispute was raised successfully
     * @dev Only sender or recipient can raise a dispute. Escrow must be in PENDING state.
     *      After dispute is raised, escrow state changes to DISPUTED and can only be resolved by authorized resolver.
     *      If a custom resolver is configured, it will be notified via IResolver.onDisputeOpened callback.
     */
    function raiseDispute(uint256 workflowId) public returns (bool) {
        _validateWorkflowId(workflowId);
        EscrowTransfer storage et = escrowTransfers[workflowId];
        if(et.escrowState != EscrowState.PENDING) {
            revert TransferNotPending(workflowId, et.escrowState);
        }
        
        // Phase 1: Capture old status and resolver for events
        EscrowState oldStatus = et.escrowState;
        address resolver = et.disputeResolver;
        
        if(et.from == _msgSender()) {
            et.senderStatus = SenderStatus.RAISE_DISPUTE;
            et.escrowState = EscrowState.DISPUTED;
        } else if(et.to == _msgSender()) {
            et.recipientStatus = RecipientStatus.RAISE_DISPUTE;
            et.escrowState = EscrowState.DISPUTED;
        } else {
            revert NotParticipant(workflowId, _msgSender(), et.from, et.to);
        }
        
        // Record dispute timestamp for safety mechanism (prevent permanently stuck escrows)
        disputeRaisedTimestamp[workflowId] = block.timestamp;
        
        // Phase 1: Emit state change and dispute opened events
        emit EscrowStateChanged(workflowId, oldStatus, EscrowState.DISPUTED);
        emit DisputeOpened(workflowId, _msgSender(), resolver);
        emit EscrowTransferDisputed(workflowId, et.from, et.to, et.remainingBalance);
        
        // Phase 2: Initialize dispute in resolution module if active
        if (address(resolutionModule) != address(0)) {
            bytes memory escrowData = _encodeResolutionData(et.token, et.from, et.to, et.remainingBalance, et.totalDeposited);
            
            // Get resolver from module (may update resolver if module has dynamic assignment)
            try IResolutionModule(resolutionModule).getResolver(workflowId, escrowData) returns (address moduleResolver, uint8 /* escalationLevel */) {
                if (moduleResolver != address(0) && moduleResolver != resolver) {
                    // Module assigned a different resolver, update it
                    et.disputeResolver = moduleResolver;
                    resolver = moduleResolver;
                }
                
                // Try to initialize dispute in module (if it supports it)
                // This is optional - module may handle initialization internally
                _initializeDisputeInModule(workflowId, resolver, et.token, et.remainingBalance);
            } catch {
                // Module call failed, use existing resolver
            }
        }
        
        // Phase 2: Call IResolver.onDisputeOpened if resolver is a contract implementing IResolver
        if (resolver.code.length > 0) {
            try IERC165(resolver).supportsInterface(type(IResolver).interfaceId) returns (bool supported) {
                if (supported) {
                    try IResolver(resolver).onDisputeOpened(workflowId, "") {
                        // Callback succeeded, continue
                    } catch {
                        // Callback failed, but don't revert - dispute is still opened
                    }
                }
            } catch {
                // Not an IResolver contract, continue
            }
        }
        
        return true;
    }
    
    /**
     * @notice Initialize dispute in resolution module (internal helper)
     * @param workflowId The escrow transfer ID
     * @param resolver The resolver address
     * @param token The token address
     * @param amount The escrow amount
     * @dev This function is called internally to initialize dispute metadata in the module
     *      Uses a try-catch pattern to handle modules that don't support initialization
     */
    function _initializeDisputeInModule(
        uint256 workflowId,
        address resolver,
        address token,
        uint256 amount
    ) internal {
        // Generate category key based on amount
        bytes32 categoryKey = _generateCategoryKey(token, amount);
        
        // Try to call initializeDispute if module supports it
        // Use low-level call to handle modules that may not have this function
        (bool success, ) = resolutionModule.call(
            abi.encodeWithSignature(
                "initializeDispute(uint256,address,bytes32)",
                workflowId,
                resolver,
                categoryKey
            )
        );
        
        // If call fails, that's okay - module may handle initialization internally
        // or may not support this function (e.g., DefaultResolutionModule)
        success; // Silence unused variable warning
    }
    
    /**
     * @notice Record resolution outcome in resolution module (for reversal tracking)
     * @param workflowId The escrow transfer ID
     * @param resolver Resolver address
     * @param isRelease True if RELEASE, false if CANCEL
     * @dev Optimized for contract size: minimal bytecode footprint
     *      Calls recordResolution on DecentralizedResolutionModule if available
     */
    function _recordResolutionOutcome(
        uint256 workflowId,
        address resolver,
        bool isRelease
    ) internal {
        address module = resolutionModule;
        if (module == address(0)) return;
        // ResolutionOutcome: 1 = RELEASE, 2 = CANCEL
        (bool success, ) = module.call(
            abi.encodeWithSignature(
                "recordResolution(uint256,address,uint8,bool,uint256)",
                workflowId, resolver, isRelease ? 1 : 2, false, 0
            )
        );
        success; // Silence unused variable warning
    }
    
    /**
     * @notice Generate category key for resolution table lookup
     * @param token Token address
     * @param amount Escrow amount
     * @return Category key
     * @dev Generates a category key based on amount ranges
     */
    function _generateCategoryKey(address token, uint256 amount) internal pure returns (bytes32) {
        // Simple amount-based categorization
        if (amount < 1 ether) {
            return keccak256(abi.encodePacked(token, "SMALL"));
        } else if (amount < 10 ether) {
            return keccak256(abi.encodePacked(token, "MEDIUM"));
        } else if (amount < 100 ether) {
            return keccak256(abi.encodePacked(token, "LARGE"));
        } else {
            return keccak256(abi.encodePacked(token, "VERY_LARGE"));
        }
    }
    
    /**
     * @notice Escalate a dispute to the next resolution level
     * @param workflowId The escrow transfer ID
     * @return success True if escalation was successful
     * @return newResolver Address of the new resolver
     * @return newLevel New escalation level
     * @dev Only participants (sender or recipient) can escalate. Escrow must be in DISPUTED state.
     *      Escalation fees are handled by the resolution module.
     */
    function escalateDispute(uint256 workflowId) public payable nonReentrant returns (
        bool success,
        address newResolver,
        uint8 newLevel
    ) {
        _validateWorkflowId(workflowId);
        EscrowTransfer storage et = escrowTransfers[workflowId];
        
        // Only participants can escalate
        if (et.from != _msgSender() && et.to != _msgSender()) {
            revert NotParticipant(workflowId, _msgSender(), et.from, et.to);
        }
        
        // Escrow must be in dispute
        if (et.escrowState != EscrowState.DISPUTED) {
            revert TransferNotInDispute(workflowId, et.escrowState);
        }
        
        // Resolution module must be active
        if (address(resolutionModule) == address(0)) {
            revert InvalidAddress("Resolution module not set", address(0));
        }
        
        // Get current escalation level from module
        bytes memory escrowData = _encodeResolutionData(et.token, et.from, et.to, et.remainingBalance, et.totalDeposited);
        (, uint8 currentLevel) = IResolutionModule(resolutionModule).getResolver(
            workflowId,
            escrowData
        );
        
        // Check if escalation is allowed
        (bool canEscalate, , uint256 escalationFee) = IResolutionModule(resolutionModule).canEscalate(
            workflowId,
            currentLevel,
            escrowData
        );
        
        if (!canEscalate) {
            revert InvalidAmount("Escalation not allowed");
        }
        
        // Validate fee if required
        if (escalationFee > 0 && msg.value < escalationFee) {
            revert InvalidAmount("Insufficient escalation fee");
        }
        
        // Execute escalation in module
        (bool escalationSuccess, address newResolverAddress, uint8 newEscalationLevel) = 
            IResolutionModule(resolutionModule).executeEscalation(workflowId, escrowData);
        
        if (!escalationSuccess) {
            revert ResolutionModuleCallFailed();
        }
        
        // Update resolver in escrow
        et.disputeResolver = newResolverAddress;
        
        // Transfer escalation fee to fee address
        if (escalationFee > 0 && escrowFeeAddress != address(0)) {
            payable(escrowFeeAddress).transfer(escalationFee);
        }
        
        // Refund excess fee
        if (msg.value > escalationFee) {
            payable(_msgSender()).transfer(msg.value - escalationFee);
        }
        
        // Emit event
        emit DisputeEscalated(workflowId, currentLevel, newEscalationLevel, newResolverAddress, _msgSender());
        
        return (true, newResolverAddress, newEscalationLevel);
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
     * @param settings Settings to apply (custom resolver, auto times, etc.)
     * @dev Applies custom resolver if set, auto times (or defaults if not set), and stores settings
     */
    function _applyEscrowSettings(uint256 workflowId, EscrowSettings memory settings) internal {
        EscrowTransfer storage et = escrowTransfers[workflowId];
        
        // Apply custom resolver
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
     * @return Default settings struct with all fields set to default values (no custom resolver, no yield, no auto times, STANDARD type)
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

    /**
     * @notice Check if escrow is generating yield
     * @param workflowId The escrow transfer ID
     * @return True if escrow has yield generation module and is generating yield
     * @dev Queries the yield generation module to determine if escrow is generating yield
     */
    function isEscrowInAave(uint256 workflowId) public view returns (bool) {
        _validateWorkflowId(workflowId);
        IYieldGenerationModule generationModule = _getYieldGenerationModule(workflowId);
        if (address(generationModule) == address(0)) {
            return false;
        }
        // Check if there's any yield (if calculateYield > 0, escrow is generating yield)
        uint256 yield = generationModule.calculateYield(workflowId, escrowTransfers[workflowId].token);
        return yield > 0;
    }

    /**
     * @notice Get escrow's yield token balance (e.g., aToken balance for Aave)
     * @param workflowId The escrow transfer ID
     * @return yieldTokenBalance Yield token balance at deposit time
     * @dev Queries the yield generation module. Returns 0 if no yield module or not generating yield.
     */
    function getEscrowATokenBalance(uint256 workflowId) public view returns (uint256) {
        _validateWorkflowId(workflowId);
        IYieldGenerationModule generationModule = _getYieldGenerationModule(workflowId);
        if (address(generationModule) == address(0)) {
            return 0;
        }
        // For AaveYieldGenerationModule, we can query the module directly
        // This is a view function that queries the module's internal state
        // Note: This requires the module to expose this data, or we return 0
        return 0; // Module-specific data, not available via interface
    }

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
    
    /**
     * @notice Get the current escrow amount for a transfer
     * @param workflowId The escrow transfer ID
     * @return Current amount held in escrow (may be less than totalDeposited if partially released/cancelled)
     * @dev Reverts if workflowId is invalid
     * @dev NOTE: Consider using getRemainingBalance() instead for clearer naming
     */
    function getEscrowAmount(uint256 workflowId) public view returns (uint256) {
        _validateWorkflowId(workflowId);
        return escrowTransfers[workflowId].remainingBalance;
    }
    
    /**
     * @notice Get escrow's original deposit amount (for yield calculation)
     * @param workflowId The escrow transfer ID
     * @return Original deposit amount
     * @dev Returns the total amount originally deposited.
     *      For yield tracking, query the yield generation module directly.
     * @dev NOTE: Consider using getTotalDeposited() instead for clearer naming
     */
    function getEscrowOriginalDeposit(uint256 workflowId) public view returns (uint256) {
        _validateWorkflowId(workflowId);
        return escrowTransfers[workflowId].totalDeposited;
    }

    /**
     * @dev Internal function to cancel and refund an escrow
     * @param workflowId The escrow transfer ID
     * @dev Cancels the escrow, changes state to REFUNDED, and transfers funds back to sender.
     *      If escrow was generating yield via Aave, withdraws from Aave first.
     *      Must be implemented by derived contracts to handle token transfers.
     */
    function _cancelAndRefund(uint256 workflowId) internal {
        EscrowTransfer storage et = escrowTransfers[workflowId];
        
        // Phase 1: Emit state change event
        EscrowState oldStatus = et.escrowState;
        
        // Save values before state changes
        uint256 amount = et.remainingBalance;
        address from = et.from;
        uint256 originalAmount = et.totalDeposited;
        address token = et.token;
        
        // State changes BEFORE external calls (checks-effects-interactions)
        // Update escrow state first to prevent reentrancy
        et.escrowState = EscrowState.REFUNDED;
        et.remainingBalance = 0;
        totalEscrowsPending--;
        
        emit EscrowStateChanged(workflowId, oldStatus, EscrowState.REFUNDED);
        
        uint256 originalDeposit = amount;
        IYieldGenerationModule genModule = _getYieldGenerationModule(workflowId);
        if (address(genModule) != address(0)) {
            (bool success, uint256 amt, ) = genModule.withdrawWithYield(workflowId, token, originalDeposit);
            if (success) amount = amt;
        }
        
        // Update escrow balance AFTER yield withdrawal (tokens are now back in contract)
        // Use original deposit amount for balance tracking
        uint256 balanceToUpdate = originalDeposit;
        _updateEscrowBalance(token, balanceToUpdate, false);
        
        // External call after all state changes
        _transferTokens(token, from, amount);
        _emitEscrowTransferCancelled(workflowId, token, from, originalAmount);
    }

    /**
     * @dev Internal function to release an escrow transfer
     * @param workflowId The escrow transfer ID
     * @dev Releases the escrow, changes state to RELEASED, and transfers funds to recipient.
     *      If escrow was generating yield via Aave, withdraws from Aave and distributes yield.
     *      Must be implemented by derived contracts to handle token transfers.
     */
    function _releaseEscrowTransfer(uint256 workflowId) internal {
        EscrowTransfer storage et = escrowTransfers[workflowId];
        
        // Phase 1: Capture old status for state change event
        EscrowState oldStatus = et.escrowState;
        
        // Save values before state changes
        uint256 amount = et.remainingBalance;
        address to = et.to;
        uint256 originalAmount = et.totalDeposited;
        address token = et.token;
        uint256 yield = 0;
        
        // State changes BEFORE external calls (checks-effects-interactions)
        // Update escrow state first to prevent reentrancy
        et.escrowState = EscrowState.RELEASED;
        et.remainingBalance = 0;
        totalEscrowsPending--;
        
        emit EscrowStateChanged(workflowId, oldStatus, EscrowState.RELEASED);
        
        uint256 originalDeposit = amount;
        IYieldGenerationModule genModule = _getYieldGenerationModule(workflowId);
        uint256 actualAmount = originalDeposit;
        if (address(genModule) != address(0)) {
            (bool success, uint256 amt, ) = genModule.withdrawWithYield(workflowId, token, originalDeposit);
            if (success) actualAmount = amt;
        }
        yield = actualAmount > originalDeposit ? actualAmount - originalDeposit : 0;
        amount = originalDeposit;
        
        // Update escrow balance AFTER yield withdrawal (tokens are now back in contract)
        // Use original deposit amount for balance tracking
        _updateEscrowBalance(token, originalDeposit, false);
        
        // Distribute yield if any (after state changes to prevent reentrancy)
        // This transfers yield to distribution recipients
        if (yield > 0) {
            _distributeYield(workflowId, token, yield);
        }
        
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
     * @param resolutionModuleAddr Resolution module address
     * @param releaseStrategyAddr Release strategy address
     * @param yieldGenerationModuleAddr Yield generation module address
     * @param yieldDistributionModuleAddr Yield distribution module address
     * @dev Stores current module addresses in escrow struct to ensure module changes only affect new escrows
     */
    function _snapshotModulesForEscrow(
        uint256 workflowId,
        address resolutionModuleAddr,
        address releaseStrategyAddr,
        address yieldGenerationModuleAddr,
        address yieldDistributionModuleAddr
    ) internal {
        EscrowTransfer storage et = escrowTransfers[workflowId];
        
        // Snapshot current module addresses
        et.snapshotResolutionModule = resolutionModuleAddr;
        et.snapshotReleaseStrategy = releaseStrategyAddr;
        et.snapshotYieldGenerationModule = yieldGenerationModuleAddr;
        et.snapshotYieldDistributionModule = yieldDistributionModuleAddr;
        
        emit EscrowModuleSnapshot(
            workflowId,
            resolutionModuleAddr,
            releaseStrategyAddr,
            yieldGenerationModuleAddr,
            yieldDistributionModuleAddr
        );
    }

    /**
     * @dev Encode yield distribution data for module
     * @param workflowId The escrow transfer ID
     * @return Encoded distribution data (recipients and percentages) as bytes
     * @dev Uses escrow-specific distribution if set, otherwise falls back to default distribution.
     *      Encodes as (address[], uint256[]) tuple for yield module consumption.
     */
    function _encodeYieldDistribution(uint256 workflowId) internal view returns (bytes memory) {
        YieldDistribution memory distribution;
        
        // Check if escrow has custom distribution, otherwise use default
        if (escrowYieldDistribution[workflowId].isSet) {
            distribution = escrowYieldDistribution[workflowId];
        } else {
            distribution = defaultYieldDistribution;
        }
        
        // Encode using library
        return YieldDistributionLibrary.encodeYieldDistribution(distribution);
    }

    function _distributeYield(uint256 workflowId, address token, uint256 yieldAmount) internal {
        if (yieldAmount == 0) return;
        
        IYieldDistributionModule distributionModule = _getYieldDistributionModule(workflowId);
        
        if (address(distributionModule) == address(0)) {
            YieldDistribution memory distribution = escrowYieldDistribution[workflowId].isSet 
                ? escrowYieldDistribution[workflowId] 
                : defaultYieldDistribution;
            YieldDistributionLibrary.distributeYieldFallback(token, yieldAmount, distribution, escrowFeeAddress);
            return;
        }
        
        bytes memory distributionData = _encodeYieldDistribution(workflowId);
        (bool success, uint256 distributed) = distributionModule.distributeYield(
            workflowId, token, yieldAmount, distributionData
        );
        
        if (!success || distributed < yieldAmount) {
            uint256 remainder = yieldAmount - distributed;
            if (remainder > 0) {
                IERC20(token).safeTransfer(escrowFeeAddress, remainder);
            }
        }
    }

    /**
     * @dev Validate yield distribution parameters
     * @param recipients Array of recipient addresses
     * @param percentages Array of percentages in basis points (10000 = 100%)
     * @dev Reverts if validation fails: empty arrays, length mismatch, zero addresses, zero percentages,
     *      or percentages don't sum to 10000 (100%).
     */
    function _validateYieldDistribution(address[] memory recipients, uint256[] memory percentages) internal pure {
        // Phase 6: Use SettingsValidationLibrary for bounds enforcement
        SettingsValidationLibrary.validateYieldDistribution(recipients, percentages);
    }

    /**
     * @notice Set default yield distribution
     * @param recipients Array of recipient addresses
     * @param percentages Array of percentages in basis points (must sum to 10000)
     */
    function setDefaultYieldDistribution(
        address[] memory recipients,
        uint256[] memory percentages
    ) public onlyRole(ROLE_TIMELOCK) {
        _validateYieldDistribution(recipients, percentages);
        defaultYieldDistribution = YieldDistribution({
            recipients: recipients,
            percentages: percentages,
            isSet: true
        });
        emit DefaultYieldDistributionUpdated(recipients, percentages);
    }

    /**
     * @notice Set escrow-specific yield distribution
     * @param workflowId The escrow transfer ID
     * @param recipients Array of recipient addresses
     * @param percentages Array of percentages in basis points (must sum to 10000)
     */
    function setEscrowYieldDistribution(
        uint256 workflowId,
        address[] memory recipients,
        uint256[] memory percentages
    ) public {
        _validateWorkflowId(workflowId);
        
        EscrowTransfer storage et = escrowTransfers[workflowId];
        
        // Only sender or owner can set yield distribution
        if (et.from != _msgSender() && !hasRole(ROLE_TIMELOCK, _msgSender())) {
            revert NotParticipant(workflowId, _msgSender(), et.from, et.to);
        }
        
        // Can only set if pending
        if (et.escrowState != EscrowState.PENDING) {
            revert TransferNotPending(workflowId, et.escrowState);
        }
        
        _validateYieldDistribution(recipients, percentages);
        escrowYieldDistribution[workflowId] = YieldDistribution({
            recipients: recipients,
            percentages: percentages,
            isSet: true
        });
        emit EscrowYieldDistributionUpdated(workflowId, recipients, percentages);
    }

    /**
     * @notice Get default yield distribution
     * @return YieldDistribution struct
     */
    /**
     * @notice Get default yield distribution configuration
     * @return YieldDistribution struct with default recipients and percentages
     * @dev Returns the default yield distribution used when escrow-specific distribution is not set
     */
    function getDefaultYieldDistribution() public view returns (YieldDistribution memory) {
        return defaultYieldDistribution;
    }

    /**
     * @notice Get escrow yield distribution
     * @param workflowId The escrow transfer ID
     * @return YieldDistribution struct
     */
    function getEscrowYieldDistribution(uint256 workflowId) public view returns (YieldDistribution memory) {
        _validateWorkflowId(workflowId);
        return escrowYieldDistribution[workflowId];
    }

    // ============ Aave Configuration Functions ============
    // NOTE: Aave configuration functions have been moved to AaveYieldModule.
    // Use the yield module's configuration functions instead:
    // - AaveYieldModule.setAavePoolAddressesProvider()
    // - AaveYieldModule.setAaveEnabled()
    // - AaveYieldModule.registerTokenForAave()
    // - AaveYieldModule.batchRegisterTokensForAave()

    // Getter functions
    /**
     * @notice Get all attachment URIs for an escrow transfer
     * @param workflowId The escrow transfer ID
     * @return Array of attachment URIs
     * @dev Reverts if workflowId is invalid
     */
    function getAttachmentURIs(uint256 workflowId) public view returns (string[] memory) {
        _validateWorkflowId(workflowId);
        return escrowTransfers[workflowId].attachmentURIs;
    }

    /**
     * @notice Get all attachment hashes for an escrow transfer
     * @param workflowId The escrow transfer ID
     * @return Array of attachment hashes
     * @dev Reverts if workflowId is invalid. Hashes correspond to URIs returned by getAttachmentURIs.
     */
    function getAttachmentHashes(uint256 workflowId) public view returns (bytes32[] memory) {
        _validateWorkflowId(workflowId);
        return escrowTransfers[workflowId].attachmentHashes;
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
     * @notice Get the current status of an escrow transfer
     * @param workflowId The escrow transfer ID
     * @return EscrowState The current state of the escrow
     * @dev Reverts if workflowId is invalid
     */
    function getEscrowStatus(uint256 workflowId) public view returns (EscrowState) {
        _validateWorkflowId(workflowId);
        return escrowTransfers[workflowId].escrowState;
    }
    
    /**
     * @notice Check if an escrow is in an active state (PENDING or DISPUTED)
     * @param workflowId The escrow transfer ID
     * @return True if escrow is active (PENDING or DISPUTED), false otherwise
     * @dev Returns false for invalid workflowId
     */
    function isEscrowActive(uint256 workflowId) public view returns (bool) {
        if (workflowId >= nextWorkflowId) {
            return false;
        }
        EscrowState state = escrowTransfers[workflowId].escrowState;
        return state == EscrowState.PENDING || state == EscrowState.DISPUTED;
    }
    
    /**
     * @notice Check if an escrow transfer is in PENDING state
     * @param workflowId The escrow transfer ID
     * @return True if escrow is pending, false otherwise (including invalid workflowId)
     */
    function isEscrowPending(uint256 workflowId) public view returns (bool) {
        if (workflowId >= nextWorkflowId) {
            return false;
        }
        return escrowTransfers[workflowId].escrowState == EscrowState.PENDING;
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

    /**
     * @notice Batch release multiple escrow transfers
     * @param workflowIds Array of escrow transfer IDs to release
     * @return success True if all releases were successful
     * @dev Only sender can release their own escrows. Reverts if any escrow fails validation.
     */
    function batchReleaseEscrow(uint256[] memory workflowIds) public nonReentrant whenNotPaused returns (bool) {
        for (uint256 i = 0; i < workflowIds.length; i++) {
            uint256 workflowId = workflowIds[i];
            _validateWorkflowId(workflowId);
            
            EscrowTransfer storage et = escrowTransfers[workflowId];
            
            // Only sender can release
            if (et.from != _msgSender()) {
                revert NotSender(workflowId, _msgSender(), et.from);
            }
            
            // Must be pending - skip if not pending (don't revert entire batch)
            if (et.escrowState != EscrowState.PENDING) {
                continue; // Skip non-pending escrows
            }
            
            _releaseEscrowTransfer(workflowId);
        }
        return true;
    }

    /**
     * @notice Batch cancel multiple escrow transfers (mutual agreement required)
     * @param workflowIds Array of escrow transfer IDs to cancel
     * @return success True if batch processing completed
     * @dev Both sender and recipient must agree to cancel (via senderCancel/recipientCancel)
     *      This function only processes escrows where both parties have already agreed.
     *      Escrows without mutual agreement are skipped (don't revert entire batch).
     */
    function batchCancelEscrow(uint256[] memory workflowIds) public nonReentrant returns (bool) {
        for (uint256 i = 0; i < workflowIds.length; i++) {
            uint256 workflowId = workflowIds[i];
            _validateWorkflowId(workflowId);
            
            EscrowTransfer storage et = escrowTransfers[workflowId];
            
            // Must be pending
            if (et.escrowState != EscrowState.PENDING) {
                continue; // Skip non-pending escrows
            }
            
            // If sender is calling and recipient has agreed, set sender status
            if (et.from == _msgSender() && et.recipientStatus == RecipientStatus.AGREE_TO_CANCEL) {
                et.senderStatus = SenderStatus.AGREE_TO_CANCEL;
                emit CancelRequested(workflowId, _msgSender());
            }
            
            // Both parties must have agreed to cancel
            if (et.senderStatus == SenderStatus.AGREE_TO_CANCEL && 
                et.recipientStatus == RecipientStatus.AGREE_TO_CANCEL) {
                _cancelAndRefund(workflowId);
            }
            // If not both agreed, skip this escrow (don't revert entire batch)
        }
        return true;
    }

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
     *      Can be called by authorized resolver or IResolver contract implementing the interface.
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
        address resolver = _msgSender();
        if (!_isAuthorizedResolver(workflowId, resolver)) {
            revert NotAuthorizedResolver(resolver, et.disputeResolver);
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

        // Distribute yield if any
        if (yieldToDistribute > 0) {
            _distributeYield(workflowId, et.token, yieldToDistribute);
        }

        // External calls after state changes - execute payouts
        for (uint256 i = 0; i < payouts.length; i++) {
            _transferTokens(et.token, payouts[i].recipient, payoutAmounts[i]);
        }

        // Phase 2: Emit standardized resolution event
        emit EscrowResolved(workflowId, resolver, resolutionHash);
        
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
        if (recipient == address(0)) {
            revert InvalidAddress("Recipient cannot be zero address", recipient);
        }
        
        uint256 balance = address(this).balance;
        uint256 recoverAmount = amount == 0 ? balance : amount;
        
        if (recoverAmount == 0) {
            revert InvalidAmount("No ETH to recover");
        }
        
        if (recoverAmount > balance) {
            revert InvalidAmount("Amount exceeds contract balance");
        }
        
        payable(recipient).transfer(recoverAmount);
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
    function recoverERC20(address token, address recipient, uint256 amount) external onlyRole(ROLE_TIMELOCK) nonReentrant returns (bool) {
        if (token == address(0)) {
            revert InvalidAddress("Token address cannot be zero", token);
        }
        if (recipient == address(0)) {
            revert InvalidAddress("Recipient cannot be zero address", recipient);
        }
        
        IERC20 tokenContract = IERC20(token);
        uint256 balance = tokenContract.balanceOf(address(this));
        
        // Calculate recoverable amount
        uint256 recoverAmount = amount == 0 ? balance : amount;
        
        if (recoverAmount == 0) {
            revert InvalidAmount("No tokens to recover");
        }
        
        if (recoverAmount > balance) {
            revert InvalidAmount("Amount exceeds contract balance");
        }
        
        // For EscrowVault, check that we're not recovering tracked fees or escrowed amounts
        // This is handled by the derived contract if needed
        
        tokenContract.safeTransfer(recipient, recoverAmount);
        emit ERC20Recovered(token, recipient, recoverAmount);
        return true;
    }
}

