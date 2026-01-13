// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.33;

import "../shared/interfaces/IResolutionModule.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/introspection/ERC165Upgradeable.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import "../shared/governance/SlowLaneQueueActivateUpgradeable.sol";
import "./IIncentiveModule.sol";
import "./DecentralizedResolverStructs.sol";
import "./ResolutionAnalytics.sol";
import "./EscalationCostLibrary.sol";
import "../libraries/ResolutionTableLibrary.sol";

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
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    IResolutionModule,
    SlowLaneQueueActivateUpgradeable,
    UUPSUpgradeable,
    DecentralizedResolverStructs
{
    using ResolutionAnalytics for mapping(address => ResolverStats);
    using ResolutionTableLibrary for bytes;

    bytes32 public constant ROLE_TIMELOCK = keccak256("ROLE_TIMELOCK");
    uint8 public constant MAX_ROUND = 2; // 0=resolver, 1=senior, 2=external (Kleros)
    uint256 public constant BASIS_POINTS_DENOMINATOR = 10000;
    uint256 public constant DEFAULT_DISPUTE_TIMEOUT = 7 days;
    uint256 public constant MAX_DISPUTE_TIMEOUT = 365 days;
    
    // DR v1: EMA parameters (governance-controlled)
    uint256 public emaAlphaBps = 1000; // 10% EMA step (alphaBps / 10000)
    uint256 public minEmaScoreThreshold = 500000; // 50% minimum score to receive work
    uint256 public maxTimeoutRateBps = 3000; // 30% maximum timeout rate
    
    // DR v1: Timeout durations per round
    uint256[3] public resolveDeadlines = [3 days, 5 days, 7 days]; // Time to resolve per round
    uint256[3] public appealWindows = [2 days, 3 days, 0]; // Time to appeal after decision
    
    // DR v2: Appeal bond configuration
    EscalationCostConfig public escalationCostConfig;
    PendingEscalationCostConfig private _pendingEscalationCostConfig;
    uint256 public minEscrowValueForEscalation; // Minimum escrow value to allow escalation (anti-griefing)
    
    struct PendingEscalationCostConfig {
        EscalationCostConfig config;
        uint64 eta;
        bool exists;
    }
    
    mapping(address => ResolverRole) public resolverRoles;
    mapping(address => bool) public isApprovedResolver;
    mapping(address => bool) public isApprovedSeniorResolver;
    address[] public approvedResolvers;
    address[] public approvedSeniorResolvers;
    
    mapping(address => ResolverMetadata) public resolverMetadata;
    mapping(uint256 => DisputeMetadata) public disputeMetadata;
    mapping(uint256 => bool) public escalationFeePaid; // Track if escalation fee was paid for a dispute
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
    
    // DR v3 placeholders (not implemented in v1/v2, guarded behind module swap)
    // IStakingModule public stakingModule; // DR v3 - resolver staking
    // ISlashingModule public slashingModule; // DR v3 - resolver slashing
    // IFraudProofModule public fraudProofModule; // DR v3 - fraud lane

    event ResolverAppointed(address indexed resolver, ResolverRole role, address indexed appointedBy);
    event ResolverRemoved(address indexed resolver, address indexed removedBy);
    event ResolverMetadataUpdated(address indexed resolver, ResolverMetadata metadata);
    event DisputeEscalatedToRound(uint256 indexed workflowId, uint8 fromRound, uint8 toRound, address indexed newResolver);
    event DecisionSubmitted(uint256 indexed workflowId, uint8 round, address indexed resolver, ResolutionOutcome decision);
    event ResolutionTableEntrySet(bytes32 indexed categoryKey, ResolutionTableEntry entry);
    event ResolverAssigned(uint256 indexed workflowId, address indexed resolver, bytes32 category, uint8 round);
    event EscalationConfigUpdated(uint8 level, EscalationConfig config);
    event ExternalResolverUpdated(address indexed oldResolver, address indexed newResolver);
    event EscrowContractRegistered(address indexed escrowContract);
    event EscrowContractUnregistered(address indexed escrowContract);
    event EscalationConfigQueued(uint8 level, EscalationConfig config, uint64 eta);
    event EscalationConfigActivated(uint8 level, EscalationConfig oldConfig, EscalationConfig newConfig);
    event IncentiveModuleUpdated(address indexed oldModule, address indexed newModule);
    event ResolverActiveStatusChanged(address indexed resolver, bool active);
    event IncentiveModuleCallFailed(uint256 indexed workflowId, string functionName, string reason);
    event RoundRobinCounterAdvanced(bytes32 indexed category, bool seniorResolvers, uint256 newIndex);
    event ResolverCapacityUpdated(address indexed resolver, ResolverCapacity capacity);
    event ModuleUpgraded(address indexed oldImplementation, address indexed newImplementation, address indexed upgradedBy, uint256 timestamp);
    event EscalationFeePaid(uint256 indexed workflowId, uint256 fee);
    event ResolverAssignmentWeightUpdated(address indexed resolver, uint256 oldWeight, uint256 newWeight); // DR v1
    
    // DR v2 events
    event EscalationCostConfigQueued(EscalationCostConfig config, uint64 eta);
    event EscalationCostConfigActivated(EscalationCostConfig oldConfig, EscalationCostConfig newConfig);
    event AppealBondRequired(uint256 indexed workflowId, uint8 round, uint256 amount, address token);
    event MinEscrowValueUpdated(uint256 oldValue, uint256 newValue);

    modifier onlySeniorResolver() { require(isApprovedSeniorResolver[_msgSender()], "Not senior resolver"); _; }
    modifier onlyResolver() { require(isApprovedResolver[_msgSender()] || isApprovedSeniorResolver[_msgSender()], "Not authorized resolver"); _; }
    modifier onlyEscrowContract() { require(registeredEscrowContracts[_msgSender()], "Not registered escrow contract"); _; }

    function initialize(address initialOwner) public initializer {
        __AccessControl_init(); __ReentrancyGuard_init(); __UUPSUpgradeable_init();
        _grantRole(DEFAULT_ADMIN_ROLE, initialOwner); _grantRole(ROLE_TIMELOCK, initialOwner);
        escalationConfig[0] = EscalationConfig({resolver: address(0), fee: 0, enabled: true});
        escalationConfig[1] = EscalationConfig({resolver: address(0), fee: 0, enabled: true});
        escalationConfig[2] = EscalationConfig({resolver: address(0), fee: 0, enabled: false});
        
        // Initialize DR v1 timeout parameters
        resolveDeadlines = [3 days, 5 days, 7 days];
        appealWindows = [2 days, 3 days, 0];
        
        // Initialize DR v1 EMA parameters
        emaAlphaBps = 1000; // 10% EMA step
        minEmaScoreThreshold = 500000; // 50% minimum score
        maxTimeoutRateBps = 3000; // 30% maximum timeout rate
        
        // Initialize DR v2 parameters (disabled by default)
        escalationCostConfig.enabled = false;
        minEscrowValueForEscalation = 0; // No minimum by default
    }

    function _authorizeUpgrade(address newImplementation) internal override {
        require(hasRole(ROLE_TIMELOCK, _msgSender()), "Not authorized to upgrade");
        emit ModuleUpgraded(ERC1967Utils.getImplementation(), newImplementation, _msgSender(), block.timestamp);
    }

    function appointResolver(address resolver, string memory name, string memory description) external onlySeniorResolver {
        require(resolver != address(0) && !isApprovedResolver[resolver] && !isApprovedSeniorResolver[resolver], "Invalid resolver");
        resolverRoles[resolver] = ResolverRole.RESOLVER; isApprovedResolver[resolver] = true;
        resolverIndex[resolver] = approvedResolvers.length; approvedResolvers.push(resolver);
        resolverActive[resolver] = true; resolverLastActive[resolver] = block.timestamp;
        
        // DR v1: Initialize with default EMA score and full assignment weight
        ResolutionAnalytics.initializeResolver(resolverStats[resolver]);
        
        resolverMetadata[resolver] = ResolverMetadata({name: name, description: description, appointedAt: block.timestamp, appointedBy: _msgSender(), active: true});
        emit ResolverAppointed(resolver, ResolverRole.RESOLVER, _msgSender());
    }

    function appointSeniorResolver(address resolver, string memory name, string memory description) external onlyRole(ROLE_TIMELOCK) {
        require(resolver != address(0) && !isApprovedResolver[resolver] && !isApprovedSeniorResolver[resolver], "Invalid senior resolver");
        resolverRoles[resolver] = ResolverRole.SENIOR_RESOLVER; isApprovedSeniorResolver[resolver] = true;
        seniorResolverIndex[resolver] = approvedSeniorResolvers.length; approvedSeniorResolvers.push(resolver);
        resolverActive[resolver] = true; resolverLastActive[resolver] = block.timestamp;
        
        // DR v1: Initialize with default EMA score and full assignment weight
        ResolutionAnalytics.initializeResolver(resolverStats[resolver]);
        
        resolverCapacity[resolver] = ResolverCapacity({maxConcurrentDisputes: 0, currentDisputes: 0, acceptsNewDisputes: true});
        resolverMetadata[resolver] = ResolverMetadata({name: name, description: description, appointedAt: block.timestamp, appointedBy: _msgSender(), active: true});
        emit ResolverAppointed(resolver, ResolverRole.SENIOR_RESOLVER, _msgSender());
    }

    function removeResolver(address resolver) external {
        require(isApprovedResolver[resolver] && resolverActiveDisputes[resolver] == 0, "Cannot remove");
        require(resolverMetadata[resolver].appointedBy == _msgSender() || hasRole(ROLE_TIMELOCK, _msgSender()), "Unauthorized");
        _removeFromArray(approvedResolvers, resolverIndex, resolver);
        resolverRoles[resolver] = ResolverRole.NONE; isApprovedResolver[resolver] = false; resolverActive[resolver] = false;
        emit ResolverRemoved(resolver, _msgSender());
    }

    function removeSeniorResolver(address resolver) external onlyRole(ROLE_TIMELOCK) {
        require(isApprovedSeniorResolver[resolver] && resolverActiveDisputes[resolver] == 0, "Cannot remove");
        _removeFromArray(approvedSeniorResolvers, seniorResolverIndex, resolver);
        resolverRoles[resolver] = ResolverRole.NONE; isApprovedSeniorResolver[resolver] = false; resolverActive[resolver] = false;
        emit ResolverRemoved(resolver, _msgSender());
    }

    function _removeFromArray(address[] storage arr, mapping(address => uint256) storage indices, address item) internal {
        uint256 idx = indices[item]; uint256 lastIdx = arr.length - 1;
        if (idx != lastIdx) { address last = arr[lastIdx]; arr[idx] = last; indices[last] = idx; }
        arr.pop(); delete indices[item];
    }

    function updateResolverMetadata(address resolver, string memory name, string memory description) external {
        require(resolverMetadata[resolver].appointedBy == _msgSender() || hasRole(ROLE_TIMELOCK, _msgSender()), "Unauthorized");
        resolverMetadata[resolver].name = name; resolverMetadata[resolver].description = description;
        emit ResolverMetadataUpdated(resolver, resolverMetadata[resolver]);
    }

    function getApprovedResolvers() external view returns (address[] memory) { return approvedResolvers; }
    function getApprovedSeniorResolvers() external view returns (address[] memory) { return approvedSeniorResolvers; }
    function getDisputeResolverRole(address disputeResolver) external view returns (ResolverRole) { return resolverRoles[disputeResolver]; }
    function getDisputeMetadata(uint256 workflowId) external view returns (DisputeMetadata memory) { return disputeMetadata[workflowId]; }

    function isAuthorizedDisputeResolver(uint256 workflowId, address disputeResolver, bytes calldata) external view override returns (bool authorized, uint8 role) {
        DisputeMetadata memory dm = disputeMetadata[workflowId];
        address currentResolver = dm.resolverAtRound[dm.currentRound];
        if (disputeResolver == currentResolver) return (true, dm.currentRound);
        ResolverRole rRole = resolverRoles[disputeResolver];
        uint8 req = dm.currentRound == 0 ? uint8(ResolverRole.RESOLVER) : uint8(ResolverRole.SENIOR_RESOLVER);
        return (uint8(rRole) >= req && (isApprovedResolver[disputeResolver] || isApprovedSeniorResolver[disputeResolver]), uint8(rRole));
    }

    function getDisputeResolver(uint256 workflowId, bytes calldata) external view override returns (address disputeResolver, uint8 escalationLevel) {
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

    function canEscalate(uint256 workflowId, uint8 currentLevel, bytes calldata) external view override returns (bool allowed, address nextResolver, uint256 escalationFee) {
        uint8 nextRound = currentLevel + 1;
        if (nextRound > MAX_ROUND || !escalationConfig[nextRound].enabled) return (false, address(0), 0);
        if (nextRound == 1) nextResolver = selectResolverRoundRobin(escrowCategory[workflowId], true);
        else if (nextRound == 2) nextResolver = externalResolver;
        return (nextResolver != address(0), nextResolver, escalationConfig[nextRound].fee);
    }

    function executeEscalation(uint256 workflowId, bytes calldata) external override nonReentrant returns (bool success, address newResolver, uint8 newLevel) {
        DisputeMetadata storage dm = disputeMetadata[workflowId]; 
        uint8 fromRound = dm.currentRound;
        uint8 toRound = fromRound + 1;
        
        if (toRound > MAX_ROUND || !escalationConfig[toRound].enabled) {
            return (false, address(0), dm.currentRound);
        }
        
        // Verify escalation fee was paid (if required)
        uint256 requiredFee = escalationConfig[toRound].fee;
        if (requiredFee > 0) {
            // Escrow contract must mark fee as paid before calling executeEscalation()
            // This is done by calling markEscalationFeePaid() after collecting the fee
            require(escalationFeePaid[workflowId], "Escalation fee not paid");
            
            // Clear the flag after verification (prevents reuse)
            escalationFeePaid[workflowId] = false;
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
            try incentiveModule.onResolverAssigned(workflowId, nextRes, toRound) {} 
            catch { emit IncentiveModuleCallFailed(workflowId, "onResolverAssigned", "FAILED"); }
            
            try incentiveModule.onEscalated(workflowId, fromRound, toRound, _msgSender()) {}
            catch { emit IncentiveModuleCallFailed(workflowId, "onEscalated", "FAILED"); }
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
        bytes calldata /* escrowData */
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
        
        return (bondAmount, escalationCostConfig.bondToken);
    }

    function moduleName() external pure override returns (string memory) { return "DecentralizedResolution"; }
    function moduleVersion() external pure override returns (string memory) { return "1.0.0"; }
    function supportsInterface(bytes4 interfaceId) public view virtual override(AccessControlUpgradeable, IERC165) returns (bool) {
        return interfaceId == type(IResolutionModule).interfaceId || super.supportsInterface(interfaceId);
    }

    function setResolutionTableEntry(bytes32 categoryKey, ResolutionTableEntry memory entry) external onlyRole(ROLE_TIMELOCK) { resolutionTable[categoryKey] = entry; emit ResolutionTableEntrySet(categoryKey, entry); }
    function getResolutionTableEntry(bytes32 categoryKey) external view returns (ResolutionTableEntry memory) { return resolutionTable[categoryKey]; }
    function setEscrowCategory(uint256 workflowId, bytes32 categoryKey) external onlyEscrowContract { escrowCategory[workflowId] = categoryKey; }
    function generateCategoryKey(address token, uint256 amount, string memory categoryType) external pure returns (bytes32) { return keccak256(abi.encode(token, amount, categoryType)); }
    function autoCategorizeEscrow(bytes calldata escrowData) public pure returns (bytes32) { return ResolutionTableLibrary.autoCategorize(escrowData); }
    function getAmountTier(uint256 amount) public pure returns (string memory) { return ResolutionTableLibrary.getAmountTier(amount); }
    function getAmountCategory(uint256 amount) external pure returns (bytes32) { return keccak256(abi.encode(ResolutionTableLibrary.getAmountTier(amount))); }

    function queueEscalationConfig(uint8 level, EscalationConfig memory config) external onlyRole(ROLE_TIMELOCK) {
        require(level <= MAX_ROUND, "Invalid level");
        _pendingEscalationConfig[level] = PendingEscalationConfig({level: level, config: config, eta: uint64(block.timestamp + SLOW_DELAY), exists: true});
        emit EscalationConfigQueued(level, config, _pendingEscalationConfig[level].eta);
    }

    function activateEscalationConfig(uint8 level) external onlyRole(ROLE_TIMELOCK) {
        PendingEscalationConfig storage pending = _pendingEscalationConfig[level];
        if (!pending.exists || block.timestamp < pending.eta) revert NoPending();
        EscalationConfig memory old = escalationConfig[level]; escalationConfig[level] = pending.config;
        emit EscalationConfigActivated(level, old, pending.config); emit EscalationConfigUpdated(level, pending.config);
        delete _pendingEscalationConfig[level];
    }

    function getPendingEscalationConfig(uint8 level) public view returns (EscalationConfig memory config, uint64 eta, bool exists) {
        PendingEscalationConfig storage pending = _pendingEscalationConfig[level]; return (pending.config, pending.eta, pending.exists);
    }

    function setExternalResolver(address resolver) external onlyRole(ROLE_TIMELOCK) {
        externalResolver = resolver;
        if (resolver != address(0)) { escalationConfig[2].enabled = true; escalationConfig[2].resolver = resolver; }
        emit ExternalResolverUpdated(address(0), resolver);
    }

    function selectResolverRoundRobin(bytes32 category, bool useSenior) internal view returns (address) {
        address[] storage list = useSenior ? approvedSeniorResolvers : approvedResolvers;
        uint256 len = list.length; if (len == 0) return address(0);
        uint256 curIdx = useSenior ? categorySeniorResolverIndex[category] : categoryResolverIndex[category];
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
            
            if (resolverActive[cand] && (resolverCapacity[cand].maxConcurrentDisputes == 0 || resolverCapacity[cand].currentDisputes < resolverCapacity[cand].maxConcurrentDisputes)) return cand;
        }
        return address(0);
    }
    
    function selectResolverWithQuality(bytes32 category, bool useSenior) internal view returns (address) {
        address[] storage list = useSenior ? approvedSeniorResolvers : approvedResolvers;
        uint256 len = list.length; if (len == 0) return address(0);
        
        // Calculate total quality weight
        uint256 totalWeight = 0;
        uint256[] memory weights = new uint256[](len);
        address[] memory eligibleResolvers = new address[](len);
        uint256 eligibleCount = 0;
        
        for (uint256 i = 0; i < len; i++) {
            address resolver = list[i];
            if (!resolverActive[resolver]) continue;
            if (!resolverCapacity[resolver].acceptsNewDisputes) continue;
            if (resolverCapacity[resolver].maxConcurrentDisputes > 0 && 
                resolverCapacity[resolver].currentDisputes >= resolverCapacity[resolver].maxConcurrentDisputes) {
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
        uint256 random = uint256(keccak256(abi.encodePacked(blockHash, category, block.timestamp))) % totalWeight;
        
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
        if (useSenior) categorySeniorResolverIndex[category] = (categorySeniorResolverIndex[category] + 1) % len;
        else categoryResolverIndex[category] = (categoryResolverIndex[category] + 1) % len;
        emit RoundRobinCounterAdvanced(category, useSenior, 0);
    }

    function initializeDispute(uint256 workflowId, address resolver, bytes32 categoryKey) external onlyEscrowContract {
        DisputeMetadata storage dm = disputeMetadata[workflowId]; 
        require(dm.resolverAtRound[0] == address(0), "Already initialized");
        
        // Atomic capacity check and increment
        require(resolverActive[resolver], "Resolver inactive");
        ResolverCapacity storage capacity = resolverCapacity[resolver];
        require(capacity.acceptsNewDisputes, "Resolver not accepting new disputes");
        if (capacity.maxConcurrentDisputes > 0) {
            require(capacity.currentDisputes < capacity.maxConcurrentDisputes, "Resolver capacity exceeded");
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
            try incentiveModule.onResolverAssigned(workflowId, resolver, 0) {} 
            catch { emit IncentiveModuleCallFailed(workflowId, "onResolverAssigned", "FAILED"); } 
        }
    }

    function registerEscrowContract(address c) external onlyRole(ROLE_TIMELOCK) { registeredEscrowContracts[c] = true; emit EscrowContractRegistered(c); }
    function unregisterEscrowContract(address c) external onlyRole(ROLE_TIMELOCK) { registeredEscrowContracts[c] = false; emit EscrowContractUnregistered(c); }
    
    /**
     * @notice Mark escalation fee as paid for a dispute
     * @param workflowId The escrow transfer ID
     * @param fee The escalation fee amount paid
     * @dev Called by escrow contract after collecting escalation fee
     *      Must be called before executeEscalation() for fee-required escalations
     */
    function markEscalationFeePaid(uint256 workflowId, uint256 fee) external onlyEscrowContract {
        escalationFeePaid[workflowId] = true;
        emit EscalationFeePaid(workflowId, fee);
    }
    function setIncentiveModule(address m) external onlyRole(ROLE_TIMELOCK) { incentiveModule = IIncentiveModule(m); emit IncentiveModuleUpdated(address(0), m); }
    function setResolverActive(address r, bool a) external onlyRole(ROLE_TIMELOCK) { resolverActive[r] = a; emit ResolverActiveStatusChanged(r, a); }
    function decrementResolverActiveDisputes(address r) external onlyEscrowContract { if (resolverActiveDisputes[r] > 0) resolverActiveDisputes[r]--; if (resolverCapacity[r].currentDisputes > 0) resolverCapacity[r].currentDisputes--; }
    function setResolverCapacity(address r, uint256 m, bool a) external onlyRole(ROLE_TIMELOCK) { resolverCapacity[r].maxConcurrentDisputes = m; resolverCapacity[r].acceptsNewDisputes = a; emit ResolverCapacityUpdated(r, resolverCapacity[r]); }
    
    /**
     * @notice Set assignment weight for a resolver (DR v1)
     * @param resolver The resolver address
     * @param weight Assignment weight (0-10000 basis points, 0 = workload to zero)
     * @dev DR v1: Primary lever for performance-based routing. Weight=0 excludes resolver from selection.
     *      Weight is multiplied with quality score in quality-based selection.
     *      Default weight for new resolvers is 10000 (full weight).
     */
    function setResolverAssignmentWeight(address resolver, uint256 weight) external onlyRole(ROLE_TIMELOCK) {
        require(weight <= BASIS_POINTS_DENOMINATOR, "Weight exceeds max");
        require(resolver != address(0), "Zero address");
        
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
            revert("No timeout");
        }
        
        if (dm.status != DisputeStatus.Open) {
            revert("Not open");
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
            try incentiveModule.onResolverTimeout(workflowId, timedOutResolver, currentRound, 1) {}
            catch { emit IncentiveModuleCallFailed(workflowId, "onResolverTimeout", "FAILED"); }
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
            // Reassign within same round
            dm.resolverAtRound[currentRound] = newResolver;
            dm.assignedAt = block.timestamp;
            dm.resolveBy = block.timestamp + resolveDeadlines[currentRound];
            
            resolverStats[newResolver].casesAssigned++;
            
            emit ResolverAssigned(workflowId, newResolver, category, currentRound);
            
            if (address(incentiveModule) != address(0)) {
                try incentiveModule.onResolverAssigned(workflowId, newResolver, currentRound) {}
                catch { emit IncentiveModuleCallFailed(workflowId, "onResolverAssigned", "FAILED"); }
            }
        } else {
            // No suitable replacement, mark as timed out
            dm.status = DisputeStatus.Final;
        }
    }
    function setDisputeTimeout(uint256 t) external onlyRole(ROLE_TIMELOCK) { require(t > 0 && t <= MAX_DISPUTE_TIMEOUT, "T"); disputeTimeout = t; }
    
    /**
     * @notice Record a resolution decision (DR v1)
     * @param workflowId Dispute ID
     * @param resolver Resolver who made the decision
     * @param outcome Resolution outcome
     * @param resolutionTime Time taken to resolve (seconds)
     * @dev Updates EMA score, tracks decision in round-based metadata, calls incentive hooks
     */
    function recordResolution(uint256 workflowId, address resolver, ResolutionOutcome outcome, uint256 resolutionTime) external onlyEscrowContract {
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
            try incentiveModule.onDecisionSubmitted(workflowId, resolver, currentRound, outcome, resolutionTime) {}
            catch { emit IncentiveModuleCallFailed(workflowId, "onDecisionSubmitted", "FAILED"); }
        }
    }

    function getAverageResolutionTime(address resolver) external view returns (uint256) { return resolverStats[resolver].casesDecided > 0 ? resolverStats[resolver].totalResolutionTime / resolverStats[resolver].casesDecided : 0; }
    function getDisputeResolverStats(address r) external view returns (ResolverStats memory) { return resolverStats[r]; }
    function checkResolverNeedsAttention(address r) external view returns (bool, uint8) { return ResolutionAnalytics.checkResolverNeedsAttention(resolverStats[r], resolverActive[r]); }
    function selectResolverWithQuality(bytes32 cat, bool useSenior, bool useQual) external view returns (address) { 
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
    function getV1PhaseGateMetrics() external view returns (uint256 escalationRate, uint256 avgResponseTime, uint256 activeResolvers) {
        uint256 totalCases = 0;
        uint256 totalReversals = 0;
        uint256 totalResolutionTime = 0;
        uint256 totalResolutions = 0;
        uint256 totalTimeouts = 0;
        
        // Aggregate stats from all resolvers
        address[] memory allResolvers = new address[](approvedResolvers.length + approvedSeniorResolvers.length);
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
        escalationRate = totalCases > 0 ? (totalReversals * BASIS_POINTS_DENOMINATOR) / totalCases : 0;
        
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
        require(alphaBps <= BASIS_POINTS_DENOMINATOR, "Invalid alpha");
        require(minScoreThreshold <= ResolutionAnalytics.EMA_PRECISION, "Invalid threshold");
        require(maxTimeoutRate <= BASIS_POINTS_DENOMINATOR, "Invalid timeout rate");
        
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
            require(roundResolveDeadlines[i] > 0 && roundResolveDeadlines[i] <= MAX_DISPUTE_TIMEOUT, "Invalid resolve deadline");
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
    function recordReversal(
        uint256 workflowId,
        uint8 priorRound
    ) external onlyEscrowContract {
        DisputeMetadata storage dm = disputeMetadata[workflowId];
        
        require(priorRound < dm.currentRound, "Invalid round");
        require(dm.decisionAtRound[priorRound] != ResolutionOutcome.NONE, "No prior decision");
        require(dm.decisionAtRound[dm.currentRound] != ResolutionOutcome.NONE, "No current decision");
        
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
        }
    }

    // ============ DR v2 Governance Functions ============
    
    /**
     * @notice Queue escalation cost configuration (DR v2 - slow lane)
     * @param config Escalation cost curve configuration
     */
    function queueEscalationCostConfig(EscalationCostConfig memory config) external onlyRole(ROLE_TIMELOCK) {
        require(config.baseCost > 0 || !config.enabled, "Base cost must be > 0 if enabled");
        
        _pendingEscalationCostConfig = PendingEscalationCostConfig({
            config: config,
            eta: uint64(block.timestamp + SLOW_DELAY),
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
    function getPendingEscalationCostConfig() external view returns (
        EscalationCostConfig memory config,
        uint64 eta,
        bool exists
    ) {
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

    uint256[50] private __gap;
}
