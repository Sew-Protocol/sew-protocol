// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import "../interfaces/IResolutionModule.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

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
contract DecentralizedResolutionModule is Ownable, ReentrancyGuard, IResolutionModule {
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
    
    // Resolution table
    struct ResolutionTableEntry {
        address initialResolver;      // Initial resolver for this category
        uint8 maxEscalationLevel;     // Maximum escalation level (0-2)
        uint256 escalationFee;        // Fee required for escalation
        bool enabled;                 // Whether this entry is active
        string categoryName;          // Human-readable category name
    }
    mapping(bytes32 => ResolutionTableEntry) public resolutionTable;
    mapping(uint256 => bytes32) public escrowCategory; // workflowId => category key
    
    // External resolver (e.g., Kleros)
    address public externalResolver;
    
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
    
    // ============ Constructor ============
    
    constructor(address initialOwner) Ownable(initialOwner) {
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
    ) external onlyOwner {
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
            resolverMetadata[resolver].appointedBy == _msgSender() || _msgSender() == owner(),
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
    function removeSeniorResolver(address resolver) external onlyOwner {
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
            resolverMetadata[resolver].appointedBy == _msgSender() || _msgSender() == owner(),
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
        
        // Otherwise, determine resolver from resolution table or escrow data
        bytes32 category = escrowCategory[workflowId];
        if (category != bytes32(0)) {
            ResolutionTableEntry memory entry = resolutionTable[category];
            if (entry.enabled && entry.initialResolver != address(0)) {
                return (entry.initialResolver, 0);
            }
        }
        
        // Fallback: use first available resolver or return address(0)
        if (approvedResolvers.length > 0) {
            return (approvedResolvers[0], 0);
        }
        
        return (address(0), 0);
    }
    
    /**
     * @notice Check if escalation is allowed and get next resolver
     * @param currentLevel Current escalation level
     * @return allowed True if escalation is allowed
     * @return nextResolver Address of next resolver (address(0) if cannot escalate)
     * @return escalationFee Fee required for escalation (0 if none)
     */
    function canEscalate(
        uint256 /* workflowId */,
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
        
        // Determine next resolver
        if (nextLevel == 1) {
            // Escalate to senior resolver
            if (approvedSeniorResolvers.length > 0) {
                nextResolver = approvedSeniorResolvers[0]; // Use first available, or implement selection logic
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
        
        emit DisputeEscalated(workflowId, currentLevel, nextLevel, nextResolver);
        
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
    ) external onlyOwner {
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
     */
    function setEscrowCategory(uint256 workflowId, bytes32 categoryKey) external {
        // In production, this should be restricted to the escrow contract
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
     * @notice Set escalation configuration for a level
     * @param level Escalation level (0-2)
     * @param config Escalation configuration
     */
    function setEscalationConfig(uint8 level, EscalationConfig memory config) external onlyOwner {
        require(level <= 2, "Invalid level");
        escalationConfig[level] = config;
        emit EscalationConfigUpdated(level, config);
    }
    
    /**
     * @notice Set external resolver (e.g., Kleros)
     * @param resolver External resolver address
     */
    function setExternalResolver(address resolver) external onlyOwner {
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
     * @notice Initialize dispute metadata (called when dispute is raised)
     * @param workflowId Escrow ID
     * @param resolver Initial resolver
     * @param categoryKey Category key
     * @dev Can be called by escrow contract or owner for initialization
     */
    function initializeDispute(
        uint256 workflowId,
        address resolver,
        bytes32 categoryKey
    ) external {
        DisputeMetadata storage dm = disputeMetadata[workflowId];
        require(dm.currentResolver == address(0), "Dispute already initialized");
        require(resolver != address(0), "Zero resolver");
        
        dm.currentResolver = resolver;
        dm.escalationLevel = 0;
        escrowCategory[workflowId] = categoryKey;
        
        emit ResolverAssigned(workflowId, resolver, categoryKey);
    }
}

