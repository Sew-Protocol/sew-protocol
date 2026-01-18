// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import '../shared/interfaces/IResolutionModule.sol';
import '@openzeppelin/contracts/access/AccessControl.sol';
import '@openzeppelin/contracts/utils/ReentrancyGuard.sol';
import '../governance/SlowLaneQueueActivate.sol';
import './IIncentiveModule.sol';
import './IStakingModule.sol';
import './ISlashingModule.sol';
import './DecentralizedResolverStructs.sol';
import './ResolutionAnalytics.sol';
import './EscalationCostLibrary.sol';
import '../libraries/ResolutionTableLibrary.sol';

/**
 * @title DecentralizedResolutionModule
 * @notice Optimized decentralized resolution module with externalized analytics and table logic
 * @dev Staged Rollout Plan (see docs/dispute-resolution/DR_STAGING_PLAN.md):
 *      - DR v1: Decentralise decisions (workload routing, no resolver capital at risk)
 *      - DR v2: Decentralise incentives (user appeal bonds, cost curves, no resolver staking)
 *      - DR v3: Decentralise capital (resolver bonds, slashing, senior backing, fraud lane)
 * @dev DR v3 interfaces (IStakingModule, ISlashingModule, IFraudProofModule) are placeholders.
 *      Not implemented until v1/v2 phase gates are met. Implementation guarded behind module swap.
 */
