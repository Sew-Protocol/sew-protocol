// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.33;

import "../shared/interfaces/IResolutionModule.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/introspection/ERC165Upgradeable.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import "../shared/governance/SlowLaneQueueActivateUpgradeable.sol";
import "./ResolverIncentiveModule.sol";
import "./DecentralizedResolverStructs.sol";
import "./ResolutionAnalytics.sol";
import "../libraries/ResolutionTableLibrary.sol";

/**
 * @title DecentralizedResolutionModule
 * @notice Optimized decentralized resolution module with externalized analytics and table logic
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
    uint8 public constant MAX_ESCALATION_LEVEL = 2;
    uint256 public constant BASIS_POINTS_DENOMINATOR = 10000;
    uint256 public constant DEFAULT_DISPUTE_TIMEOUT = 7 days;
    uint256 public constant MAX_DISPUTE_TIMEOUT = 365 days;
    
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
    ResolverIncentiveModule public incentiveModule;

    event ResolverAppointed(address indexed resolver, ResolverRole role, address indexed appointedBy);
    event ResolverRemoved(address indexed resolver, address indexed removedBy);
    event ResolverMetadataUpdated(address indexed resolver, ResolverMetadata metadata);
    event DisputeEscalated(uint256 indexed workflowId, uint8 fromLevel, uint8 toLevel, address indexed newResolver);
    event ResolutionTableEntrySet(bytes32 indexed categoryKey, ResolutionTableEntry entry);
    event ResolverAssigned(uint256 indexed workflowId, address indexed resolver, bytes32 category);
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

    modifier onlySeniorResolver() { require(isApprovedSeniorResolver[_msgSender()], "Not senior resolver"); _; }
    modifier onlyResolver() { require(isApprovedResolver[_msgSender()] || isApprovedSeniorResolver[_msgSender()], "Not authorized resolver"); _; }
    modifier onlyEscrowContract() { require(registeredEscrowContracts[_msgSender()], "Not registered escrow contract"); _; }

    function initialize(address initialOwner) public initializer {
        __AccessControl_init(); __ReentrancyGuard_init(); __UUPSUpgradeable_init();
        _grantRole(DEFAULT_ADMIN_ROLE, initialOwner); _grantRole(ROLE_TIMELOCK, initialOwner);
        escalationConfig[0] = EscalationConfig({resolver: address(0), fee: 0, enabled: true});
        escalationConfig[1] = EscalationConfig({resolver: address(0), fee: 0, enabled: true});
        escalationConfig[2] = EscalationConfig({resolver: address(0), fee: 0, enabled: false});
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
        resolverMetadata[resolver] = ResolverMetadata({name: name, description: description, appointedAt: block.timestamp, appointedBy: _msgSender(), active: true});
        emit ResolverAppointed(resolver, ResolverRole.RESOLVER, _msgSender());
    }

    function appointSeniorResolver(address resolver, string memory name, string memory description) external onlyRole(ROLE_TIMELOCK) {
        require(resolver != address(0) && !isApprovedResolver[resolver] && !isApprovedSeniorResolver[resolver], "Invalid senior resolver");
        resolverRoles[resolver] = ResolverRole.SENIOR_RESOLVER; isApprovedSeniorResolver[resolver] = true;
        seniorResolverIndex[resolver] = approvedSeniorResolvers.length; approvedSeniorResolvers.push(resolver);
        resolverActive[resolver] = true; resolverLastActive[resolver] = block.timestamp;
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
        if (disputeResolver == dm.currentResolver) return (true, dm.escalationLevel);
        ResolverRole rRole = resolverRoles[disputeResolver];
        uint8 req = dm.escalationLevel == 0 ? uint8(ResolverRole.RESOLVER) : uint8(ResolverRole.SENIOR_RESOLVER);
        return (uint8(rRole) >= req && (isApprovedResolver[disputeResolver] || isApprovedSeniorResolver[disputeResolver]), uint8(rRole));
    }

    function getDisputeResolver(uint256 workflowId, bytes calldata) external view override returns (address disputeResolver, uint8 escalationLevel) {
        DisputeMetadata memory dm = disputeMetadata[workflowId];
        if (dm.currentResolver != address(0)) return (dm.currentResolver, dm.escalationLevel);
        bytes32 cat = escrowCategory[workflowId];
        if (cat != bytes32(0) && resolutionTable[cat].enabled) {
            address selected = selectResolverRoundRobin(cat, false);
            if (selected != address(0)) return (selected, 0);
        }
        return (selectResolverRoundRobin(bytes32(0), false), 0);
    }

    function canEscalate(uint256 workflowId, uint8 currentLevel, bytes calldata) external view override returns (bool allowed, address nextResolver, uint256 escalationFee) {
        uint8 nextLevel = currentLevel + 1;
        if (nextLevel > 2 || !escalationConfig[nextLevel].enabled) return (false, address(0), 0);
        if (nextLevel == 1) nextResolver = selectResolverRoundRobin(escrowCategory[workflowId], true);
        else if (nextLevel == 2) nextResolver = externalResolver;
        return (nextResolver != address(0), nextResolver, escalationConfig[nextLevel].fee);
    }

    function executeEscalation(uint256 workflowId, bytes calldata) external override nonReentrant returns (bool success, address newResolver, uint8 newLevel) {
        DisputeMetadata storage dm = disputeMetadata[workflowId]; 
        uint8 nextLevel = dm.escalationLevel + 1;
        
        if (nextLevel > MAX_ESCALATION_LEVEL || !escalationConfig[nextLevel].enabled) {
            return (false, address(0), dm.escalationLevel);
        }
        
        // Verify escalation fee was paid (if required)
        uint256 requiredFee = escalationConfig[nextLevel].fee;
        if (requiredFee > 0) {
            // Escrow contract must mark fee as paid before calling executeEscalation()
            // This is done by calling markEscalationFeePaid() after collecting the fee
            require(escalationFeePaid[workflowId], "Escalation fee not paid");
            
            // Clear the flag after verification (prevents reuse)
            escalationFeePaid[workflowId] = false;
        }
        
        address nextRes;
        if (nextLevel == 1) {
            nextRes = selectResolverRoundRobin(escrowCategory[workflowId], true);
            if (nextRes != address(0)) advanceRoundRobinCounter(escrowCategory[workflowId], true);
        } else if (nextLevel == 2) {
            nextRes = externalResolver;
        }
        
        if (nextRes == address(0)) {
            return (false, address(0), dm.escalationLevel);
        }
        
        // Update dispute metadata
        dm.escalationLevel = nextLevel;
        dm.currentResolver = nextRes;
        dm.escalatedBy = _msgSender();
        dm.escalationTimestamp = block.timestamp;
        
        emit DisputeEscalated(workflowId, nextLevel - 1, nextLevel, nextRes);
        
        // Record resolver in incentive module
        if (address(incentiveModule) != address(0)) {
            try incentiveModule.recordResolver(workflowId, nextRes, nextLevel) {} 
            catch { emit IncentiveModuleCallFailed(workflowId, "recordResolver", "FAILED"); }
        }
        
        return (true, nextRes, nextLevel);
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
        require(level <= MAX_ESCALATION_LEVEL, "Invalid level");
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
            
            // Quality-based weight (minimum 50% to ensure fairness for new resolvers)
            ResolverStats memory stats = resolverStats[resolver];
            uint256 qualityScore = stats.totalDisputes > 0 ? stats.qualityScore : BASIS_POINTS_DENOMINATOR;
            uint256 weight = qualityScore > 0 ? qualityScore : BASIS_POINTS_DENOMINATOR / 2;
            
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
        require(dm.currentResolver == address(0), "Already initialized");
        
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
        
        // Initialize dispute metadata
        dm.currentResolver = resolver;
        dm.timeoutTimestamp = block.timestamp + disputeTimeout;
        escrowCategory[workflowId] = categoryKey;
        
        advanceRoundRobinCounter(categoryKey, false);
        emit ResolverAssigned(workflowId, resolver, categoryKey);
        
        if (address(incentiveModule) != address(0)) { 
            try incentiveModule.recordResolver(workflowId, resolver, 0) {} 
            catch { emit IncentiveModuleCallFailed(workflowId, "recordResolver", "FAILED"); } 
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
    function setIncentiveModule(address m) external onlyRole(ROLE_TIMELOCK) { incentiveModule = ResolverIncentiveModule(m); emit IncentiveModuleUpdated(address(0), m); }
    function setResolverActive(address r, bool a) external onlyRole(ROLE_TIMELOCK) { resolverActive[r] = a; emit ResolverActiveStatusChanged(r, a); }
    function decrementResolverActiveDisputes(address r) external onlyEscrowContract { if (resolverActiveDisputes[r] > 0) resolverActiveDisputes[r]--; if (resolverCapacity[r].currentDisputes > 0) resolverCapacity[r].currentDisputes--; }
    function setResolverCapacity(address r, uint256 m, bool a) external onlyRole(ROLE_TIMELOCK) { resolverCapacity[r].maxConcurrentDisputes = m; resolverCapacity[r].acceptsNewDisputes = a; emit ResolverCapacityUpdated(r, resolverCapacity[r]); }
    function checkAndAutoEscalate(uint256 workflowId) external { if (block.timestamp >= disputeMetadata[workflowId].timeoutTimestamp) this.executeEscalation(workflowId, ""); }
    function setDisputeTimeout(uint256 t) external onlyRole(ROLE_TIMELOCK) { require(t > 0 && t <= MAX_DISPUTE_TIMEOUT, "T"); disputeTimeout = t; }
    
    function recordResolution(uint256 workflowId, address resolver, ResolutionOutcome outcome, bool wasEscalated, uint256 resolutionTime) external onlyEscrowContract {
        DisputeMetadata storage dm = disputeMetadata[workflowId];
        resolverStats.recordResolution(workflowId, resolver, outcome, wasEscalated, resolutionTime, dm.escalationLevel, dm.lastResolver, dm.lastResolutionOutcome);
        dm.lastResolutionOutcome = outcome; dm.lastResolver = resolver;
    }

    function getAverageResolutionTime(address resolver) external view returns (uint256) { return resolverStats[resolver].disputesResolved > 0 ? resolverStats[resolver].totalResolutionTime / resolverStats[resolver].disputesResolved : 0; }
    function getDisputeResolverStats(address r) external view returns (ResolverStats memory) { return resolverStats[r]; }
    function checkResolverNeedsAttention(address r) external view returns (bool, uint8) { return resolverStats.checkResolverNeedsAttention(r, resolverActive[r]); }
    function selectResolverWithQuality(bytes32 cat, bool useSenior, bool useQual) external view returns (address) { 
        if (useQual) {
            return selectResolverWithQuality(cat, useSenior);
        }
        return selectResolverRoundRobin(cat, useSenior);
    }

    uint256[50] private __gap;
}
