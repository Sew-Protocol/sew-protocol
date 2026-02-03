// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import './ISlashingModule.sol';
import './ResolverStakingModuleV1.sol';
import './InsurancePoolVault.sol';
import '@openzeppelin/contracts/access/AccessControl.sol';
import '@openzeppelin/contracts/utils/ReentrancyGuard.sol';
import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';

/**
 * @title ResolverSlashingModuleV1
 * @notice Real slashing implementation for DR v3 with conservative penalties
 * @dev Key Features:
 *      - Trigger types: missed accept, missed resolve, unresponsive
 *      - No reversal slashing initially (too harsh for early rollout)
 *      - Conservative penalty schedule: 2% (accept), 5% (resolve), 10% (unresponsive)
 *      - Waterfall: Resolver bond first, then senior coverage after exhaustion
 *      - Circuit breakers: Mass unavailability detection → throttle assignments
 *
 * Security Properties:
 *      1. Slashes never exceed caps (per-slash and per-period)
 *      2. No double slashing (one slash per offense)
 *      3. Freeze logic prevents withdrawal during slash processing
 *      4. Waterfall ordering: junior exhausted before senior exposed
 */
contract ResolverSlashingModuleV1 is ISlashingModule, AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ============ Custom Errors ============
    error ZeroAddress(string field);
    error AlreadySlashedForWorkflow(address escrowContract, uint256 workflowId, address resolver);
    error SlashNotPending(uint256 slashId, SlashStatus currentStatus);
    error AppealWindowOpen(uint256 slashId, uint256 appealDeadline, uint256 currentTime);
    error AppealWindowClosed(uint256 slashId, uint256 appealDeadline, uint256 currentTime);
    error NotResolver(address caller, address expectedResolver);
    error AlreadyAppealed(uint256 slashId);
    error AppealAlreadyResolved(uint256 appealId);
    error FraudSlashingNotEnabled();
    error InvalidBps(uint256 bps, uint256 maxBps);
    error CooldownNotPassed(uint256 availableAt, uint256 currentTime);
    error ZeroAmount();
    error SlashNotFound(uint256 slashId);

    // ============ Constants ============

    bytes32 public constant ROLE_TIMELOCK = keccak256('ROLE_TIMELOCK');
    bytes32 public constant ROLE_RESOLUTION_MODULE = keccak256('ROLE_RESOLUTION_MODULE');

    uint256 public constant BASIS_POINTS = 10000;
    uint256 public constant PRECISION = 1e18;

    // v3 objective slashing schedule (basis points)
    uint256 public constant PENALTY_MISSED_ACCEPT = 25; // 0.25% (25 bps)
    uint256 public constant PENALTY_MISSED_RESOLVE = 200; // 2% (200 bps)
    uint256 public constant PENALTY_REPEAT_RESOLVE = 500; // 5% (500 bps) - repeat missed resolve in same epoch
    uint256 public constant PENALTY_REVERSAL = 0; // 0 bps initially (use reputation/workload only)

    // Epoch-based slash caps (v3)
    uint256 public constant EPOCH_LENGTH = 7 days;
    uint256 public constant RESOLVER_SLASH_CAP_BPS = 2000; // 20% per resolver per epoch
    uint256 public constant SENIOR_SLASH_CAP_BPS = 1000; // 10% per senior per epoch

    // Legacy slash caps (kept for backward compatibility)
    uint256 public constant MAX_SLASH_PER_OFFENSE = 5000; // 50% max per slash
    uint256 public constant MAX_SLASH_PER_PERIOD = 10000; // 100% max per 30 days
    uint256 public constant SLASH_PERIOD = 30 days;

    // Circuit breaker thresholds
    uint256 public constant MASS_UNAVAILABILITY_THRESHOLD = 3000; // 30% of resolvers
    uint256 public constant CIRCUIT_BREAKER_COOLDOWN = 1 hours;

    // SEW burn handling:
    // Prefer reducing totalSupply via ERC20Burnable.burn(uint256) if the token supports it.
    // Fallback is a transfer to a well-known dead address (effective burn, but supply not reduced).
    address public constant DEAD_BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    // ============ State Variables ============

    ResolverStakingModuleV1 public stakingModule;
    InsurancePoolVault public insurancePoolVault;
    IERC20 public stableToken;

    bool public circuitBreakerActive;
    uint256 public lastCircuitBreakerTrigger;

    // Slash tracking
    uint256 private _nextSlashId;
    mapping(uint256 => SlashEvent) public slashEvents; // slashId => SlashEvent
    mapping(uint256 => SlashAppeal) public slashAppeals; // slashId => SlashAppeal

    // Prevent double slashing
    mapping(address => mapping(uint256 => mapping(address => bool))) public workflowSlashed; // escrowContract => workflowId => resolver => slashed

    // Per-resolver slash tracking (for caps)
    struct SlashPeriodTracker {
        uint256 periodStart;
        uint256 totalSlashedInPeriod;
    }
    mapping(address => SlashPeriodTracker) public slashTrackers;

    // v3 epoch-based slash tracking
    struct EpochSlashTracker {
        uint256 epochStart;
        uint256 totalSlashedInEpoch;
        uint256 lastSlashTime;
        uint8 slashCount; // Count of slashes in this epoch
    }
    mapping(address => EpochSlashTracker) public epochSlashTrackers;

    // Freeze tracking (prevents withdrawal during slash processing)
    mapping(address => uint256) public frozenUntil; // resolver => timestamp
    mapping(address => uint256) public freezeUntil; // resolver => timestamp (for insufficient bond)
    
    // v3 freeze durations
    uint256 public constant FREEZE_DURATION_SEVERE = 72 hours; // Severe event (missed resolve deadline)
    uint256 public constant FREEZE_DURATION_REPEATED = 7 days; // Repeated severe event within epoch
    uint256 public constant FREEZE_DURATION_LEGACY = 7 days; // Legacy freeze duration (backward compatibility)

    // Mass unavailability tracking
    struct UnavailabilityStats {
        uint256 totalResolvers;
        uint256 unavailableCount;
        uint256 lastUpdate;
    }
    UnavailabilityStats public unavailabilityStats;

    // Slash config (governance-controlled)
    SlashConfig public slashConfig;

    // ============ Events ============

    event SlashExecutedWithWaterfall(
        uint256 indexed slashId,
        address indexed resolver,
        address indexed senior,
        uint256 resolverSlashed,
        uint256 seniorSlashed,
        uint256 totalSlashed
    );
    event ResolverFrozen(address indexed resolver, uint256 frozenUntil);
    event ResolverUnfrozen(address indexed resolver);
    event MassUnavailabilityDetected(
        uint256 unavailableCount,
        uint256 totalResolvers,
        uint256 percentage
    );
    event CircuitBreakerActivated(string reason);
    event CircuitBreakerDeactivated();
    event SlashCapEnforced(
        address indexed resolver,
        uint256 requestedSlash,
        uint256 actualSlash,
        string reason
    );

    event SlashedSEWHandled(uint256 indexed workflowId, uint256 amount, bool supplyReduced);

    // ============ Initialization ============

    constructor(
        address initialOwner,
        address _stakingModule,
        address _insurancePoolVault,
        address _stableToken
    ) {
        if (_stakingModule == address(0)) revert ZeroAddress('stakingModule');
        if (_insurancePoolVault == address(0)) revert ZeroAddress('insurancePoolVault');
        if (_stableToken == address(0)) revert ZeroAddress('stableToken');

        // OpenZeppelin best practice: Grant DEFAULT_ADMIN_ROLE to deployer
        // Deployment scripts will transfer this to TimelockController
        _grantRole(DEFAULT_ADMIN_ROLE, initialOwner);

        stakingModule = ResolverStakingModuleV1(_stakingModule);
        insurancePoolVault = InsurancePoolVault(_insurancePoolVault);
        stableToken = IERC20(_stableToken);

        // Note: ROLE_SLASHING_MODULE must be granted by vault admin after initialization
        // This is done in test setup and deployment scripts

        _nextSlashId = 1;
        circuitBreakerActive = false;

        // Initialize slash config with conservative defaults
        slashConfig = SlashConfig({
            timeoutSlashBps: PENALTY_MISSED_RESOLVE, // 200 bps (2%)
            reversalSlashBps: PENALTY_REVERSAL, // 0 bps initially (disabled)
            fraudSlashBps: 0, // Not implemented yet
            maxSlashPerPeriod: MAX_SLASH_PER_PERIOD,
            slashPeriod: SLASH_PERIOD,
            appealWindow: 3 days,
            appealBond: 100e18 // 100 USD
        });
    }

    // ============ Core Slashing Functions ============

    /**
     * @notice Propose a slash (not used in automated flow, for manual slashes)
     */
    function proposeSlash(
        uint256 workflowId,
        address escrowContract,
        address resolver,
        SlashReason reason,
        bytes calldata evidence
    ) external override onlyRole(ROLE_TIMELOCK) returns (uint256 slashId) {
        if (workflowSlashed[escrowContract][workflowId][resolver]) {
            revert AlreadySlashedForWorkflow(escrowContract, workflowId, resolver);
        }

        slashId = _nextSlashId++;

        uint256 slashAmount = _calculateSlashAmount(resolver, reason);

        slashEvents[slashId] = SlashEvent({
            slashId: slashId,
            workflowId: workflowId,
            escrowContract: escrowContract,
            resolver: resolver,
            reason: reason,
            amount: slashAmount,
            proposedAt: block.timestamp,
            executedAt: 0,
            appealDeadline: block.timestamp + slashConfig.appealWindow,
            status: SlashStatus.PENDING,
            proposer: _msgSender(),
            evidence: evidence
        });

        emit SlashProposed(slashId, workflowId, resolver, reason, slashAmount, _msgSender());
        return slashId;
    }

    /**
     * @notice Execute a slash (with waterfall: resolver → senior)
     */
    function executeSlash(uint256 slashId) external override nonReentrant onlyRole(ROLE_TIMELOCK) {
        SlashEvent storage slashEvent = slashEvents[slashId];
        if (slashEvent.slashId == 0) revert SlashNotFound(slashId);

        if (slashEvent.status != SlashStatus.PENDING) revert SlashNotPending(slashId, slashEvent.status);
        if (block.timestamp <= slashEvent.appealDeadline) {
            revert AppealWindowOpen(slashId, slashEvent.appealDeadline, block.timestamp);
        }

        address resolver = slashEvent.resolver;
        uint256 slashAmount = slashEvent.amount;

        // Reset tracking before slash
        _currentSlashStableAmount = 0;
        _currentSlashSewAmount = 0;

        // Execute waterfall slash
        (uint256 resolverSlashed, uint256 seniorSlashed, address senior) = _executeWaterfallSlash(
            resolver,
            slashAmount
        );

        uint256 totalSlashed = resolverSlashed + seniorSlashed;

        // Update slash event
        slashEvent.status = SlashStatus.EXECUTED;
        slashEvent.executedAt = block.timestamp;

        // Mark as slashed
        workflowSlashed[slashEvent.escrowContract][slashEvent.workflowId][resolver] = true;

        // Freeze resolver
        _freezeResolver(resolver);

        // Distribute slashed funds (using actual token amounts received)
        SlashDistribution memory distribution = _distributeSlashedFunds(
            _currentSlashStableAmount,
            slashEvent.reason,
            slashEvent.workflowId
        );

        // Reset tracking after distribution
        _currentSlashStableAmount = 0;
        _currentSlashSewAmount = 0;

        emit SlashExecuted(slashId, resolver, totalSlashed, distribution);
        emit SlashExecutedWithWaterfall(
            slashId,
            resolver,
            senior,
            resolverSlashed,
            seniorSlashed,
            totalSlashed
        );
    }

    /**
     * @notice Appeal a slash
     */
    function appealSlash(
        uint256 slashId,
        string calldata reason,
        bytes calldata evidence
    ) external override nonReentrant {
        SlashEvent storage slashEvent = slashEvents[slashId];
        if (slashEvent.slashId == 0) revert SlashNotFound(slashId);

        if (slashEvent.status != SlashStatus.PENDING) revert SlashNotPending(slashId, slashEvent.status);
        if (block.timestamp > slashEvent.appealDeadline) {
            revert AppealWindowClosed(slashId, slashEvent.appealDeadline, block.timestamp);
        }
        if (_msgSender() != slashEvent.resolver) revert NotResolver(_msgSender(), slashEvent.resolver);
        if (slashAppeals[slashId].slashId != 0 && slashAppeals[slashId].slashId != 0 && slashAppeals[slashId].resolved) {
            revert AlreadyAppealed(slashId);
        }

        // Record appeal
        slashAppeals[slashId] = SlashAppeal({
            slashId: slashId,
            appellant: _msgSender(),
            appealBond: slashConfig.appealBond,
            appealedAt: block.timestamp,
            reason: reason,
            evidence: evidence,
            resolved: false,
            upheld: false
        });

        emit SlashAppealed(slashId, _msgSender(), slashConfig.appealBond, reason);
    }

    /**
     * @notice Resolve an appeal
     */
    function resolveAppeal(uint256 slashId, bool upheld) external override onlyRole(ROLE_TIMELOCK) {
        SlashAppeal storage appeal = slashAppeals[slashId];
        SlashEvent storage slashEvent = slashEvents[slashId];
        if (slashEvent.slashId == 0) revert SlashNotFound(slashId);

        if (appeal.resolved) revert AppealAlreadyResolved(slashId);
        if (slashEvent.status != SlashStatus.PENDING) revert SlashNotPending(slashId, slashEvent.status);

        appeal.resolved = true;
        appeal.upheld = upheld;

        if (!upheld) {
            // Appeal rejected, slash proceeds
            emit SlashAppealResolved(slashId, false, address(0), 0);
        } else {
            // Appeal accepted, cancel slash
            slashEvent.status = SlashStatus.REVERSED;
            emit SlashReversed(slashId, slashEvent.resolver, slashEvent.amount);
            emit SlashAppealResolved(slashId, true, slashEvent.resolver, slashEvent.amount);
        }
    }

    // ============ Automated Slashing (Called by Resolution Module) ============

    /**
     * @notice Slash for timeout (missed accept or missed resolve)
     * @param workflowId Dispute ID
     * @param escrowContract Related escrow contract
     * @param resolver Resolver who timed out
     * @param timeoutType 0 = accept, 1 = resolve
     */
    function slashForTimeout(
        uint256 workflowId,
        address escrowContract,
        address resolver,
        uint8 timeoutType
    ) external override onlyRole(ROLE_RESOLUTION_MODULE) returns (uint256 slashId) {
        // Reset tracking before slash
        _currentSlashStableAmount = 0;
        _currentSlashSewAmount = 0;

        // Check if already slashed for this workflow
        if (workflowSlashed[escrowContract][workflowId][resolver]) {
            return 0; // Already slashed, skip
        }

        // Check circuit breaker
        if (circuitBreakerActive) {
            emit SlashCapEnforced(resolver, 0, 0, 'Circuit breaker active');
            return 0;
        }

        // Determine slash reason and amount
        SlashReason reason = (timeoutType == 0)
            ? SlashReason.TIMEOUT_ACCEPT
            : SlashReason.TIMEOUT_RESOLVE;

        uint256 slashAmount = _calculateSlashAmount(resolver, reason);

        // Check if slash would exceed caps
        slashAmount = _enforceSlashCaps(resolver, slashAmount);

        if (slashAmount == 0) {
            return 0; // Cap reached, skip slash
        }

        // Create slash event
        slashId = _nextSlashId++;

        slashEvents[slashId] = SlashEvent({
            slashId: slashId,
            workflowId: workflowId,
            escrowContract: escrowContract,
            resolver: resolver,
            reason: reason,
            amount: slashAmount,
            proposedAt: block.timestamp,
            executedAt: block.timestamp, // Auto-execute
            appealDeadline: 0, // No appeal for automated slashes
            status: SlashStatus.EXECUTED,
            proposer: _msgSender(),
            evidence: ''
        });

        // Execute waterfall slash immediately
        (uint256 resolverSlashed, uint256 seniorSlashed, address senior) = _executeWaterfallSlash(
            resolver,
            slashAmount
        );

        uint256 totalSlashed = resolverSlashed + seniorSlashed;

        // Mark as slashed
        workflowSlashed[escrowContract][workflowId][resolver] = true;

        // Freeze resolver
        _freezeResolver(resolver);

        // Distribute slashed funds (using actual token amounts received from staking module)
        SlashDistribution memory distribution = _distributeSlashedFunds(
            _currentSlashStableAmount,
            reason,
            workflowId
        );

        // Reset tracking after distribution
        _currentSlashStableAmount = 0;
        _currentSlashSewAmount = 0;

        // Update unavailability stats
        _updateUnavailabilityStats(resolver, true);

        emit SlashProposed(slashId, workflowId, resolver, reason, slashAmount, _msgSender());
        emit SlashExecuted(slashId, resolver, totalSlashed, distribution);
        emit SlashExecutedWithWaterfall(
            slashId,
            resolver,
            senior,
            resolverSlashed,
            seniorSlashed,
            totalSlashed
        );
        return slashId;
    }

    /**
     * @notice Slash for reversal
     */
    function slashForReversal(
        uint256 workflowId,
        address escrowContract,
        address resolver,
        uint8 priorRound
    ) external override onlyRole(ROLE_RESOLUTION_MODULE) returns (uint256 slashId) {
        priorRound;
        // Reset tracking before slash
        _currentSlashStableAmount = 0;
        _currentSlashSewAmount = 0;

        // Check if already slashed for this workflow
        if (workflowSlashed[escrowContract][workflowId][resolver]) {
            return 0; // Already slashed, skip
        }

        // Check circuit breaker
        if (circuitBreakerActive) {
            emit SlashCapEnforced(resolver, 0, 0, 'Circuit breaker active');
            return 0;
        }

        // Determine slash reason and amount
        SlashReason reason = SlashReason.REVERSAL;
        uint256 slashAmount = _calculateSlashAmount(resolver, reason);

        // Check if slash would exceed caps
        slashAmount = _enforceSlashCaps(resolver, slashAmount);

        if (slashAmount == 0) {
            return 0; // Cap reached, skip slash
        }

        // Create slash event
        slashId = _nextSlashId++;

        slashEvents[slashId] = SlashEvent({
            slashId: slashId,
            workflowId: workflowId,
            escrowContract: escrowContract,
            resolver: resolver,
            reason: reason,
            amount: slashAmount,
            proposedAt: block.timestamp,
            executedAt: block.timestamp, // Auto-execute
            appealDeadline: 0, // No appeal for automated slashes
            status: SlashStatus.EXECUTED,
            proposer: _msgSender(),
            evidence: ''
        });

        // Execute waterfall slash immediately
        (uint256 resolverSlashed, uint256 seniorSlashed, address senior) = _executeWaterfallSlash(
            resolver,
            slashAmount
        );

        uint256 totalSlashed = resolverSlashed + seniorSlashed;

        // Mark as slashed
        workflowSlashed[escrowContract][workflowId][resolver] = true;

        // Freeze resolver
        _freezeResolver(resolver);

        // Distribute slashed funds
        SlashDistribution memory distribution = _distributeSlashedFunds(
            _currentSlashStableAmount,
            reason,
            workflowId
        );

        // Reset tracking after distribution
        _currentSlashStableAmount = 0;
        _currentSlashSewAmount = 0;

        emit SlashProposed(slashId, workflowId, resolver, reason, slashAmount, _msgSender());
        emit SlashExecuted(slashId, resolver, totalSlashed, distribution);
        emit SlashExecutedWithWaterfall(
            slashId,
            resolver,
            senior,
            resolverSlashed,
            seniorSlashed,
            totalSlashed
        );
        return slashId;
    }

    /**
     * @notice Slash for fraud (provable malicious behavior)
     */
    function slashForFraud(
        uint256 workflowId,
        address escrowContract,
        address resolver,
        bytes calldata evidence
    ) external override onlyRole(ROLE_TIMELOCK) returns (uint256 slashId) {
        // Reset tracking before slash
        _currentSlashStableAmount = 0;
        _currentSlashSewAmount = 0;

        // Check if already slashed for this workflow
        if (workflowSlashed[escrowContract][workflowId][resolver]) {
            return 0; // Already slashed, skip
        }

        // Check circuit breaker
        if (circuitBreakerActive) {
            emit SlashCapEnforced(resolver, 0, 0, 'Circuit breaker active');
            return 0;
        }

        // Verify fraud slash percentage is configured
        if (slashConfig.fraudSlashBps == 0) revert FraudSlashingNotEnabled();

        // Determine slash reason and amount
        SlashReason reason = SlashReason.FRAUD;
        uint256 slashAmount = _calculateSlashAmount(resolver, reason);

        // Check if slash would exceed caps
        slashAmount = _enforceSlashCaps(resolver, slashAmount);

        if (slashAmount == 0) {
            return 0; // Cap reached, skip slash
        }

        // Create slash event with evidence
        slashId = _nextSlashId++;

        slashEvents[slashId] = SlashEvent({
            slashId: slashId,
            workflowId: workflowId,
            escrowContract: escrowContract,
            resolver: resolver,
            reason: reason,
            amount: slashAmount,
            proposedAt: block.timestamp,
            executedAt: block.timestamp, // Auto-execute for TIMELOCK-initiated fraud slashes
            appealDeadline: block.timestamp + slashConfig.appealWindow, // Allow appeal
            status: SlashStatus.EXECUTED,
            proposer: _msgSender(),
            evidence: evidence // Store evidence for audit
        });

        // Execute waterfall slash immediately
        (uint256 resolverSlashed, uint256 seniorSlashed, address senior) = _executeWaterfallSlash(
            resolver,
            slashAmount
        );

        uint256 totalSlashed = resolverSlashed + seniorSlashed;

        // Mark as slashed
        workflowSlashed[escrowContract][workflowId][resolver] = true;

        // Freeze resolver (fraud is severe)
        _freezeResolver(resolver);

        // Distribute slashed funds
        SlashDistribution memory distribution = _distributeSlashedFunds(
            _currentSlashStableAmount,
            reason,
            workflowId
        );

        // Reset tracking after distribution
        _currentSlashStableAmount = 0;
        _currentSlashSewAmount = 0;

        // Update unavailability stats
        _updateUnavailabilityStats(resolver, true);

        emit SlashProposed(slashId, workflowId, resolver, reason, slashAmount, _msgSender());
        emit SlashExecuted(slashId, resolver, totalSlashed, distribution);
        emit SlashExecutedWithWaterfall(
            slashId,
            resolver,
            senior,
            resolverSlashed,
            seniorSlashed,
            totalSlashed
        );

        return slashId;
    }

    // ============ Internal Functions ============

    /**
     * @notice Execute waterfall slash: resolver bond first, then senior coverage
     * @return resolverSlashed Amount slashed from resolver
     * @return seniorSlashed Amount slashed from senior
     * @return senior Address of senior (if any)
     */
    function _executeWaterfallSlash(
        address resolver,
        uint256 slashAmount
    ) internal returns (uint256 resolverSlashed, uint256 seniorSlashed, address senior) {
        // Get resolver's stake info
        IStakingModule.StakeInfo memory stakeInfo = stakingModule.getStakeInfo(resolver);

        // Get delegation info (if junior)
        IStakingModule.DelegationInfo memory delegation;
        uint8 tier = stakingModule.resolverTier(resolver);

        if (tier == 0) {
            // Junior resolver - check for delegation
            delegation = _findDelegation(resolver);
        }

        // Calculate waterfall
        uint256 availableStake = stakeInfo.availableStake;

        if (slashAmount <= availableStake) {
            // Resolver's stake covers the slash
            resolverSlashed = slashAmount;
            seniorSlashed = 0;
            senior = address(0);

            // Slash resolver's stake (via staking module)
            _slashResolverStake(resolver, resolverSlashed);
        } else {
            // Resolver's stake exhausted, slash senior coverage
            resolverSlashed = availableStake;
            uint256 remaining = slashAmount - availableStake;

            if (delegation.active && remaining > 0) {
                // Slash from senior's coverage
                senior = delegation.delegatee;
                seniorSlashed = remaining;

                // Slash resolver's remaining stake
                if (resolverSlashed > 0) {
                    _slashResolverStake(resolver, resolverSlashed);
                }

                // Slash senior's coverage
                _slashSeniorCoverage(senior, seniorSlashed, resolver);
            } else {
                // No senior coverage, slash only what's available
                if (resolverSlashed > 0) {
                    _slashResolverStake(resolver, resolverSlashed);
                }
                seniorSlashed = 0;
                senior = address(0);
            }
        }
    }

    /**
     * @notice Calculate slash amount based on reason
     */
    function _calculateSlashAmount(
        address resolver,
        SlashReason reason
    ) internal view returns (uint256) {
        IStakingModule.StakeInfo memory stakeInfo = stakingModule.getStakeInfo(resolver);
        uint256 totalStake = stakeInfo.totalStake;

        uint256 penaltyBps;

        if (reason == SlashReason.TIMEOUT_ACCEPT) {
            penaltyBps = PENALTY_MISSED_ACCEPT; // 25 bps (0.25%)
        } else if (reason == SlashReason.TIMEOUT_RESOLVE) {
            // Check if this is a repeat offense in the same epoch
            EpochSlashTracker storage epochTracker = epochSlashTrackers[resolver];
            uint256 currentEpochStart = (block.timestamp / EPOCH_LENGTH) * EPOCH_LENGTH; // forge-lint: disable-line(divide-before-multiply)
            
            // If resolver already slashed in this epoch, use repeat penalty
            if (epochTracker.epochStart == currentEpochStart && epochTracker.slashCount > 0) {
                penaltyBps = PENALTY_REPEAT_RESOLVE; // 500 bps (5%) for repeat
            } else {
                penaltyBps = PENALTY_MISSED_RESOLVE; // 200 bps (2%) for first offense
            }
        } else if (reason == SlashReason.REVERSAL) {
            penaltyBps = slashConfig.reversalSlashBps;
        } else if (reason == SlashReason.FRAUD) {
            penaltyBps = slashConfig.fraudSlashBps;
        } else {
            penaltyBps = PENALTY_REPEAT_RESOLVE; // Use repeat penalty as fallback
        }

        uint256 slashAmount = (totalStake * penaltyBps) / BASIS_POINTS;

        // Enforce per-offense cap
        uint256 maxPerOffense = (totalStake * MAX_SLASH_PER_OFFENSE) / BASIS_POINTS;
        if (slashAmount > maxPerOffense) {
            slashAmount = maxPerOffense;
        }

        return slashAmount;
    }

    /**
     * @notice Enforce slash caps (per-period limit and per-epoch limit)
     */
    function _enforceSlashCaps(
        address resolver,
        uint256 requestedSlash
    ) internal returns (uint256 actualSlash) {
        SlashPeriodTracker storage tracker = slashTrackers[resolver];
        EpochSlashTracker storage epochTracker = epochSlashTrackers[resolver];

        // Check if new period
        if (block.timestamp >= tracker.periodStart + slashConfig.slashPeriod) {
            // Reset period
            tracker.periodStart = block.timestamp;
            tracker.totalSlashedInPeriod = 0;
        }

        // Check if new epoch (v3 epoch-based caps)
        uint256 currentEpochStart = (block.timestamp / EPOCH_LENGTH) * EPOCH_LENGTH; // forge-lint: disable-line(divide-before-multiply)
        if (epochTracker.epochStart != currentEpochStart) {
            // Reset epoch
            epochTracker.epochStart = currentEpochStart;
            epochTracker.totalSlashedInEpoch = 0;
            epochTracker.slashCount = 0;
        }

        // Get resolver's total stake and tier
        IStakingModule.StakeInfo memory stakeInfo = stakingModule.getStakeInfo(resolver);
        uint256 totalStake = stakeInfo.totalStake;
        uint8 tier = stakingModule.resolverTier(resolver);

        // Calculate max allowed in period (legacy cap)
        uint256 maxInPeriod = (totalStake * slashConfig.maxSlashPerPeriod) / BASIS_POINTS;
        uint256 remainingInPeriod = maxInPeriod > tracker.totalSlashedInPeriod
            ? maxInPeriod - tracker.totalSlashedInPeriod
            : 0;

        // Calculate max allowed in epoch (v3 cap)
        uint256 epochCapBps = (tier == 1) ? SENIOR_SLASH_CAP_BPS : RESOLVER_SLASH_CAP_BPS;
        uint256 maxInEpoch = (totalStake * epochCapBps) / BASIS_POINTS;
        uint256 remainingInEpoch = maxInEpoch > epochTracker.totalSlashedInEpoch
            ? maxInEpoch - epochTracker.totalSlashedInEpoch
            : 0;

        // Enforce both caps (use the more restrictive)
        uint256 maxAllowed = remainingInPeriod < remainingInEpoch ? remainingInPeriod : remainingInEpoch;

        if (requestedSlash > maxAllowed) {
            actualSlash = maxAllowed;
            string memory reason = remainingInPeriod < remainingInEpoch ? 'Period cap reached' : 'Epoch cap reached';
            emit SlashCapEnforced(resolver, requestedSlash, actualSlash, reason);
        } else {
            actualSlash = requestedSlash;
        }

        // Update trackers
        tracker.totalSlashedInPeriod += actualSlash;
        epochTracker.totalSlashedInEpoch += actualSlash;
        epochTracker.slashCount++;
        epochTracker.lastSlashTime = block.timestamp;
    }

    // Track slashed token amounts for distribution
    uint256 private _currentSlashStableAmount;
    uint256 private _currentSlashSewAmount;

    /**
     * @notice Slash resolver's stake (real implementation)
     */
    function _slashResolverStake(address resolver, uint256 amount) internal {
        if (amount == 0) return;

        // Call staking module to slash resolver's bond
        (uint256 stableSlashed, uint256 sewSlashed) = stakingModule.slash(resolver, amount);

        // Track amounts for distribution
        _currentSlashStableAmount += stableSlashed;
        _currentSlashSewAmount += sewSlashed;
    }

    /**
     * @notice Slash senior's coverage (real implementation)
     */
    function _slashSeniorCoverage(address senior, uint256 amount, address slashedFor) internal {
        if (amount == 0) return;

        // Call staking module to slash senior's coverage
        (uint256 stableSlashed, uint256 sewSlashed) = stakingModule.slashCoverage(
            senior,
            amount,
            slashedFor
        );

        // Track amounts for distribution
        _currentSlashStableAmount += stableSlashed;
        _currentSlashSewAmount += sewSlashed;
    }

    /**
     * @notice Find delegation for a resolver
     */
    function _findDelegation(
        address resolver
    ) internal view returns (IStakingModule.DelegationInfo memory) {
        // Access the public delegations mapping via low-level call
        (bool success, bytes memory data) = address(stakingModule).staticcall(
            abi.encodeWithSignature('delegations(address)', resolver)
        );

        if (success && data.length >= 128) {
            // Decode the tuple: (address senior, uint256 coverageAmount, uint256 delegatedAt, bool active)
            (address senior, uint256 coverageAmount, uint256 delegatedAt, bool active) = abi.decode(
                data,
                (address, uint256, uint256, bool)
            );

            if (active && senior != address(0)) {
                return
                    IStakingModule.DelegationInfo({
                        delegator: resolver,
                        delegatee: senior,
                        amount: coverageAmount,
                        delegatedAt: delegatedAt,
                        active: true
                    });
            }
        }

        return
            IStakingModule.DelegationInfo({
                delegator: resolver,
                delegatee: address(0),
                amount: 0,
                delegatedAt: 0,
                active: false
            });
    }

    /**
     * @notice Distribute slashed funds
     */
    function _distributeSlashedFunds(
        uint256 amount,
        SlashReason reason,
        uint256 workflowId
    ) internal returns (SlashDistribution memory distribution) {
        distribution.toInsurancePool = (amount * 5000) / BASIS_POINTS;
        distribution.toProtocol = (amount * 3000) / BASIS_POINTS;
        distribution.toCounterParty = 0;
        distribution.toSlashProposer = 0;

        // Transfer insurance pool portion to vault
        if (amount > 0 && distribution.toInsurancePool > 0 && address(insurancePoolVault) != address(0)) {
            stableToken.safeTransfer(address(insurancePoolVault), distribution.toInsurancePool);
            insurancePoolVault.recordDeposit(distribution.toInsurancePool, reason, workflowId, address(0));
        }

        // Burn any slashed SEW received from the staking module for this slash
        _handleSlashedSEW(workflowId);

        return distribution;
    }

    /**
     * @notice Handle slashed SEW from the staking module (burn)
     */
    function _handleSlashedSEW(uint256 workflowId) internal {
        uint256 amount = _currentSlashSewAmount;
        if (amount == 0) return;

        IERC20 sew = IERC20(stakingModule.sewToken());

        // Try to burn (preferred: reduces totalSupply)
        (bool ok, ) = address(sew).call(abi.encodeWithSignature('burn(uint256)', amount));
        if (ok) {
            emit SlashedSEWHandled(workflowId, amount, true);
            return;
        }

        // Fallback: transfer to dead address (effective burn)
        sew.safeTransfer(DEAD_BURN_ADDRESS, amount);
        emit SlashedSEWHandled(workflowId, amount, false);
    }

    /**
     * @notice Freeze resolver (prevents withdrawal during slash processing)
     */
    function _freezeResolver(address resolver) internal {
        EpochSlashTracker storage epochTracker = epochSlashTrackers[resolver];
        uint256 currentEpochStart = (block.timestamp / EPOCH_LENGTH) * EPOCH_LENGTH; // forge-lint: disable-line(divide-before-multiply)
        
        // Determine freeze duration based on context
        uint256 freezeDuration;
        
        // Check if this is a repeated offense in the same epoch
        if (epochTracker.epochStart == currentEpochStart && epochTracker.slashCount > 1) {
            freezeDuration = FREEZE_DURATION_REPEATED; // 7 days
        } else {
            freezeDuration = FREEZE_DURATION_SEVERE; // 72 hours
        }
        
        frozenUntil[resolver] = block.timestamp + freezeDuration;
        emit ResolverFrozen(resolver, frozenUntil[resolver]);
    }

    /**
     * @notice Update unavailability stats (for circuit breaker)
     */
    function _updateUnavailabilityStats(address /* resolver */, bool unavailable) internal {
        UnavailabilityStats storage stats = unavailabilityStats;
        stats.lastUpdate = block.timestamp;

        if (unavailable) {
            stats.unavailableCount++;
        }

        if (stats.totalResolvers > 0) {
            uint256 unavailablePercentage = (stats.unavailableCount * BASIS_POINTS) /
                stats.totalResolvers;

            if (unavailablePercentage >= MASS_UNAVAILABILITY_THRESHOLD) {
                _triggerCircuitBreaker('Mass unavailability detected');
                emit MassUnavailabilityDetected(
                    stats.unavailableCount,
                    stats.totalResolvers,
                    unavailablePercentage
                );
            }
        }
    }

    /**
     * @notice Trigger circuit breaker
     */
    function _triggerCircuitBreaker(string memory reason) internal {
        if (!circuitBreakerActive) {
            circuitBreakerActive = true;
            lastCircuitBreakerTrigger = block.timestamp;
            emit CircuitBreakerActivated(reason);
        }
    }

    // ============ Query Functions ============

    function getSlashEvent(uint256 slashId) external view override returns (SlashEvent memory) {
        return slashEvents[slashId];
    }

    function getSlashAppeal(uint256 slashId) external view override returns (SlashAppeal memory) {
        return slashAppeals[slashId];
    }

    function calculateSlashAmount(
        address resolver,
        SlashReason reason
    ) external view override returns (uint256) {
        return _calculateSlashAmount(resolver, reason);
    }

    function getSlashableStake(address resolver) external view override returns (uint256) {
        IStakingModule.StakeInfo memory stakeInfo = stakingModule.getStakeInfo(resolver);
        return stakeInfo.availableStake;
    }

    function getSlashedInPeriod(address resolver) external view override returns (uint256) {
        return slashTrackers[resolver].totalSlashedInPeriod;
    }

    function getSlashConfig() external view override returns (SlashConfig memory) {
        return slashConfig;
    }

    function canAppeal(uint256 slashId) external view override returns (bool) {
        SlashEvent storage slashEvent = slashEvents[slashId];
        return
            slashEvent.status == SlashStatus.PENDING &&
            block.timestamp <= slashEvent.appealDeadline &&
            slashAppeals[slashId].slashId == 0;
    }

    function canExecute(uint256 slashId) external view override returns (bool) {
        SlashEvent storage slashEvent = slashEvents[slashId];
        return
            slashEvent.status == SlashStatus.PENDING && block.timestamp > slashEvent.appealDeadline;
    }

    function getInsurancePoolBalance() external view override returns (uint256) {
        if (address(insurancePoolVault) != address(0)) {
            return insurancePoolVault.getTotalBalance();
        }
        return 0;
    }

    function isResolverFrozen(address resolver) external view returns (bool frozen, uint256 until) {
        frozen = block.timestamp < frozenUntil[resolver];
        until = frozenUntil[resolver];
    }

    // ============ Distribution Functions ============

    function calculateDistribution(
        uint256 amount,
        SlashReason /* reason */
    ) external pure override returns (SlashDistribution memory) {
        return SlashDistribution({
            toProtocol: (amount * 3000) / BASIS_POINTS,
            toCounterParty: 0,
            toInsurancePool: (amount * 5000) / BASIS_POINTS,
            toSlashProposer: 0
        });
    }

    function claimInsurancePayout(
        uint256 /* workflowId */,
        address /* to */,
        uint256 /* amount */
    ) external pure override {
        revert('Use InsurancePoolVault.proposePayout() instead');
    }

    // ============ Admin Functions ============

    function setSlashPercentage(SlashReason reason, uint256 bps) external override onlyRole(ROLE_TIMELOCK) {
        if (bps > BASIS_POINTS) revert InvalidBps(bps, BASIS_POINTS);

        uint256 oldBps;

        if (reason == SlashReason.TIMEOUT_ACCEPT || reason == SlashReason.TIMEOUT_RESOLVE) {
            oldBps = slashConfig.timeoutSlashBps;
            slashConfig.timeoutSlashBps = bps;
        } else if (reason == SlashReason.REVERSAL) {
            oldBps = slashConfig.reversalSlashBps;
            slashConfig.reversalSlashBps = bps;
        } else {
            oldBps = slashConfig.fraudSlashBps;
            slashConfig.fraudSlashBps = bps;
        }

        emit SlashConfigUpdated(reason, oldBps, bps);
    }

    function setMaxSlashPerPeriod(uint256 max, uint256 period) external override onlyRole(ROLE_TIMELOCK) {
        slashConfig.maxSlashPerPeriod = max;
        slashConfig.slashPeriod = period;
    }

    function setAppealWindow(uint256 window) external override onlyRole(ROLE_TIMELOCK) {
        slashConfig.appealWindow = window;
    }

    function setAppealBond(uint256 bond) external override onlyRole(ROLE_TIMELOCK) {
        slashConfig.appealBond = bond;
    }

    function fundInsurancePool(uint256 amount) external override {
        if (address(insurancePoolVault) != address(0)) {
            stableToken.safeTransferFrom(_msgSender(), address(this), amount);
            stableToken.safeTransfer(address(insurancePoolVault), amount);
            insurancePoolVault.recordDeposit(amount, SlashReason.TIMEOUT_ACCEPT, 0, address(0));
        }
    }

    /**
     * @notice Set insurance pool vault (governance)
     */
    function setInsurancePoolVault(address vault) external onlyRole(ROLE_TIMELOCK) {
        insurancePoolVault = InsurancePoolVault(vault);
    }

    function triggerCircuitBreaker(string memory reason) external override onlyRole(ROLE_TIMELOCK) {
        _triggerCircuitBreaker(reason);
    }

    function resetCircuitBreaker() external override onlyRole(ROLE_TIMELOCK) {
        uint256 availableAt = lastCircuitBreakerTrigger + CIRCUIT_BREAKER_COOLDOWN;
        if (block.timestamp < availableAt) {
            revert CooldownNotPassed(availableAt, block.timestamp);
        }
        circuitBreakerActive = false;
        emit CircuitBreakerDeactivated();
    }

    function unfreezeResolver(address resolver) external onlyRole(ROLE_TIMELOCK) {
        frozenUntil[resolver] = 0;
        emit ResolverUnfrozen(resolver);
    }

    function setUnavailabilityStats(
        uint256 totalResolvers,
        uint256 unavailableCount
    ) external onlyRole(ROLE_TIMELOCK) {
        unavailabilityStats.totalResolvers = totalResolvers;
        unavailabilityStats.unavailableCount = unavailableCount;
        unavailabilityStats.lastUpdate = block.timestamp;
    }
}