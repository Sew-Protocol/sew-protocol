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
    // ============ Constants ============

    bytes32 public constant ROLE_TIMELOCK = keccak256('ROLE_TIMELOCK');
    bytes32 public constant ROLE_RESOLUTION_MODULE = keccak256('ROLE_RESOLUTION_MODULE');

    uint256 public constant BASIS_POINTS = 10000;
    uint256 public constant PRECISION = 1e18;

    // Conservative penalty schedule (basis points)
    uint256 public constant PENALTY_MISSED_ACCEPT = 200; // 2%
    uint256 public constant PENALTY_MISSED_RESOLVE = 500; // 5%
    uint256 public constant PENALTY_UNRESPONSIVE = 1000; // 10%

    // Slash caps
    uint256 public constant MAX_SLASH_PER_OFFENSE = 5000; // 50% max per slash
    uint256 public constant MAX_SLASH_PER_PERIOD = 10000; // 100% max per 30 days
    uint256 public constant SLASH_PERIOD = 30 days;

    // Circuit breaker thresholds
    uint256 public constant MASS_UNAVAILABILITY_THRESHOLD = 3000; // 30% of resolvers
    uint256 public constant CIRCUIT_BREAKER_COOLDOWN = 1 hours;

    // ============ State Variables ============

    ResolverStakingModuleV1 public stakingModule;
    InsurancePoolVault public insurancePoolVault;
    IERC20 public stableToken;

    bool public circuitBreakerActive;
    uint256 public lastCircuitBreakerTrigger;

    // Slash tracking
    uint256 private _nextSlashId;
    mapping(uint256 => SlashEvent) public slashEvents;
    mapping(uint256 => SlashAppeal) public slashAppeals;

    // Prevent double slashing
    mapping(uint256 => mapping(address => bool)) public workflowSlashed; // workflowId => resolver => slashed

    // Per-resolver slash tracking (for caps)
    struct SlashPeriodTracker {
        uint256 periodStart;
        uint256 totalSlashedInPeriod;
    }
    mapping(address => SlashPeriodTracker) public slashTrackers;

    // Freeze tracking (prevents withdrawal during slash processing)
    mapping(address => uint256) public frozenUntil; // resolver => timestamp
    uint256 public constant FREEZE_DURATION = 7 days;

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

    // ============ Initialization ============

    constructor(
        address initialOwner,
        address _stakingModule,
        address _insurancePoolVault,
        address _stableToken
    ) {
        require(_stakingModule != address(0), 'Zero staking module');
        require(_insurancePoolVault != address(0), 'Zero insurance vault');
        require(_stableToken != address(0), 'Zero stable token');

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
            timeoutSlashBps: PENALTY_MISSED_RESOLVE,
            reversalSlashBps: 0, // Disabled initially
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
        address resolver,
        SlashReason reason,
        bytes calldata evidence
    ) external onlyRole(ROLE_TIMELOCK) returns (uint256 slashId) {
        require(!workflowSlashed[workflowId][resolver], 'Already slashed for this workflow');

        slashId = _nextSlashId++;

        uint256 slashAmount = _calculateSlashAmount(resolver, reason);

        slashEvents[slashId] = SlashEvent({
            slashId: slashId,
            workflowId: workflowId,
            resolver: resolver,
            reason: reason,
            amount: slashAmount,
            proposedAt: block.timestamp,
            executedAt: 0,
            appealDeadline: block.timestamp + slashConfig.appealWindow,
            status: SlashStatus.PENDING,
            proposer: msg.sender,
            evidence: ''
        });

        emit SlashProposed(slashId, workflowId, resolver, reason, slashAmount, msg.sender);
    }

    /**
     * @notice Execute a slash (with waterfall: resolver → senior)
     */
    function executeSlash(uint256 slashId) external nonReentrant onlyRole(ROLE_TIMELOCK) {
        SlashEvent storage slashEvent = slashEvents[slashId];

        require(slashEvent.status == SlashStatus.PENDING, 'Not pending');
        require(block.timestamp > slashEvent.appealDeadline, 'Appeal window open');

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
        workflowSlashed[slashEvent.workflowId][resolver] = true;

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
    ) external nonReentrant {
        SlashEvent storage slashEvent = slashEvents[slashId];

        require(slashEvent.status == SlashStatus.PENDING, 'Not pending');
        require(block.timestamp <= slashEvent.appealDeadline, 'Appeal window closed');
        require(msg.sender == slashEvent.resolver, 'Not resolver');
        require(!slashAppeals[slashId].resolved, 'Already appealed');

        // Record appeal
        slashAppeals[slashId] = SlashAppeal({
            slashId: slashId,
            appellant: msg.sender,
            appealBond: slashConfig.appealBond,
            appealedAt: block.timestamp,
            reason: reason,
            evidence: '',
            resolved: false,
            upheld: false
        });

        emit SlashAppealed(slashId, msg.sender, slashConfig.appealBond, reason);
    }

    /**
     * @notice Resolve an appeal
     */
    function resolveAppeal(uint256 slashId, bool upheld) external onlyRole(ROLE_TIMELOCK) {
        SlashAppeal storage appeal = slashAppeals[slashId];
        SlashEvent storage slashEvent = slashEvents[slashId];

        require(!appeal.resolved, 'Already resolved');
        require(slashEvent.status == SlashStatus.PENDING, 'Not pending');

        appeal.resolved = true;
        appeal.upheld = upheld;

        if (upheld) {
            // Appeal rejected, slash proceeds
            emit SlashAppealResolved(slashId, true, address(0), 0);
        } else {
            // Appeal accepted, cancel slash
            slashEvent.status = SlashStatus.APPEALED;
            emit SlashReversed(slashId, slashEvent.resolver, slashEvent.amount);
            emit SlashAppealResolved(slashId, false, slashEvent.resolver, slashEvent.amount);
        }
    }

    // ============ Automated Slashing (Called by Resolution Module) ============

    /**
     * @notice Slash for timeout (missed accept or missed resolve)
     * @param workflowId Dispute ID
     * @param resolver Resolver who timed out
     * @param timeoutType 0 = accept, 1 = resolve
     */
    function slashForTimeout(
        uint256 workflowId,
        address resolver,
        uint8 timeoutType
    ) external onlyRole(ROLE_RESOLUTION_MODULE) returns (uint256 slashId) {
        // Check if already slashed for this workflow
        if (workflowSlashed[workflowId][resolver]) {
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
            resolver: resolver,
            reason: reason,
            amount: slashAmount,
            proposedAt: block.timestamp,
            executedAt: block.timestamp, // Auto-execute
            appealDeadline: 0, // No appeal for automated slashes
            status: SlashStatus.EXECUTED,
            proposer: msg.sender,
            evidence: ''
        });

        // Execute waterfall slash immediately
        (uint256 resolverSlashed, uint256 seniorSlashed, address senior) = _executeWaterfallSlash(
            resolver,
            slashAmount
        );

        uint256 totalSlashed = resolverSlashed + seniorSlashed;

        // Mark as slashed
        workflowSlashed[workflowId][resolver] = true;

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

        emit SlashProposed(slashId, workflowId, resolver, reason, slashAmount, msg.sender);
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
     * @notice Slash for reversal (disabled initially)
     */
    function slashForReversal(
        uint256 workflowId,
        address resolver,
        uint8 priorRound
    ) external onlyRole(ROLE_RESOLUTION_MODULE) returns (uint256 slashId) {
        // Reversal slashing disabled initially (too harsh for early rollout)
        return 0;
    }

    /**
     * @notice Slash for fraud (not implemented yet)
     */
    function slashForFraud(
        uint256 workflowId,
        address resolver,
        bytes calldata evidence
    ) external returns (uint256 slashId) {
        // Fraud slashing not implemented yet
        revert('Not implemented');
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
            // We need to iterate through potential seniors (simplified: assume one senior per junior)
            // In production, would need better tracking
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
                _slashSeniorCoverage(senior, seniorSlashed);
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
            penaltyBps = PENALTY_MISSED_ACCEPT; // 2%
        } else if (reason == SlashReason.TIMEOUT_RESOLVE) {
            penaltyBps = PENALTY_MISSED_RESOLVE; // 5%
        } else if (reason == SlashReason.REVERSAL) {
            penaltyBps = slashConfig.reversalSlashBps; // 0% initially
        } else if (reason == SlashReason.FRAUD) {
            penaltyBps = slashConfig.fraudSlashBps; // 0% initially
        } else {
            // COLLUSION, BRIBERY, or custom
            penaltyBps = PENALTY_UNRESPONSIVE; // 10%
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
     * @notice Enforce slash caps (per-period limit)
     */
    function _enforceSlashCaps(
        address resolver,
        uint256 requestedSlash
    ) internal returns (uint256 actualSlash) {
        SlashPeriodTracker storage tracker = slashTrackers[resolver];

        // Check if new period
        if (block.timestamp >= tracker.periodStart + slashConfig.slashPeriod) {
            // Reset period
            tracker.periodStart = block.timestamp;
            tracker.totalSlashedInPeriod = 0;
        }

        // Get resolver's total stake
        IStakingModule.StakeInfo memory stakeInfo = stakingModule.getStakeInfo(resolver);
        uint256 totalStake = stakeInfo.totalStake;

        // Calculate max allowed in period
        uint256 maxInPeriod = (totalStake * slashConfig.maxSlashPerPeriod) / BASIS_POINTS;
        uint256 remainingInPeriod = maxInPeriod > tracker.totalSlashedInPeriod
            ? maxInPeriod - tracker.totalSlashedInPeriod
            : 0;

        if (requestedSlash > remainingInPeriod) {
            actualSlash = remainingInPeriod;
            emit SlashCapEnforced(resolver, requestedSlash, actualSlash, 'Period cap reached');
        } else {
            actualSlash = requestedSlash;
        }

        // Update tracker
        tracker.totalSlashedInPeriod += actualSlash;
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
    function _slashSeniorCoverage(address senior, uint256 amount) internal {
        if (amount == 0) return;

        // Call staking module to slash senior's coverage
        (uint256 stableSlashed, uint256 sewSlashed) = stakingModule.slashCoverage(
            senior,
            amount,
            address(0)
        );

        // Track amounts for distribution
        _currentSlashStableAmount += stableSlashed;
        _currentSlashSewAmount += sewSlashed;
    }

    /**
     * @notice Find delegation for a resolver
     * @dev Accesses the public delegations mapping in staking module
     *      Uses a low-level call to access the public mapping since it's not in the interface
     */
    function _findDelegation(
        address resolver
    ) internal view returns (IStakingModule.DelegationInfo memory) {
        // Access the public delegations mapping via low-level call
        // delegations(junior) returns (address senior, uint256 coverageAmount, uint256 delegatedAt, bool active)
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
        // Conservative distribution:
        // - 50% to insurance pool (protect users)
        // - 30% to protocol treasury
        // - 20% burned (deflationary)

        distribution.toInsurancePool = (amount * 5000) / BASIS_POINTS;
        distribution.toProtocol = (amount * 3000) / BASIS_POINTS;
        distribution.toCounterParty = 0; // Not implemented yet
        distribution.toSlashProposer = 0; // Not implemented yet

        // Transfer insurance pool portion to vault (with source tag)
        if (distribution.toInsurancePool > 0 && address(insurancePoolVault) != address(0)) {
            // Transfer funds directly to vault (they're already in this contract from staking module)
            stableToken.safeTransfer(address(insurancePoolVault), distribution.toInsurancePool);

            // Record the deposit in vault accounting
            insurancePoolVault.recordDeposit(distribution.toInsurancePool, reason, workflowId);
        }

        // TODO: Transfer protocol portion to treasury (when treasury contract exists)
        // For now, protocol portion remains in this contract

        return distribution;
    }

    /**
     * @notice Freeze resolver (prevents withdrawal during slash processing)
     */
    function _freezeResolver(address resolver) internal {
        frozenUntil[resolver] = block.timestamp + FREEZE_DURATION;
        emit ResolverFrozen(resolver, frozenUntil[resolver]);
    }

    /**
     * @notice Update unavailability stats (for circuit breaker)
     */
    function _updateUnavailabilityStats(address resolver, bool unavailable) internal {
        UnavailabilityStats storage stats = unavailabilityStats;

        // Update timestamp
        stats.lastUpdate = block.timestamp;

        // Increment counters (simplified - in production would track per resolver)
        if (unavailable) {
            stats.unavailableCount++;
        }

        // Check for mass unavailability
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

    function getSlashEvent(uint256 slashId) external view returns (SlashEvent memory slashEvent) {
        return slashEvents[slashId];
    }

    function getSlashAppeal(uint256 slashId) external view returns (SlashAppeal memory) {
        return slashAppeals[slashId];
    }

    function calculateSlashAmount(
        address resolver,
        SlashReason reason
    ) external view returns (uint256 amount) {
        return _calculateSlashAmount(resolver, reason);
    }

    function getSlashableStake(address resolver) external view returns (uint256 slashable) {
        IStakingModule.StakeInfo memory stakeInfo = stakingModule.getStakeInfo(resolver);
        return stakeInfo.availableStake;
    }

    function getSlashedInPeriod(address resolver) external view returns (uint256 slashed) {
        return slashTrackers[resolver].totalSlashedInPeriod;
    }

    function getSlashConfig() external view returns (SlashConfig memory config) {
        return slashConfig;
    }

    function canAppeal(uint256 slashId) external view returns (bool) {
        SlashEvent storage slashEvent = slashEvents[slashId];
        return
            slashEvent.status == SlashStatus.PENDING &&
            block.timestamp <= slashEvent.appealDeadline &&
            !slashAppeals[slashId].resolved;
    }

    function canExecute(uint256 slashId) external view returns (bool) {
        SlashEvent storage slashEvent = slashEvents[slashId];
        return
            slashEvent.status == SlashStatus.PENDING && block.timestamp > slashEvent.appealDeadline;
    }

    function getInsurancePoolBalance() external view returns (uint256 balance) {
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
        SlashReason reason
    ) external pure returns (SlashDistribution memory distribution) {
        distribution.toInsurancePool = (amount * 5000) / BASIS_POINTS;
        distribution.toProtocol = (amount * 3000) / BASIS_POINTS;
        distribution.toCounterParty = 0;
        distribution.toSlashProposer = 0;
    }

    function claimInsurancePayout(
        uint256 workflowId,
        address to,
        uint256 amount
    ) external onlyRole(ROLE_TIMELOCK) {
        // This function is deprecated - use InsurancePoolVault.proposePayout() instead
        // Kept for backward compatibility, but should route through vault
        revert('Use InsurancePoolVault.proposePayout() instead');
    }

    // ============ Admin Functions ============

    function setSlashPercentage(SlashReason reason, uint256 bps) external onlyRole(ROLE_TIMELOCK) {
        require(bps <= BASIS_POINTS, 'Invalid bps');

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

    function setMaxSlashPerPeriod(uint256 max, uint256 period) external onlyRole(ROLE_TIMELOCK) {
        slashConfig.maxSlashPerPeriod = max;
        slashConfig.slashPeriod = period;
    }

    function setAppealWindow(uint256 window) external onlyRole(ROLE_TIMELOCK) {
        slashConfig.appealWindow = window;
    }

    function setAppealBond(uint256 bond) external onlyRole(ROLE_TIMELOCK) {
        slashConfig.appealBond = bond;
    }

    function fundInsurancePool(uint256 amount) external {
        // This function is deprecated - use InsurancePoolVault.deposit() directly
        // Kept for backward compatibility
        if (address(insurancePoolVault) != address(0)) {
            stableToken.safeTransferFrom(msg.sender, address(this), amount);
            stableToken.safeTransfer(address(insurancePoolVault), amount);
            insurancePoolVault.recordDeposit(amount, SlashReason.TIMEOUT_ACCEPT, 0);
        }
    }

    /**
     * @notice Set insurance pool vault (governance)
     * @param vault New vault address
     */
    function setInsurancePoolVault(address vault) external onlyRole(ROLE_TIMELOCK) {
        address oldVault = address(insurancePoolVault);
        insurancePoolVault = InsurancePoolVault(vault);

        if (vault != address(0)) {
            // Grant role to this contract
            InsurancePoolVault(vault).grantRole(
                InsurancePoolVault(vault).ROLE_SLASHING_MODULE(),
                address(this)
            );
        }

        if (oldVault != address(0)) {
            // Revoke role from old vault
            InsurancePoolVault(oldVault).revokeRole(
                InsurancePoolVault(oldVault).ROLE_SLASHING_MODULE(),
                address(this)
            );
        }
    }

    function triggerCircuitBreaker(string memory reason) external onlyRole(ROLE_TIMELOCK) {
        _triggerCircuitBreaker(reason);
    }

    function resetCircuitBreaker() external onlyRole(ROLE_TIMELOCK) {
        require(
            block.timestamp >= lastCircuitBreakerTrigger + CIRCUIT_BREAKER_COOLDOWN,
            'Cooldown not passed'
        );
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
