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
import "../interfaces/IResolver.sol";
import "../interfaces/IReleaseStrategy.sol";
import "../shared/interfaces/IResolutionModule.sol";
import "../interfaces/IYieldGenerationModule.sol";
import "../interfaces/IYieldDistributionModule.sol";
import "../libraries/SettingsValidationLibrary.sol";
import "../libraries/EscrowCreationLibrary.sol";
import "../libraries/EscrowEncodingLibrary.sol";
import "../libraries/ResolverLogicLibrary.sol";
import "../libraries/RecoveryLibrary.sol";
import "../libraries/ModuleProposalLibrary.sol";
import "../libraries/ResolverActionLibrary.sol";
import "../libraries/StateManagementLibrary.sol";
import "../libraries/DisputeInitializationLibrary.sol";
import "../libraries/DisputeManagementLibrary.sol";
import "../types/EscrowTypes.sol";
import "../governance/SlowLaneQueueActivate.sol";
import "../YieldOps.sol";
import "../DisputeOps.sol";
import "../EscrowOps.sol";

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
    
    bytes32 public constant ROLE_TIMELOCK = keccak256("ROLE_TIMELOCK");
    bytes32 public constant ROLE_GUARDIAN = keccak256("ROLE_GUARDIAN");
    
    // Interface ID for resolution functions (V1)
    bytes4 public constant RESOLUTION_INTERFACE_V1 = 
        bytes4(keccak256("cancelAsDisputeResolver(uint256,bytes32)")) ^
        bytes4(keccak256("releaseAsDisputeResolver(uint256,bytes32)")) ^
        bytes4(keccak256("partialReleaseAsDisputeResolver(uint256,uint256,bytes32)")) ^
        bytes4(keccak256("partialCancelAsDisputeResolver(uint256,uint256,bytes32)"));
    
    uint256 public escrowFee;
    uint256 public constant ESCROW_FEE_DENOMINATOR = 10000;
    uint256 public constant MAX_AUTOMATION_RANGE = 100;
    uint256 public nextWorkflowId = 0;
    EscrowTransfer[] public escrowTransfers;
    address public escrowFeeAddress;
    uint256 public totalFees = 0;
    uint256 public totalEscrowsPending = 0;
    
    address public disputeResolutionModule;
    uint256 public defaultAutoReleaseTime = 0;
    uint256 public defaultAutoCancelTime = 0;
    uint256 public constant MAX_AUTO_TIME_DURATION = 10 * 365 * 24 * 60 * 60;
    uint256 public maxDisputeDuration = 90 days;
    
    mapping(uint256 => uint256) public disputeRaisedTimestamp;
    mapping(uint256 => EscrowSettings) public escrowSettings;
    
    mapping(uint256 => address) internal snapshotResolutionModules;
    mapping(uint256 => address) internal snapshotReleaseStrategies;
    mapping(uint256 => address) internal snapshotYieldGenerationModules;
    mapping(uint256 => address) internal snapshotYieldDistributionModules;
    
    enum ModuleType { RESOLUTION, RELEASE, YIELD_GEN, YIELD_DIST }

    YieldOps public yieldOps;
    DisputeOps public disputeOps;
    EscrowOps public escrowOps;

    PendingAddress private _pendingFeeRecipient;
    PendingUint private _pendingEscrowFee;
    
    mapping(ModuleType => PendingAddress) private _pendingModules;

    event EscrowStateChanged(uint256 indexed workflowId, EscrowState oldStatus, EscrowState newStatus);
    event EscrowTransferDisputed(uint256 indexed workflowId, address indexed from, address indexed to, uint256 amount);
    event EscrowTransferResolved(uint256 indexed workflowId, address indexed from, address indexed to, uint256 amount);
    event EscrowTransferResolvedWithPartialRelease(uint256 indexed workflowId, address indexed from, address indexed to, uint256 amount);
    event EscrowTransferResolvedWithPartialCancel(uint256 indexed workflowId, address indexed from, address indexed to, uint256 amount);
    event EscrowResolved(uint256 indexed workflowId, address indexed disputeResolver, bytes32 resolutionHash);
    event DisputeEscalated(uint256 indexed workflowId, uint8 fromLevel, uint8 toLevel, address indexed newDisputeResolver, address indexed escalatedBy);
    event EscalationFeeCollected(uint256 indexed workflowId, uint256 fee, address indexed feeRecipient);
    event EscrowTransferAutoReleased(uint256 indexed workflowId, address indexed to, uint256 amount);
    event EscrowTransferAutoCancelled(uint256 indexed workflowId, address indexed from, uint256 amount);
    event MaxDisputeDurationUpdated(uint256 newDuration);
    event DisputeAutoCancelled(uint256 indexed workflowId, address indexed from, uint256 amount, string reason);
    event CancelRequested(uint256 indexed workflowId, address indexed by);
    event CancelConfirmed(uint256 indexed workflowId, address indexed by);
    event DisputeOpened(uint256 indexed workflowId, address indexed by, address indexed disputeResolver);
    event TimeoutExecuted(uint256 indexed workflowId, uint8 action);
    event EscrowFeeUpdated(uint256 oldFee, uint256 newFee);
    event EscrowFeeAddressUpdated(address oldAddress, address newAddress);
    event ResolutionModuleQueued(address indexed oldModule, address indexed newModule, uint64 eta);
    event ResolutionModuleActivated(address indexed oldModule, address indexed newModule);
    event EscrowSettingsUpdated(uint256 indexed workflowId, EscrowSettings settings);
    event EscrowModuleSnapshot(uint256 indexed workflowId, address resolutionModule, address releaseStrategy, address yieldGenerationModule, address yieldDistributionModule);
    event NativeETHRecovered(address indexed recipient, uint256 amount);
    event ERC20Recovered(address indexed token, address indexed recipient, uint256 amount);

    function queueEscrowFeeAddress(address a) public onlyRole(ROLE_TIMELOCK) { _queueAddress(_pendingFeeRecipient, a); }
    function activateEscrowFeeAddress() public onlyRole(ROLE_TIMELOCK) { escrowFeeAddress = _activateAddress(_pendingFeeRecipient); }
    function getPendingFeeRecipient() public view returns (address value, uint64 eta, bool exists) { return getPendingAddress(_pendingFeeRecipient); }
    function queueEscrowFee(uint256 f) public virtual onlyRole(ROLE_TIMELOCK) { _queueUint(_pendingEscrowFee, f); }
    function activateEscrowFee() public virtual onlyRole(ROLE_TIMELOCK) { escrowFee = _activateUint(_pendingEscrowFee); }
    function getPendingEscrowFee() public view virtual returns (uint256 value, uint64 eta, bool exists) { return getPendingUint(_pendingEscrowFee); }

    function autoCancelDisputedEscrow(uint256 workflowId) external nonReentrant returns (bool) {
        _validateWorkflowId(workflowId); EscrowTransfer storage et = escrowTransfers[workflowId];
        require(et.escrowState == EscrowState.DISPUTED, "Not in dispute");
        uint256 ts = disputeRaisedTimestamp[workflowId];
        require(ts > 0 && block.timestamp >= ts + maxDisputeDuration, "T");
        address from = et.from; uint256 amt = et.totalDeposited;
        _cancelAndRefund(workflowId); et.escrowState = EscrowState.RESOLVED;
        delete disputeRaisedTimestamp[workflowId];
        emit EscrowStateChanged(workflowId, EscrowState.DISPUTED, EscrowState.RESOLVED);
        emit DisputeAutoCancelled(workflowId, from, amt, "Timeout");
        emit EscrowTransferResolved(workflowId, from, et.to, amt);
        return true;
    }
    
    function isDisputeTimedOut(uint256 workflowId) external view returns (bool isTimedOut, uint256 timeRemaining) {
        _validateWorkflowId(workflowId);
        return DisputeManagementLibrary.isTimedOut(workflowId, escrowTransfers[workflowId].escrowState, disputeRaisedTimestamp[workflowId], maxDisputeDuration);
    }

    function pause() public onlyRole(ROLE_GUARDIAN) { _pause(); }
    function unpause() public onlyRole(ROLE_TIMELOCK) { _unpause(); }

    function createEscrow(address token, address to, uint256 amount, EscrowSettings memory settings) public nonReentrant whenNotPaused returns (uint256) {
        if (amount == 0) revert InvalidAmount("Amount > 0");
        _validateEscrowSettings(settings);
        
        uint256 workflowId = nextWorkflowId++;
        uint256 fee = amount * escrowFee / ESCROW_FEE_DENOMINATOR;
        uint256 amountAfterFee = amount - fee;
        
        _pullTokens(token, _msgSender(), amount);
        
        address defaultResolver = _getDisputeResolverForNewEscrow(workflowId, token, _msgSender(), to, amountAfterFee, amount);
        
        escrowTransfers.push(EscrowCreationLibrary.createEscrowTransferStruct(workflowId, token, to, _msgSender(), amount, amountAfterFee, defaultResolver));
        totalFees += fee; totalEscrowsPending++;
        
        _updateEscrowBalance(token, amountAfterFee, true);
        _recordFee(token, fee);
        _applyEscrowSettings(workflowId, settings);
        _snapshotModulesForEscrow(workflowId);
        
        if (settings.yieldEnabled) {
            IYieldGenerationModule genModule = _getYieldGenerationModule(workflowId);
            if (address(genModule) != address(0) && genModule.isTokenSupported(token)) _depositForYield(genModule, workflowId, token, amountAfterFee);
        }
        
        emit EscrowStateChanged(workflowId, EscrowState.PENDING, EscrowState.PENDING);
        _emitEscrowTransferCreated(workflowId, token, _msgSender(), to, amount);
        
        return workflowId;
    }

    function _pullTokens(address token, address from, uint256 amount) internal virtual;
    function _recordFee(address token, uint256 amount) internal virtual;
    function _depositForYield(IYieldGenerationModule genModule, uint256 workflowId, address token, uint256 amount) internal virtual;
    function _emitEscrowTransferCreated(uint256 workflowId, address token, address from, address to, uint256 amount) internal virtual;

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

    function setDefaultAutoCancelTime(uint256 time) public onlyRole(ROLE_TIMELOCK) { SettingsValidationLibrary.validateAutoCancel(time); defaultAutoCancelTime = time; }
    function setDefaultAutoReleaseTime(uint256 time) public onlyRole(ROLE_TIMELOCK) { SettingsValidationLibrary.validateAutoRelease(time); defaultAutoReleaseTime = time; }
    
    function setMaxDisputeDuration(uint256 duration) external onlyRole(ROLE_TIMELOCK) { maxDisputeDuration = duration; emit MaxDisputeDurationUpdated(duration); }

    function automateTimedActions(uint256 workflowId) public nonReentrant returns (bool) {
        _validateWorkflowId(workflowId);
        EscrowTransfer storage et = escrowTransfers[workflowId];
        if(et.escrowState != EscrowState.PENDING) return false;
        if(et.autoReleaseTime > 0 && block.timestamp >= et.autoReleaseTime) {
            _releaseEscrowTransfer(workflowId);
            emit TimeoutExecuted(workflowId, 0); emit EscrowTransferAutoReleased(workflowId, et.to, 0);
            return true;
        } else if(et.autoCancelTime > 0 && block.timestamp >= et.autoCancelTime) {
            _cancelAndRefund(workflowId);
            emit TimeoutExecuted(workflowId, 1); emit EscrowTransferAutoCancelled(workflowId, et.from, 0);
            return true;
        }
        return false;
    }

    function _cancelWorkflow(uint256 id, address caller, bool isSender) internal returns (bool) {
        EscrowTransfer storage et = escrowTransfers[id];
        if (isSender) et.senderStatus = SenderStatus.AGREE_TO_CANCEL;
        else et.recipientStatus = RecipientStatus.AGREE_TO_CANCEL;
        emit CancelRequested(id, caller);
        if (et.senderStatus == SenderStatus.AGREE_TO_CANCEL && et.recipientStatus == RecipientStatus.AGREE_TO_CANCEL) {
            emit CancelConfirmed(id, caller); _cancelAndRefund(id);
        }
        return true;
    }

    function recipientCancel(uint256 workflowId) public returns (bool) {
        _validateWorkflowId(workflowId); EscrowTransfer storage et = escrowTransfers[workflowId];
        if (et.to != _msgSender()) revert NotRecipient(workflowId, _msgSender(), et.to);
        if(et.escrowState != EscrowState.PENDING) revert TransferNotPending(workflowId, et.escrowState);
        return _cancelWorkflow(workflowId, _msgSender(), false);
    }

    function senderCancel(uint256 workflowId) public returns (bool) {
        _validateWorkflowId(workflowId); EscrowTransfer storage et = escrowTransfers[workflowId];
        if (et.from != _msgSender()) revert NotSender(workflowId, _msgSender(), et.from);
        if(et.escrowState != EscrowState.PENDING) revert TransferNotPending(workflowId, et.escrowState);
        return _cancelWorkflow(workflowId, _msgSender(), true);
    }

    function queueResolutionModule(address m) public onlyRole(ROLE_TIMELOCK) { 
        _queueAddress(_pendingModules[ModuleType.RESOLUTION], m); 
        emit ResolutionModuleQueued(disputeResolutionModule, m, _pendingModules[ModuleType.RESOLUTION].eta); 
    }
    function activateResolutionModule() public onlyRole(ROLE_TIMELOCK) { 
        address oldModule = disputeResolutionModule; 
        disputeResolutionModule = _activateAddress(_pendingModules[ModuleType.RESOLUTION]); 
        emit ResolutionModuleActivated(oldModule, disputeResolutionModule); 
    }
    function getPendingResolutionModule() public view returns (address value, uint64 eta, bool exists) { 
        return getPendingAddress(_pendingModules[ModuleType.RESOLUTION]); 
    }

    /**
     * @notice Shared internal function for executing resolution actions
     * @param workflowId The escrow workflow ID
     * @param isRelease True to release to recipient, false to cancel/refund to sender
     * @param amount If 0 or >= remainingBalance, treat as full resolution. If < remainingBalance, treat as partial.
     * @param resolutionHash Hash of resolution details (for offchain verification)
     * @return success True if resolution executed successfully
     */
    function _executeResolution(uint256 workflowId, bool isRelease, uint256 amount, bytes32 resolutionHash) internal returns (bool) {
        _validateWorkflowId(workflowId);
        EscrowTransfer storage et = escrowTransfers[workflowId];
        
        // Authorization check
        if (!_isAuthorizedDisputeResolver(workflowId, _msgSender())) 
            revert NotAuthorizedResolver(_msgSender(), et.disputeResolver);
        
        // State check
        if(et.escrowState != EscrowState.DISPUTED) 
            revert TransferNotInDispute(workflowId, et.escrowState);
        
        // Determine if full or partial
        uint256 remaining = et.remainingBalance;
        bool isFull = (amount == 0 || amount >= remaining);
        uint256 actualAmount = isFull ? remaining : amount;
        
        // Validate amount for partial
        if (!isFull && (actualAmount == 0 || actualAmount > remaining)) 
            revert InvalidAmount("Invalid amount");
        
        // Execute resolution
        if (isFull) {
            _executeFullResolution(workflowId, et, isRelease, actualAmount, resolutionHash);
        } else {
            _executePartialResolution(workflowId, et, isRelease, actualAmount, remaining, resolutionHash);
        }
        
        return true;
    }

    /**
     * @notice Execute full resolution (complete release or cancel)
     */
    function _executeFullResolution(
        uint256 workflowId,
        EscrowTransfer storage et,
        bool isRelease,
        uint256 amount,
        bytes32 resolutionHash
    ) internal {
        address recipient = isRelease ? et.to : et.from;
        address token = et.token;
        
        // Update state
        et.remainingBalance = 0;
        et.escrowState = EscrowState.RESOLVED;
        totalEscrowsPending--;
        _updateEscrowBalance(token, amount, false);
        delete disputeRaisedTimestamp[workflowId];
        
        emit EscrowStateChanged(workflowId, EscrowState.DISPUTED, EscrowState.RESOLVED);
        
        // Handle yield
        if (address(yieldOps) != address(0)) {
            IYieldGenerationModule genModule = _getYieldGenerationModule(workflowId);
            IYieldDistributionModule distModule = _getYieldDistributionModule(workflowId);
            try yieldOps.handleFullYield(genModule, distModule, workflowId, token, amount) {} catch {}
        }
        
        // Transfer tokens
        _transferTokens(token, recipient, amount);
        
        // Record outcome and emit events
        _recordResolutionOutcome(workflowId, _msgSender(), isRelease, resolutionHash);
        emit EscrowResolved(workflowId, _msgSender(), resolutionHash);
        emit EscrowTransferResolved(workflowId, et.from, et.to, et.totalDeposited);
    }

    /**
     * @notice Execute partial resolution (partial release or cancel)
     */
    function _executePartialResolution(
        uint256 workflowId,
        EscrowTransfer storage et,
        bool isRelease,
        uint256 amount,
        uint256 remaining,
        bytes32 resolutionHash
    ) internal {
        address recipient = isRelease ? et.to : et.from;
        address token = et.token;
        
        // Execute action using library
        IYieldGenerationModule genModule = _getYieldGenerationModule(workflowId);
        ResolverActionLibrary.ActionParams memory params = ResolverActionLibrary.ActionParams({
            workflowId: workflowId,
            amount: amount,
            isRelease: isRelease,
            isPartial: true,
            recipient: recipient,
            token: token,
            remainingBalance: remaining,
            totalDeposited: et.totalDeposited
        });
        
        ResolverActionLibrary.ActionResult memory result = 
            ResolverActionLibrary.executeAction(params, genModule);
        
        // Update state
        et.remainingBalance -= result.actualAmount;
        bool isComplete = (et.remainingBalance == 0);
        if (isComplete) {
            et.escrowState = EscrowState.RESOLVED;
            totalEscrowsPending--;
            delete disputeRaisedTimestamp[workflowId];
        }
        _updateEscrowBalance(token, result.actualAmount, false);
        
        // Handle yield
        if (result.yieldToDistribute > 0 && address(yieldOps) != address(0)) {
            IYieldDistributionModule distModule = _getYieldDistributionModule(workflowId);
            try yieldOps.handlePartialYield(
                genModule,
                distModule,
                workflowId,
                token,
                result.actualAmount,
                remaining,
                et.totalDeposited
            ) {} catch {}
        }
        
        // Transfer tokens
        _transferTokens(token, recipient, result.actualAmount);
        
        // Record outcome and emit events
        _recordResolutionOutcome(workflowId, _msgSender(), isRelease, resolutionHash);
        emit EscrowResolved(workflowId, _msgSender(), resolutionHash);
        if (isRelease) {
            emit EscrowTransferResolvedWithPartialRelease(workflowId, et.from, et.to, result.actualAmount);
        } else {
            emit EscrowTransferResolvedWithPartialCancel(workflowId, et.from, et.to, result.actualAmount);
        }
        if (isComplete) {
            emit EscrowTransferResolved(workflowId, et.from, et.to, et.totalDeposited);
        }
    }

    /**
     * @notice Cancel dispute resolution - refund full amount to sender
     * @param workflowId The escrow workflow ID
     * @param resolutionHash Hash of resolution details (for offchain verification)
     * @return success True if resolution executed successfully
     */
    function cancelAsDisputeResolver(uint256 workflowId, bytes32 resolutionHash) public nonReentrant returns (bool) {
        return _executeResolution(workflowId, false, 0, resolutionHash);
    }
    
    /**
     * @notice Release dispute resolution - release full amount to recipient
     * @param workflowId The escrow workflow ID
     * @param resolutionHash Hash of resolution details (for offchain verification)
     * @return success True if resolution executed successfully
     */
    function releaseAsDisputeResolver(uint256 workflowId, bytes32 resolutionHash) public nonReentrant returns (bool) {
        return _executeResolution(workflowId, true, 0, resolutionHash);
    }

    /**
     * @notice Partial release dispute resolution - release partial amount to recipient
     * @param workflowId The escrow workflow ID
     * @param amount Amount to release (must be > 0 and < remainingBalance)
     * @param resolutionHash Hash of resolution details (for offchain verification)
     * @return success True if resolution executed successfully
     */
    function partialReleaseAsDisputeResolver(uint256 workflowId, uint256 amount, bytes32 resolutionHash) public nonReentrant returns (bool) {
        return _executeResolution(workflowId, true, amount, resolutionHash);
    }

    /**
     * @notice Partial cancel dispute resolution - refund partial amount to sender
     * @param workflowId The escrow workflow ID
     * @param amount Amount to refund (must be > 0 and < remainingBalance)
     * @param resolutionHash Hash of resolution details (for offchain verification)
     * @return success True if resolution executed successfully
     */
    function partialCancelAsDisputeResolver(uint256 workflowId, uint256 amount, bytes32 resolutionHash) public nonReentrant returns (bool) {
        return _executeResolution(workflowId, false, amount, resolutionHash);
    }

    function _isAuthorizedDisputeResolver(uint256 workflowId, address disputeResolver) internal view returns (bool) {
        EscrowTransfer storage et = escrowTransfers[workflowId]; address snap = snapshotResolutionModules[workflowId];
        if (snap != address(0)) {
            try IResolutionModule(snap).isAuthorizedDisputeResolver(workflowId, disputeResolver, EscrowEncodingLibrary.encodeEscrowTransferData(et.token, et.from, et.to, et.remainingBalance, et.totalDeposited)) returns (bool authorized, uint8) {
                if (authorized) return true;
            } catch {}
        }
        return disputeResolver == et.disputeResolver;
    }

    function _getDisputeResolverForNewEscrow(uint256 workflowId, address token, address from, address to, uint256 amount, uint256 originalAmount) internal view virtual returns (address) {
        IResolutionModule module = _getResolutionModule(workflowId);
        if (address(module) == address(0)) revert ResolutionModuleNotConfigured();
        try module.getDisputeResolver(workflowId, EscrowEncodingLibrary.encodeEscrowTransferData(token, from, to, amount, originalAmount)) returns (address disputeResolver, uint8) {
            if (disputeResolver == address(0)) revert ResolutionModuleReturnedZeroAddress();
            return disputeResolver;
        } catch { revert ResolutionModuleCallFailed(); }
    }

    function raiseDispute(uint256 workflowId) public returns (bool) {
        _validateWorkflowId(workflowId); EscrowTransfer storage et = escrowTransfers[workflowId];
        if(et.escrowState != EscrowState.PENDING) revert TransferNotPending(workflowId, et.escrowState);
        address disputeResolver = et.disputeResolver; bool isSender = (et.from == _msgSender());
        if (!isSender && et.to != _msgSender()) revert NotParticipant(workflowId, _msgSender(), et.from, et.to);
        StateManagementLibrary.transitionToDisputed(et, workflowId, isSender); disputeRaisedTimestamp[workflowId] = block.timestamp;
        emit EscrowStateChanged(workflowId, EscrowState.PENDING, EscrowState.DISPUTED); emit DisputeOpened(workflowId, _msgSender(), disputeResolver);
        emit EscrowTransferDisputed(workflowId, et.from, et.to, et.remainingBalance);
        address updated = DisputeInitializationLibrary.initializeInModule(address(_getResolutionModule(workflowId)), workflowId, disputeResolver, EscrowEncodingLibrary.encodeEscrowTransferData(et.token, et.from, et.to, et.remainingBalance, et.totalDeposited));
        if (updated != disputeResolver) { et.disputeResolver = updated; disputeResolver = updated; }
        DisputeInitializationLibrary.callResolverCallback(disputeResolver, workflowId);
        return true;
    }

    function escalateDispute(uint256 workflowId) public payable nonReentrant returns (bool success, address newDisputeResolver, uint8 newLevel) {
        _validateWorkflowId(workflowId); EscrowTransfer storage et = escrowTransfers[workflowId];
        if (address(disputeOps) == address(0)) revert("!Ops");
        IResolutionModule resolutionModule = _getResolutionModule(workflowId);
        
        // Get escalation info via disputeOps (which calls canEscalate)
        DisputeOps.EscalationResult memory result = disputeOps.computeEscalation(address(resolutionModule), workflowId, _msgSender(), et.from, et.to, et.token, et.remainingBalance, et.totalDeposited, et.escrowState);
        if (!result.success) revert(result.failureReason);
        
        // Validate and collect fee
        (bool feeValid, uint256 excess) = disputeOps.validateEscalationFee(result.escalationFee, msg.value);
        if (!feeValid) revert InvalidAmount("Fee");
        if (result.escalationFee > 0) {
            if (escrowFeeAddress == address(0)) revert InvalidAddress("Fee", address(0));
            (bool s, ) = payable(escrowFeeAddress).call{value: result.escalationFee}("");
            require(s, "F"); 
            emit EscalationFeeCollected(workflowId, result.escalationFee, escrowFeeAddress);
            
            // Mark escalation fee as paid in resolution module (for DecentralizedResolutionModule)
            // This must be done before calling executeEscalation()
            // Use low-level call since not all modules implement this function
            (bool feeMarked, ) = address(resolutionModule).call(
                abi.encodeWithSignature("markEscalationFeePaid(uint256,uint256)", workflowId, result.escalationFee)
            );
            feeMarked; // Silence unused variable warning
        }
        
        // Re-compute escalation now that fee is marked as paid (if needed)
        // Note: disputeOps.computeEscalation already called executeEscalation, but it failed if fee wasn't paid
        // So we need to call it again, or better: call executeEscalation directly now
        bytes memory escrowData = EscrowEncodingLibrary.encodeEscrowTransferData(et.token, et.from, et.to, et.remainingBalance, et.totalDeposited);
        (bool escalationSuccess, address newResolver, uint8 newLevel_) = resolutionModule.executeEscalation(workflowId, escrowData);
        if (!escalationSuccess) revert("Escalation failed");
        
        // Update escrow state with new resolver
        et.disputeResolver = newResolver;
        if (excess > 0) { (bool s, ) = payable(_msgSender()).call{value: excess}(""); require(s, "R"); }
        emit DisputeEscalated(workflowId, result.currentLevel, newLevel_, newResolver, _msgSender());
        return (true, newResolver, newLevel_);
    }

    function _validateWorkflowId(uint256 workflowId) internal view { if (workflowId >= nextWorkflowId) revert InvalidWorkflowId(workflowId, nextWorkflowId); }
    function _requirePending(uint256 workflowId) internal view { _validateWorkflowId(workflowId); if(escrowTransfers[workflowId].escrowState != EscrowState.PENDING) revert TransferNotPending(workflowId, EscrowState.PENDING); }
    function _validateEscrowSettings(EscrowSettings memory settings) internal view { SettingsValidationLibrary.validateEscrowSettings(settings, block.timestamp); }
    function _applyEscrowSettings(uint256 workflowId, EscrowSettings memory settings) internal {
        EscrowTransfer storage et = escrowTransfers[workflowId];
        if (settings.customResolver != address(0)) et.disputeResolver = settings.customResolver;
        bool def = (settings.autoReleaseTime == 0 && settings.autoCancelTime == 0);
        et.autoReleaseTime = settings.autoReleaseTime > 0 ? uint64(settings.autoReleaseTime) : (def ? uint64(defaultAutoReleaseTime) : 0);
        et.autoCancelTime = settings.autoCancelTime > 0 ? uint64(settings.autoCancelTime) : (def ? uint64(defaultAutoCancelTime) : 0);
        escrowSettings[workflowId] = settings;
        emit EscrowSettingsUpdated(workflowId, settings);
    }

    function getDefaultSettings() public pure returns (EscrowSettings memory) { return SettingsValidationLibrary.getDefaultSettings(); }
    function updateEscrowSettings(uint256 workflowId, EscrowSettings memory settings) public {
        _validateWorkflowId(workflowId); EscrowTransfer storage et = escrowTransfers[workflowId];
        if (et.from != _msgSender() && !hasRole(ROLE_TIMELOCK, _msgSender())) revert NotParticipant(workflowId, _msgSender(), et.from, et.to);
        if (et.escrowState != EscrowState.PENDING) revert TransferNotPending(workflowId, et.escrowState);
        _validateEscrowSettings(settings); _applyEscrowSettings(workflowId, settings);
    }

    function getEscrowSettings(uint256 workflowId) public view returns (EscrowSettings memory) { _validateWorkflowId(workflowId); return escrowSettings[workflowId]; }
    function getTotalDeposited(uint256 workflowId) public view returns (uint256) { _validateWorkflowId(workflowId); return escrowTransfers[workflowId].totalDeposited; }
    function getRemainingBalance(uint256 workflowId) public view returns (uint256) { _validateWorkflowId(workflowId); return escrowTransfers[workflowId].remainingBalance; }

    function _cancelAndRefund(uint256 workflowId) internal {
        EscrowTransfer storage et = escrowTransfers[workflowId]; uint256 amount = et.remainingBalance; address from = et.from; uint256 originalAmount = et.totalDeposited; address token = et.token;
        EscrowState oldStatus = StateManagementLibrary.transitionToRefunded(et, workflowId);
        totalEscrowsPending--; emit EscrowStateChanged(workflowId, oldStatus, EscrowState.REFUNDED);
        if (address(yieldOps) != address(0)) {
            IYieldGenerationModule genModule = _getYieldGenerationModule(workflowId);
            IYieldDistributionModule distModule = _getYieldDistributionModule(workflowId);
            try yieldOps.handleFullYield(genModule, distModule, workflowId, token, amount) {} catch {}
        }
        _updateEscrowBalance(token, amount, false); _transferTokens(token, from, amount);
        _emitEscrowTransferCancelled(workflowId, token, from, originalAmount);
    }

    function _releaseEscrowTransfer(uint256 workflowId) internal {
        EscrowTransfer storage et = escrowTransfers[workflowId]; uint256 amount = et.remainingBalance; address to = et.to; uint256 originalAmount = et.totalDeposited; address token = et.token;
        EscrowState oldStatus = StateManagementLibrary.transitionToReleased(et, workflowId);
        totalEscrowsPending--; emit EscrowStateChanged(workflowId, oldStatus, EscrowState.RELEASED);
        if (address(yieldOps) != address(0)) {
            IYieldGenerationModule genModule = _getYieldGenerationModule(workflowId);
            IYieldDistributionModule distModule = _getYieldDistributionModule(workflowId);
            try yieldOps.handleFullYield(genModule, distModule, workflowId, token, amount) {} catch {}
        }
        _updateEscrowBalance(token, amount, false); _transferTokens(token, to, amount);
        _emitEscrowTransferReleased(workflowId, token, to, originalAmount);
    }

    function _transferTokens(address token, address to, uint256 amount) internal virtual;
    function _updateEscrowBalance(address token, uint256 amount, bool add) internal virtual;
    function _emitEscrowTransferCancelled(uint256 workflowId, address token, address from, uint256 originalAmount) internal virtual;
    function _emitEscrowTransferReleased(uint256 workflowId, address token, address to, uint256 originalAmount) internal virtual;
    function _getYieldGenerationModule(uint256 workflowId) internal view virtual returns (IYieldGenerationModule);
    function _getYieldDistributionModule(uint256 workflowId) internal view virtual returns (IYieldDistributionModule);
    function _getReleaseStrategy(uint256 workflowId) internal view virtual returns (IReleaseStrategy);
    function _getResolutionModule(uint256 workflowId) internal view virtual returns (IResolutionModule) {
        // BaseEscrow: return snapshotted module if exists, otherwise base-level module
        address snap = snapshotResolutionModules[workflowId];
        if (snap != address(0)) {
            return IResolutionModule(snap);
        }
        return IResolutionModule(disputeResolutionModule);
    }

    function getEscrowTransfer(uint256 id) public view returns (EscrowTransfer memory) { return escrowTransfers[id]; }
    function getEscrowCount() public view returns (uint256) { return nextWorkflowId; }
    function getNextWorkflowId() public view returns (uint256) { return nextWorkflowId; }
    function getEscrowStatusInfo(uint256 workflowId) public view returns (EscrowState status, bool isActive, bool isPending) { if (workflowId >= nextWorkflowId) return (EscrowState.NONE, false, false); status = escrowTransfers[workflowId].escrowState; isPending = (status == EscrowState.PENDING); isActive = (status == EscrowState.PENDING || status == EscrowState.DISPUTED); }
    function getEscrowParticipants(uint256 workflowId) public view returns (address from, address to) { return (escrowTransfers[workflowId].from, escrowTransfers[workflowId].to); }
    function getSnapshotResolutionModule(uint256 id) public view returns (address) { return snapshotResolutionModules[id]; }
    function getSnapshotReleaseStrategy(uint256 id) public view returns (address) { return snapshotReleaseStrategies[id]; }
    function getSnapshotYieldGenerationModule(uint256 id) public view returns (address) { return snapshotYieldGenerationModules[id]; }
    function getSnapshotYieldDistributionModule(uint256 id) public view returns (address) { return snapshotYieldDistributionModules[id]; }
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return interfaceId == RESOLUTION_INTERFACE_V1 ||
               interfaceId == type(IERC165).interfaceId ||
               super.supportsInterface(interfaceId);
    }

    function _recordResolutionOutcome(uint256 workflowId, address disputeResolver, bool isRelease, bytes32 /* resolutionHash */) internal {
        address module = address(_getResolutionModule(workflowId)); 
        if (module == address(0)) return;
        // Note: resolutionHash is available via EscrowResolved event if modules need it
        // Current module interface doesn't include it, but can be added in future versions
        (bool success, ) = module.call(abi.encodeWithSignature("recordResolution(uint256,address,uint8,bool,uint256)", workflowId, disputeResolver, isRelease ? 1 : 2, false, 0));
        success;
    }

    function recoverNativeETH(address recipient, uint256 amount) external onlyRole(ROLE_TIMELOCK) nonReentrant returns (bool) {
        uint256 rec = RecoveryLibrary.recoverNativeETH(recipient, amount, address(this).balance);
        emit NativeETHRecovered(recipient, rec); return true;
    }
    
    function recoverERC20(address token, address recipient, uint256 amount) external virtual onlyRole(ROLE_TIMELOCK) nonReentrant returns (bool) {
        uint256 rec = RecoveryLibrary.recoverERC20(token, recipient, amount, IERC20(token).balanceOf(address(this)));
        emit ERC20Recovered(token, recipient, rec); return true;
    }
}
