// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import './IPaymentCalculationLibrary.sol';
import './IIncentiveModule.sol';
import '@openzeppelin/contracts/access/AccessControl.sol';
import '@openzeppelin/contracts/utils/ReentrancyGuard.sol';
import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import '@openzeppelin/contracts/utils/introspection/IERC165.sol';
import '../governance/SlowLaneQueueActivate.sol';
import '../types/EscrowTypes.sol'; // For ArrayLengthMismatch error

// Custom errors for gas efficiency
error BalanceMismatch(uint256 expected, uint256 actual);
error AmountExceedsMaximum(uint256 amount, uint256 maximum);
error ResolverAlreadyRecorded(address resolver);
error TooManyResolvers(uint256 count, uint256 maximum);
error EscrowFeeAlreadyRecorded(uint256 workflowId);
error InsufficientBalanceForFees(uint256 required, uint256 available);
// Transfer validation errors
error TransferRequiredBeforeResolution(uint256 workflowId);
error StaleFeeRecording(uint256 workflowId, uint256 recordedAt, uint256 currentTime);
// Rate limiting errors
error EscrowRateLimitExceeded(address escrow, uint256 current, uint256 limit);
error EscrowPaused(address escrow);
error NotRegisteredEscrowContract(address escrow);
error ZeroOwner();
error ZeroLibrary();
error InvalidLibrary(address libAddress);
error ZeroResolver();
error InvalidLevel(uint8 level, uint8 maxLevel);
error ZeroToken();
error ZeroAmount();
error AmountTooLarge(uint256 amount);
error DisputeNotInitialized(uint256 workflowId);
error PaymentsAlreadyCalculated(uint256 workflowId);
error NoResolvers(uint256 workflowId);
// ArrayLengthMismatch is imported from EscrowTypes.sol above
error ResolverShareExceedsTotalFees(uint256 resolverShare, uint256 totalFees);
error IndividualPaymentExceedsTotal(uint256 payment, uint256 total);
error PaymentSumOverflow(uint256 previousTotal, uint256 payment);
error PaymentSumMismatch(uint256 calculatedTotal, uint256 expectedTotal);
error ZeroResolverAddress(uint256 index);
error PaymentExceedsMaximumAllowed(uint256 payment, uint256 maxPayment);
error PaymentsNotCalculated(uint256 workflowId);
error NothingToClaim(uint256 workflowId, address claimer);
error ZeroAddressField(string fieldName);
error InvalidPercentage(uint256 percentage, uint256 maxPercentage);
error InvalidWeight(uint8 level, uint256 weight);

/**
 * @title ResolverIncentiveModuleV1
 * @notice DR v1 incentive module: performance-based workload routing (no appeal bonds/staking)
 * @dev Uses functional library approach with governance-controlled upgrades
 *      - State management: Imperative (in this contract)
 *      - Payment calculations: Functional (in library)
 *      - Library upgrades: Governance-controlled (slow lane) or instant (module developer)
 *      - UUPS upgradeable for rapid iteration and bug fixes
 *      - Implements IIncentiveModule for compatibility with DecentralizedResolutionModule
 */
