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
import '../types/EscrowTypes.sol';
import '../types/YieldPresets.sol';
import '../libraries/YieldPresetLibrary.sol';
import '../YieldOps.sol';
import '../DisputeOps.sol';
import '../SettlementOps.sol';
import '../CreateOps.sol';
import '../decentralized-resolution-module/IIncentiveModule.sol';
import './BondCollector.sol';
import '../libraries/AaveYieldLibrary.sol';
import '../interfaces/aave/AaveV3Interfaces.sol';

// Failure reason codes for events (replaces string reasons to save bytecode)
// IMPORTANT: Do not reorder. Only append new values.
enum FailureReason {
    UNKNOWN, // 0

    // Generic call / module wiring
    CALL_FAILED, // 1
    MALFORMED_RETURN_DATA, // 2
    MODULE_NOT_SET, // 3
    MODULE_NOT_CONTRACT, // 4

    // Transfers / accounting
    CONTRACT_INSUFFICIENT_BALANCE, // 5
    TRANSFER_FAILED, // 6
    PUSH_FAILED_FALLBACK_TO_PULL, // 7

    // Yield lifecycle
    DEPOSIT_FAILED, // 8
    WITHDRAWAL_FAILED, // 9
    LESS_THAN_PRINCIPAL, // 10

    // (reserve future: dispute/bond reasons appended later)
    TIMEOUT // 11
}

// EscrowTransferAutoResult reasonCode meanings:
// - If success == true: reasonCode is an action code (NOT a FailureReason).
//   - 0 = push transfer succeeded
//   - 1 = auto-release executed
//   - 2 = auto-cancel executed
//   - 3 = pending settlement executed
// - If success == false: reasonCode is a FailureReason value.

// Function selectors (replaces abi.encodeWithSignature strings to save bytecode)
bytes4 constant SEL_INCENTIVE_MODULE = bytes4(keccak256("incentiveModule()"));
bytes4 constant SEL_FINALIZE_DISPUTE = bytes4(keccak256("finalizeDispute(uint256)"));
bytes4 constant SEL_RECORD_RESOLUTION = bytes4(keccak256("recordResolution(uint256,address,uint8,uint256)"));

// High-signal errors (user-facing flows)
error InvalidWorkflowId(uint256 workflowId, uint256 maxWorkflowId);
error TransferNotPending(uint256 workflowId, EscrowState currentStatus);
error NotAuthorizedResolver(address caller, address expectedResolver);
error TransferNotInDispute(uint256 workflowId, EscrowState currentStatus);
error NotParticipant(uint256 workflowId, address caller, address sender, address recipient);
error NotSender(uint256 workflowId, address caller, address expectedSender);
error NotRecipient(uint256 workflowId, address caller, address expectedRecipient);
error AmountExceedsTransfer(uint256 workflowId, uint256 requestedAmount, uint256 availableAmount);
error InvalidEscrowFee(uint256 fee, uint256 maxFee);
error FeeExceedsMaximum(uint256 feeBps, uint256 maxFeeBps);
error NoClaimableBalance(uint256 workflowId, address recipient, address token);
error TransferNotFinalized(uint256 workflowId, EscrowState currentState);
error NoPendingSettlement(uint256 workflowId);
error AppealWindowNotExpired(uint256 workflowId, uint256 appealDeadline, uint256 currentTime);
error NotInDisputedState(uint256 workflowId, EscrowState currentState);
error YieldPresetLocked(uint256 workflowId);
error ExcessRefundTransferFailed(uint256 workflowId, address recipient, uint256 amount);

// Collapsed generic errors (internal/rarely-hit)
error InvalidState(uint256 workflowId, uint8 expected, uint8 actual);
error InvalidConfig(uint8 code, uint256 value);
// InvalidAddress already defined in EscrowTypes.sol
error TransferFailed(uint8 kind, address token, address to, uint256 amount);
error ResolutionModuleError(uint8 code);
error ZeroBondCollector();
error EscalationNotAllowed();
error AppealBondQueryFailed(uint256 workflowId);
error InvalidBondMsgValue(uint256 workflowId, uint256 required, uint256 provided);
error UnexpectedETH(uint256 workflowId, uint256 provided);
error BondCollectionFailed(uint256 workflowId);

// Errors used by child contracts (EscrowVault, EscrowableERC20)
error BalanceUnderflow(address token, uint256 currentBalance, uint256 requestedAmount);
error NotFeeAddress(address caller, address expectedFeeAddress);
error NoFeesToWithdraw(address token, uint256 availableFees);
error InsufficientContractBalance(address token, uint256 required, uint256 available);
error AmountExceedsAvailable(address token, uint256 requestedAmount, uint256 availableAmount);
error AccountingDeficit(address token, uint256 deficit);