contract DecentralizedResolutionModule is
    SlowLaneQueueActivate,
    AccessControl,
    ReentrancyGuard,
    IResolutionModule,
    DecentralizedResolverStructs
{
    using ResolutionAnalytics for mapping(address => ResolverStats);
    using ResolutionTableLibrary for bytes;
    using EscalationCostLibrary for EscalationCostConfig;

    // Custom errors
    error InvalidDisputeTimeout(uint256 timeout, uint256 minTimeout, uint256 maxTimeout);
    error NotSeniorResolver(address caller);
    error NotRegisteredEscrowContract(address caller);
    error InvalidLevel(uint8 level, uint8 maxLevel);
    error AlreadyInitialized(uint256 workflowId);
    error ResolverInactive(address resolver);
    error ResolverNotAcceptingDisputes(address resolver);
    error WeightExceedsMaximum(uint256 weight, uint256 maxWeight);
    error ZeroAddress(string field);
    error InvalidAlpha(uint256 alphaBps, uint256 maxAlpha);
    error InvalidThreshold(uint256 threshold, uint256 maxThreshold);
    error InvalidTimeoutRate(uint256 rate, uint256 maxRate);
    error InvalidRound(uint8 priorRound, uint8 currentRound);
    error NoPriorDecision(uint8 round);
    error AlreadyFinalized(uint256 workflowId);
    error NoDecision(uint256 workflowId, uint8 round);
    error CannotFinalizeYet(uint256 workflowId, string reason);
    error InvalidBaseCost(uint256 baseCost, bool enabled);
    error InvalidBondToken(address token);
    error TokenAlreadyInWhitelist(address token);
    error CannotRemoveDefaultToken(address token);
    error TokenNotInWhitelist(address token);
    error NoPendingBondTokenChange();
    error TimelockNotElapsed(uint64 eta, uint256 currentTime);
    error AlreadyPaused();
    error NotPaused();
    error NotAuthorized(address caller);
    error ResolverCapacityExceeded(address resolver, uint256 currentDisputes, uint256 maxDisputes);
    error NotAuthorizedResolver(address caller);
    error InvalidResolver(address resolver);
    error InvalidSeniorResolver(address resolver);
    error CannotRemoveResolver(address resolver, uint256 activeDisputes);
    error Unauthorized(address caller);

    bytes32 public constant ROLE_TIMELOCK = keccak256('ROLE_TIMELOCK');
    bytes32 public constant ROLE_GUARDIAN = keccak256('ROLE_GUARDIAN');
    uint8 public constant MAX_ROUND = 2; // 0=resolver, 1=senior, 2=external (Kleros)
    uint256 public constant BASIS_POINTS_DENOMINATOR = 10000;
    uint256 public constant DEFAULT_DISPUTE_TIMEOUT = 7 days;
    uint256 public constant MAX_DISPUTE_TIMEOUT = 365 days;

    // DR v1: EMA parameters (governance-controlled)
    uint256 public emaAlphaBps = 1000; // 10% EMA step (alphaBps / 10000)
    uint256 public minEmaScoreThreshold = 500000; // 50% minimum score to receive work
    uint256 public maxTimeoutRateBps = 3000; // 30% maximum timeout rate

    // DR v1: Timeout durations per round
    // v3 objective slashing schedule:
    // - t_accept: 30 minutes (used for accept deadline check)
    // - t_resolve_L0: 24 hours (resolver round)
    // - t_resolve_L1: 48 hours (senior round)
    uint256 public constant ACCEPT_DEADLINE = 30 minutes; // Time to accept assignment
    uint256[3] public resolveDeadlines = [24 hours, 48 hours, 7 days]; // Time to resolve per round (L0, L1, L2)
    uint256[3] public appealWindows = [2 days, 3 days, 0]; // Time to appeal after decision

    // DR v2: Appeal bond configuration
    struct PendingEscalationCostConfig {
        EscalationCostConfig config;
        uint64 eta;
        bool exists;
    }

    EscalationCostConfig public escalationCostConfig;
    PendingEscalationCostConfig private _pendingEscalationCostConfig;
    uint256 public minEscrowValueForEscalation; // Minimum escrow value to allow escalation (anti-griefing)

    // DR v2: Appeal bond token whitelist
    mapping(address => bool) public acceptedBondTokens;
    address[] public acceptedBondTokensList;
    address public defaultBondToken;

    struct PendingBondTokenChange {
        address token;
        bool isAdd; // true = add, false = remove
        uint64 eta;
        bool exists;
    }
    PendingBondTokenChange private _pendingBondTokenChange;

    struct PendingDefaultBondToken {
        address token;
        uint64 eta;
        bool exists;
    }
    PendingDefaultBondToken private _pendingDefaultBondToken;

    mapping(address => ResolverRole) public resolverRoles;
    mapping(address => bool) public isApprovedResolver;
    mapping(address => bool) public isApprovedSeniorResolver;
    address[] public approvedResolvers;
    address[] public approvedSeniorResolvers;

    mapping(address => ResolverMetadata) public resolverMetadata;
    mapping(uint256 => DisputeMetadata) public disputeMetadata;
    uint256 public disputeTimeout = DEFAULT_DISPUTE_TIMEOUT;
    mapping(uint8 => EscalationConfig) public escalationConfig;
    mapping(uint8 => PendingEscalationConfig) private _pendingEscalationConfig;

    mapping(bytes32 => ResolutionTableEntry) public resolutionTable;
    mapping(uint256 => bytes32) public escrowCategory;
    mapping(bytes32 => uint256) public categoryResolverIndex;
    mapping(bytes32 => uint256) public categorySeniorResolverIndex;

    mapping(address => bool) public resolverActive;
    mapping(address => uint256) public resolverLastActive;
    mapping(address => uint256) public resolverActiveDisputes;
    mapping(address => ResolverCapacity) public resolverCapacity;
    mapping(address => ResolverStats) public resolverStats;
    mapping(address => uint256) public resolverIndex;
    mapping(address => uint256) public seniorResolverIndex;

    address public externalResolver;
    mapping(address => bool) public registeredEscrowContracts;
    IIncentiveModule public incentiveModule; // Swappable incentive module (v1/v2/v3)

    // DR v3 Phase 5: Emergency controls
    bool public newAssignmentsPaused; // Emergency toggle to freeze all new assignments

    // DR v3: Module configuration structs
    struct PendingModuleConfig {
        address module;
        uint64 eta;
        bool exists;
    }

    // DR v3 modules (swappable implementations, can be address(0) for backward compatibility)
    IStakingModule public stakingModule; // DR v3 - resolver staking
    ISlashingModule public slashingModule; // DR v3 - resolver slashing
    // IFraudProofModule public fraudProofModule; // DR v3 - fraud lane (future)

    PendingModuleConfig private _pendingStakingModule;
    PendingModuleConfig private _pendingSlashingModule;

    event ResolverAppointed(
        address indexed resolver,
        ResolverRole role,
        address indexed appointedBy
    );
    event ResolverRemoved(address indexed resolver, address indexed removedBy);
    event ResolverMetadataUpdated(address indexed resolver, ResolverMetadata metadata);
    event DisputeEscalatedToRound(
        uint256 indexed workflowId,
        uint8 fromRound,
        uint8 toRound,
        address indexed newResolver
    );
    event DecisionSubmitted(
        uint256 indexed workflowId,
        uint8 round,
        address indexed resolver,
        ResolutionOutcome decision
    );
    event ResolutionTableEntrySet(bytes32 indexed categoryKey, ResolutionTableEntry entry);
    event ResolverAssigned(
        uint256 indexed workflowId,
        address indexed resolver,
        bytes32 category,
        uint8 round
    );
    event EscalationConfigUpdated(uint8 level, EscalationConfig config);
    event ExternalResolverUpdated(address indexed oldResolver, address indexed newResolver);
    event EscrowContractRegistered(address indexed escrowContract);
    event EscrowContractUnregistered(address indexed escrowContract);
    event EscalationConfigQueued(uint8 level, EscalationConfig config, uint64 eta);
    event EscalationConfigActivated(
        uint8 level,
        EscalationConfig oldConfig,
        EscalationConfig newConfig
    );
    event IncentiveModuleUpdated(address indexed oldModule, address indexed newModule);
    event ResolverActiveStatusChanged(address indexed resolver, bool active);
    event IncentiveModuleCallFailed(uint256 indexed workflowId, string functionName, string reason);
    event RoundRobinCounterAdvanced(
        bytes32 indexed category,
        bool seniorResolvers,
        uint256 newIndex
    );
    event ResolverCapacityUpdated(address indexed resolver, ResolverCapacity capacity);
    event ResolverAssignmentWeightUpdated(
        address indexed resolver,
        uint256 oldWeight,
        uint256 newWeight
    ); // DR v1

    // DR v2 events
    event EscalationCostConfigQueued(EscalationCostConfig config, uint64 eta);
    event EscalationCostConfigActivated(
        EscalationCostConfig oldConfig,
        EscalationCostConfig newConfig
    );
    event AppealBondRequired(uint256 indexed workflowId, uint8 round, uint256 amount, address token);
    event MinEscrowValueUpdated(uint256 oldValue, uint256 newValue);
    event AcceptedBondTokenQueued(address indexed token, bool isAdd, uint64 eta);
    event AcceptedBondTokenChanged(address indexed token, bool isAdd);
    event DefaultBondTokenQueued(address indexed token, uint64 eta);
    event DefaultBondTokenChanged(address indexed oldToken, address indexed newToken);

    // DR v3 events
    event StakingModuleQueued(address indexed module, uint64 eta);
    event StakingModuleActivated(address indexed oldModule, address indexed newModule);
    event SlashingModuleQueued(address indexed module, uint64 eta);
    event SlashingModuleActivated(address indexed oldModule, address indexed newModule);

    // DR v3 Phase 5: Emergency controls events
    event NewAssignmentsPaused(address indexed pausedBy, string reason);
    event NewAssignmentsResumed(address indexed resumedBy);

    modifier onlySeniorResolver() {
        if (!isApprovedSeniorResolver[_msgSender()]) revert NotSeniorResolver(_msgSender());
        _;
    }
    modifier onlyResolver() {
        if (!isApprovedResolver[_msgSender()] && !isApprovedSeniorResolver[_msgSender()]) {
            revert NotAuthorizedResolver(_msgSender());
        }
        _;
    }
    modifier onlyEscrowContract() {
        if (!registeredEscrowContracts[_msgSender()]) revert NotRegisteredEscrowContract(_msgSender());
        _;
    }

    constructor(address initialOwner) {
        // OpenZeppelin best practice: Grant DEFAULT_ADMIN_ROLE to deployer
        // Deployment scripts will transfer this to TimelockController
        _grantRole(DEFAULT_ADMIN_ROLE, initialOwner);

        escalationConfig[0] = EscalationConfig({resolver: address(0), fee: 0, enabled: true});
        escalationConfig[1] = EscalationConfig({resolver: address(0), fee: 0, enabled: true});
        escalationConfig[2] = EscalationConfig({resolver: address(0), fee: 0, enabled: false});

        // Initialize DR v1 timeout parameters (v3 updated defaults)
        // v3: t_resolve_L0 = 24 hours, t_resolve_L1 = 48 hours
        resolveDeadlines = [24 hours, 48 hours, 7 days];
        appealWindows = [2 days, 3 days, 0];

        // Initialize DR v1 EMA parameters
        emaAlphaBps = 1000; // 10% EMA step
        minEmaScoreThreshold = 500000; // 50% minimum score
        maxTimeoutRateBps = 3000; // 30% maximum timeout rate

        // Initialize DR v1 escalation bond configuration (enabled in DR v1)
        // NOTE: Default bondToken is ETH (address(0)) for backward compatibility.
        // In production, this should be set to a USD stablecoin (e.g., USDC) via governance
        // after deployment. See APPEAL_BOND_TOKEN_WHITELIST_PLAN.md for implementation plan.
        escalationCostConfig = EscalationCostConfig({
            enabled: true,
            curveType: CostCurveType.QUADRATIC,
            baseCost: 0.01 ether,
            stepSize: 0.01 ether,
            multiplier: 0,
            bondToken: address(0) // Default: ETH. Production: USD stablecoin (governance-controlled)
        });
        minEscrowValueForEscalation = 0; // No minimum by default

        // Initialize bond token whitelist with ETH as default
        acceptedBondTokens[address(0)] = true; // ETH (address(0)) is accepted by default
        acceptedBondTokensList.push(address(0));
        defaultBondToken = address(0); // ETH as default for backward compatibility
    }

    function appointResolver(
        address resolver,
        string memory name,
        string memory description
    ) external onlySeniorResolver {
        if (resolver == address(0) || isApprovedResolver[resolver] || isApprovedSeniorResolver[resolver]) {
            revert InvalidResolver(resolver);
        }
        resolverRoles[resolver] = ResolverRole.RESOLVER;
        isApprovedResolver[resolver] = true;
        resolverIndex[resolver] = approvedResolvers.length;
        approvedResolvers.push(resolver);
        resolverActive[resolver] = true;
        resolverLastActive[resolver] = block.timestamp;

        // DR v1: Initialize with default EMA score and full assignment weight
        ResolutionAnalytics.initializeResolver(resolverStats[resolver]);

        resolverMetadata[resolver] = ResolverMetadata({
            name: name,
            description: description,
            appointedAt: block.timestamp,
            appointedBy: _msgSender(),
            active: true
        });
        emit ResolverAppointed(resolver, ResolverRole.RESOLVER, _msgSender());
    }

    function appointSeniorResolver(
        address resolver,
        string memory name,
        string memory description
    ) external onlyRole(ROLE_TIMELOCK) {
        if (resolver == address(0) || isApprovedResolver[resolver] || isApprovedSeniorResolver[resolver]) {
            revert InvalidSeniorResolver(resolver);
        }
        resolverRoles[resolver] = ResolverRole.SENIOR_RESOLVER;
        isApprovedSeniorResolver[resolver] = true;
        seniorResolverIndex[resolver] = approvedSeniorResolvers.length;
        approvedSeniorResolvers.push(resolver);
        resolverActive[resolver] = true;
        resolverLastActive[resolver] = block.timestamp;

        // DR v1: Initialize with default EMA score and full assignment weight
        ResolutionAnalytics.initializeResolver(resolverStats[resolver]);

        resolverCapacity[resolver] = ResolverCapacity({
            maxConcurrentDisputes: 0,
            currentDisputes: 0,
            acceptsNewDisputes: true
        });
        resolverMetadata[resolver] = ResolverMetadata({
            name: name,
            description: description,
            appointedAt: block.timestamp,
            appointedBy: _msgSender(),
            active: true
        });
        emit ResolverAppointed(resolver, ResolverRole.SENIOR_RESOLVER, _msgSender());
    }

    function removeResolver(address resolver) external {
        if (!isApprovedResolver[resolver] || resolverActiveDisputes[resolver] > 0) {
            revert CannotRemoveResolver(resolver, resolverActiveDisputes[resolver]);
        }
        if (resolverMetadata[resolver].appointedBy != _msgSender() && !hasRole(ROLE_TIMELOCK, _msgSender())) {
            revert Unauthorized(_msgSender());
        }
        _removeFromArray(approvedResolvers, resolverIndex, resolver);
        resolverRoles[resolver] = ResolverRole.NONE;
        isApprovedResolver[resolver] = false;
        resolverActive[resolver] = false;
        emit ResolverRemoved(resolver, _msgSender());
    }

    function removeSeniorResolver(address resolver) external onlyRole(ROLE_TIMELOCK) {
        if (!isApprovedSeniorResolver[resolver] || resolverActiveDisputes[resolver] > 0) {
            revert CannotRemoveResolver(resolver, resolverActiveDisputes[resolver]);
        }
        _removeFromArray(approvedSeniorResolvers, seniorResolverIndex, resolver);
        resolverRoles[resolver] = ResolverRole.NONE;
        isApprovedSeniorResolver[resolver] = false;
        resolverActive[resolver] = false;
        emit ResolverRemoved(resolver, _msgSender());
    }

    function _removeFromArray(
        address[] storage arr,
        mapping(address => uint256) storage indices,
        address item
    ) internal {
        uint256 idx = indices[item];
        uint256 lastIdx = arr.length - 1;
        if (idx != lastIdx) {
            address last = arr[lastIdx];
            arr[idx] = last;
            indices[last] = idx;
        }
        arr.pop();
        delete indices[item];
    }

    function updateResolverMetadata(
        address resolver,
        string memory name,
        string memory description
    ) external {
        if (resolverMetadata[resolver].appointedBy != _msgSender() && !hasRole(ROLE_TIMELOCK, _msgSender())) {
            revert Unauthorized(_msgSender());
        }
        resolverMetadata[resolver].name = name;
        resolverMetadata[resolver].description = description;
        emit ResolverMetadataUpdated(resolver, resolverMetadata[resolver]);
    }

    function getApprovedResolvers() external view returns (address[] memory) {
        return approvedResolvers;
    }
    function getApprovedSeniorResolvers() external view returns (address[] memory) {
        return approvedSeniorResolvers;
    }
    function getDisputeResolverRole(address disputeResolver) external view returns (ResolverRole) {
        return resolverRoles[disputeResolver];
    }
    function getDisputeMetadata(uint256 workflowId) external view returns (DisputeMetadata memory) {
        return disputeMetadata[workflowId];
    }

    /**
     * @notice Get decision at a specific round (helper for appeal access control)
     * @param workflowId Dispute ID
     * @param round Round to check (0, 1, or 2)
     * @return decision ResolutionOutcome enum value (0 = NONE, 1 = RELEASE, 2 = CANCEL)
     * @dev Returns the decision made at the specified round
     */
    function getDecisionAtRound(uint256 workflowId, uint8 round) external view returns (uint8 decision) {
        require(round < 3, 'Invalid round');
        DisputeMetadata storage dm = disputeMetadata[workflowId];
        decision = uint8(dm.decisionAtRound[round]);
    }

    /**
     * @notice Get appeal deadline and current round for a dispute (for appeal window enforcement)
     * @param workflowId Dispute ID
     * @return appealDeadline Appeal deadline for current round (0 if no deadline or final round)
     * @return currentRound Current round (0-2)
     * @return isFinalRound True if this is the final round (MAX_ROUND)
     * @dev Used by BaseEscrow to enforce appeal windows before executing transfers
     */
    function getAppealDeadlineAndRound(
        uint256 workflowId
    ) external view returns (uint256 appealDeadline, uint8 currentRound, bool isFinalRound) {
        DisputeMetadata storage dm = disputeMetadata[workflowId];
        currentRound = dm.currentRound;
        isFinalRound = (currentRound >= MAX_ROUND);

        // If final round, no appeal window (return 0)
        if (isFinalRound) {
            return (0, currentRound, true);
        }

        // Get appeal deadline for current round
        appealDeadline = dm.appealDeadline[currentRound];

        return (appealDeadline, currentRound, isFinalRound);
    }

    function isAuthorizedDisputeResolver(
        uint256 workflowId,
        address disputeResolver,
        bytes calldata
    ) external view override returns (bool authorized, uint8 role) {
        DisputeMetadata memory dm = disputeMetadata[workflowId];
        address currentResolver = dm.resolverAtRound[dm.currentRound];
        if (disputeResolver == currentResolver) return (true, dm.currentRound);
        ResolverRole rRole = resolverRoles[disputeResolver];
        uint8 req = dm.currentRound == 0
            ? uint8(ResolverRole.RESOLVER)
            : uint8(ResolverRole.SENIOR_RESOLVER);
        return (
            uint8(rRole) >= req &&
                (isApprovedResolver[disputeResolver] || isApprovedSeniorResolver[disputeResolver]),
            uint8(rRole)
        );
    }

    function getDisputeResolver(
        uint256 workflowId,
        bytes calldata
    ) external view override returns (address disputeResolver, uint8 escalationLevel) {
        DisputeMetadata memory dm = disputeMetadata[workflowId];
        address currentResolver = dm.resolverAtRound[dm.currentRound];
        if (currentResolver != address(0)) return (currentResolver, dm.currentRound);
        bytes32 cat = escrowCategory[workflowId];
        if (cat != bytes32(0) && resolutionTable[cat].enabled) {
            address selected = selectResolverRoundRobin(cat, false);
            if (selected != address(0)) return (selected, 0);
        }
        return (selectResolverRoundRobin(bytes32(0), false), 0);
    }

    function canEscalate(
        uint256 workflowId,
        uint8 currentLevel,
        bytes calldata
    ) external view override returns (bool allowed, address nextResolver, uint256 escalationFee) {
        uint8 nextRound = currentLevel + 1;
        if (nextRound > MAX_ROUND || !escalationConfig[nextRound].enabled)
            return (false, address(0), 0);
        if (nextRound == 1)
            nextResolver = selectResolverRoundRobin(escrowCategory[workflowId], true);
        else if (nextRound == 2) nextResolver = externalResolver;
        if (nextResolver == address(0)) return (false, address(0), 0);

        // Return escalation bond amount (from escalationCostConfig) instead of fee
        uint256 bondAmount = 0;
        if (escalationCostConfig.enabled) {
            uint8 escalationCount = currentLevel;
            bondAmount = EscalationCostLibrary.calculateEscalationCost(
                escalationCount,
                escalationCostConfig
            );
        }
        return (true, nextResolver, bondAmount);
    }

    function executeEscalation(
        uint256 workflowId,
        bytes calldata
    ) external override nonReentrant returns (bool success, address newResolver, uint8 newLevel) {
        DisputeMetadata storage dm = disputeMetadata[workflowId];
        uint8 fromRound = dm.currentRound;
        uint8 toRound = fromRound + 1;

        if (toRound > MAX_ROUND || !escalationConfig[toRound].enabled) {
            return (false, address(0), dm.currentRound);
        }

        address nextRes;
        if (toRound == 1) {
            nextRes = selectResolverRoundRobin(escrowCategory[workflowId], true);
            if (nextRes != address(0)) advanceRoundRobinCounter(escrowCategory[workflowId], true);
        } else if (toRound == 2) {
            nextRes = externalResolver;
        }

        if (nextRes == address(0)) {
            return (false, address(0), dm.currentRound);
        }

        // Update round-based metadata
        dm.currentRound = toRound;
        dm.resolverAtRound[toRound] = nextRes;
        dm.escalatedBy = _msgSender();
        dm.escalationTimestamp = block.timestamp;
        dm.assignedAt = block.timestamp;
        dm.resolveBy = block.timestamp + resolveDeadlines[toRound];
        dm.status = DisputeStatus.Escalated;

        emit DisputeEscalatedToRound(workflowId, fromRound, toRound, nextRes);
        emit ResolverAssigned(workflowId, nextRes, escrowCategory[workflowId], toRound);

        // Increment case counter for new resolver
        resolverStats[nextRes].casesAssigned++;

        // Call incentive module hooks
        if (address(incentiveModule) != address(0)) {
            try incentiveModule.onResolverAssigned(workflowId, nextRes, toRound) {} catch {
                emit IncentiveModuleCallFailed(workflowId, 'onResolverAssigned', 'FAILED');
            }

            try incentiveModule.onEscalated(workflowId, fromRound, toRound, _msgSender()) {} catch {
                emit IncentiveModuleCallFailed(workflowId, 'onEscalated', 'FAILED');
            }
        }

        // DR v3: Call staking module hooks (if enabled)
        if (address(stakingModule) != address(0)) {
            // Unlock stake from prior round resolver
            address priorResolver = dm.resolverAtRound[fromRound];
            try stakingModule.onDisputeEscalated(workflowId, priorResolver) {} catch {}

            // Lock stake for new resolver
            try stakingModule.onResolverAssigned(workflowId, nextRes, 0) {} catch {}
        }

        return (true, nextRes, toRound);
    }

    /**
     * @notice Get required appeal bond for escalation (DR v2)
     * @dev Calculates bond based on escalation cost curve configuration
     * @param currentLevel Current escalation level/round
     * @return amount Required bond amount
     * @return token Token address for bond
     */
    function getRequiredAppealBond(
        uint256 /* workflowId */,
        uint8 currentLevel,
        bytes calldata escrowData
    ) external view override returns (uint256 amount, address token) {
        if (!escalationCostConfig.enabled) {
            return (0, address(0));
        }

        // Use escalation count (number of prior escalations)
        // Round 0 → 1: escalationCount = 0 (first escalation)
        // Round 1 → 2: escalationCount = 1 (second escalation)
        // Round 2 → 3: escalationCount = 2 (hypothetical third escalation)
        uint8 escalationCount = currentLevel;

        uint256 bondAmount = EscalationCostLibrary.calculateEscalationCost(
            escalationCount,
            escalationCostConfig
        );

        // SECURITY: Enforce bond token matches escrow token
        // This ensures participants always have the required bond token
        // Decode escrowData to get escrow token
        (address escrowToken, , , ) = abi.decode(escrowData, (address, address, address, uint256));
        
        // Use escrow token as bond token (participants already have this token)
        address bondToken = escrowToken;

        // Note: escalationCostConfig.bondToken and defaultBondToken are now ignored
        // for security and simplicity - bond must match escrow token

        return (bondAmount, bondToken);
    }

    function moduleName() external pure override returns (string memory) {
        return 'DecentralizedResolution';
    }
    function moduleVersion() external pure override returns (string memory) {
        return '1.0.0';
    }
    function supportsInterface(
        bytes4 interfaceId
    ) public view virtual override(AccessControl, IERC165) returns (bool) {
        return
            interfaceId == type(IResolutionModule).interfaceId ||
            super.supportsInterface(interfaceId);
    }

    function setResolutionTableEntry(
        bytes32 categoryKey,
        ResolutionTableEntry memory entry
    ) external onlyRole(ROLE_TIMELOCK) {
        resolutionTable[categoryKey] = entry;
        emit ResolutionTableEntrySet(categoryKey, entry);
    }
    function getResolutionTableEntry(
        bytes32 categoryKey
    ) external view returns (ResolutionTableEntry memory) {
        return resolutionTable[categoryKey];
    }
    function setEscrowCategory(
        uint256 workflowId,
        bytes32 categoryKey
    ) external onlyEscrowContract {
        escrowCategory[workflowId] = categoryKey;
    }
    function generateCategoryKey(
        address token,
        uint256 amount,
        string memory categoryType
    ) external pure returns (bytes32) {
        return keccak256(abi.encode(token, amount, categoryType));
    }
    function autoCategorizeEscrow(bytes calldata escrowData) public pure returns (bytes32) {
        return ResolutionTableLibrary.autoCategorize(escrowData);
    }
    function getAmountTier(uint256 amount) public pure returns (string memory) {
        return ResolutionTableLibrary.getAmountTier(amount);
    }
    function getAmountCategory(uint256 amount) external pure returns (bytes32) {
        return keccak256(abi.encode(ResolutionTableLibrary.getAmountTier(amount)));
    }

    function queueEscalationConfig(
        uint8 level,
        EscalationConfig memory config
    ) external onlyRole(ROLE_TIMELOCK) {
        if (level > MAX_ROUND) revert InvalidLevel(level, MAX_ROUND);
        _pendingEscalationConfig[level] = PendingEscalationConfig({
            level: level,
            config: config,
            eta: uint64(block.timestamp + SLOW_DELAY), // forge-lint: disable-line(unsafe-typecast)
            exists: true
        });
        emit EscalationConfigQueued(level, config, _pendingEscalationConfig[level].eta);
    }

    function activateEscalationConfig(uint8 level) external onlyRole(ROLE_TIMELOCK) {
        PendingEscalationConfig storage pending = _pendingEscalationConfig[level];
        if (!pending.exists || block.timestamp < pending.eta) revert NoPending();
        EscalationConfig memory old = escalationConfig[level];
        escalationConfig[level] = pending.config;
        emit EscalationConfigActivated(level, old, pending.config);
        emit EscalationConfigUpdated(level, pending.config);
        delete _pendingEscalationConfig[level];
    }

    function getPendingEscalationConfig(
        uint8 level
    ) public view returns (EscalationConfig memory config, uint64 eta, bool exists) {
        PendingEscalationConfig storage pending = _pendingEscalationConfig[level];
        return (pending.config, pending.eta, pending.exists);
    }

    function setExternalResolver(address resolver) external onlyRole(ROLE_TIMELOCK) {
        externalResolver = resolver;
        if (resolver != address(0)) {
            escalationConfig[2].enabled = true;
            escalationConfig[2].resolver = resolver;
        }
        emit ExternalResolverUpdated(address(0), resolver);
    }

    function selectResolverRoundRobin(
        bytes32 category,
        bool useSenior
    ) internal view returns (address) {
        // Phase 5: Emergency pause check - freeze all new assignments
        if (newAssignmentsPaused) {
            return address(0);
        }

        address[] storage list = useSenior ? approvedSeniorResolvers : approvedResolvers;
        uint256 len = list.length;
        if (len == 0) return address(0);
        uint256 curIdx = useSenior
            ? categorySeniorResolverIndex[category]
            : categoryResolverIndex[category];
        // Use older blockhash (block.number - 256) to prevent miner manipulation
        // If block.number < 256, use blockhash(0) as fallback
        bytes32 blockHash = block.number >= 256 ? blockhash(block.number - 256) : blockhash(0);
        uint256 seed = uint256(keccak256(abi.encodePacked(blockHash, category, curIdx)));
        uint256 offset = seed % len;
        for (uint256 i = 0; i < len; i++) {
            address cand = list[(curIdx + offset + i) % len];

            // DR v1: Calculate workload weight from EMA score
            uint256 workloadWeight = ResolutionAnalytics.calculateWorkloadWeight(
                resolverStats[cand],
                minEmaScoreThreshold
            );
            if (workloadWeight == 0) continue; // Skip if below threshold or manually excluded

            // Check timeout rate
            uint256 timeoutRate = ResolutionAnalytics.getTimeoutRate(resolverStats[cand]);
            if (timeoutRate > maxTimeoutRateBps) continue;

            if (
                resolverActive[cand] &&
                (resolverCapacity[cand].maxConcurrentDisputes == 0 ||
                    resolverCapacity[cand].currentDisputes <
                    resolverCapacity[cand].maxConcurrentDisputes)
            ) return cand;
        }
        return address(0);
    }

    function selectResolverWithQuality(
        bytes32 category,
        bool useSenior
    ) internal view returns (address) {
        // Phase 5: Emergency pause check - freeze all new assignments
        if (newAssignmentsPaused) {
            return address(0);
        }

        address[] storage list = useSenior ? approvedSeniorResolvers : approvedResolvers;
        uint256 len = list.length;
        if (len == 0) return address(0);

        // Calculate total quality weight
        uint256 totalWeight = 0;
        uint256[] memory weights = new uint256[](len);
        address[] memory eligibleResolvers = new address[](len);
        uint256 eligibleCount = 0;

        for (uint256 i = 0; i < len; i++) {
            address resolver = list[i];
            if (!resolverActive[resolver]) continue;
            if (!resolverCapacity[resolver].acceptsNewDisputes) continue;
            if (
                resolverCapacity[resolver].maxConcurrentDisputes > 0 &&
                resolverCapacity[resolver].currentDisputes >=
                resolverCapacity[resolver].maxConcurrentDisputes
            ) {
                continue;
            }

            // DR v1: Calculate workload weight from EMA score
            ResolverStats memory stats = resolverStats[resolver];
            uint256 workloadWeight = ResolutionAnalytics.calculateWorkloadWeight(
                stats,
                minEmaScoreThreshold
            );
            if (workloadWeight == 0) continue; // Skip if below threshold or manually excluded

            // Check timeout rate
            uint256 timeoutRate = ResolutionAnalytics.getTimeoutRate(stats);
            if (timeoutRate > maxTimeoutRateBps) continue;

            // Workload weight already incorporates EMA score (0-10000 basis points)
            uint256 weight = workloadWeight;
            if (weight == 0) continue;

            eligibleResolvers[eligibleCount] = resolver;
            weights[eligibleCount] = weight;
            totalWeight += weight;
            eligibleCount++;
        }

        if (eligibleCount == 0) return address(0);
        if (totalWeight == 0) return eligibleResolvers[0]; // Fallback to first eligible

        // Use older blockhash for randomness
        bytes32 blockHash = block.number >= 256 ? blockhash(block.number - 256) : blockhash(0);
        uint256 random = uint256(
            keccak256(abi.encodePacked(blockHash, category, block.timestamp))
        ) % totalWeight;

        // Weighted random selection
        uint256 cumulative = 0;
        for (uint256 i = 0; i < eligibleCount; i++) {
            cumulative += weights[i];
            if (random < cumulative) {
                return eligibleResolvers[i];
            }
        }

        // Fallback (shouldn't reach here)
        return eligibleResolvers[0];
    }

    function advanceRoundRobinCounter(bytes32 category, bool useSenior) internal {
        uint256 len = useSenior ? approvedSeniorResolvers.length : approvedResolvers.length;
        if (len == 0) return;
        if (useSenior)
            categorySeniorResolverIndex[category] =
                (categorySeniorResolverIndex[category] + 1) %
                len;
        else categoryResolverIndex[category] = (categoryResolverIndex[category] + 1) % len;
        emit RoundRobinCounterAdvanced(category, useSenior, 0);
    }

    function initializeDispute(
        uint256 workflowId,
        address resolver,
        bytes32 categoryKey
    ) external onlyEscrowContract {
        DisputeMetadata storage dm = disputeMetadata[workflowId];
        if (dm.resolverAtRound[0] != address(0)) revert AlreadyInitialized(workflowId);

        // Atomic capacity check and increment
        if (!resolverActive[resolver]) revert ResolverInactive(resolver);
        ResolverCapacity storage capacity = resolverCapacity[resolver];
        if (!capacity.acceptsNewDisputes) revert ResolverNotAcceptingDisputes(resolver);
        if (capacity.maxConcurrentDisputes > 0) {
            if (capacity.currentDisputes >= capacity.maxConcurrentDisputes) {
                revert ResolverCapacityExceeded(resolver, capacity.currentDisputes, capacity.maxConcurrentDisputes);
            }
        }

        // Increment atomically (both counters to maintain consistency)
        capacity.currentDisputes++;
        resolverActiveDisputes[resolver]++;

        // Initialize round-based dispute metadata (DR v1)
        dm.currentRound = 0;
        dm.status = DisputeStatus.Open;
        dm.resolverAtRound[0] = resolver;
        dm.assignedAt = block.timestamp;
        dm.resolveBy = block.timestamp + resolveDeadlines[0];
        escrowCategory[workflowId] = categoryKey;

        // Increment case counter
        resolverStats[resolver].casesAssigned++;

        advanceRoundRobinCounter(categoryKey, false);
        emit ResolverAssigned(workflowId, resolver, categoryKey, 0);

        // Call incentive module hooks
        if (address(incentiveModule) != address(0)) {
            try incentiveModule.onResolverAssigned(workflowId, resolver, 0) {} catch {
                emit IncentiveModuleCallFailed(workflowId, 'onResolverAssigned', 'FAILED');
            }
        }

        // DR v3: Call staking module hook (if enabled)
        if (address(stakingModule) != address(0)) {
            try stakingModule.onResolverAssigned(workflowId, resolver, 0) {
                // Success - stake locked for this dispute
            } catch {
                // Non-critical: Continue even if staking hook fails
            }
        }
    }

    function registerEscrowContract(address c) external onlyRole(ROLE_TIMELOCK) {
        registeredEscrowContracts[c] = true;
        emit EscrowContractRegistered(c);
    }
    function unregisterEscrowContract(address c) external onlyRole(ROLE_TIMELOCK) {
        registeredEscrowContracts[c] = false;
        emit EscrowContractUnregistered(c);
    }
    function setIncentiveModule(address m) external onlyRole(ROLE_TIMELOCK) {
        incentiveModule = IIncentiveModule(m);
        emit IncentiveModuleUpdated(address(0), m);
    }
    function setResolverActive(address r, bool a) external onlyRole(ROLE_TIMELOCK) {
        resolverActive[r] = a;
        emit ResolverActiveStatusChanged(r, a);
    }
    function decrementResolverActiveDisputes(address r) external onlyEscrowContract {
        if (resolverActiveDisputes[r] > 0) resolverActiveDisputes[r]--;
        if (resolverCapacity[r].currentDisputes > 0) resolverCapacity[r].currentDisputes--;
    }
    function setResolverCapacity(address r, uint256 m, bool a) external onlyRole(ROLE_TIMELOCK) {
        resolverCapacity[r].maxConcurrentDisputes = m;
        resolverCapacity[r].acceptsNewDisputes = a;
        emit ResolverCapacityUpdated(r, resolverCapacity[r]);
    }

    /**
     * @notice Set assignment weight for a resolver (DR v1)
     * @param resolver The resolver address
     * @param weight Assignment weight (0-10000 basis points, 0 = workload to zero)
     * @dev DR v1: Primary lever for performance-based routing. Weight=0 excludes resolver from selection.
     *      Weight is multiplied with quality score in quality-based selection.
     *      Default weight for new resolvers is 10000 (full weight).
     */
    function setResolverAssignmentWeight(
        address resolver,
        uint256 weight
    ) external onlyRole(ROLE_TIMELOCK) {
        if (weight > BASIS_POINTS_DENOMINATOR) revert WeightExceedsMaximum(weight, BASIS_POINTS_DENOMINATOR);
        if (resolver == address(0)) revert ZeroAddress('resolver');

        uint256 oldWeight = resolverStats[resolver].assignmentWeight;
        resolverStats[resolver].assignmentWeight = weight;

        emit ResolverAssignmentWeightUpdated(resolver, oldWeight, weight);
    }

    /**
     * @notice Calculate assignment weight from quality score (DR v1 helper)
     * @param resolver The resolver address
     * @return weight Assignment weight (0-10000 basis points)
     * @dev DR v1: Helper function that maps quality score to assignment weight.
     *      Can be used by governance to set weights, but manual control is preferred.
     *      Thresholds: qualityScore < 5000 → weight=0, qualityScore >= 5000 → weight=qualityScore
     */
    function calculateAssignmentWeight(address resolver) external view returns (uint256 weight) {
        ResolverStats memory stats = resolverStats[resolver];

        // If assignment weight is manually set (including 0 or 10000), return it (takes precedence)
        // Note: 0 means explicitly set to zero (workload-to-zero)
        // Note: 10000 means default or explicitly set to full weight
        return stats.assignmentWeight;
    }
    /**
     * @notice Force progress on a stalled dispute (DR v1 timeout handling)
     * @param workflowId Dispute ID
     * @dev Anyone can call. If resolver timeout occurred, auto-reassigns within same round or escalates.
     *      Records timeout penalty, updates EMA score, calls incentive hooks.
     */
    function forceProgress(uint256 workflowId) external nonReentrant {
        DisputeMetadata storage dm = disputeMetadata[workflowId];

        // Check if resolve deadline passed
        if (block.timestamp < dm.resolveBy) {
            revert('No timeout');
        }

        if (dm.status != DisputeStatus.Open) {
            revert('Not open');
        }

        uint8 currentRound = dm.currentRound;
        address timedOutResolver = dm.resolverAtRound[currentRound];

        // Record timeout and update EMA score
        ResolutionAnalytics.recordTimeout(
            resolverStats[timedOutResolver],
            timedOutResolver,
            workflowId,
            currentRound,
            1, // resolve timeout
            emaAlphaBps
        );

        // Call incentive module hook
        if (address(incentiveModule) != address(0)) {
            try
                incentiveModule.onResolverTimeout(workflowId, timedOutResolver, currentRound, 1)
            {} catch {
                emit IncentiveModuleCallFailed(workflowId, 'onResolverTimeout', 'FAILED');
            }
        }

        // DR v3: Call slashing module hook for timeout (if enabled)
        if (address(slashingModule) != address(0)) {
            try slashingModule.slashForTimeout(workflowId, timedOutResolver, 1) {
                // Success - timeout recorded for potential slashing
            } catch {
                // Non-critical: Continue even if slashing hook fails
            }
        }

        // Auto-reassign within same round
        bytes32 category = escrowCategory[workflowId];
        address newResolver;

        if (currentRound == 0) {
            newResolver = selectResolverRoundRobin(category, false);
            if (newResolver != address(0)) advanceRoundRobinCounter(category, false);
        } else if (currentRound == 1) {
            newResolver = selectResolverRoundRobin(category, true);
            if (newResolver != address(0)) advanceRoundRobinCounter(category, true);
        }

        if (newResolver != address(0) && newResolver != timedOutResolver) {
            // DR v3: Unlock old resolver's stake when reassigning
            if (address(stakingModule) != address(0)) {
                try stakingModule.unlockStake(workflowId, timedOutResolver) {
                    // Success - old resolver's stake unlocked
                } catch {
                    // Non-critical: Continue even if unlock fails
                }
            }

            // Reassign within same round
            dm.resolverAtRound[currentRound] = newResolver;
            dm.assignedAt = block.timestamp;
            dm.resolveBy = block.timestamp + resolveDeadlines[currentRound];

            resolverStats[newResolver].casesAssigned++;

            emit ResolverAssigned(workflowId, newResolver, category, currentRound);

            if (address(incentiveModule) != address(0)) {
                try
                    incentiveModule.onResolverAssigned(workflowId, newResolver, currentRound)
                {} catch {
                    emit IncentiveModuleCallFailed(workflowId, 'onResolverAssigned', 'FAILED');
                }
            }

            // DR v3: Lock stake for new resolver
            if (address(stakingModule) != address(0)) {
                try stakingModule.onResolverAssigned(workflowId, newResolver, currentRound) {
                    // Success - new resolver's stake locked
                } catch {
                    // Non-critical: Continue even if lock fails
                }
            }
        } else {
            // No suitable replacement, mark as timed out
            // DR v3: Unlock timed out resolver's stake
            if (address(stakingModule) != address(0)) {
                try stakingModule.unlockStake(workflowId, timedOutResolver) {
                    // Success - resolver's stake unlocked
                } catch {
                    // Non-critical: Continue even if unlock fails
                }
            }
            dm.status = DisputeStatus.Final;
        }
    }
    function setDisputeTimeout(uint256 t) external onlyRole(ROLE_TIMELOCK) {
        if (t == 0 || t > MAX_DISPUTE_TIMEOUT) {
            revert InvalidDisputeTimeout(t, 1, MAX_DISPUTE_TIMEOUT);
        }
        disputeTimeout = t;
    }

    /**
     * @notice Record a resolution decision (DR v1)
     * @param workflowId Dispute ID
     * @param resolver Resolver who made the decision
     * @param outcome Resolution outcome
     * @param resolutionTime Time taken to resolve (seconds)
     * @dev Updates EMA score, tracks decision in round-based metadata, calls incentive hooks
     */
    function recordResolution(
        uint256 workflowId,
        address resolver,
        ResolutionOutcome outcome,
        uint256 resolutionTime
    ) external onlyEscrowContract {
        DisputeMetadata storage dm = disputeMetadata[workflowId];
        uint8 currentRound = dm.currentRound;

        // Update round-based decision tracking
        dm.decisionAtRound[currentRound] = outcome;
        dm.decidedAtRound[currentRound] = block.timestamp;
        dm.appealDeadline[currentRound] = block.timestamp + appealWindows[currentRound];
        dm.status = DisputeStatus.Decided;

        // Update EMA score for successful resolution
        ResolutionAnalytics.recordSuccessfulResolution(
            resolverStats[resolver],
            resolver,
            resolutionTime,
            emaAlphaBps
        );

        emit DecisionSubmitted(workflowId, currentRound, resolver, outcome);

        // Call incentive module hook
        if (address(incentiveModule) != address(0)) {
            try
                incentiveModule.onDecisionSubmitted(
                    workflowId,
                    resolver,
                    currentRound,
                    outcome,
                    resolutionTime
                )
            {} catch {
                emit IncentiveModuleCallFailed(workflowId, 'onDecisionSubmitted', 'FAILED');
            }
        }

        // DR v3: Call staking module hook (if enabled)
        if (address(stakingModule) != address(0)) {
            try stakingModule.onResolutionFinalized(workflowId, resolver, true) {
                // Success - stake unlocked
            } catch {
                // Non-critical: Continue even if staking hook fails
            }
        }
    }

    function getAverageResolutionTime(address resolver) external view returns (uint256) {
        return
            resolverStats[resolver].casesDecided > 0
                ? resolverStats[resolver].totalResolutionTime / resolverStats[resolver].casesDecided
                : 0;
    }
    function getDisputeResolverStats(address r) external view returns (ResolverStats memory) {
        return resolverStats[r];
    }
    function checkResolverNeedsAttention(address r) external view returns (bool, uint8) {
        return ResolutionAnalytics.checkResolverNeedsAttention(resolverStats[r], resolverActive[r]);
    }
    function selectResolverWithQuality(
        bytes32 cat,
        bool useSenior,
        bool useQual
    ) external view returns (address) {
        if (useQual) {
            return selectResolverWithQuality(cat, useSenior);
        }
        return selectResolverRoundRobin(cat, useSenior);
    }

    /**
     * @notice Get DR v1 phase gate metrics for upgrade readiness
     * @return escalationRate Escalation rate (basis points: escalations / total disputes * 10000)
     * @return avgResponseTime Average resolution time in seconds (0 if no resolutions)
     * @return activeResolvers Number of active resolvers (standard + senior)
     * @dev DR v1: Used to assess readiness for DR v2 upgrade
     *      Exit criteria: stable escalation rate, predictable response times, operational resolvers
     */
    function getV1PhaseGateMetrics()
        external
        view
        returns (uint256 escalationRate, uint256 avgResponseTime, uint256 activeResolvers)
    {
        uint256 totalCases = 0;
        uint256 totalReversals = 0;
        uint256 totalResolutionTime = 0;
        uint256 totalResolutions = 0;
        uint256 totalTimeouts = 0;

        // Aggregate stats from all resolvers
        address[] memory allResolvers = new address[](
            approvedResolvers.length + approvedSeniorResolvers.length
        );
        uint256 count = 0;
        for (uint256 i = 0; i < approvedResolvers.length; i++) {
            allResolvers[count++] = approvedResolvers[i];
        }
        for (uint256 i = 0; i < approvedSeniorResolvers.length; i++) {
            allResolvers[count++] = approvedSeniorResolvers[i];
        }

        for (uint256 i = 0; i < count; i++) {
            address resolver = allResolvers[i];
            ResolverStats memory stats = resolverStats[resolver];
            totalCases += stats.casesDecided;
            totalReversals += stats.reversals;
            totalResolutionTime += stats.totalResolutionTime;
            totalResolutions += stats.casesDecided;
            totalTimeouts += stats.timeoutsAccept + stats.timeoutsResolve;

            if (resolverActive[resolver]) {
                activeResolvers++;
            }
        }

        // Calculate reversal rate (basis points) - proxy for escalation rate
        escalationRate = totalCases > 0
            ? (totalReversals * BASIS_POINTS_DENOMINATOR) / totalCases
            : 0;

        // Calculate average response time
        avgResponseTime = totalResolutions > 0 ? totalResolutionTime / totalResolutions : 0;

        return (escalationRate, avgResponseTime, activeResolvers);
    }

    /**
     * @notice Set EMA parameters (DR v1 governance)
     * @param alphaBps EMA step parameter in basis points (e.g., 1000 = 10%)
     * @param minScoreThreshold Minimum EMA score to receive work (e.g., 500000 = 50%)
     * @param maxTimeoutRate Maximum timeout rate in basis points (e.g., 3000 = 30%)
     */
    function setEMAParameters(
        uint256 alphaBps,
        uint256 minScoreThreshold,
        uint256 maxTimeoutRate
    ) external onlyRole(ROLE_TIMELOCK) {
        if (alphaBps > BASIS_POINTS_DENOMINATOR) revert InvalidAlpha(alphaBps, BASIS_POINTS_DENOMINATOR);
        if (minScoreThreshold > ResolutionAnalytics.EMA_PRECISION) {
            revert InvalidThreshold(minScoreThreshold, ResolutionAnalytics.EMA_PRECISION);
        }
        if (maxTimeoutRate > BASIS_POINTS_DENOMINATOR) {
            revert InvalidTimeoutRate(maxTimeoutRate, BASIS_POINTS_DENOMINATOR);
        }

        emaAlphaBps = alphaBps;
        minEmaScoreThreshold = minScoreThreshold;
        maxTimeoutRateBps = maxTimeoutRate;
    }

    /**
     * @notice Set timeout durations for each round (DR v1 governance)
     * @param roundResolveDeadlines Array of resolve deadlines per round [0, 1, 2]
     * @param roundAppealWindows Array of appeal windows per round [0, 1, 2]
     */
    function setRoundTimeouts(
        uint256[3] memory roundResolveDeadlines,
        uint256[3] memory roundAppealWindows
    ) external onlyRole(ROLE_TIMELOCK) {
        for (uint256 i = 0; i < 3; i++) {
            if (roundResolveDeadlines[i] == 0 || roundResolveDeadlines[i] > MAX_DISPUTE_TIMEOUT) {
                revert InvalidDisputeTimeout(roundResolveDeadlines[i], 1, MAX_DISPUTE_TIMEOUT);
            }
            resolveDeadlines[i] = roundResolveDeadlines[i];
            appealWindows[i] = roundAppealWindows[i];
        }
    }

    /**
     * @notice Record a reversal when escalation reveals prior decision was wrong (DR v1)
     * @param workflowId Dispute ID
     * @param priorRound Round where original decision was made
     * @dev Called when a decision at priorRound is overturned by decision at priorRound+1
     *      Updates EMA score with penalty for the original resolver
     */
    function recordReversal(uint256 workflowId, uint8 priorRound) external onlyEscrowContract {
        DisputeMetadata storage dm = disputeMetadata[workflowId];

        if (priorRound >= dm.currentRound) revert InvalidRound(priorRound, dm.currentRound);
        if (dm.decisionAtRound[priorRound] == ResolutionOutcome.NONE) revert NoPriorDecision(priorRound);
        if (dm.decisionAtRound[dm.currentRound] == ResolutionOutcome.NONE) {
            revert NoDecision(workflowId, dm.currentRound);
        }

        // Check if decisions differ (reversal occurred)
        if (dm.decisionAtRound[priorRound] != dm.decisionAtRound[dm.currentRound]) {
            address priorResolver = dm.resolverAtRound[priorRound];

            ResolutionAnalytics.recordReversal(
                resolverStats[priorResolver],
                priorResolver,
                workflowId,
                dm.decisionAtRound[priorRound],
                dm.decisionAtRound[dm.currentRound],
                priorRound,
                dm.currentRound,
                emaAlphaBps
            );

            // DR v2: Distribute appeal bond if reversal occurred (appeal succeeded)
            if (address(incentiveModule) != address(0)) {
                try incentiveModule.distributeAppealBond(workflowId, priorRound, true) {
                    // Success - bond refunded to depositor
                } catch {
                    // Non-critical: Continue even if bond distribution fails
                }
            }

            // DR v3: Call slashing module hook for reversal (if enabled)
            if (address(slashingModule) != address(0)) {
                try slashingModule.slashForReversal(workflowId, priorResolver, priorRound) {
                    // Success - reversal recorded for potential slashing
                } catch {
                    // Non-critical: Continue even if slashing hook fails
                }
            }
        }
    }

    /**
     * @notice Finalize a dispute (no more appeals possible)
     * @param workflowId Dispute ID
     * @dev Called when appeal window expires or final round decision is made
     *      Triggers onDisputeFinalized hook and distributes any remaining appeal bonds
     */
    function finalizeDispute(uint256 workflowId) external onlyEscrowContract {
        DisputeMetadata storage dm = disputeMetadata[workflowId];

        if (dm.status == DisputeStatus.Final) revert AlreadyFinalized(workflowId);
        if (dm.decisionAtRound[dm.currentRound] == ResolutionOutcome.NONE) {
            revert NoDecision(workflowId, dm.currentRound);
        }

        // Check if appeal window has expired or this is final round
        bool canFinalize = false;
        if (dm.currentRound == MAX_ROUND) {
            // Final round - can finalize immediately
            canFinalize = true;
        } else if (dm.appealDeadline[dm.currentRound] > 0) {
            // Check if appeal window expired
            canFinalize = block.timestamp >= dm.appealDeadline[dm.currentRound];
        }

        if (!canFinalize) revert CannotFinalizeYet(workflowId, 'Appeal window not expired or not final round');

        dm.status = DisputeStatus.Final;
        ResolutionOutcome finalDecision = dm.decisionAtRound[dm.currentRound];
        uint8 finalRound = dm.currentRound;

        // Call incentive module onDisputeFinalized hook
        if (address(incentiveModule) != address(0)) {
            try incentiveModule.onDisputeFinalized(workflowId, finalRound, finalDecision) {
                // Success
            } catch {
                // Non-critical: Continue even if hook fails
            }

            // Distribute any appeal bonds that haven't been distributed yet
            // Check each round for bonds and distribute based on outcome
            // Note: We try to distribute bonds for each prior round
            // The incentive module will check if bond exists internally
            for (uint8 round = 0; round < finalRound; round++) {
                // Prior round - check if decision at finalRound matches decision at round
                bool outcomeFlipped = (dm.decisionAtRound[round] != finalDecision);
                try incentiveModule.distributeAppealBond(workflowId, round, outcomeFlipped) {
                    // Success - bond distributed (or no bond existed, which is fine)
                } catch {
                    // Non-critical: Continue even if bond distribution fails
                }
            }
        }
    }

    // ============ DR v2 Governance Functions ============

    /**
     * @notice Queue escalation cost configuration (DR v2 - slow lane)
     * @param config Escalation cost curve configuration
     */
    function queueEscalationCostConfig(
        EscalationCostConfig memory config
    ) external onlyRole(ROLE_TIMELOCK) {
        if (config.baseCost == 0 && config.enabled) revert InvalidBaseCost(config.baseCost, config.enabled);

        // Validate bond token if specified and not address(0)
        // Allow address(0) (ETH) without whitelist check for backward compatibility
        if (config.bondToken != address(0)) {
            // For non-ETH tokens, we optionally validate against whitelist
            // but don't strictly require it for backward compatibility
            // The actual validation happens when the bond is retrieved in getRequiredAppealBond
        }

        _pendingEscalationCostConfig = PendingEscalationCostConfig({
            config: config,
            eta: uint64(block.timestamp + SLOW_DELAY), // forge-lint: disable-line(unsafe-typecast)
            exists: true
        });

        emit EscalationCostConfigQueued(config, _pendingEscalationCostConfig.eta);
    }

    /**
     * @notice Activate queued escalation cost configuration (DR v2 - slow lane)
     */
    function activateEscalationCostConfig() external onlyRole(ROLE_TIMELOCK) {
        PendingEscalationCostConfig storage pending = _pendingEscalationCostConfig;
        if (!pending.exists || block.timestamp < pending.eta) revert NoPending();

        EscalationCostConfig memory oldConfig = escalationCostConfig;
        escalationCostConfig = pending.config;

        emit EscalationCostConfigActivated(oldConfig, pending.config);
        delete _pendingEscalationCostConfig;
    }

    /**
     * @notice Get pending escalation cost configuration
     * @return config Pending configuration
     * @return eta Activation timestamp
     * @return exists Whether pending config exists
     */
    function getPendingEscalationCostConfig()
        external
        view
        returns (EscalationCostConfig memory config, uint64 eta, bool exists)
    {
        PendingEscalationCostConfig storage pending = _pendingEscalationCostConfig;
        return (pending.config, pending.eta, pending.exists);
    }

    /**
     * @notice Set minimum escrow value for escalation (DR v2 anti-griefing)
     * @param minValue Minimum escrow value (0 = no minimum)
     */
    function setMinEscrowValueForEscalation(uint256 minValue) external onlyRole(ROLE_TIMELOCK) {
        uint256 oldValue = minEscrowValueForEscalation;
        minEscrowValueForEscalation = minValue;
        emit MinEscrowValueUpdated(oldValue, minValue);
    }

    // ============ DR v2 Bond Token Whitelist Functions ============

    /**
     * @notice Queue adding a token to the accepted bond tokens whitelist
     * @param token Token address to add
     * @dev Requires ROLE_TIMELOCK, slow lane governance
     */
    function queueAddAcceptedBondToken(address token) external onlyRole(ROLE_TIMELOCK) {
        if (token == address(0) && !acceptedBondTokens[address(0)]) revert InvalidBondToken(token);
        if (acceptedBondTokens[token]) revert TokenAlreadyInWhitelist(token);

        _pendingBondTokenChange = PendingBondTokenChange({
            token: token,
            isAdd: true,
            eta: uint64(block.timestamp + 7 days),
            exists: true
        });

        emit AcceptedBondTokenQueued(token, true, _pendingBondTokenChange.eta);
    }

    /**
     * @notice Queue removing a token from the accepted bond tokens whitelist
     * @param token Token address to remove
     * @dev Requires ROLE_TIMELOCK, slow lane governance
     */
    function queueRemoveAcceptedBondToken(address token) external onlyRole(ROLE_TIMELOCK) {
        if (token == defaultBondToken) revert CannotRemoveDefaultToken(token);
        if (!acceptedBondTokens[token]) revert TokenNotInWhitelist(token);

        _pendingBondTokenChange = PendingBondTokenChange({
            token: token,
            isAdd: false,
            eta: uint64(block.timestamp + 7 days),
            exists: true
        });

        emit AcceptedBondTokenQueued(token, false, _pendingBondTokenChange.eta);
    }

    /**
     * @notice Activate queued bond token whitelist change
     * @dev Requires ROLE_TIMELOCK, after timelock delay
     */
    function activateBondTokenWhitelistChange() external onlyRole(ROLE_TIMELOCK) {
        if (!_pendingBondTokenChange.exists) revert NoPendingBondTokenChange();
        if (block.timestamp < _pendingBondTokenChange.eta) {
            revert TimelockNotElapsed(_pendingBondTokenChange.eta, block.timestamp);
        }

        address token = _pendingBondTokenChange.token;
        bool isAdd = _pendingBondTokenChange.isAdd;

        if (isAdd) {
            acceptedBondTokens[token] = true;
            acceptedBondTokensList.push(token);
        } else {
            acceptedBondTokens[token] = false;
            // Note: We don't remove from array to preserve indices
        }

        delete _pendingBondTokenChange;
        emit AcceptedBondTokenChanged(token, isAdd);
    }

    /**
     * @notice Queue setting the default bond token
     * @param token Token address (must be in whitelist)
     * @dev Requires ROLE_TIMELOCK, slow lane governance
     */
    function queueSetDefaultBondToken(address token) external onlyRole(ROLE_TIMELOCK) {
        if (!acceptedBondTokens[token]) revert TokenNotInWhitelist(token);

        _pendingDefaultBondToken = PendingDefaultBondToken({
            token: token,
            eta: uint64(block.timestamp + 7 days),
            exists: true
        });

        emit DefaultBondTokenQueued(token, _pendingDefaultBondToken.eta);
    }

    /**
     * @notice Activate queued default bond token change
     * @dev Requires ROLE_TIMELOCK, after timelock delay
     */
    function activateDefaultBondToken() external onlyRole(ROLE_TIMELOCK) {
        if (!_pendingDefaultBondToken.exists) revert NoPendingBondTokenChange();
        if (block.timestamp < _pendingDefaultBondToken.eta) {
            revert TimelockNotElapsed(_pendingDefaultBondToken.eta, block.timestamp);
        }

        address oldToken = defaultBondToken;
        address newToken = _pendingDefaultBondToken.token;

        defaultBondToken = newToken;
        delete _pendingDefaultBondToken;

        emit DefaultBondTokenChanged(oldToken, newToken);
    }

    /**
     * @notice Check if token is accepted for bonds
     * @param token Token address to check
     * @return True if token is accepted
     */
    function isAcceptedBondToken(address token) external view returns (bool) {
        return acceptedBondTokens[token];
    }

    /**
     * @notice Get list of accepted bond tokens
     * @return Array of accepted bond token addresses
     */
    function getAcceptedBondTokens() external view returns (address[] memory) {
        return acceptedBondTokensList;
    }

    /**
     * @notice Get pending bond token change
     * @return token Token address
     * @return isAdd Whether change is adding (true) or removing (false)
     * @return eta Activation time
     * @return exists Whether a change is pending
     */
    function getPendingBondTokenChange()
        external
        view
        returns (address token, bool isAdd, uint64 eta, bool exists)
    {
        return (
            _pendingBondTokenChange.token,
            _pendingBondTokenChange.isAdd,
            _pendingBondTokenChange.eta,
            _pendingBondTokenChange.exists
        );
    }

    /**
     * @notice Get pending default bond token change
     * @return token Token address
     * @return eta Activation time
     * @return exists Whether a change is pending
     */
    function getPendingDefaultBondToken()
        external
        view
        returns (address token, uint64 eta, bool exists)
    {
        return (
            _pendingDefaultBondToken.token,
            _pendingDefaultBondToken.eta,
            _pendingDefaultBondToken.exists
        );
    }

    // ============ DR v3 Governance Functions ============

    /**
     * @notice Queue staking module update (DR v3 - slow lane)
     * @param module New staking module address (can be address(0) to disable)
     */
    function queueStakingModule(address module) external onlyRole(ROLE_TIMELOCK) {
        _pendingStakingModule = PendingModuleConfig({
            module: module,
            eta: uint64(block.timestamp + SLOW_DELAY), // forge-lint: disable-line(unsafe-typecast)
            exists: true
        });

        emit StakingModuleQueued(module, _pendingStakingModule.eta);
    }

    /**
     * @notice Activate queued staking module (DR v3 - slow lane)
     */
    function activateStakingModule() external onlyRole(ROLE_TIMELOCK) {
        PendingModuleConfig storage pending = _pendingStakingModule;
        if (!pending.exists || block.timestamp < pending.eta) revert NoPending();

        address oldModule = address(stakingModule);
        stakingModule = IStakingModule(pending.module);

        emit StakingModuleActivated(oldModule, pending.module);
        delete _pendingStakingModule;
    }

    /**
     * @notice Queue slashing module update (DR v3 - slow lane)
     * @param module New slashing module address (can be address(0) to disable)
     */
    function queueSlashingModule(address module) external onlyRole(ROLE_TIMELOCK) {
        _pendingSlashingModule = PendingModuleConfig({
            module: module,
            eta: uint64(block.timestamp + SLOW_DELAY), // forge-lint: disable-line(unsafe-typecast)
            exists: true
        });

        emit SlashingModuleQueued(module, _pendingSlashingModule.eta);
    }

    /**
     * @notice Activate queued slashing module (DR v3 - slow lane)
     */
    function activateSlashingModule() external onlyRole(ROLE_TIMELOCK) {
        PendingModuleConfig storage pending = _pendingSlashingModule;
        if (!pending.exists || block.timestamp < pending.eta) revert NoPending();

        address oldModule = address(slashingModule);
        slashingModule = ISlashingModule(pending.module);

        emit SlashingModuleActivated(oldModule, pending.module);
        delete _pendingSlashingModule;
    }

    /**
     * @notice Get pending staking module config
     * @return module Pending module address
     * @return eta Activation timestamp
     * @return exists Whether pending config exists
     */
    function getPendingStakingModule()
        external
        view
        returns (address module, uint64 eta, bool exists)
    {
        PendingModuleConfig storage pending = _pendingStakingModule;
        return (pending.module, pending.eta, pending.exists);
    }

    /**
     * @notice Get pending slashing module config
     * @return module Pending module address
     * @return eta Activation timestamp
     * @return exists Whether pending config exists
     */
    function getPendingSlashingModule()
        external
        view
        returns (address module, uint64 eta, bool exists)
    {
        PendingModuleConfig storage pending = _pendingSlashingModule;
        return (pending.module, pending.eta, pending.exists);
    }

    /**
     * @notice Check if DR v3 modules are active
     * @return stakingActive Whether staking module is set
     * @return slashingActive Whether slashing module is set
     */
    function isV3Active() external view returns (bool stakingActive, bool slashingActive) {
        return (address(stakingModule) != address(0), address(slashingModule) != address(0));
    }

    // ============ DR v3 Phase 5: Emergency Controls ============

    /**
     * @notice Pause all new resolver assignments (emergency control)
     * @param reason Reason for pausing
     * @dev When paused, selectResolverRoundRobin() and selectResolverWithQuality() return address(0)
     *      Existing disputes continue processing normally
     *      Requires ROLE_TIMELOCK (slow lane) or ROLE_GUARDIAN (emergency)
     */
    function pauseNewAssignments(string memory reason) external {
        if (!hasRole(ROLE_TIMELOCK, msg.sender) && !hasRole(ROLE_GUARDIAN, msg.sender)) {
            revert NotAuthorized(msg.sender);
        }
        if (newAssignmentsPaused) revert AlreadyPaused();

        newAssignmentsPaused = true;
        emit NewAssignmentsPaused(msg.sender, reason);
    }

    /**
     * @notice Resume new resolver assignments
     * @dev Requires ROLE_TIMELOCK (slow lane). Guardian is down-only and cannot resume.
     */
    function resumeNewAssignments() external {
        if (!hasRole(ROLE_TIMELOCK, msg.sender)) {
            revert NotAuthorized(msg.sender);
        }
        if (!newAssignmentsPaused) revert NotPaused();

        newAssignmentsPaused = false;
        emit NewAssignmentsResumed(msg.sender);
    }

    /**
     * @notice Check if new assignments are paused
     * @return paused Whether new assignments are paused
     */
    function areNewAssignmentsPaused() external view returns (bool paused) {
        return newAssignmentsPaused;
    }
}
