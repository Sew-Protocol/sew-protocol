// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import "../interfaces/IResolutionModule.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "../governance/SlowLaneQueueActivate.sol";
import "./ResolverIncentiveModule.sol";

/**
 * @title DecentralizedResolutionModule
 * @notice Decentralized resolution module with resolver registries, escalation paths, and dynamic resolution table
 * @dev Implements full decentralized dispute resolution system as described in DISPUTE_RESOLUTION_IMPLEMENTATION_PLAN.md
 *      This module provides:
 *      - Resolver registry (standard resolvers appointed by senior resolvers)
 *      - Senior resolver registry (appointed by DAO/owner)
 *      - Escalation paths (resolver → senior resolver → external)
 *      - Dynamic resolution table (based on escrow characteristics)
 */
contract DecentralizedResolutionModule is AccessControl, ReentrancyGuard, IResolutionModule, SlowLaneQueueActivate {
    // Role constants for governance
    bytes32 public constant ROLE_TIMELOCK = keccak256("ROLE_TIMELOCK");
    // ============ Resolver Roles ============
    
    enum ResolverRole {
        NONE,           // 0 - Not a resolver
        RESOLVER,       // 1 - Standard resolver (appointed by senior resolver)
        SENIOR_RESOLVER,// 2 - Senior resolver (appointed by DAO/owner)
        EXTERNAL        // 3 - External resolver (e.g., Kleros)
    }
    
    // ============ State Variables ============
    
    // Resolver registries
    mapping(address => ResolverRole) public resolverRoles;
    mapping(address => bool) public isApprovedResolver;
    mapping(address => bool) public isApprovedSeniorResolver;
    address[] public approvedResolvers;
    address[] public approvedSeniorResolvers;
    
    // Resolver metadata
    struct ResolverMetadata {
        string name;
        string description;
        uint256 appointedAt;
        address appointedBy;
        bool active;
    }
    mapping(address => ResolverMetadata) public resolverMetadata;
    
    // Escalation tracking per dispute
    struct DisputeMetadata {
        address currentResolver;      // Current resolver assigned
        uint8 escalationLevel;        // Current escalation level (0 = initial, 1 = senior, 2 = external)
        address escalatedBy;          // Who escalated (if escalated)
        uint256 escalationTimestamp;  // When escalated
        bytes resolutionData;         // Additional resolution data
    }
    mapping(uint256 => DisputeMetadata) public disputeMetadata;
    
    // Escalation configuration
    struct EscalationConfig {
        address resolver;        // Resolver for this level (or address(0) for dynamic)
        uint256 fee;            // Fee required to escalate to this level
        bool enabled;           // Whether this level is enabled
    }
    mapping(uint8 => EscalationConfig) public escalationConfig;
    
    // Slow lane pending changes (Phase 3)
    struct PendingEscalationConfig {
        uint8 level;
        EscalationConfig config;
        uint64 eta;
        bool exists;
    }
    mapping(uint8 => PendingEscalationConfig) private _pendingEscalationConfig;
    
    // Resolution table
    struct ResolutionTableEntry {
        address initialResolver;      // Initial resolver for this category (deprecated - use round-robin)
        uint8 maxEscalationLevel;     // Maximum escalation level (0-2)
        uint256 escalationFee;        // Fee required for escalation
        bool enabled;                 // Whether this entry is active
        string categoryName;          // Human-readable category name
    }
    mapping(bytes32 => ResolutionTableEntry) public resolutionTable;
    mapping(uint256 => bytes32) public escrowCategory; // workflowId => category key
    
    // Round-robin counters for resolver selection (per category)
    mapping(bytes32 => uint256) public categoryResolverIndex; // Category => next resolver index
    mapping(bytes32 => uint256) public categorySeniorResolverIndex; // Category => next senior resolver index
    
    // External resolver (e.g., Kleros)
    address public externalResolver;
    
    // Registered escrow contracts that can call initializeDispute and setEscrowCategory
    mapping(address => bool) public registeredEscrowContracts;
    
    // Resolver incentive module (optional - for tracking resolver payments)
    ResolverIncentiveModule public incentiveModule;
    
    // ============ Events ============
    
    event ResolverAppointed(address indexed resolver, ResolverRole role, address indexed appointedBy);
    event ResolverRemoved(address indexed resolver, address indexed removedBy);
    event ResolverMetadataUpdated(address indexed resolver, ResolverMetadata metadata);
    event DisputeEscalated(
        uint256 indexed workflowId,
        uint8 fromLevel,
        uint8 toLevel,
        address indexed newResolver
    );
    event ResolutionTableEntrySet(bytes32 indexed categoryKey, ResolutionTableEntry entry);
    event ResolverAssigned(uint256 indexed workflowId, address indexed resolver, bytes32 category);
    event EscalationConfigUpdated(uint8 level, EscalationConfig config);
    event ExternalResolverUpdated(address indexed oldResolver, address indexed newResolver);
    event EscrowContractRegistered(address indexed escrowContract);
    event EscrowContractUnregistered(address indexed escrowContract);
    
    // Slow lane queue/activate events (Phase 3)
    event EscalationConfigQueued(uint8 level, EscalationConfig config, uint64 eta);
    event EscalationConfigActivated(uint8 level, EscalationConfig oldConfig, EscalationConfig newConfig);
    
    // Incentive module events
    event IncentiveModuleUpdated(address indexed oldModule, address indexed newModule);
    
    // ============ Modifiers ============
    
    modifier onlySeniorResolver() {
        require(isApprovedSeniorResolver[_msgSender()], "Not senior resolver");
        _;
    }
    
    modifier onlyResolver() {
        require(
            isApprovedResolver[_msgSender()] || isApprovedSeniorResolver[_msgSender()],
            "Not authorized resolver"
        );
        _;
    }
    
    modifier onlyEscrowContract() {
        require(registeredEscrowContracts[_msgSender()], "Not registered escrow contract");
        _;
    }
    
    // ============ Constructor ============
    
    constructor(address initialOwner) {
        // Grant DEFAULT_ADMIN_ROLE to initialOwner so roles can be granted later
        _grantRole(DEFAULT_ADMIN_ROLE, initialOwner);
        
        // Initialize escalation configs
        escalationConfig[0] = EscalationConfig({
            resolver: address(0), // Dynamic based on resolution table
            fee: 0,
            enabled: true
        });
        escalationConfig[1] = EscalationConfig({
            resolver: address(0), // Dynamic based on senior resolver registry
            fee: 0,
            enabled: true
        });
        escalationConfig[2] = EscalationConfig({
            resolver: address(0), // External resolver (Kleros)
            fee: 0,
            enabled: false // Disabled by default until external resolver is set
        });
    }
    
    // ============ Resolver Management ============
    
    /**
     * @notice Appoint a standard resolver (only senior resolvers can do this)
     * @param resolver Address of the resolver to appoint
     * @param name Resolver name/identifier
     * @param description Resolver description
     */
    function appointResolver(
        address resolver,
        string memory name,
        string memory description
    ) external onlySeniorResolver {
        require(resolver != address(0), "Zero address");
        require(!isApprovedResolver[resolver] && !isApprovedSeniorResolver[resolver], "Already a resolver");
        
        resolverRoles[resolver] = ResolverRole.RESOLVER;
        isApprovedResolver[resolver] = true;
        approvedResolvers.push(resolver);
        
        resolverMetadata[resolver] = ResolverMetadata({
            name: name,
            description: description,
            appointedAt: block.timestamp,
            appointedBy: _msgSender(),
            active: true
        });
        
        emit ResolverAppointed(resolver, ResolverRole.RESOLVER, _msgSender());
    }
    
    /**
     * @notice Appoint a senior resolver (only owner/DAO can do this)
     * @param resolver Address of the senior resolver to appoint
     * @param name Senior resolver name/identifier
     * @param description Senior resolver description
     */
    function appointSeniorResolver(
        address resolver,
        string memory name,
        string memory description
    ) external onlyRole(ROLE_TIMELOCK) {
        require(resolver != address(0), "Zero address");
        require(!isApprovedResolver[resolver] && !isApprovedSeniorResolver[resolver], "Already a resolver");
        
        resolverRoles[resolver] = ResolverRole.SENIOR_RESOLVER;
        isApprovedSeniorResolver[resolver] = true;
        approvedSeniorResolvers.push(resolver);
        
        resolverMetadata[resolver] = ResolverMetadata({
            name: name,
            description: description,
            appointedAt: block.timestamp,
            appointedBy: _msgSender(),
            active: true
        });
        
        emit ResolverAppointed(resolver, ResolverRole.SENIOR_RESOLVER, _msgSender());
    }
    
    /**
     * @notice Remove a standard resolver (only senior resolver who appointed or owner can do this)
     * @param resolver Address of the resolver to remove
     */
    function removeResolver(address resolver) external {
        require(isApprovedResolver[resolver], "Not a resolver");
        require(
            resolverMetadata[resolver].appointedBy == _msgSender() || hasRole(ROLE_TIMELOCK, _msgSender()),
            "Not authorized to remove"
        );
        
        resolverRoles[resolver] = ResolverRole.NONE;
        isApprovedResolver[resolver] = false;
        resolverMetadata[resolver].active = false;
        
        // Remove from array
        for (uint256 i = 0; i < approvedResolvers.length; i++) {
            if (approvedResolvers[i] == resolver) {
                approvedResolvers[i] = approvedResolvers[approvedResolvers.length - 1];
                approvedResolvers.pop();
                break;
            }
        }
        
        emit ResolverRemoved(resolver, _msgSender());
    }
    
    /**
     * @notice Remove a senior resolver (only owner can do this)
     * @param resolver Address of the senior resolver to remove
     */
    function removeSeniorResolver(address resolver) external onlyRole(ROLE_TIMELOCK) {
        require(isApprovedSeniorResolver[resolver], "Not a senior resolver");
        
        resolverRoles[resolver] = ResolverRole.NONE;
        isApprovedSeniorResolver[resolver] = false;
        resolverMetadata[resolver].active = false;
        
        // Remove from array
        for (uint256 i = 0; i < approvedSeniorResolvers.length; i++) {
            if (approvedSeniorResolvers[i] == resolver) {
                approvedSeniorResolvers[i] = approvedSeniorResolvers[approvedSeniorResolvers.length - 1];
                approvedSeniorResolvers.pop();
                break;
            }
        }
        
        emit ResolverRemoved(resolver, _msgSender());
    }
    
    /**
     * @notice Update resolver metadata
     * @param resolver Address of the resolver
     * @param name New name
     * @param description New description
     */
    function updateResolverMetadata(
        address resolver,
        string memory name,
        string memory description
    ) external {
        require(
            resolverMetadata[resolver].appointedBy == _msgSender() || hasRole(ROLE_TIMELOCK, _msgSender()),
            "Not authorized"
        );
        require(
            isApprovedResolver[resolver] || isApprovedSeniorResolver[resolver],
            "Not a resolver"
        );
        
        resolverMetadata[resolver].name = name;
        resolverMetadata[resolver].description = description;
        
        emit ResolverMetadataUpdated(resolver, resolverMetadata[resolver]);
    }
    
    // ============ View Functions ============
    
    /**
     * @notice Get all approved resolvers
     * @return Array of resolver addresses
     */
    function getApprovedResolvers() external view returns (address[] memory) {
        return approvedResolvers;
    }
    
    /**
     * @notice Get all approved senior resolvers
     * @return Array of senior resolver addresses
     */
    function getApprovedSeniorResolvers() external view returns (address[] memory) {
        return approvedSeniorResolvers;
    }
    
    /**
     * @notice Get resolver role
     * @param resolver Address to check
     * @return Role of the resolver
     */
    function getResolverRole(address resolver) external view returns (ResolverRole) {
        return resolverRoles[resolver];
    }
    
    /**
     * @notice Get dispute metadata
     * @param workflowId Escrow ID to check
     * @return Metadata for the dispute
     */
    function getDisputeMetadata(uint256 workflowId) external view returns (DisputeMetadata memory) {
        return disputeMetadata[workflowId];
    }
    
    // ============ IResolutionModule Implementation ============
    
    /**
     * @notice Check if an address is authorized to resolve a dispute
     * @param workflowId The escrow transfer ID
     * @param resolver The address attempting to resolve
     * @return authorized True if authorized
     * @return role The resolver role (0 = standard resolver, 1 = senior resolver, etc.)
     */
    function isAuthorizedResolver(
        uint256 workflowId,
        address resolver,
        bytes calldata /* escrowData */
    ) external view override returns (bool authorized, uint8 role) {
        DisputeMetadata memory dm = disputeMetadata[workflowId];
        
        // Check if resolver matches current resolver for this dispute
        if (resolver == dm.currentResolver) {
            return (true, dm.escalationLevel);
        }
        
        // Check if resolver is in approved list with appropriate role
        ResolverRole resolverRole = resolverRoles[resolver];
        uint8 requiredRole = dm.escalationLevel == 0 ? 
            uint8(ResolverRole.RESOLVER) : 
            uint8(ResolverRole.SENIOR_RESOLVER);
        
        bool isAuthorized = uint8(resolverRole) >= requiredRole && 
                           (isApprovedResolver[resolver] || isApprovedSeniorResolver[resolver]);
        
        return (isAuthorized, uint8(resolverRole));
    }
    
    /**
     * @notice Get the appropriate resolver for a dispute
     * @param workflowId The escrow transfer ID
     * @return resolver The resolver address
     * @return escalationLevel Current escalation level (0 = initial, 1+ = escalated)
     */
    function getResolver(
        uint256 workflowId,
        bytes calldata /* escrowData */
    ) external view override returns (address resolver, uint8 escalationLevel) {
        DisputeMetadata memory dm = disputeMetadata[workflowId];
        
        // If dispute metadata exists, return current resolver
        if (dm.currentResolver != address(0)) {
            return (dm.currentResolver, dm.escalationLevel);
        }
        
        // Determine resolver using round-robin selection
        bytes32 category = escrowCategory[workflowId];
        if (category != bytes32(0)) {
            ResolutionTableEntry memory entry = resolutionTable[category];
            if (entry.enabled) {
                // Use round-robin selection for this category
                address selectedResolver = selectResolverRoundRobin(category, false);
                if (selectedResolver != address(0)) {
                    return (selectedResolver, 0);
                }
            }
        }
        
        // Fallback: use round-robin from default category (empty category)
        if (approvedResolvers.length > 0) {
            address selectedResolver = selectResolverRoundRobin(bytes32(0), false);
            if (selectedResolver != address(0)) {
                return (selectedResolver, 0);
            }
        }
        
        return (address(0), 0);
    }
    
    /**
     * @notice Check if escalation is allowed and get next resolver
     * @param workflowId The escrow transfer ID
     * @param currentLevel Current escalation level
     * @return allowed True if escalation is allowed
     * @return nextResolver Address of next resolver (address(0) if cannot escalate)
     * @return escalationFee Fee required for escalation (0 if none)
     */
    function canEscalate(
        uint256 workflowId,
        uint8 currentLevel,
        bytes calldata /* escrowData */
    ) external view override returns (
        bool allowed,
        address nextResolver,
        uint256 escalationFee
    ) {
        uint8 nextLevel = currentLevel + 1;
        
        // Check if next level exists
        if (nextLevel > 2) {
            return (false, address(0), 0);
        }
        
        EscalationConfig memory config = escalationConfig[nextLevel];
        if (!config.enabled) {
            return (false, address(0), 0);
        }
        
        // Determine next resolver using round-robin
        if (nextLevel == 1) {
            // Escalate to senior resolver - use round-robin
            bytes32 category = escrowCategory[workflowId];
            if (approvedSeniorResolvers.length > 0) {
                nextResolver = selectResolverRoundRobin(category, true); // true = senior resolvers
                if (nextResolver == address(0)) {
                    return (false, address(0), 0);
                }
            } else {
                return (false, address(0), 0);
            }
        } else if (nextLevel == 2) {
            // Escalate to external resolver
            nextResolver = externalResolver;
            if (nextResolver == address(0)) {
                return (false, address(0), 0);
            }
        } else {
            nextResolver = config.resolver;
        }
        
        return (true, nextResolver, config.fee);
    }
    
    /**
     * @notice Execute escalation to next level
     * @param workflowId The escrow transfer ID
     * @param escrowData Encoded escrow data (unused but required by interface)
     * @return success True if escalation was successful
     * @return newResolver Address of new resolver
     * @return newLevel New escalation level
     */
    function executeEscalation(
        uint256 workflowId,
        bytes calldata escrowData
    ) external override nonReentrant returns (
        bool success,
        address newResolver,
        uint8 newLevel
    ) {
        DisputeMetadata storage dm = disputeMetadata[workflowId];
        uint8 currentLevel = dm.escalationLevel;
        uint8 nextLevel = currentLevel + 1;
        
        // Check if escalation is allowed
        // Note: escalationFee is returned but recording is handled by escrow contract
        (bool allowed, address nextResolver, ) = this.canEscalate(
            workflowId,
            currentLevel,
            escrowData
        );
        
        if (!allowed || nextResolver == address(0)) {
            return (false, address(0), currentLevel);
        }
        
        // Update metadata
        dm.escalationLevel = nextLevel;
        dm.currentResolver = nextResolver;
        dm.escalatedBy = _msgSender();
        dm.escalationTimestamp = block.timestamp;
        
        // Advance round-robin counter for senior resolvers if escalating to level 1
        if (nextLevel == 1) {
            bytes32 category = escrowCategory[workflowId];
            advanceRoundRobinCounter(category, true);
        }
        
        emit DisputeEscalated(workflowId, currentLevel, nextLevel, nextResolver);
        
        // Record new resolver in incentive module (if configured)
        // Note: Escalation fee recording should be handled by escrow contract
        // (it has access to token address and can transfer fees)
        if (address(incentiveModule) != address(0)) {
            try incentiveModule.recordResolver(workflowId, nextResolver, nextLevel) {
                // Successfully recorded
            } catch {
                // Incentive module call failed, continue anyway
                // This is non-critical - payment tracking is optional
            }
        }
        
        return (true, nextResolver, nextLevel);
    }
    
    /**
     * @notice Get the module name/identifier
     * @return name The module name
     */
    function moduleName() external pure override returns (string memory name) {
        return "DecentralizedResolution";
    }
    
    // ============ Resolution Table Management ============
    
    /**
     * @notice Set resolution table entry (owner only)
     * @param categoryKey Category key (e.g., based on amount, type, location)
     * @param entry Resolution table entry
     */
    function setResolutionTableEntry(
        bytes32 categoryKey,
        ResolutionTableEntry memory entry
    ) external onlyRole(ROLE_TIMELOCK) {
        resolutionTable[categoryKey] = entry;
        emit ResolutionTableEntrySet(categoryKey, entry);
    }
    
    /**
     * @notice Get resolution table entry
     * @param categoryKey Category key
     * @return Entry for the category
     */
    function getResolutionTableEntry(bytes32 categoryKey) external view returns (ResolutionTableEntry memory) {
        return resolutionTable[categoryKey];
    }
    
    /**
     * @notice Set category for an escrow (called when escrow is created or dispute is raised)
     * @param workflowId Escrow ID
     * @param categoryKey Category key
     * @dev Only registered escrow contracts can call this
     */
    function setEscrowCategory(uint256 workflowId, bytes32 categoryKey) external onlyEscrowContract {
        escrowCategory[workflowId] = categoryKey;
    }
    
    /**
     * @notice Generate category key based on escrow characteristics
     * @param token Token address
     * @param amount Escrow amount
     * @param categoryType Category type string
     * @return Category key
     */
    function generateCategoryKey(
        address token,
        uint256 amount,
        string memory categoryType
    ) external pure returns (bytes32) {
        return keccak256(abi.encodePacked(token, amount, categoryType));
    }
    
    /**
     * @notice Get amount-based category
     * @param amount Escrow amount
     * @return Category key
     */
    function getAmountCategory(uint256 amount) external pure returns (bytes32) {
        if (amount < 1 ether) return keccak256("SMALL");
        if (amount < 10 ether) return keccak256("MEDIUM");
        if (amount < 100 ether) return keccak256("LARGE");
        return keccak256("VERY_LARGE");
    }
    
    // ============ Escalation Configuration ============
    
    /**
     * @notice Queue a new escalation configuration for a level (Slow lane: 7-day delay)
     * @param level Escalation level (0-2)
     * @param config Escalation configuration
     * @dev After 7 days, call activateEscalationConfig() to apply the change
     */
    function queueEscalationConfig(uint8 level, EscalationConfig memory config) external onlyRole(ROLE_TIMELOCK) {
        require(level <= 2, "Invalid level");
        _pendingEscalationConfig[level] = PendingEscalationConfig({
            level: level,
            config: config,
            eta: uint64(block.timestamp + SLOW_DELAY),
            exists: true
        });
        emit EscalationConfigQueued(level, config, _pendingEscalationConfig[level].eta);
    }

    /**
     * @notice Activate the queued escalation configuration
     * @param level Escalation level (0-2)
     * @dev Reverts if no pending change or 7-day delay has not elapsed
     */
    function activateEscalationConfig(uint8 level) external onlyRole(ROLE_TIMELOCK) {
        require(level <= 2, "Invalid level");
        PendingEscalationConfig storage pending = _pendingEscalationConfig[level];
        if (!pending.exists) {
            revert NoPending();
        }
        if (block.timestamp < pending.eta) {
            revert NotReady(pending.eta);
        }
        EscalationConfig memory oldConfig = escalationConfig[level];
        escalationConfig[level] = pending.config;
        emit EscalationConfigActivated(level, oldConfig, pending.config);
        emit EscalationConfigUpdated(level, pending.config);
        
        // Clear pending
        delete _pendingEscalationConfig[level];
    }

    /**
     * @notice Get pending escalation config change (if any)
     * @param level Escalation level (0-2)
     * @return config Pending config
     * @return eta Timestamp when activation is allowed
     * @return exists Whether a pending change exists
     */
    function getPendingEscalationConfig(uint8 level) public view returns (EscalationConfig memory config, uint64 eta, bool exists) {
        PendingEscalationConfig storage pending = _pendingEscalationConfig[level];
        return (pending.config, pending.eta, pending.exists);
    }
    
    /**
     * @notice Set external resolver (e.g., Kleros)
     * @param resolver External resolver address
     */
    function setExternalResolver(address resolver) external onlyRole(ROLE_TIMELOCK) {
        address oldResolver = externalResolver;
        externalResolver = resolver;
        
        // Enable level 2 if external resolver is set
        if (resolver != address(0)) {
            escalationConfig[2].enabled = true;
            escalationConfig[2].resolver = resolver;
        }
        
        emit ExternalResolverUpdated(oldResolver, resolver);
    }
    
    // ============ Internal Helper Functions ============
    
    /**
     * @notice Select resolver using round-robin algorithm
     * @param category Category key (bytes32(0) for default)
     * @param useSeniorResolvers If true, select from senior resolvers; otherwise from standard resolvers
     * @return selectedResolver Selected resolver address
     * @dev Round-robin selection ensures fair distribution across resolvers
     */
    function selectResolverRoundRobin(bytes32 category, bool useSeniorResolvers)
        internal view returns (address selectedResolver)
    {
        address[] memory resolverList = useSeniorResolvers ? approvedSeniorResolvers : approvedResolvers;
        
        if (resolverList.length == 0) {
            return address(0);
        }
        
        // Get current index for this category
        uint256 currentIndex = useSeniorResolvers 
            ? categorySeniorResolverIndex[category] 
            : categoryResolverIndex[category];
        
        // Select resolver at current index (round-robin)
        selectedResolver = resolverList[currentIndex % resolverList.length];
        
        return selectedResolver;
    }
    
    /**
     * @notice Advance round-robin counter for a category
     * @param category Category key (bytes32(0) for default)
     * @param useSeniorResolvers If true, advance senior resolver counter; otherwise standard resolver counter
     * @dev Called after resolver is selected to advance the counter for next selection
     */
    function advanceRoundRobinCounter(bytes32 category, bool useSeniorResolvers) internal {
        address[] memory resolverList = useSeniorResolvers ? approvedSeniorResolvers : approvedResolvers;
        
        if (resolverList.length == 0) {
            return;
        }
        
        if (useSeniorResolvers) {
            categorySeniorResolverIndex[category] = (categorySeniorResolverIndex[category] + 1) % resolverList.length;
        } else {
            categoryResolverIndex[category] = (categoryResolverIndex[category] + 1) % resolverList.length;
        }
    }
    
    /**
     * @notice Initialize dispute metadata (called when dispute is raised)
     * @param workflowId Escrow ID
     * @param resolver Initial resolver
     * @param categoryKey Category key
     * @dev Only registered escrow contracts can call this
     */
    function initializeDispute(
        uint256 workflowId,
        address resolver,
        bytes32 categoryKey
    ) external onlyEscrowContract {
        DisputeMetadata storage dm = disputeMetadata[workflowId];
        require(dm.currentResolver == address(0), "Dispute already initialized");
        require(resolver != address(0), "Zero resolver");
        
        dm.currentResolver = resolver;
        dm.escalationLevel = 0;
        escrowCategory[workflowId] = categoryKey;
        
        // Advance round-robin counter for this category
        advanceRoundRobinCounter(categoryKey, false);
        
        emit ResolverAssigned(workflowId, resolver, categoryKey);
        
        // Record resolver in incentive module (if configured)
        if (address(incentiveModule) != address(0)) {
            try incentiveModule.recordResolver(workflowId, resolver, 0) {
                // Successfully recorded
            } catch {
                // Incentive module call failed, continue anyway
                // This is non-critical - payment tracking is optional
            }
        }
    }
    
    /**
     * @notice Register an escrow contract to allow it to call initializeDispute and setEscrowCategory
     * @param escrowContract Address of the escrow contract
     * @dev Only ROLE_TIMELOCK can register escrow contracts
     */
    function registerEscrowContract(address escrowContract) external onlyRole(ROLE_TIMELOCK) {
        require(escrowContract != address(0), "Zero address");
        require(!registeredEscrowContracts[escrowContract], "Already registered");
        
        registeredEscrowContracts[escrowContract] = true;
        emit EscrowContractRegistered(escrowContract);
    }
    
    /**
     * @notice Unregister an escrow contract
     * @param escrowContract Address of the escrow contract
     * @dev Only ROLE_TIMELOCK can unregister escrow contracts
     */
    function unregisterEscrowContract(address escrowContract) external onlyRole(ROLE_TIMELOCK) {
        require(registeredEscrowContracts[escrowContract], "Not registered");
        
        registeredEscrowContracts[escrowContract] = false;
        emit EscrowContractUnregistered(escrowContract);
    }
    
    /**
     * @notice Check if an address is a registered escrow contract
     * @param escrowContract Address to check
     * @return True if registered
     */
    function isRegisteredEscrowContract(address escrowContract) external view returns (bool) {
        return registeredEscrowContracts[escrowContract];
    }
    
    // ============ Incentive Module Management ============
    
    /**
     * @notice Set the resolver incentive module
     * @param _incentiveModule Address of the incentive module (address(0) to disable)
     * @dev Only ROLE_TIMELOCK can set the incentive module
     */
    function setIncentiveModule(address _incentiveModule) external onlyRole(ROLE_TIMELOCK) {
        address oldModule = address(incentiveModule);
        incentiveModule = ResolverIncentiveModule(_incentiveModule);
        emit IncentiveModuleUpdated(oldModule, _incentiveModule);
    }
    
    /**
     * @notice Get the current incentive module address
     * @return Address of the incentive module (address(0) if not set)
     */
    function getIncentiveModule() external view returns (address) {
        return address(incentiveModule);
    }
}