contract ResolverIncentiveModuleV1 is
    IIncentiveModule,
    AccessControl,
    ReentrancyGuard,
    SlowLaneQueueActivate
{
    using SafeERC20 for IERC20;

    // ============ Role Constants ============
    bytes32 public constant ROLE_TIMELOCK = keccak256('ROLE_TIMELOCK');

    // ============ Constants ============
    uint256 public constant BASIS_POINTS_DENOMINATOR = 10000;
    uint256 public constant MAX_SINGLE_PAYMENT_PERCENTAGE = 9000; // 90% - maximum single payment share
    /// @notice Maximum fee limits per dispute
    uint256 public constant MAX_ESCROW_FEE_PER_DISPUTE = 10000 ether;
    uint256 public constant MAX_ESCALATION_FEE_PER_DISPUTE = 1000 ether;
    /// @notice Maximum resolver count to prevent gas DoS
    uint256 public constant MAX_RESOLVERS_PER_DISPUTE = 50;
    // CRIT-1/CRIT-3: Tolerance for balance mismatch (0.01% = 1 basis point)
    uint256 public constant BALANCE_TOLERANCE_BPS = 1;
    /// @notice Rate limiting constants
    uint256 public constant MAX_DISPUTES_PER_ESCROW_PER_DAY = 1000;
    uint256 public constant MAX_FEES_PER_ESCROW_PER_DAY = 100000 ether;
    uint256 public constant RATE_LIMIT_WINDOW = 1 days;
    /// @notice Maximum age for fee recording before requiring re-validation (30 days)
    uint256 public constant MAX_FEE_RECORDING_AGE = 30 days;

    // ============ State Variables ============

    // Current payment calculation library (upgradeable via governance)
    address public currentPaymentLibrary;
    PendingAddress private _pendingPaymentLibrary;

    // Resolver tracking per dispute
    mapping(uint256 => ResolverRecord[]) public disputeResolvers;
    mapping(uint256 => uint256) public disputeEscrowFees;
    mapping(uint256 => uint256) public disputeEscalationFees;
    mapping(uint256 => bool) public disputePaymentsDistributed;

    // Pull pattern: claimable payments per resolver per dispute
    mapping(uint256 => mapping(address => uint256)) public claimablePayments;
    mapping(uint256 => bool) public paymentsCalculated;

    // Configuration (governance-controlled)
    uint256 public resolverSharePercentage;
    PendingUint private _pendingResolverSharePercentage;

    Weights public weights;
    PendingWeights private _pendingWeights;

    // Registered escrow contracts that can call onDisputeOpened and onDisputeResolved
    mapping(address => bool) public registeredEscrowContracts;

    // CRIT-2/CRIT-3: Track expected token balance per dispute to validate transfers
    mapping(uint256 => uint256) public disputeExpectedTokenBalance; // workflowId => expected balance
    // HIGH-2: Track resolver recording to prevent duplicates (same resolver at any level)
    mapping(uint256 => mapping(address => bool)) public resolverRecorded; // workflowId => resolver => recorded
    // HIGH-2: Track when fees were recorded to detect stale recordings
    mapping(uint256 => uint256) public feeRecordedTimestamp; // workflowId => timestamp when fee was recorded
    /// @notice Per-escrow rate limiting and tracking
    struct EscrowRateLimit {
        uint256 disputesToday; // Disputes recorded in current window
        uint256 feesToday; // Total fees recorded in current window (wei)
        uint256 windowStart; // Start timestamp of current rate limit window
        bool paused; // Whether this escrow is paused (emergency stop)
    }
    mapping(address => EscrowRateLimit) public escrowRateLimits; // escrow => rate limit data

    // ============ Events ============

    event ResolverRecorded(
        uint256 indexed workflowId,
        address indexed resolver,
        uint8 level,
        uint256 timestamp
    );

    event EscrowFeeRecorded(uint256 indexed workflowId, address indexed token, uint256 amount);

    event EscalationFeeRecorded(uint256 indexed workflowId, address indexed token, uint256 amount);

    event PaymentsDistributed(
        uint256 indexed workflowId,
        address indexed token,
        uint256 totalResolverShare,
        address[] resolvers,
        uint256[] payments
    );

    event PaymentLibraryQueued(address indexed oldLibrary, address indexed newLibrary, uint64 eta);

    event PaymentLibraryActivated(address indexed oldLibrary, address indexed newLibrary);

    event PaymentLibraryRolledBack(address indexed previousLibrary);

    event PaymentLibrarySwappedInstant(
        address indexed oldLibrary,
        address indexed newLibrary,
        address indexed swappedBy,
        uint256 timestamp
    );

    // Phase 3: Task 3.3 - Event completeness
    event ZeroPaymentSkipped(uint256 indexed workflowId, address indexed resolver);

    event ResolverSharePercentageQueued(uint256 oldPercentage, uint256 newPercentage, uint64 eta);

    event ResolverSharePercentageActivated(uint256 oldPercentage, uint256 newPercentage);

    event WeightsQueued(Weights oldWeights, Weights newWeights, uint64 eta);

    event WeightsActivated(Weights oldWeights, Weights newWeights);

    event EscrowContractRegistered(address indexed escrowContract);
    event EscrowContractUnregistered(address indexed escrowContract);

    event PaymentsCalculated(
        uint256 indexed workflowId,
        address indexed token,
        uint256 totalResolverShare
    );

    event PaymentClaimed(uint256 indexed workflowId, address indexed resolver, uint256 amount);

    event PaymentClaimFailed(uint256 indexed workflowId, address indexed resolver, string reason);
    event BalanceMismatchDetected(
        uint256 indexed workflowId,
        address indexed token,
        uint256 expectedBalance,
        uint256 actualBalance
    );
    /// @notice Transfer validation events
    event FeeRecordingCleared(uint256 indexed workflowId, string reason);
    event StaleFeeRecordingDetected(
        uint256 indexed workflowId,
        uint256 recordedAt,
        uint256 currentTime
    );
    /// @notice Rate limiting events
    event EscrowRateLimitExceededEvent(
        address indexed escrow,
        string limitType,
        uint256 current,
        uint256 limit
    );
    event EscrowPausedEvent(address indexed escrow, address indexed by);
    event EscrowUnpausedEvent(address indexed escrow, address indexed by);
    event EscrowRateLimitReset(address indexed escrow, uint256 newWindowStart);

    // ============ Structs ============

    struct PendingWeights {
        Weights value;
        uint64 eta;
        bool exists;
    }

    // ============ Modifiers ============

    modifier onlyEscrowContract() {
        address escrow = _msgSender();
        if (!registeredEscrowContracts[escrow]) revert NotRegisteredEscrowContract(escrow);
        // Check if escrow is paused
        if (escrowRateLimits[escrow].paused) {
            revert EscrowPaused(escrow);
        }
        _;
    }

    // ============ Initialization ============

    /**
     * @notice Constructor for immutable contract
     * @param initialOwner Address that will receive DEFAULT_ADMIN_ROLE
     * @param initialLibrary Address of initial payment calculation library
     */
    constructor(address initialOwner, address initialLibrary) {
        if (initialOwner == address(0)) revert ZeroOwner();
        if (initialLibrary == address(0)) revert ZeroLibrary();

        // OpenZeppelin best practice: Grant DEFAULT_ADMIN_ROLE to deployer
        // Deployment scripts will transfer this to TimelockController
        _grantRole(DEFAULT_ADMIN_ROLE, initialOwner);

        // Initialize configuration
        resolverSharePercentage = 5000; // 50%
        weights = Weights({level0: 10000, level1: 15000, level2: 20000});

        // Validate and set initial library
        if (!validateLibrary(initialLibrary)) revert InvalidLibrary(initialLibrary);
        currentPaymentLibrary = initialLibrary;
    }

    /**
     * @notice Event emitted when incentive module is upgraded
     * @param oldImplementation Previous implementation address
     * @param newImplementation New implementation address
     * @param upgradedBy Address that executed the upgrade
     * @param timestamp Block timestamp of upgrade
     */

    // ============ Core Functions ============

    /**
     * @notice Record resolver involvement in a dispute
     * @param workflowId The escrow transfer ID
     * @param resolver Resolver address
     * @param level Escalation level (0 = standard, 1 = senior, 2 = external)
     * @dev Called by escrow contract or resolution module when resolver is assigned or escalated
     */
    function recordResolver(
        uint256 workflowId,
        address resolver,
        uint8 level
    ) external onlyEscrowContract {
        _recordResolver(workflowId, resolver, level);
    }

    function _recordResolver(uint256 workflowId, address resolver, uint8 level) internal {
        if (resolver == address(0)) revert ZeroResolver();
        if (level > 2) revert InvalidLevel(level, 2);

        // Prevent duplicate resolver recording (same resolver at any level)
        if (resolverRecorded[workflowId][resolver]) {
            revert ResolverAlreadyRecorded(resolver);
        }

        // Prevent gas DoS with too many resolvers
        ResolverRecord[] storage resolvers = disputeResolvers[workflowId];
        if (resolvers.length >= MAX_RESOLVERS_PER_DISPUTE) {
            revert TooManyResolvers(resolvers.length, MAX_RESOLVERS_PER_DISPUTE);
        }

        // Record new resolver
        resolvers.push(
            ResolverRecord({resolver: resolver, level: level, timestamp: block.timestamp})
        );
        
        // Mark resolver as recorded
        resolverRecorded[workflowId][resolver] = true;

        emit ResolverRecorded(workflowId, resolver, level, block.timestamp);
    }

    /**
     * @notice Record escrow fee for a dispute
     * @param workflowId The escrow transfer ID
     * @param token Token address
     * @param amount Fee amount
     * @dev Called by escrow contract or resolution module when dispute is opened
     *      HIGH-2: IMPORTANT - Escrow contract MUST transfer tokens to this contract
     *      BEFORE calling onDisputeResolved(). The expected balance is tracked here,
     *      and onDisputeResolved() will validate that actual balance matches expected.
     *      If tokens are not transferred, onDisputeResolved() will fail with
     *      InsufficientBalanceForFees error.
     */
    function recordEscrowFee(
        uint256 workflowId,
        address token,
        uint256 amount
    ) external onlyEscrowContract {
        _recordEscrowFee(workflowId, token, amount);
    }

    function _recordEscrowFee(uint256 workflowId, address token, uint256 amount) internal {
        address escrow = _msgSender();
        if (token == address(0)) revert ZeroToken();
        if (amount == 0) revert ZeroAmount();
        
        // Check and update rate limits
        _checkAndUpdateRateLimits(escrow, 1, amount);
        
        // MED-1: Prevent duplicate escrow fee recording
        if (disputeEscrowFees[workflowId] != 0) {
            revert EscrowFeeAlreadyRecorded(workflowId);
        }
        
        // Maximum fee limit per dispute
        if (amount > MAX_ESCROW_FEE_PER_DISPUTE) {
            revert AmountExceedsMaximum(amount, MAX_ESCROW_FEE_PER_DISPUTE);
        }

        // CRIT-2: Track expected balance
        disputeEscrowFees[workflowId] = amount;
        disputeExpectedTokenBalance[workflowId] += amount;
        // Track timestamp for stale detection
        feeRecordedTimestamp[workflowId] = block.timestamp;
        
        emit EscrowFeeRecorded(workflowId, token, amount);
    }

    /**
     * @notice Record escalation fee for a dispute
     * @param workflowId The escrow transfer ID
     * @param token Token address
     * @param amount Fee amount
     * @dev Called by escrow contract when dispute is escalated
     */
    function recordEscalationFee(
        uint256 workflowId,
        address token,
        uint256 amount
    ) external onlyEscrowContract {
        _recordEscalationFee(workflowId, token, amount);
    }

    function _recordEscalationFee(uint256 workflowId, address token, uint256 amount) internal {
        address escrow = _msgSender();
        if (token == address(0)) revert ZeroToken();
        if (amount == 0) revert ZeroAmount();
        if (amount >= type(uint256).max / 2) revert AmountTooLarge(amount); // Prevent overflow

        // Check if dispute exists
        if (disputeResolvers[workflowId].length == 0) revert DisputeNotInitialized(workflowId);

        // Check and update rate limits (only count fees, not additional dispute)
        _checkAndUpdateRateLimits(escrow, 0, amount);

        // HIGH-1: Maximum escalation fee limit per dispute (check after accumulation)
        uint256 newTotal = disputeEscalationFees[workflowId] + amount;
        if (amount > MAX_ESCALATION_FEE_PER_DISPUTE) {
            revert AmountExceedsMaximum(amount, MAX_ESCALATION_FEE_PER_DISPUTE);
        }
        if (newTotal > MAX_ESCALATION_FEE_PER_DISPUTE) {
            revert AmountExceedsMaximum(newTotal, MAX_ESCALATION_FEE_PER_DISPUTE);
        }

        // CRIT-2: Track expected balance
        disputeEscalationFees[workflowId] = newTotal;
        disputeExpectedTokenBalance[workflowId] += amount;
        // Update timestamp if not already set
        if (feeRecordedTimestamp[workflowId] == 0) {
            feeRecordedTimestamp[workflowId] = block.timestamp;
        }
        
        emit EscalationFeeRecorded(workflowId, token, amount);
    }

    // ============ IIncentiveModule Lifecycle Hooks ============

    /**
     * @notice Called when a dispute is opened (IIncentiveModule interface)
     * @dev Records escrow fee for the dispute
     */
    function onDisputeOpened(
        uint256 workflowId,
        address token,
        uint256 /* amount */,
        uint256 escrowFee,
        uint8 /* round */
    ) external override onlyEscrowContract {
        // Record escrow fee (V1 tracks fees separately)
        if (escrowFee > 0) {
            _recordEscrowFee(workflowId, token, escrowFee);
        }
    }

    /**
     * @notice Called when a resolver is assigned (IIncentiveModule interface)
     * @dev Records resolver involvement
     */
    function onResolverAssigned(
        uint256 workflowId,
        address resolver,
        uint8 round
    ) external override onlyEscrowContract {
        _recordResolver(workflowId, resolver, round);
    }

    /**
     * @notice Called when a resolver submits a decision (IIncentiveModule interface)
     * @dev V1 doesn't track individual decisions, but can be extended
     */
    function onDecisionSubmitted(
        uint256 workflowId,
        address resolver,
        uint8 round,
        DecentralizedResolverStructs.ResolutionOutcome decision,
        uint256 responseTime
    ) external override onlyEscrowContract {
        // V1 doesn't need to track individual decisions
        // This hook is for V2+ appeal bond logic
    }

    /**
     * @notice Called when a dispute is escalated (IIncentiveModule interface)
     * @dev V1 tracks escalation fees separately
     */
    function onEscalated(
        uint256 workflowId,
        uint8 fromRound,
        uint8 toRound,
        address escalatedBy
    ) external override onlyEscrowContract {
        // V1 tracks escalation fees via recordEscalationFee
        // This hook is for V2+ appeal bond logic
    }

    /**
     * @notice Called when a dispute is finalized (IIncentiveModule interface)
     * @dev V1 can trigger payment distribution if not already done
     */
    function onDisputeFinalized(
        uint256 /* workflowId */,
        uint8 /* finalRound */,
        DecentralizedResolverStructs.ResolutionOutcome /* finalDecision */
    ) external override onlyEscrowContract {
        // V1 payments are calculated via onDisputeResolved
        // This hook is informational for V2+ appeal bond distribution
    }

    /**
     * @notice Called when a resolver times out (IIncentiveModule interface)
     * @dev V1 doesn't track timeouts in incentive module
     */
    function onResolverTimeout(
        uint256 workflowId,
        address resolver,
        uint8 round,
        uint8 timeoutType
    ) external override onlyEscrowContract {
        // V1 doesn't track timeouts in incentive module
        // This hook is for V2+ appeal bond logic
    }

    // ============ V2+ Functions (Stub Implementations) ============

    /**
     * @notice Get required appeal bond for escalation (V2+)
     * @dev V1 doesn't support appeal bonds - returns zero
     */
    function getRequiredAppealBond(
        uint256 /* workflowId */,
        uint8 /* fromRound */,
        uint8 /* toRound */
    ) external view virtual override returns (uint256 bondAmount, address token) {
        return (0, address(0));
    }

    /**
     * @notice Check if module supports a specific feature
     * @return supported Whether the feature is supported (V1 returns false for all features)
     */
    function supportsFeature(bytes4 /* featureId */) external pure virtual returns (bool supported) {
        return false; // V1 doesn't support any V2+ features
    }

    /**
     * @notice Record appeal bond payment (V2+)
     * @dev V1 doesn't support appeal bonds - reverts
     */
    function recordAppealBond(
        uint256 /* workflowId */,
        address /* depositor */,
        address /* escalatedBy */,
        uint256 /* amount */,
        address /* token */,
        uint8 /* round */
    ) external payable virtual override {
        revert('V1 does not support appeal bonds');
    }

    /**
     * @notice Distribute appeal bond based on outcome (V2+)
     * @dev V1 doesn't support appeal bonds - reverts
     */
    function distributeAppealBond(
        uint256 /* workflowId */,
        uint8 /* round */,
        bool /* outcomeFlipped */
    ) external virtual override {
        revert('V1 does not support appeal bonds');
    }

    /**
     * @notice Calculate and distribute resolver payments for a finalized dispute (IIncentiveModule interface)
     * @param workflowId Unique identifier for the dispute
     * @param token Token address for payment
     * @dev This is a wrapper that calls onDisputeResolved for backward compatibility
     *      Note: totalFees parameter from interface is ignored as fees are already recorded via recordEscrowFee/recordEscalationFee
     */
    function distributePayments(
        uint256 workflowId,
        address token,
        uint256 /* totalFees */
    ) external virtual override onlyEscrowContract {
        // Delegate to onDisputeResolved for backward compatibility
        // Note: totalFees parameter is ignored as fees are already recorded via recordEscrowFee/recordEscalationFee
        onDisputeResolved(workflowId, token);
    }

    /**
     * @notice Calculate payments when dispute is resolved (pull pattern)
     * @param workflowId The escrow transfer ID
     * @param token Token address for payments
     * @dev Called by escrow contract when dispute is resolved
     *      Calculates payments and makes them claimable (pull pattern)
     *      HIGH-2: Escrow contract MUST transfer tokens to this contract BEFORE calling this function.
     *      The expected balance is tracked via recordEscrowFee/recordEscalationFee, and this function
     *      validates that actual balance >= expected balance. If tokens are not transferred, this will
     *      fail with InsufficientBalanceForFees error.
     */
    function onDisputeResolved(
        uint256 workflowId,
        address token
    ) public onlyEscrowContract nonReentrant {
        if (token == address(0)) revert ZeroToken();
        if (paymentsCalculated[workflowId]) revert PaymentsAlreadyCalculated(workflowId);

        // Gather data (imperative - state reads)
        ResolverRecord[] memory resolvers = disputeResolvers[workflowId];
        if (resolvers.length == 0) revert NoResolvers(workflowId);

        uint256 escrowFee = disputeEscrowFees[workflowId];
        uint256 escalationFees = disputeEscalationFees[workflowId];
        uint256 totalRecordedFees = escrowFee + escalationFees;

        // Check for stale fee recording (fees recorded too long ago)
        uint256 feeRecordedAt = feeRecordedTimestamp[workflowId];
        if (feeRecordedAt > 0 && block.timestamp > feeRecordedAt + MAX_FEE_RECORDING_AGE) {
            emit StaleFeeRecordingDetected(workflowId, feeRecordedAt, block.timestamp);
            // Continue anyway - escrow may have valid reason for delay
            // But this allows monitoring for potential issues
        }

        // CRIT-1/CRIT-3: Validate balance matches recorded fees (with tolerance for rounding)
        IERC20 tokenContract = IERC20(token);
        uint256 contractBalance = tokenContract.balanceOf(address(this));
        uint256 expectedBalance = disputeExpectedTokenBalance[workflowId];
        
        // Check that balance is sufficient for recorded fees
        if (contractBalance < totalRecordedFees) {
            // Emit detailed error for debugging transfer issues
            revert InsufficientBalanceForFees(totalRecordedFees, contractBalance);
        }
        
        // Check that balance matches expected (with tolerance for rounding/errors)
        // Allow small tolerance (0.01% = 1 basis point) for rounding errors
        uint256 tolerance = (expectedBalance * BALANCE_TOLERANCE_BPS) / BASIS_POINTS_DENOMINATOR;
        if (contractBalance > expectedBalance + tolerance) {
            // Balance exceeds expected - emit event for monitoring but allow to proceed
            // This could indicate direct token sends (attack attempt) or accounting error
            emit BalanceMismatchDetected(workflowId, token, expectedBalance, contractBalance);
            // Continue but use recorded fees for calculation, not inflated balance
        }
        
        // Clear expected balance tracking after validation
        delete disputeExpectedTokenBalance[workflowId];

        // Prepare input (functional data structure)
        PaymentInput memory input = PaymentInput({
            escrowFee: escrowFee,
            escalationFees: escalationFees,
            resolverSharePercentage: resolverSharePercentage,
            resolvers: resolvers,
            weights: weights
        });

        // Calculate payments (functional - pure library call)
        PaymentOutput memory output = calculatePaymentsWithVersion(input);

        // ============ Bounds Checking ============
        // Validate payment calculation results

        // 1. Array length validation
        if (output.resolvers.length != output.payments.length) {
            revert ArrayLengthMismatch(output.resolvers.length, output.payments.length); // Uses EscrowTypes.sol error
        }
        if (output.resolvers.length == 0) revert NoResolvers(workflowId);

        // 2. Total amount validation - resolver share cannot exceed total fees
        if (output.totalResolverShare > escrowFee + escalationFees) {
            revert ResolverShareExceedsTotalFees(output.totalResolverShare, escrowFee + escalationFees);
        }

        // 3. Individual payment validation
        uint256 calculatedTotal = 0;
        for (uint256 i = 0; i < output.payments.length; i++) {
            // Each payment must be non-negative and not exceed total
            if (output.payments[i] > output.totalResolverShare) {
                revert IndividualPaymentExceedsTotal(output.payments[i], output.totalResolverShare);
            }

            // Sum validation (check for overflow)
            uint256 previousTotal = calculatedTotal;
            calculatedTotal += output.payments[i];
            if (calculatedTotal < previousTotal) revert PaymentSumOverflow(previousTotal, output.payments[i]);
        }

        // 4. Sum validation - sum of individual payments should equal total
        if (calculatedTotal != output.totalResolverShare) {
            revert PaymentSumMismatch(calculatedTotal, output.totalResolverShare);
        }

        // 5. Resolver address validation
        for (uint256 i = 0; i < output.resolvers.length; i++) {
            if (output.resolvers[i] == address(0)) revert ZeroResolverAddress(i);
        }

        // 6. Maximum payment validation - no single payment should exceed reasonable bounds
        // (e.g., no single resolver should get more than 90% of total share)
        // Only apply this check when there are multiple resolvers
        // When there's only one resolver, they should legitimately get 100% of the share
        if (output.resolvers.length > 1) {
            uint256 maxSinglePayment = (output.totalResolverShare * MAX_SINGLE_PAYMENT_PERCENTAGE) /
                BASIS_POINTS_DENOMINATOR;
            for (uint256 i = 0; i < output.payments.length; i++) {
                if (output.payments[i] > maxSinglePayment) {
                    revert PaymentExceedsMaximumAllowed(output.payments[i], maxSinglePayment);
                }
            }
        }

        // 7. Minimum payment validation - if there are multiple resolvers, no payment should be 0
        // (unless explicitly allowed by the payment library)
        // Note: Zero payments are allowed but will be skipped in distribution

        // CRIT-1/CRIT-3: Additional check - resolver share cannot exceed what we actually have
        // Note: contractBalance was already checked above, but double-check here for safety
        if (contractBalance < output.totalResolverShare) {
            revert InsufficientBalanceForFees(output.totalResolverShare, contractBalance);
        }

        // Store claimable amounts (pull pattern - resolvers claim their payments)
        for (uint256 i = 0; i < output.resolvers.length; i++) {
            if (output.resolvers[i] != address(0) && output.payments[i] > 0) {
                claimablePayments[workflowId][output.resolvers[i]] = output.payments[i];
            }
        }

        // Mark as calculated (allows resolvers to claim)
        paymentsCalculated[workflowId] = true;
        disputePaymentsDistributed[workflowId] = true; // For backward compatibility
        
        // CRIT-2/CRIT-3: Clear fee tracking after successful payment calculation
        // Note: Keep fees in storage for view functions, but clear expected balance (already cleared above)
        // Consider clearing fees if needed, but keeping them for historical queries might be useful

        emit PaymentsCalculated(workflowId, token, output.totalResolverShare);
    }

    /**
     * @notice Claim payment for a resolved dispute (pull pattern)
     * @param workflowId The escrow transfer ID
     * @param token Token address for payment
     * @dev Resolvers call this to claim their payment
     *      Allows retry if initial transfer fails
     */
    function claimPayment(uint256 workflowId, address token) external nonReentrant {
        if (token == address(0)) revert ZeroToken();
        if (!paymentsCalculated[workflowId]) revert PaymentsNotCalculated(workflowId);

        uint256 amount = claimablePayments[workflowId][_msgSender()];
        if (amount == 0) revert NothingToClaim(workflowId, _msgSender());

        // Clear claimable amount before transfer (prevent reentrancy)
        delete claimablePayments[workflowId][_msgSender()];

        // Transfer payment (safeTransfer will revert on failure, restoring claimable amount is not needed
        // since the delete above will be reverted by the transaction revert)
        IERC20 tokenContract = IERC20(token);
        tokenContract.safeTransfer(_msgSender(), amount);

        emit PaymentClaimed(workflowId, _msgSender(), amount);
    }

    /**
     * @notice Calculate payments using current library with version detection
     * @param input Payment calculation input
     * @return output Payment calculation results
     * @dev Detects library version and calls appropriate function
     */
    function calculatePaymentsWithVersion(
        PaymentInput memory input
    ) internal view returns (PaymentOutput memory) {
        // Get library version
        string memory libVersion = IPaymentCalculationLibrary(currentPaymentLibrary).version();

        // For V1, use standard interface
        // Future versions can add version-specific handling here
        if (keccak256(bytes(libVersion)) == keccak256(bytes('1.0.0'))) {
            // V1: Standard interface call
            return IPaymentCalculationLibrary(currentPaymentLibrary).calculatePayments(input);
        } else {
            // Unknown version - try standard interface (extensible input should handle it)
            return IPaymentCalculationLibrary(currentPaymentLibrary).calculatePayments(input);
        }
    }

    // ============ Governance Functions ============

    /**
     * @notice Queue new payment calculation library (slow-lane, governance-controlled)
     * @param newLibrary Address of new library contract
     * @dev Validates library before queueing, 7-day delay before activation
     */
    function queuePaymentCalculationLibrary(address newLibrary) external onlyRole(ROLE_TIMELOCK) {
        if (newLibrary == address(0)) revert ZeroAddressField('paymentLibrary');
        if (!validateLibrary(newLibrary)) revert InvalidLibrary(newLibrary);

        _queueAddress(_pendingPaymentLibrary, newLibrary);
        emit PaymentLibraryQueued(currentPaymentLibrary, newLibrary, _pendingPaymentLibrary.eta);
    }

    /**
     * @notice Activate queued payment calculation library
     * @dev Reverts if 7-day delay has not elapsed
     */
    function activatePaymentCalculationLibrary() external onlyRole(ROLE_TIMELOCK) {
        address oldLibrary = currentPaymentLibrary;
        currentPaymentLibrary = _activateAddress(_pendingPaymentLibrary);

        emit PaymentLibraryActivated(oldLibrary, currentPaymentLibrary);
    }

    /**
     * @notice Rollback to previous library (emergency only)
     * @param previousLibrary Address of previous library
     * @dev Should be used only in emergencies
     */
    function rollbackToPreviousLibrary(address previousLibrary) external onlyRole(ROLE_TIMELOCK) {
        if (previousLibrary == address(0)) revert ZeroAddressField('paymentLibrary');
        if (!validateLibrary(previousLibrary)) revert InvalidLibrary(previousLibrary);

        currentPaymentLibrary = previousLibrary;
        emit PaymentLibraryRolledBack(previousLibrary);
    }

    /**
     * @notice Queue resolver share percentage change
     * @param newPercentage New percentage (basis points, e.g., 5000 = 50%)
     * @dev 7-day delay before activation
     */
    function queueResolverSharePercentage(uint256 newPercentage) external onlyRole(ROLE_TIMELOCK) {
        if (newPercentage > 10000) revert InvalidPercentage(newPercentage, 10000);

        _queueUint(_pendingResolverSharePercentage, newPercentage);
        emit ResolverSharePercentageQueued(
            resolverSharePercentage,
            newPercentage,
            _pendingResolverSharePercentage.eta
        );
    }

    /**
     * @notice Activate queued resolver share percentage
     * @dev Reverts if 7-day delay has not elapsed
     */
    function activateResolverSharePercentage() external onlyRole(ROLE_TIMELOCK) {
        uint256 oldPercentage = resolverSharePercentage;
        resolverSharePercentage = _activateUint(_pendingResolverSharePercentage);

        emit ResolverSharePercentageActivated(oldPercentage, resolverSharePercentage);
    }

    /**
     * @notice Queue weights change
     * @param newWeights New weight configuration
     * @dev 7-day delay before activation
     */
    function queueWeights(Weights memory newWeights) external onlyRole(ROLE_TIMELOCK) {
        if (newWeights.level0 == 0) revert InvalidWeight(0, newWeights.level0);
        if (newWeights.level1 == 0) revert InvalidWeight(1, newWeights.level1);
        if (newWeights.level2 == 0) revert InvalidWeight(2, newWeights.level2);

        _pendingWeights = PendingWeights({
            value: newWeights,
            eta: uint64(block.timestamp + SLOW_DELAY), // forge-lint: disable-line(unsafe-typecast)
            exists: true
        });

        emit WeightsQueued(weights, newWeights, _pendingWeights.eta);
    }

    /**
     * @notice Activate queued weights
     * @dev Reverts if 7-day delay has not elapsed
     */
    function activateWeights() external onlyRole(ROLE_TIMELOCK) {
        if (!_pendingWeights.exists) {
            revert NoPending();
        }
        if (block.timestamp < _pendingWeights.eta) {
            revert NotReady(_pendingWeights.eta);
        }

        Weights memory oldWeights = weights;
        weights = _pendingWeights.value;

        emit WeightsActivated(oldWeights, weights);

        // Clear pending
        delete _pendingWeights;
    }

    /**
     * @notice Register escrow contract
     * @param escrowContract Address of escrow contract
     * @dev Only registered contracts can call incentive functions
     */
    function registerEscrowContract(address escrowContract) external onlyRole(ROLE_TIMELOCK) {
        if (escrowContract == address(0)) revert ZeroAddressField('escrowContract');
        registeredEscrowContracts[escrowContract] = true;
        emit EscrowContractRegistered(escrowContract);
    }

    /**
     * @notice Unregister escrow contract
     * @param escrowContract Address of escrow contract
     */
    function unregisterEscrowContract(address escrowContract) external onlyRole(ROLE_TIMELOCK) {
        registeredEscrowContracts[escrowContract] = false;
        emit EscrowContractUnregistered(escrowContract);
    }

    // ============ HIGH-3: Escrow Rate Limiting Functions ============

    /**
     * @notice Check and update rate limits for an escrow contract
     * @param escrow Escrow contract address
     * @param disputeCount Number of new disputes (typically 0 or 1)
     * @param feeAmount Fee amount to add to daily total
     * @dev Internal function called by fee recording functions
     */
    function _checkAndUpdateRateLimits(
        address escrow,
        uint256 disputeCount,
        uint256 feeAmount
    ) internal {
        EscrowRateLimit storage limit = escrowRateLimits[escrow];
        
        // Reset window if new day
        if (block.timestamp >= limit.windowStart + RATE_LIMIT_WINDOW) {
            limit.disputesToday = 0;
            limit.feesToday = 0;
            limit.windowStart = block.timestamp;
            emit EscrowRateLimitReset(escrow, block.timestamp);
        }
        
        // Check dispute rate limit
        if (disputeCount > 0) {
            uint256 newDisputeCount = limit.disputesToday + disputeCount;
            if (newDisputeCount > MAX_DISPUTES_PER_ESCROW_PER_DAY) {
                emit EscrowRateLimitExceededEvent(
                    escrow,
                    'disputes',
                    newDisputeCount,
                    MAX_DISPUTES_PER_ESCROW_PER_DAY
                );
                revert EscrowRateLimitExceeded(escrow, newDisputeCount, MAX_DISPUTES_PER_ESCROW_PER_DAY);
            }
            limit.disputesToday = newDisputeCount;
        }
        
        // Check fee rate limit
        if (feeAmount > 0) {
            uint256 newFeeTotal = limit.feesToday + feeAmount;
            if (newFeeTotal > MAX_FEES_PER_ESCROW_PER_DAY) {
                emit EscrowRateLimitExceededEvent(
                    escrow,
                    'fees',
                    newFeeTotal,
                    MAX_FEES_PER_ESCROW_PER_DAY
                );
                revert EscrowRateLimitExceeded(escrow, newFeeTotal, MAX_FEES_PER_ESCROW_PER_DAY);
            }
            limit.feesToday = newFeeTotal;
        }
    }

    /**
     * @notice Pause an escrow contract (emergency stop)
     * @param escrowContract Address of escrow contract to pause
     * @dev Only timelock can pause escrows. Paused escrows cannot call incentive functions.
     */
    function pauseEscrowContract(address escrowContract) external onlyRole(ROLE_TIMELOCK) {
        if (!registeredEscrowContracts[escrowContract]) revert NotRegisteredEscrowContract(escrowContract);
        escrowRateLimits[escrowContract].paused = true;
        emit EscrowPausedEvent(escrowContract, _msgSender());
    }

    /**
     * @notice Unpause an escrow contract
     * @param escrowContract Address of escrow contract to unpause
     * @dev Only timelock can unpause escrows
     */
    function unpauseEscrowContract(address escrowContract) external onlyRole(ROLE_TIMELOCK) {
        escrowRateLimits[escrowContract].paused = false;
        emit EscrowUnpausedEvent(escrowContract, _msgSender());
    }

    /**
     * @notice Reset rate limit window for an escrow (emergency override)
     * @param escrowContract Address of escrow contract
     * @dev Only timelock can reset rate limits. Use with caution - only for legitimate emergencies.
     */
    function resetEscrowRateLimit(address escrowContract) external onlyRole(ROLE_TIMELOCK) {
        EscrowRateLimit storage limit = escrowRateLimits[escrowContract];
        limit.disputesToday = 0;
        limit.feesToday = 0;
        limit.windowStart = block.timestamp;
        emit EscrowRateLimitReset(escrowContract, block.timestamp);
    }

    /**
     * @notice Get rate limit status for an escrow
     * @param escrowContract Address of escrow contract
     * @return disputesToday Current disputes in window
     * @return feesToday Current fees in window
     * @return windowStart Start timestamp of current window
     * @return paused Whether escrow is paused
     * @return windowEnd When current window expires
     */
    function getEscrowRateLimit(
        address escrowContract
    )
        external
        view
        returns (
            uint256 disputesToday,
            uint256 feesToday,
            uint256 windowStart,
            bool paused,
            uint256 windowEnd
        )
    {
        EscrowRateLimit storage limit = escrowRateLimits[escrowContract];
        return (
            limit.disputesToday,
            limit.feesToday,
            limit.windowStart,
            limit.paused,
            limit.windowStart + RATE_LIMIT_WINDOW
        );
    }

    // ============ HIGH-2: Fee Recording Management Functions ============

    /**
     * @notice Clear expected balance for a dispute (if transfer validation fails)
     * @param workflowId The escrow transfer ID
     * @param reason Reason for clearing (for event logging)
     * @dev Only timelock can clear fee recordings. Use when escrow fails to transfer tokens
     *      and dispute needs to be reset or cancelled.
     */
    function clearFeeRecording(uint256 workflowId, string memory reason) external onlyRole(ROLE_TIMELOCK) {
        delete disputeExpectedTokenBalance[workflowId];
        delete feeRecordedTimestamp[workflowId];
        // Note: Keep disputeEscrowFees and disputeEscalationFees for historical record
        emit FeeRecordingCleared(workflowId, reason);
    }

    // ============ Validation Functions ============

    /**
     * @notice Validate a library before queueing
     * @param libAddress Library address to validate
     * @return valid True if library is valid
     */
    function validateLibrary(address libAddress) public view returns (bool) {
        if (libAddress.code.length == 0) return false;

        // Check interface compliance
        try IPaymentCalculationLibrary(libAddress).validate() returns (bool valid) {
            if (!valid) return false;
        } catch {
            return false;
        }

        // Test with sample input
        PaymentInput memory testInput = createTestInput();
        try IPaymentCalculationLibrary(libAddress).calculatePayments(testInput) returns (
            PaymentOutput memory
        ) {
            return true;
        } catch {
            return false;
        }
    }

    /**
     * @notice Create test input for validation
     * @return testInput Test payment input
     */
    function createTestInput() internal view returns (PaymentInput memory) {
        ResolverRecord[] memory resolvers = new ResolverRecord[](2);
        resolvers[0] = ResolverRecord({
            resolver: address(0x1),
            level: 0,
            timestamp: 0 // Timestamp not needed for calculation
        });
        resolvers[1] = ResolverRecord({
            resolver: address(0x2),
            level: 1,
            timestamp: 0 // Timestamp not needed for calculation
        });

        return
            PaymentInput({
                escrowFee: 1000,
                escalationFees: 500,
                resolverSharePercentage: resolverSharePercentage,
                resolvers: resolvers,
                weights: weights
            });
    }

    // ============ View Functions ============

    /**
     * @notice Get pending library change
     * @return libAddress Pending library address
     * @return eta Activation timestamp
     * @return exists Whether pending change exists
     */
    function getPendingPaymentLibrary()
        external
        view
        returns (address libAddress, uint64 eta, bool exists)
    {
        return getPendingAddress(_pendingPaymentLibrary);
    }

    /**
     * @notice Get pending resolver share percentage change
     * @return percentage Pending percentage
     * @return eta Activation timestamp
     * @return exists Whether pending change exists
     */
    function getPendingResolverSharePercentage()
        external
        view
        returns (uint256 percentage, uint64 eta, bool exists)
    {
        return getPendingUint(_pendingResolverSharePercentage);
    }

    /**
     * @notice Get pending weights change
     * @return pendingWeights Pending weights
     * @return eta Activation timestamp
     * @return exists Whether pending change exists
     */
    function getPendingWeights()
        external
        view
        returns (Weights memory pendingWeights, uint64 eta, bool exists)
    {
        return (_pendingWeights.value, _pendingWeights.eta, _pendingWeights.exists);
    }

    /**
     * @notice Get resolvers for a dispute
     * @param workflowId The escrow transfer ID
     * @return resolvers Array of resolver records
     */
    function getDisputeResolvers(
        uint256 workflowId
    ) external view returns (ResolverRecord[] memory) {
        return disputeResolvers[workflowId];
    }

    /**
     * @notice Get fee information for a dispute
     * @param workflowId The escrow transfer ID
     * @return escrowFee Escrow fee
     * @return escalationFees Total escalation fees
     */
    function getDisputeFees(
        uint256 workflowId
    ) external view returns (uint256 escrowFee, uint256 escalationFees) {
        return (disputeEscrowFees[workflowId], disputeEscalationFees[workflowId]);
    }

    /**
     * @notice Check if payments have been distributed for a dispute
     * @param workflowId The escrow transfer ID
     * @return distributed True if payments have been distributed
     */
    function arePaymentsDistributed(uint256 workflowId) external view returns (bool) {
        return disputePaymentsDistributed[workflowId];
    }

    /**
     * @notice Check if payments have been calculated for a dispute
     * @param workflowId The escrow transfer ID
     * @return calculated True if payments have been calculated (claimable)
     */
    function arePaymentsCalculated(uint256 workflowId) external view returns (bool) {
        return paymentsCalculated[workflowId];
    }

    /**
     * @notice Get claimable payment amount for a resolver
     * @param workflowId The escrow transfer ID
     * @param resolver Resolver address
     * @return amount Claimable amount (0 if nothing to claim)
     */
    function getClaimablePayment(
        uint256 workflowId,
        address resolver
    ) external view returns (uint256) {
        return claimablePayments[workflowId][resolver];
    }

    /**
     * @notice ERC165 interface support
     * @param interfaceId The interface identifier
     * @return True if the contract supports the interface
     * @dev AccessControlUpgradeable already includes ERC165Upgradeable
     */
    function supportsInterface(
        bytes4 interfaceId
    ) public view virtual override(AccessControl) returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}