abstract contract BaseEscrow is AccessControl, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;
    // PRIORITY: Removed using Address - using .code.length and .call directly saves bytecode

    // Aave library errors (scoped to avoid global name collisions)
    error AaveLibraryNotConfigured();
    error AavePoolNotConfigured();

    bytes32 public constant ROLE_TIMELOCK = keccak256('ROLE_TIMELOCK');
    bytes32 public constant ROLE_GUARDIAN = keccak256('ROLE_GUARDIAN');
    bytes32 public constant ROLE_ADMIN_CONTRACT = keccak256('ROLE_ADMIN_CONTRACT');


    uint256 public escrowFee;
    uint256 public constant ESCROW_FEE_DENOMINATOR = 10000;
    uint256 public constant MAX_ESCROW_FEE_BPS = 200; // 2% maximum escrow fee
    uint256 public constant MAX_AUTOMATION_RANGE = 100;
    uint256 public constant MAX_PROTOCOL_FEE_BPS = 3000; // 30% maximum
    EscrowTransfer[] public escrowTransfers; // Array index IS the workflowId
    address public escrowFeeAddress;

    // Protocol fees (in basis points)
    uint256 public yieldProtocolFeeBps; // Protocol fee on yield (0-3000 bps = 0-30%)
    uint256 public appealBondProtocolFeeBps; // Protocol fee on appeal bonds (0-3000 bps = 0-30%)

    address public disputeResolutionModule;

    // ============ Timeout Configuration ============
    TimeoutConfig public timeoutConfig;

    mapping(uint256 => uint256) public disputeRaisedTimestamp;
    mapping(uint256 => EscrowSettings) public escrowSettings;

    // Pull model: claimable balances (workflowId => recipient => amount)
    // Note: Each escrow has exactly one token (stored in EscrowTransfer.token)
    mapping(uint256 => mapping(address => uint256)) public claimableBalances;

    // Phase 1: Pending settlement storage (appeal window enforcement)
    struct PendingSettlement {
        bool exists;
        bool isRelease;
        uint256 appealDeadline;
        bytes32 resolutionHash;
    }
    mapping(uint256 => PendingSettlement) public pendingSettlements;

    // Module snapshots - grouped for better organization and potential gas savings
    struct ModuleSnapshot {
        address resolutionModule;
        address releaseStrategy;
        address yieldGenerationModule;
        address yieldDistributionModule;
        address incentiveModule; // PRIORITY 3: Snapshot incentive module at creation to avoid dynamic discovery
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
    BondCollector public bondCollector; // PRIORITY 2: External bond collection contract
    CreateOps public createOps;

    // Aave library pattern support
    address public aaveYieldLibrary; // Library address (0 = not configured, use YieldOps)
    bool public aaveYieldLibraryEnabled = false; // Feature flag

    // Per-escrow aToken tracking (for library pattern)
    // Maps: workflowId => aToken address => aToken balance at deposit
    mapping(uint256 => mapping(address => uint256)) internal escrowATokenBalances;
    // Maps: workflowId => token => is in yield (for library pattern)
    mapping(uint256 => mapping(address => bool)) internal escrowInYield;

    // Library pattern v2: Per-escrow "scaled" shares tracking to support multiple concurrent escrows per token.
    // This tracks the escrow's share of the pooled aToken position without relying on total aToken balance snapshots.
    // Maps: workflowId => token => scaledShares (ray-scaled)
    mapping(uint256 => mapping(address => uint256)) internal escrowYieldScaledShares;

    uint256 internal constant AAVE_RAY = 1e27;

    // Emergency unwind state
    uint256 public constant MAX_UNWIND_AMOUNT_PER_CALL = 1_000_000e18; // 1M tokens max per call
    uint256 public constant UNWIND_COOLDOWN = 1 hours; // Minimum time between unwinds per token
    mapping(address => uint256) public lastUnwindTimestamp; // token => last unwind time
    uint256 public totalUnwoundAmount; // Total amount unwound across all tokens (for monitoring)

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
    event EscrowTransferDisputed(
        uint256 indexed workflowId,
        address indexed from,
        address indexed to,
        uint256 amount
    );
    event EscrowTransferResolved(
        uint256 indexed workflowId,
        address indexed from,
        address indexed to,
        uint256 amount
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
    // PRIORITY: Removed EscrowTransferAutoReleased, EscrowTransferAutoCancelled, TimeoutExecuted
    // Use EscrowTransferAutoResult instead (consolidated event saves bytecode)
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
    event EscrowFeeUpdated(uint256 oldFee, uint256 newFee);
    event EscrowFeeAddressUpdated(address oldAddress, address newAddress);
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
    // Consolidated: TimeoutConfigUpdated now includes all timeout changes
    // event AppealWindowDurationUpdated removed - use TimeoutConfigUpdated
    // event DefaultAutoReleaseTimeUpdated removed - use TimeoutConfigUpdated
    // event DefaultAutoCancelTimeUpdated removed - use TimeoutConfigUpdated
    // event MaxDisputeDurationUpdated removed - use TimeoutConfigUpdated
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
    // MED-3/LOW-1: Events for monitoring failures (using reason codes to save bytecode)
    event IncentiveModuleCallFailed(
        uint256 indexed workflowId,
        bytes4 selector,
        uint8 reasonCode
    );
    event YieldHandlingFailed(
        uint256 indexed workflowId,
        address indexed token,
        uint256 amount,
        uint8 reasonCode
    );

    // Aave library events
    event AaveYieldLibrarySet(address indexed oldLibrary, address indexed newLibrary);
    event AaveYieldLibraryEnabled(bool enabled);
    event YieldDepositAttempted(
        uint256 indexed workflowId,
        address indexed token,
        uint256 amount,
        bool success,
        uint8 reasonCode
    );
    event YieldWithdrawalAttempted(
        uint256 indexed workflowId,
        address indexed token,
        uint256 amount,
        uint256 actualAmount,
        bool success,
        uint8 reasonCode
    );
    event EmergencyUnwindExecuted(
        address indexed token,
        uint256 aTokenAmount,
        uint256 underlyingAmount,
        uint256 timestamp,
        address indexed caller,
        uint8 reasonCode
    );

    // P2: consolidated telemetry surface for operational failures (best-effort paths only).
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

    // ============ Minimal Admin Setters (Only callable by EscrowAdminContract) ============
    function setFeeRecipient(address newAddr) external onlyRole(ROLE_ADMIN_CONTRACT) {
        escrowFeeAddress = newAddr;
    }

    function setEscrowFeeBps(uint256 feeBps) external onlyRole(ROLE_ADMIN_CONTRACT) {
        escrowFee = feeBps;
    }

    function setYieldProtocolFeeBps(uint256 feeBps) external onlyRole(ROLE_ADMIN_CONTRACT) {
        if (feeBps > MAX_PROTOCOL_FEE_BPS) revert FeeExceedsMaximum(feeBps, MAX_PROTOCOL_FEE_BPS);
        uint256 oldFee = yieldProtocolFeeBps;
        yieldProtocolFeeBps = feeBps;
        emit YieldProtocolFeeBpsUpdated(oldFee, feeBps);
    }

    function setAppealBondProtocolFeeBps(uint256 feeBps) external onlyRole(ROLE_ADMIN_CONTRACT) {
        if (feeBps > MAX_PROTOCOL_FEE_BPS) revert FeeExceedsMaximum(feeBps, MAX_PROTOCOL_FEE_BPS);
        uint256 oldFee = appealBondProtocolFeeBps;
        appealBondProtocolFeeBps = feeBps;
        emit AppealBondProtocolFeeBpsUpdated(oldFee, feeBps);
    }

    function setResolutionModule(address module) external onlyRole(ROLE_ADMIN_CONTRACT) {
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

    /**
     * @notice Set Aave yield library address (governance-controlled)
     * @param libraryAddress Address of AaveYieldLibrary contract
     * @dev Only ROLE_TIMELOCK can set. Library must be a contract with code.
     *      Setting library does NOT enable it - use setAaveYieldLibraryEnabled().
     */
    function setAaveYieldLibrary(address libraryAddress) external onlyRole(ROLE_TIMELOCK) {
        if (libraryAddress != address(0) && libraryAddress.code.length == 0) {
            revert NotAContract(2, libraryAddress); // 2 = aaveYieldLibrary
        }
        address oldLibrary = aaveYieldLibrary;
        aaveYieldLibrary = libraryAddress;
        emit AaveYieldLibrarySet(oldLibrary, libraryAddress);
    }

    /**
     * @notice Enable/disable Aave yield library (governance-controlled)
     * @param enabled True to use library, false to use YieldOps
     * @dev Only ROLE_TIMELOCK can enable. ROLE_GUARDIAN can disable (emergency).
     *      When disabled, falls back to YieldOps pattern.
     */
    function setAaveYieldLibraryEnabled(bool enabled) external {
        if (enabled) {
            require(hasRole(ROLE_TIMELOCK, _msgSender()), "Only timelock can enable");
            if (aaveYieldLibrary == address(0)) {
                revert AaveLibraryNotConfigured();
            }
        } else {
            require(
                hasRole(ROLE_TIMELOCK, _msgSender()) || hasRole(ROLE_GUARDIAN, _msgSender()),
                "Only timelock or guardian can disable"
            );
        }
        aaveYieldLibraryEnabled = enabled;
        emit AaveYieldLibraryEnabled(enabled);
    }

    /**
     * @notice Emergency unwind Aave positions for a specific token (guardian only)
     * @param token Underlying token address to unwind
     * @param maxATokenAmount Maximum aToken amount to unwind (safety limit)
     * @return underlyingAmount Actual underlying amount withdrawn to BaseEscrow
     * @dev CRITICAL SAFETY CONSTRAINTS:
     *      - Only callable by ROLE_GUARDIAN
     *      - Only callable when paused
     *      - Proceeds ALWAYS go to BaseEscrow (not guardian)
     *      - Rate limited (cooldown per token + max per call)
     *      - Scoped to specific token (not arbitrary transfers)
     *      - Cannot reroute funds (hardcoded destination = address(this))
     *      - Non-blocking (fails gracefully, doesn't revert)
     */
    function emergencyUnwindAavePosition(
        address token,
        uint256 maxATokenAmount
    ) external onlyRole(ROLE_GUARDIAN) whenPaused returns (uint256 underlyingAmount) {
        // Safety check 1: Must be paused
        if (!paused()) {
            emit EmergencyUnwindExecuted(token, 0, 0, block.timestamp, _msgSender(), 101); // 101 = not paused
            return 0;
        }
        
        // Safety check 2: Rate limiting (cooldown per token)
        uint256 lastUnwind = lastUnwindTimestamp[token];
        if (block.timestamp < lastUnwind + UNWIND_COOLDOWN) {
            emit EmergencyUnwindExecuted(token, 0, 0, block.timestamp, _msgSender(), 102); // 102 = cooldown
            return 0;
        }
        
        // Safety check 3: Amount limit
        if (maxATokenAmount > MAX_UNWIND_AMOUNT_PER_CALL) {
            emit EmergencyUnwindExecuted(token, 0, 0, block.timestamp, _msgSender(), 103); // 103 = exceeds limit
            return 0;
        }
        
        // Safety check 4: Library must be enabled and configured
        if (!aaveYieldLibraryEnabled || aaveYieldLibrary == address(0)) {
            emit EmergencyUnwindExecuted(token, 0, 0, block.timestamp, _msgSender(), uint8(FailureReason.MODULE_NOT_SET)); // 3 = MODULE_NOT_SET
            return 0;
        }
        
        // Get module and pool address (use default module for emergency)
        IYieldGenerationModule genModule = _getDefaultYieldGenerationModule();
        if (address(genModule) == address(0)) {
            emit EmergencyUnwindExecuted(token, 0, 0, block.timestamp, _msgSender(), uint8(FailureReason.MODULE_NOT_SET)); // 3 = MODULE_NOT_SET
            return 0;
        }
        
        // Safety: Verify module is a contract before calling
        if (address(genModule).code.length == 0) {
            emit EmergencyUnwindExecuted(token, 0, 0, block.timestamp, _msgSender(), uint8(FailureReason.MODULE_NOT_SET));
            return 0;
        }
        
        address aavePool = _getAavePoolAddress(genModule);
        address aToken = _getATokenAddress(genModule, token);
        
        if (aavePool == address(0) || aToken == address(0)) {
            emit EmergencyUnwindExecuted(token, 0, 0, block.timestamp, _msgSender(), uint8(FailureReason.MODULE_NOT_SET)); // 3 = MODULE_NOT_SET
            return 0;
        }
        
        // Safety check 5: Get BaseEscrow's aToken balance (scope restriction - only this token)
        uint256 aTokenBalance = IAaveAToken(aToken).balanceOf(address(this));
        if (aTokenBalance == 0) {
            emit EmergencyUnwindExecuted(token, 0, 0, block.timestamp, _msgSender(), 104); // 104 = nothing to unwind
            return 0;
        }
        
        // Safety check 6: Cap to max amount (amount limit)
        uint256 unwindAmount = aTokenBalance < maxATokenAmount ? aTokenBalance : maxATokenAmount;
        
        // CRITICAL: Unwind to BaseEscrow (address(this)), NOT to guardian or arbitrary address
        // This ensures guardian cannot reroute funds - destination is hardcoded
        // Use delegatecall to call library function (maintains msg.sender = BaseEscrow)
        (bool success, bytes memory returnData) = aaveYieldLibrary.delegatecall(
            abi.encodeWithSelector(AaveYieldLibrary.withdraw.selector, aavePool, token, unwindAmount, address(this))
        );
        if (success && returnData.length >= 32) {
            uint256 withdrawn = abi.decode(returnData, (uint256));
            underlyingAmount = withdrawn;
            
            // Update state (rate limiting)
            lastUnwindTimestamp[token] = block.timestamp;
            totalUnwoundAmount += underlyingAmount;
            
            emit EmergencyUnwindExecuted(
                token,
                unwindAmount,
                underlyingAmount,
                block.timestamp,
                _msgSender(),
                0 // 0 = success
            );
            return underlyingAmount;
        }
        // Delegatecall failed - emit event but don't revert (non-blocking)
        emit EmergencyUnwindExecuted(
            token,
            unwindAmount,
            0,
            block.timestamp,
            _msgSender(),
            uint8(FailureReason.WITHDRAWAL_FAILED) // 9 = WITHDRAWAL_FAILED (consistent with yield withdrawal)
        );
        return 0;
    }

    // ============ Escrow Creation ============
    /**
     * @notice Create a new escrow transfer
     * @param token Token address (ERC20 for EscrowVault, address(this) for EscrowableERC20)
     * @param to Recipient address
     * @param amount Total amount to escrow (fee deducted). Must be >= MIN_ESCROW_AMOUNT (1000 wei)
     * @param settings Escrow configuration (resolver, yield, auto-times, etc.)
     * @return workflowId The workflow ID (array index)
     * @dev Fee deducted from amount. Overflow protection in Solidity 0.8+.
     */
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

        // Pull tokens (state modification - must stay in BaseEscrow)
        _pullTokens(token, _msgSender(), amount);

        // Store escrow struct (state modification - must stay in BaseEscrow)
        escrowTransfers.push(
            EscrowTransfer({
                token: token,
                to: to,
                from: _msgSender(),
                amountAfterFee: result.amountAfterFee,
                escrowState: EscrowState.PENDING,
                senderStatus: SenderStatus.NONE,
                recipientStatus: RecipientStatus.NONE,
                disputeResolver: result.resolver,
                autoReleaseTime: 0, // Set by _applyEscrowSettings
                autoCancelTime: 0   // Set by _applyEscrowSettings
            })
        );

        // Update accounting (state modification - must stay in BaseEscrow)
        _updateEscrowBalance(token, result.amountAfterFee, true);
        _recordFee(token, result.fee);
        
        // Apply settings and snapshot modules (state modification - must stay in BaseEscrow)
        _applyEscrowSettings(workflowId, settings);
        _snapshotModulesForEscrow(workflowId);

        // Yield deposit (optional, non-blocking)
        if (result.yieldEnabled && result.shouldDepositYield) {
            // NEW: Check if library pattern is enabled
            if (aaveYieldLibraryEnabled && aaveYieldLibrary != address(0)) {
                _handleYieldDepositViaLibrary(workflowId, token, result.amountAfterFee);
            } else {
                // EXISTING: YieldOps pattern (unchanged)
                IYieldGenerationModule genModule = _getYieldGenerationModule(workflowId);
                if (address(genModule) != address(0) && genModule.isTokenSupported(token)) {
                    // Use low-level call to save bytecode
                    (bool success, ) = address(genModule).call(
                        abi.encodeWithSelector(IYieldGenerationModule.depositForYield.selector, workflowId, token, result.amountAfterFee)
                    );
                    if (!success) {
                        emit YieldHandlingFailed(workflowId, token, result.amountAfterFee, uint8(FailureReason.DEPOSIT_FAILED));
                        emit OperationFailure(
                            1,
                            workflowId,
                            address(genModule),
                            IYieldGenerationModule.depositForYield.selector,
                            uint8(FailureReason.DEPOSIT_FAILED)
                        );
                    }
                }
            }
        }

        // Emit events (state modification - must stay in BaseEscrow)
        emit EscrowCreated(workflowId, token, _msgSender(), to, amount, result.amountAfterFee, result.fee);
        emit EscrowStateChanged(workflowId, EscrowState.NONE, EscrowState.PENDING);
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
        
        // PRIORITY 3: Snapshot incentive module at creation to avoid dynamic discovery
        address incentiveMod = address(0);
        if (resModule != address(0)) {
            // Try to read incentiveModule from resolution module (if supported)
            (bool success, bytes memory data) = resModule.staticcall(
                abi.encodeWithSelector(SEL_INCENTIVE_MODULE)
            );
            if (success && data.length >= 32) {
                incentiveMod = abi.decode(data, (address));
            }
        }

        // Snapshot modules and fees at creation time (immutable for this escrow)
        moduleSnapshots[workflowId] = ModuleSnapshot({
            resolutionModule: resModule,
            releaseStrategy: relStrat,
            yieldGenerationModule: genMod,
            yieldDistributionModule: distMod,
            incentiveModule: incentiveMod,
            yieldProtocolFeeBps: yieldProtocolFeeBps,
            appealBondProtocolFeeBps: appealBondProtocolFeeBps
        });

        // Module snapshot and fee data now included in EscrowCreated event
        // No separate events needed
    }

    // ============ Escrow Actions ============
    /**
     * @notice Automatically execute timed actions (auto-release or auto-cancel)
     * @param workflowId The escrow ID
     * @return executed Whether an action was executed
     * @dev Checks if auto-release or auto-cancel time has passed and executes if so.
     *      Can be called by anyone to trigger automatic actions.
     */
    function automateTimedActions(uint256 workflowId) external nonReentrant returns (bool) {
        _validateWorkflowId(workflowId);
        EscrowTransfer storage et = escrowTransfers[workflowId];
        PendingSettlement storage pending = pendingSettlements[workflowId];

        if (address(settlementOps) == address(0)) return false;

        // Use SettlementOps to compute timed actions
        // Convert storage to memory struct for external call
        SettlementOps.SettlementPendingSettlement memory pendingMem = SettlementOps.SettlementPendingSettlement({
            exists: pending.exists,
            isRelease: pending.isRelease,
            appealDeadline: pending.appealDeadline,
            resolutionHash: pending.resolutionHash
        });
        (uint8 actionType, bool isRelease) = settlementOps.computeTimedActions(
            workflowId,
            et,
            pendingMem,
            timeoutConfig
        );

        if (actionType == 0) return false;

        if (actionType == 3) {
            // Pending settlement execution
            delete pendingSettlements[workflowId];

            // Optionally finalize dispute in resolution module
            IResolutionModule resolutionModule = _getResolutionModule(workflowId);
            if (address(resolutionModule) != address(0)) {
                (bool success, ) = address(resolutionModule).call(
                    abi.encodeWithSelector(SEL_FINALIZE_DISPUTE, workflowId)
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
            emit EscrowTransferAutoResult(
                workflowId,
                isRelease ? et.to : et.from,
                et.token,
                et.amountAfterFee,
                true,
                3
            );
            return true;
        } else if (actionType == 1) {
            // Auto-release
            _releaseEscrowTransfer(workflowId);
            emit EscrowTransferAutoResult(workflowId, et.to, et.token, et.amountAfterFee, true, 1);
            return true;
        } else if (actionType == 2) {
            // Auto-cancel
            _cancelAndRefund(workflowId);
            emit EscrowTransferAutoResult(workflowId, et.from, et.token, et.amountAfterFee, true, 2);
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
     */
    function recipientCancel(uint256 workflowId) external returns (bool) {
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
     */
    function senderCancel(uint256 workflowId) external returns (bool) {
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
        et.escrowState = EscrowState.RESOLVED;
        delete disputeRaisedTimestamp[workflowId];
        emit EscrowStateChanged(workflowId, EscrowState.DISPUTED, EscrowState.RESOLVED);
        emit DisputeAutoCancelled(workflowId, from, amt, uint8(FailureReason.TIMEOUT));
        emit EscrowTransferResolved(workflowId, from, et.to, amt);
        return true;
    }

    // PRIORITY: Removed isDisputeTimedOut() - moved to EscrowViewContract to reduce contract size

    /**
     * @notice Raise a dispute for an escrow
     * @param workflowId The escrow ID
     * @return success Whether the dispute was raised successfully
     */
    function raiseDispute(uint256 workflowId) external returns (bool) {
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
        // PRIORITY 3: Use snapshotted incentive module (no dynamic discovery)
        address incentiveModAddr = moduleSnapshots[workflowId].incentiveModule;
        if (incentiveModAddr != address(0)) {
            IIncentiveModule incentiveMod = IIncentiveModule(incentiveModAddr);
            // Calculate escrow fee: fee = amount * escrowFee / ESCROW_FEE_DENOMINATOR
            // Original amount = amountAfterFee + fee, so: fee = (amountAfterFee * escrowFee) / (ESCROW_FEE_DENOMINATOR - escrowFee)
            uint256 originalAmount = et.amountAfterFee +
                ((et.amountAfterFee * escrowFee) / (ESCROW_FEE_DENOMINATOR - escrowFee));
            uint256 escrowFeeAmount = (originalAmount * escrowFee) / ESCROW_FEE_DENOMINATOR;
            // Use low-level call to save bytecode (replaces try/catch)
            (bool success, ) = address(incentiveMod).call(
                abi.encodeWithSelector(
                    IIncentiveModule.onDisputeOpened.selector,
                    workflowId,
                    et.token,
                    originalAmount,
                    escrowFeeAmount,
                    0
                )
            );
            if (!success) {
                // MED-3: Emit event for monitoring
                emit IncentiveModuleCallFailed(workflowId, IIncentiveModule.onDisputeOpened.selector, uint8(FailureReason.CALL_FAILED));
                emit OperationFailure(
                    3,
                    workflowId,
                    incentiveModAddr,
                    IIncentiveModule.onDisputeOpened.selector,
                    uint8(FailureReason.CALL_FAILED)
                );
            }
        }

        return true;
    }

    /**
     * @notice Helper function to get incentive module from resolution module
     * @dev Used to access public incentiveModule variable from DecentralizedResolutionModule
     */
    // PRIORITY 3: Removed _getIncentiveModuleFromResolution - now using snapshotted incentiveModule

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

        // Cancel pending settlement if exists (state change - must stay in BaseEscrow)
        if (pendingSettlements[workflowId].exists) {
            delete pendingSettlements[workflowId];
            emit PendingSettlementCancelled(workflowId);
        }
    }

    // DEPRECATED: _collectEscalationBond removed - use BondCollector instead


    /**
     * @notice Escalate a dispute to a higher resolution level
     * @param workflowId The escrow ID
     * @return success Whether escalation succeeded
     * @return newDisputeResolver Address of the new resolver
     * @return newLevel New escalation level
     */
    function escalateDispute(
        uint256 workflowId
    )
        external
        payable
        nonReentrant
        returns (bool success, address newDisputeResolver, uint8 newLevel)
    {
        (EscrowTransfer storage et, IResolutionModule resolutionModule) = _validateAndPrepareEscalation(workflowId);

        // Get escalation info via disputeOps (which calls canEscalate and executeEscalation)
        // Escalation now uses appeal bonds exclusively
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
        (bool bondCheckSuccess, bytes memory bondData) = address(resolutionModule).staticcall(
            abi.encodeWithSelector(
                IResolutionModule.getRequiredAppealBond.selector,
                workflowId,
                result.currentLevel,
                escrowData
            )
        );
        
        if (!bondCheckSuccess || bondData.length < 64) {
            revert AppealBondQueryFailed(workflowId);
        }

        (uint256 bondAmount, address bondToken) = abi.decode(bondData, (uint256, address));

        // Enforce msg.value invariants (audit-grade clarity)
        if (bondToken == address(0)) {
            if (msg.value < bondAmount) {
                revert InvalidBondMsgValue(workflowId, bondAmount, msg.value);
            }
        } else {
            if (msg.value != 0) {
                revert UnexpectedETH(workflowId, msg.value);
            }
        }

        if (bondAmount > 0) {
            // Use snapshotted incentive module (no dynamic discovery)
            address incentiveModAddr = moduleSnapshots[workflowId].incentiveModule;
            if (incentiveModAddr != address(0)) {
                IIncentiveModule incentiveMod = IIncentiveModule(incentiveModAddr);
                uint256 snapshottedBondFee = moduleSnapshots[workflowId].appealBondProtocolFeeBps;

                // Collect protocol fee (if enabled) and record net bond amount.
                uint256 protocolFeeAmount = 0;
                uint256 bondToRecord = bondAmount;

                if (snapshottedBondFee > 0 && escrowFeeAddress != address(0)) {
                    protocolFeeAmount = (bondAmount * snapshottedBondFee) / 10000;
                    if (protocolFeeAmount > 0) {
                        bondToRecord = bondAmount - protocolFeeAmount;
                        emit ProtocolFeeCollected(
                            1,
                            workflowId,
                            bondToken,
                            bondAmount,
                            snapshottedBondFee,
                            protocolFeeAmount
                        );
                    }
                }

                if (bondToken == address(0)) {
                    // ETH bond: pay protocol fee, then record bond (must match msg.value rules in incentive module).
                    if (protocolFeeAmount > 0) {
                        (bool feeSuccess, ) = payable(escrowFeeAddress).call{value: protocolFeeAmount}('');
                        if (!feeSuccess) revert TransferFailed(1, bondToken, escrowFeeAddress, protocolFeeAmount);
                    }

                    // For ETH bonds, depositor MUST equal escalatedBy.
                    incentiveMod.recordAppealBond{value: bondToRecord}(
                        workflowId,
                        _msgSender(), // depositor
                        _msgSender(), // escalatedBy
                        bondToRecord,
                        bondToken,
                        result.newLevel
                    );
                } else {
                    // ERC20 bond: custody lives in BondCollector, but recordAppealBond must be called
                    // by the escrow contract (onlyEscrowContract in incentive module).
                    if (address(bondCollector) == address(0)) revert ZeroBondCollector();

                    // Pull full bond amount into escrow contract, then fan out fee + custody transfer.
                    _pullTokens(bondToken, _msgSender(), bondAmount);
                    if (protocolFeeAmount > 0) {
                        IERC20(bondToken).safeTransfer(escrowFeeAddress, protocolFeeAmount);
                    }
                    IERC20(bondToken).safeTransfer(address(bondCollector), bondToRecord);

                    // Let incentive module pull tokens from BondCollector.
                    bondCollector.approveBondSpender(bondToken, address(incentiveMod), bondToRecord);
                    incentiveMod.recordAppealBond(
                        workflowId,
                        address(bondCollector), // depositor (custodian)
                        _msgSender(), // escalatedBy
                        bondToRecord,
                        bondToken,
                        result.newLevel
                    );
                    bondCollector.resetBondSpender(bondToken, address(incentiveMod));
                }
            }
        }

        // computeEscalation already called executeEscalation internally and succeeded
        // Use the result from computeEscalation instead of calling again
        address newResolver = result.newResolver;
        uint8 newLevel_ = result.newLevel;

        // Update escrow state with new resolver
        et.disputeResolver = newResolver;
        
        // Refund excess ETH if bond was ETH and msg.value exceeded bond amount
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

        // Use SettlementOps to compute resolution execution parameters
        IResolutionModule resolutionModule = _getResolutionModule(workflowId);
        
        // Validate resolution module matches snapshot before execution
        address snap = moduleSnapshots[workflowId].resolutionModule;
        if (snap != address(0) && address(resolutionModule) != snap) {
            // Module has changed - use snapshotted module instead
            resolutionModule = IResolutionModule(snap);
        }
        
        // Validate module is still a valid contract before calling
        if (address(resolutionModule) != address(0)) {
            if (address(resolutionModule).code.length == 0) {
                revert NotAContract(1, address(resolutionModule)); // 1 = resolutionModule
            }
        }

        if (address(settlementOps) == address(0)) {
            // Fallback if SettlementOps not set
            revert ZeroSettlementOps();
        }

        SettlementOps.ResolutionResult memory result = settlementOps.computeResolutionExecution(
            address(resolutionModule),
            workflowId,
            isRelease,
            timeoutConfig
        );
        
        // If final round (MAX_ROUND), execute immediately (no appeal window)
        if (result.shouldExecute) {
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
            appealDeadline: result.appealDeadline,
            resolutionHash: resolutionHash
        });

        // Keep state as DISPUTED (not RESOLVED yet - will be finalized after appeal window)
        emit PendingSettlementSet(workflowId, isRelease, result.appealDeadline);

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

        if (address(settlementOps) == address(0)) {
            revert ZeroSettlementOps();
        }

        // Use SettlementOps to compute pending settlement execution
        // Convert storage to memory struct for external call
        SettlementOps.SettlementPendingSettlement memory pendingMem = SettlementOps.SettlementPendingSettlement({
            exists: pending.exists,
            isRelease: pending.isRelease,
            appealDeadline: pending.appealDeadline,
            resolutionHash: pending.resolutionHash
        });
        (bool canExecute, bool isRelease) = settlementOps.computePendingSettlementExecution(
            workflowId,
            pendingMem,
            et.escrowState
        );

        if (!canExecute) {
            if (!pending.exists) revert NoPendingSettlement(workflowId);
            if (block.timestamp < pending.appealDeadline) {
                revert AppealWindowNotExpired(workflowId, pending.appealDeadline, block.timestamp);
            }
            revert NotInDisputedState(workflowId, et.escrowState);
        }

        // Clear pending settlement before execution (prevent reentrancy)
        delete pendingSettlements[workflowId];

        // Optionally finalize dispute in resolution module if supported
        // This ensures appeal bonds are distributed
        IResolutionModule resolutionModule = _getResolutionModule(workflowId);
        if (address(resolutionModule) != address(0)) {
            // Try to call finalizeDispute if it exists (DecentralizedResolutionModule)
            // This is a best-effort call - if it fails, we still execute the settlement
            (bool success, ) = address(resolutionModule).call(
                abi.encodeWithSelector(SEL_FINALIZE_DISPUTE, workflowId)
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

    // PRIORITY: Removed getPendingSettlement - use public mapping getter pendingSettlements(workflowId) directly
    // EscrowViewContract calculates canExecute itself: block.timestamp >= appealDeadline

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
        address snap = moduleSnapshots[workflowId].resolutionModule;
        if (snap != address(0)) {
            // Use low-level staticcall instead of try-catch for gas efficiency
            bytes memory escrowData = EscrowEncodingLibrary.encodeEscrowTransferData(
                et.token,
                et.from,
                et.to,
                et.amountAfterFee
            );
            (bool success, bytes memory data) = snap.staticcall(
                abi.encodeWithSelector(
                    IResolutionModule.isAuthorizedDisputeResolver.selector,
                    workflowId,
                    disputeResolver,
                    escrowData
                )
            );
            if (success && data.length >= 64) {
                (bool authorized, ) = abi.decode(data, (bool, uint8));
                if (authorized) return true;
            }
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
        if (address(module) == address(0)) revert ResolutionModuleError(1); // code 1 = not configured
        
        // Use low-level staticcall instead of try-catch for gas efficiency
        bytes memory escrowData = EscrowEncodingLibrary.encodeEscrowTransferData(token, from, to, amount);
        (bool success, bytes memory data) = address(module).staticcall(
            abi.encodeWithSelector(
                IResolutionModule.getDisputeResolver.selector,
                workflowId,
                escrowData
            )
        );
        
        if (!success || data.length < 64) {
            revert ResolutionModuleError(2); // code 2 = call failed
        }
        
        (address disputeResolver, ) = abi.decode(data, (address, uint8));
        if (disputeResolver == address(0)) {
            revert ResolutionModuleError(3); // code 3 = returned zero address
        }
        return disputeResolver;
    }

    function _applyEscrowSettings(uint256 workflowId, EscrowSettings memory settings) internal {
        EscrowTransfer storage et = escrowTransfers[workflowId];
        if (settings.customResolver != address(0)) et.disputeResolver = settings.customResolver;
        bool def = (settings.autoReleaseTime == 0 && settings.autoCancelTime == 0);

        uint256 autoReleaseTime = settings.autoReleaseTime > 0
            ? settings.autoReleaseTime
            : (def ? timeoutConfig.defaultAutoReleaseTime : 0);
        if (autoReleaseTime > type(uint64).max) {
            revert InvalidAutoTime(AUTO_TIME_TOO_LARGE, autoReleaseTime, block.timestamp);
        }
        et.autoReleaseTime = uint64(autoReleaseTime);

        uint256 autoCancelTime = settings.autoCancelTime > 0
            ? settings.autoCancelTime
            : (def ? timeoutConfig.defaultAutoCancelTime : 0);
        if (autoCancelTime > type(uint64).max) {
            revert InvalidAutoTime(AUTO_TIME_TOO_LARGE, autoCancelTime, block.timestamp);
        }
        et.autoCancelTime = uint64(autoCancelTime);
        escrowSettings[workflowId] = settings;
        
        emit EscrowSettingsUpdated(workflowId, settings);
    }

    // ============ View Functions ============
    // PRIORITY: Removed explicit getter functions to reduce contract size (~1.5-2.3 KB saved)
    // Public storage variables provide free auto-generated getters:
    // - escrowTransfers(uint256) - public array getter
    // - claimableBalances(workflowId, user) - public mapping getter
    // - escrowSettings(workflowId) - public mapping getter
    // - pendingSettlements(workflowId) - public mapping getter
    // - timeoutConfig - public struct getter
    // EscrowViewContract uses these public storage getters directly

    // ============ Withdrawal ============
    /**
     * @notice Withdraw claimable escrow funds (pull model)
     * @param workflowId The escrow ID
     * @return amount Amount withdrawn
     */
    function withdrawEscrow(uint256 workflowId) external nonReentrant returns (uint256) {
        _validateWorkflowId(workflowId);
        EscrowTransfer storage et = escrowTransfers[workflowId];

        // Verify escrow is finalized (or released/cancelled)
        if (et.escrowState != EscrowState.RESOLVED &&
            et.escrowState != EscrowState.RELEASED &&
            et.escrowState != EscrowState.REFUNDED) {
            revert TransferNotFinalized(workflowId, et.escrowState);
        }

        address token = et.token; // Single token per escrow
        uint256 amount = claimableBalances[workflowId][msg.sender];
        if (amount == 0) revert NoClaimableBalance(workflowId, msg.sender, token);

        // Idempotent: set to 0 before transfer (checks-effects-interactions)
        claimableBalances[workflowId][msg.sender] = 0;

        // Note: Balance already updated during finalization, don't double-subtract
        _transferTokens(token, msg.sender, amount);

        emit EscrowWithdrawn(workflowId, msg.sender, token, amount);
        return amount;
    }

    // ============ Recovery ============
    // PRIORITY 5: Removed recoverNativeETH
    // This function has been removed to reduce contract size.
    // For ERC20 vaults (EscrowVault), native ETH recovery is not needed.
    // If needed for ETH-specific vaults, it can be added to a separate RecoveryOps contract.

    /**
     * @notice Recover ERC20 tokens sent to the contract
     * @param token Token address to recover
     * @param recipient Address to receive the recovered tokens
     * @param amount Amount of tokens to recover
     * @return success Whether recovery succeeded
     * @dev Abstract function - derived contracts MUST override with accounting validation
     */
    function recoverERC20(
        address token,
        address recipient,
        uint256 amount
    ) external virtual onlyRole(ROLE_TIMELOCK) nonReentrant returns (bool) {
        /// @dev Base implementation - derived contracts MUST override with proper accounting checks
        ///      This prevents recovery of tokens that are held in escrow or fees
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
        EscrowState st = escrowTransfers[workflowId].escrowState;
        if (st != EscrowState.PENDING) {
            revert TransferNotPending(workflowId, st);
        }
    }

    function _validateEscrowSettings(EscrowSettings memory settings) internal view {
        SettingsValidationLibrary.validateEscrowSettings(settings, block.timestamp);
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

        // Attempt transfer using low-level call
        bool success = _tryTransfer(token, recipient, amount);
        if (success) {
            emit EscrowTransferAutoResult(workflowId, recipient, token, amount, true, 0);
            return true;
        } else {
            // Transfer failed - fallback to pull model
            claimableBalances[workflowId][recipient] += amount;
            emit ClaimableBalanceSet(workflowId, recipient, token, amount);
            emit EscrowTransferAutoResult(
                workflowId,
                recipient,
                token,
                amount,
                false,
                uint8(FailureReason.PUSH_FAILED_FALLBACK_TO_PULL)
            );
            emit OperationFailure(
                4,
                workflowId,
                token,
                IERC20.transfer.selector,
                uint8(FailureReason.PUSH_FAILED_FALLBACK_TO_PULL)
            );
            return false;
        }
    }

    /**
     * @notice Low-level transfer helper that returns success status
     * @param token Token address
     * @param to Recipient address
     * @param amount Amount to transfer
     * @return success Whether transfer succeeded
     */
    function _tryTransfer(address token, address to, uint256 amount) internal returns (bool success) {
        // Use low-level call to token's transfer function
        (success, ) = token.call(abi.encodeWithSelector(
            IERC20.transfer.selector,
            to,
            amount
        ));
        
        // Check return value (ERC20 standard: returns bool)
        if (success) {
            // Verify return data contains true
            assembly {
                if returndatasize() {
                    returndatacopy(0, 0, returndatasize())
                    success := and(mload(0), 0xff) // Check if first byte is non-zero
                }
            }
        }
        
        return success;
    }

    /**
     * @notice Helper to get Aave pool address from module
     * @param genModule Yield generation module
     * @return poolAddress Aave pool address (0 if not available)
     */
    function _getAavePoolAddress(IYieldGenerationModule genModule) internal view returns (address poolAddress) {
        // Early return if module is not set
        if (address(genModule) == address(0)) {
            return address(0);
        }
        // Try to call getAavePoolAddress() if module supports it
        (bool success, bytes memory data) = address(genModule).staticcall(
            abi.encodeWithSelector(bytes4(keccak256("getAavePoolAddress()")))
        );
        if (success && data.length >= 32) {
            poolAddress = abi.decode(data, (address));
        }
    }

    /**
     * @notice Helper to get aToken address from module
     * @param genModule Yield generation module
     * @param token Underlying token address
     * @return aTokenAddress aToken address (0 if not available)
     */
    function _getATokenAddress(IYieldGenerationModule genModule, address token) internal view returns (address aTokenAddress) {
        // Early return if module is not set
        if (address(genModule) == address(0)) {
            return address(0);
        }
        // Try to call getATokenAddress(address) if module supports it
        (bool success, bytes memory data) = address(genModule).staticcall(
            abi.encodeWithSelector(bytes4(keccak256("getATokenAddress(address)")), token)
        );
        if (success && data.length >= 32) {
            aTokenAddress = abi.decode(data, (address));
        }
    }

    /**
     * @notice Read Aave normalized income (RAY) for an asset.
     * @dev Best-effort via staticcall; returns AAVE_RAY (1.0) if unavailable.
     */
    function _getAaveNormalizedIncome(address pool, address token) internal view returns (uint256 incomeRay) {
        if (pool == address(0)) return AAVE_RAY;
        (bool success, bytes memory data) = pool.staticcall(
            abi.encodeWithSelector(bytes4(keccak256("getReserveNormalizedIncome(address)")), token)
        );
        if (success && data.length >= 32) {
            incomeRay = abi.decode(data, (uint256));
            if (incomeRay == 0) return AAVE_RAY;
            return incomeRay;
        }
        return AAVE_RAY;
    }

    /**
     * @notice Get default yield generation module (for emergency operations)
     * @return module Default yield generation module
     * @dev Returns default module from ModuleManagementContract or address(0)
     *      Must be overridden in derived contracts (EscrowVault, EscrowableERC20)
     */
    function _getDefaultYieldGenerationModule() internal view virtual returns (IYieldGenerationModule module) {
        // Base implementation returns address(0)
        // Derived contracts (EscrowVault, EscrowableERC20) must override this
        return IYieldGenerationModule(address(0));
    }

    /**
     * @notice Handle yield withdrawal via library pattern
     * @param workflowId The escrow ID
     * @param token Token address
     * @param amount Original escrow amount
     * @return actualAmount Actual amount after yield withdrawal
     * @dev Only called when aaveYieldLibraryEnabled == true
     */
    function _handleYieldViaLibrary(
        uint256 workflowId,
        address token,
        uint256 amount
    ) internal returns (uint256 actualAmount) {
        actualAmount = amount;
        
        EscrowSettings memory settings = escrowSettings[workflowId];
        bool yieldEnabled = settings.yieldPreset != YieldPreset.OFF;
        
        if (!yieldEnabled) {
            return actualAmount;
        }
        
        IYieldGenerationModule genModule = _getYieldGenerationModule(workflowId);
        if (address(genModule) == address(0)) {
            return actualAmount;
        }
        
        // Check if escrow has yield to withdraw
        if (!escrowInYield[workflowId][token]) {
            return actualAmount; // Not in yield, return original
        }
        
        // Get aToken address from module
        address aToken = _getATokenAddress(genModule, token);
        if (aToken == address(0)) {
            emit YieldWithdrawalAttempted(workflowId, token, amount, amount, false, uint8(FailureReason.MODULE_NOT_SET));
            return actualAmount;
        }
        
        // Get tracked scaled shares (v2). This must be present in production;
        // legacy fallback is intentionally not supported (unsafe for multi-escrow).
        uint256 scaledShares = escrowYieldScaledShares[workflowId][token];
        if (scaledShares == 0) {
            // Clear state and treat as non-blocking failure (prevents stuck escrows).
            escrowInYield[workflowId][token] = false;
            emit YieldWithdrawalAttempted(workflowId, token, amount, amount, false, uint8(FailureReason.MALFORMED_RETURN_DATA));
            return actualAmount;
        }

        // Get Aave pool address from module
        address aavePool = _getAavePoolAddress(genModule);
        if (aavePool == address(0)) {
            emit YieldWithdrawalAttempted(workflowId, token, amount, amount, false, uint8(FailureReason.MODULE_NOT_SET));
            return actualAmount;
        }

        // Compute underlying to withdraw = scaledShares * normalizedIncome / RAY.
        uint256 incomeRay = _getAaveNormalizedIncome(aavePool, token);
        uint256 underlyingToWithdraw = (scaledShares * incomeRay) / AAVE_RAY;
        if (underlyingToWithdraw == 0) {
            // Clear state and return
            escrowInYield[workflowId][token] = false;
            return actualAmount;
        }

        // Call library to withdraw (msg.sender = BaseEscrow)
        // Use delegatecall to call library function (maintains msg.sender = BaseEscrow)
        (bool success, bytes memory returnData) = aaveYieldLibrary.delegatecall(
            abi.encodeWithSelector(AaveYieldLibrary.withdraw.selector, aavePool, token, underlyingToWithdraw, address(this))
        );
        if (success && returnData.length >= 32) {
            uint256 withdrawnAmount = abi.decode(returnData, (uint256));
            // If YieldOps is configured, we distribute yield separately and only pay out principal.
            // Otherwise, we return the full withdrawn amount (principal + yield) to avoid trapping yield.
            actualAmount = withdrawnAmount;
            
            // Clear tracking
            escrowInYield[workflowId][token] = false;
            escrowYieldScaledShares[workflowId][token] = 0;
            escrowATokenBalances[workflowId][aToken] = 0; // legacy slot
            
            // Handle yield distribution (non-blocking)
            _distributeYieldIfNeeded(workflowId, token, withdrawnAmount, amount);
            if (address(yieldOps) != address(0) && address(yieldOps).code.length > 0) {
                // Yield (if any) has been routed away; pay out principal only.
                actualAmount = amount;
            }
            
            emit YieldWithdrawalAttempted(workflowId, token, amount, actualAmount, true, 0);
            return actualAmount;
        }
        // Delegatecall failed - non-blocking: return original amount
        emit YieldWithdrawalAttempted(workflowId, token, amount, amount, false, uint8(FailureReason.WITHDRAWAL_FAILED));
        
        return actualAmount;
    }

    /**
     * @notice Handle yield deposit via library pattern
     * @param workflowId The escrow ID
     * @param token Token address
     * @param amount Amount to deposit
     * @dev Only called when aaveYieldLibraryEnabled == true
     */
    function _handleYieldDepositViaLibrary(
        uint256 workflowId,
        address token,
        uint256 amount
    ) internal {
        EscrowSettings memory settings = escrowSettings[workflowId];
        bool yieldEnabled = settings.yieldPreset != YieldPreset.OFF;
        
        if (!yieldEnabled) {
            return;
        }
        
        IYieldGenerationModule genModule = _getYieldGenerationModule(workflowId);
        if (address(genModule) == address(0)) {
            return;
        }
        
        if (!genModule.isTokenSupported(token)) {
            return;
        }
        
        // Get Aave pool and aToken addresses from module
        address aavePool = _getAavePoolAddress(genModule);
        address aToken = _getATokenAddress(genModule, token);
        
        if (aavePool == address(0) || aToken == address(0)) {
            emit YieldDepositAttempted(workflowId, token, amount, false, uint8(FailureReason.MODULE_NOT_SET));
            return;
        }

        // Compute scaled shares for this escrow at current normalized income.
        // scaledShares = amount * RAY / incomeRay
        uint256 incomeRay = _getAaveNormalizedIncome(aavePool, token);
        uint256 scaledShares = (amount * AAVE_RAY) / incomeRay;
        if (scaledShares == 0) {
            emit YieldDepositAttempted(workflowId, token, amount, false, uint8(FailureReason.DEPOSIT_FAILED));
            return;
        }
        
        // Call library to supply (msg.sender = BaseEscrow)
        // Use delegatecall to call library function (maintains msg.sender = BaseEscrow)
        (bool success, ) = aaveYieldLibrary.delegatecall(
            abi.encodeWithSelector(AaveYieldLibrary.supply.selector, aavePool, token, amount, address(this))
        );
        if (success) {
            // Track per-escrow scaled shares (v2)
            escrowYieldScaledShares[workflowId][token] = scaledShares;
            // Legacy slot cleared (do not maintain in production; unsafe for multi-escrow).
            escrowATokenBalances[workflowId][aToken] = 0;
            escrowInYield[workflowId][token] = true;
            
            emit YieldDepositAttempted(workflowId, token, amount, true, 0);
        } else {
            // Delegatecall failed - non-blocking: continue without yield
            emit YieldDepositAttempted(workflowId, token, amount, false, uint8(FailureReason.DEPOSIT_FAILED));
        }
    }

    /**
     * @notice Distribute yield if needed (placeholder for now, uses YieldOps)
     * @param workflowId The escrow ID
     * @param token Token address
     * @param actualAmount Total amount withdrawn
     * @param originalAmount Original escrow amount
     * @dev Can be refactored later to use library or direct distribution
     */
    function _distributeYieldIfNeeded(
        uint256 workflowId,
        address token,
        uint256 actualAmount,
        uint256 originalAmount
    ) internal {
        if (actualAmount <= originalAmount) {
            return; // No yield to distribute
        }
        
        uint256 yieldAmount = actualAmount - originalAmount;
        
        // For library pattern: yield is already withdrawn by BaseEscrow,
        // so we must NOT call YieldOps.handleYield() (which withdraws again).
        // Instead, transfer only the yield to YieldOps and call a distribution-only entrypoint.
        // Distribution is best-effort; ensure we don't introduce revert risks that would strand yield in YieldOps.
        if (address(yieldOps) != address(0) && address(yieldOps).code.length > 0) {
            IYieldDistributionModule distModule = _getYieldDistributionModule(workflowId);
            uint256 snapshottedYieldFee = moduleSnapshots[workflowId].yieldProtocolFeeBps;
            if (snapshottedYieldFee > MAX_PROTOCOL_FEE_BPS) {
                snapshottedYieldFee = 0; // clamp to avoid YieldOps revert and stranded funds
            }
            // If feeRecipient is unset, avoid fee logic entirely (prevents YieldOps revert).
            address feeRecipient = escrowFeeAddress;
            if (feeRecipient == address(0)) {
                snapshottedYieldFee = 0;
            }
            
            EscrowTransfer memory et = escrowTransfers[workflowId];
            EscrowSettings memory settings = escrowSettings[workflowId];
            bytes memory distributionData = YieldPresetLibrary.deriveDistributionData(
                settings.yieldPreset,
                et.from,
                et.to
            );
            
            // Transfer yield to YieldOps for distribution
            IERC20(token).safeTransfer(address(yieldOps), yieldAmount);
            
            // Call YieldOps to distribute ONLY (non-blocking)
            (bool success, ) = address(yieldOps).call(
                abi.encodeWithSelector(
                    YieldOps.distributeWithdrawnYield.selector,
                    distModule,
                    workflowId,
                    token,
                    yieldAmount,
                    snapshottedYieldFee,
                    feeRecipient,
                    distributionData
                )
            );
            success; // Ignore result
        }
    }

    /**
     * @notice Handle yield withdrawal and distribution, returning actual amount available
     * @param workflowId The escrow ID
     * @param token Token address
     * @param amount Original escrow amount
     * @return actualAmount Actual amount available after yield handling (may include yield)
     */
    function _handleYieldAndGetActualAmount(
        uint256 workflowId,
        address token,
        uint256 amount
    ) internal returns (uint256 actualAmount) {
        actualAmount = amount;
        
        // NEW: Check if library pattern is enabled
        if (aaveYieldLibraryEnabled && aaveYieldLibrary != address(0)) {
            // Library pattern: BaseEscrow calls library directly
            return _handleYieldViaLibrary(workflowId, token, amount);
        }
        
        // EXISTING: YieldOps pattern (unchanged, continues to work)
        // P1: module wiring observability (only emit if yield is enabled for this escrow).
        EscrowSettings memory settings = escrowSettings[workflowId];
        bool yieldEnabled = settings.yieldPreset != YieldPreset.OFF;
        if (address(yieldOps) == address(0)) {
            if (yieldEnabled) {
                emit YieldHandlingFailed(workflowId, token, amount, uint8(FailureReason.MODULE_NOT_SET));
                emit OperationFailure(
                    2,
                    workflowId,
                    address(0),
                    YieldOps.handleYield.selector,
                    uint8(FailureReason.MODULE_NOT_SET)
                );
            }
            return actualAmount;
        }
        if (address(yieldOps).code.length == 0) {
            if (yieldEnabled) {
                emit YieldHandlingFailed(workflowId, token, amount, uint8(FailureReason.MODULE_NOT_CONTRACT));
                emit OperationFailure(
                    2,
                    workflowId,
                    address(yieldOps),
                    YieldOps.handleYield.selector,
                    uint8(FailureReason.MODULE_NOT_CONTRACT)
                );
            }
            return actualAmount;
        }
        
        IYieldGenerationModule genModule = _getYieldGenerationModule(workflowId);
        IYieldDistributionModule distModule = _getYieldDistributionModule(workflowId);
        
        // Use snapshotted fee (immutable per-escrow) instead of global fee
        uint256 snapshottedYieldFee = moduleSnapshots[workflowId].yieldProtocolFeeBps;
        
        // Derive distribution data from preset
        EscrowTransfer memory et = escrowTransfers[workflowId];
        bytes memory distributionData = YieldPresetLibrary.deriveDistributionData(
            settings.yieldPreset,
            et.from,  // sender (buyer)
            et.to     // recipient (seller)
        );

        // Low-level call to avoid try/catch bytecode bloat (yield is non-critical)
        (bool ok, bytes memory ret) = address(yieldOps).call(
            abi.encodeWithSelector(
                YieldOps.handleYield.selector,
                genModule,
                distModule,
                workflowId,
                token,
                amount,
                snapshottedYieldFee,
                escrowFeeAddress,
                distributionData
            )
        );

        if (!ok) {
            // For yield withdrawal paths, expose a stable "withdrawal failed" signal.
            emit YieldHandlingFailed(workflowId, token, amount, uint8(FailureReason.WITHDRAWAL_FAILED));
            emit OperationFailure(
                2,
                workflowId,
                address(yieldOps),
                YieldOps.handleYield.selector,
                uint8(FailureReason.CALL_FAILED)
            );
            return actualAmount;
        }
        // YieldOps currently returns YieldOps.YieldResult (4 * 32-byte words).
        // Guard decode so yield remains strictly non-blocking even if ABI drifts.
        if (ret.length < 128) {
            // For yield withdrawal paths, expose a stable "withdrawal failed" signal.
            emit YieldHandlingFailed(workflowId, token, amount, uint8(FailureReason.WITHDRAWAL_FAILED));
            emit OperationFailure(
                2,
                workflowId,
                address(yieldOps),
                YieldOps.handleYield.selector,
                uint8(FailureReason.MALFORMED_RETURN_DATA)
            );
            return actualAmount;
        }

        YieldOps.YieldResult memory result = abi.decode(ret, (YieldOps.YieldResult));

        // Use actual withdrawn amount (may include yield)
        // Yield is optional and non-critical - if withdrawal returns unexpected amount,
        // treat yield as failed and proceed with principal amount
        if (result.actualAmount > 0) {
            // Basic sanity check: actual amount should be >= principal (no loss)
            if (result.actualAmount < amount) {
                emit YieldHandlingFailed(workflowId, token, amount, uint8(FailureReason.LESS_THAN_PRINCIPAL));
                emit OperationFailure(
                    2,
                    workflowId,
                    address(yieldOps),
                    YieldOps.handleYield.selector,
                    uint8(FailureReason.LESS_THAN_PRINCIPAL)
                );
                actualAmount = amount; // Use principal amount
            } else {
                actualAmount = result.actualAmount; // Use actual amount (may include yield)
            }
        }
        
        return actualAmount;
    }

    function _cancelAndRefund(uint256 workflowId) internal {
        EscrowTransfer storage et = escrowTransfers[workflowId];
        uint256 amount = et.amountAfterFee;
        address from = et.from;
        address token = et.token;
        EscrowState oldStatus = StateManagementLibrary.transitionToRefunded(et, workflowId);
        emit EscrowStateChanged(workflowId, oldStatus, EscrowState.REFUNDED);
        
        // Yield handling may increase the payout (positive yield). Escrow accounting tracks principal held,
        // so we always decrement by principal amountAfterFee, not by payout amount.
        uint256 actualAmount = _handleYieldAndGetActualAmount(workflowId, token, amount);
        
        // Update accounting based on principal
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
        
        // Yield handling may increase the payout (positive yield). Escrow accounting tracks principal held,
        // so we always decrement by principal amountAfterFee, not by payout amount.
        uint256 actualAmount = _handleYieldAndGetActualAmount(workflowId, token, amount);
        
        // Update accounting based on principal
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
        // BaseEscrow: return snapshotted module if exists, otherwise base-level module
        address snap = moduleSnapshots[workflowId].resolutionModule;
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
