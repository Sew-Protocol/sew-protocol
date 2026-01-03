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
    // ============ Constants ============
    
    uint8 public constant MAX_ESCALATION_LEVEL = 2;
    uint256 public constant BASIS_POINTS_DENOMINATOR = 10000;
    uint256 public constant DEFAULT_DISPUTE_TIMEOUT = 7 days;
    uint256 public constant MAX_DISPUTE_TIMEOUT = 365 days;
    uint8 public constant INITIAL_ESCALATION_LEVEL = 0;
    uint8 public constant SENIOR_ESCALATION_LEVEL = 1;
    uint8 public constant EXTERNAL_ESCALATION_LEVEL = 2;
    
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
        uint256 timeoutTimestamp;     // When dispute should auto-escalate (Phase 1: Task 1.3)
        bytes resolutionData;         // Additional resolution data
    }
    mapping(uint256 => DisputeMetadata) public disputeMetadata;
    
    // Dispute timeout configuration (Phase 1: Task 1.3)
    uint256 public disputeTimeout = DEFAULT_DISPUTE_TIMEOUT;
    
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
    
    // Resolver active status and tracking (Phase 1: Task 1.1)
    mapping(address => bool) public resolverActive; // Quick check if resolver is active
    mapping(address => uint256) public resolverLastActive; // Timestamp when resolver was last active
    mapping(address => uint256) public resolverActiveDisputes; // Count of active disputes per resolver
    
    // Resolver workload balancing (Phase 2: Task 2.1)
    struct ResolverCapacity {
        uint256 maxConcurrentDisputes;  // Maximum disputes resolver can handle
        uint256 currentDisputes;        // Current number of active disputes
        bool acceptsNewDisputes;        // Whether resolver accepts new disputes
    }
    mapping(address => ResolverCapacity) public resolverCapacity;
    
    // Resolver reputation and statistics (Phase 4: Task 4.1)
    struct ResolverStats {
        uint256 disputesResolved;           // Number of disputes successfully resolved
        uint256 disputesEscalated;          // Number of disputes escalated away from this resolver
        uint256 totalResolutionTime;        // Cumulative resolution time (for average calculation)
        uint256 lastResolutionTimestamp;    // Timestamp of last resolution
        uint256 qualityScore;               // Quality score (0-10000 basis points)
        uint256 totalDisputes;             // Total disputes handled (resolved + escalated)
    }
    mapping(address => ResolverStats) public resolverStats;
    
    // Resolver index mapping for O(1) removal (Phase 1: Task 1.2)
    mapping(address => uint256) public resolverIndex; // Resolver => index in approvedResolvers array
    mapping(address => uint256) public seniorResolverIndex; // Senior resolver => index in approvedSeniorResolvers array
    
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
    
    // Phase 1 improvements events
    event ResolverActiveStatusChanged(address indexed resolver, bool active);
    event ResolverSelectedWithRandomness(
        bytes32 indexed category,
        address indexed resolver,
        uint256 baseIndex,
        uint256 randomOffset,
        uint256 finalIndex
    );
    event IncentiveModuleCallFailed(uint256 indexed workflowId, string functionName, string reason);
    event RoundRobinCounterAdvanced(bytes32 indexed category, bool seniorResolvers, uint256 newIndex);
    
    // Phase 2 improvements events
    event ResolverCapacityUpdated(address indexed resolver, ResolverCapacity capacity);
    
    // Phase 4 improvements events
    event ResolverStatsUpdated(
        address indexed resolver,
        uint256 disputesResolved,
        uint256 disputesEscalated,
        uint256 qualityScore
    );
    
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
        
        // Set index for O(1) removal (Phase 1: Task 1.2)
        resolverIndex[resolver] = approvedResolvers.length;
        approvedResolvers.push(resolver);
        
        // Set as active by default (Phase 1: Task 1.1)
        resolverActive[resolver] = true;
        resolverLastActive[resolver] = block.timestamp;
        
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
        
        // Set index for O(1) removal (Phase 1: Task 1.2)
        seniorResolverIndex[resolver] = approvedSeniorResolvers.length;
        approvedSeniorResolvers.push(resolver);
        
        // Set as active by default (Phase 1: Task 1.1)
        resolverActive[resolver] = true;
        resolverLastActive[resolver] = block.timestamp;
        
        // Initialize capacity with defaults (Phase 2: Task 2.1)
        resolverCapacity[resolver] = ResolverCapacity({
            maxConcurrentDisputes: 0, // 0 = unlimited by default
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
        
        // Check if resolver has active disputes (Phase 1: Task 1.6)
        require(
            resolverActiveDisputes[resolver] == 0,
            "Resolver has active disputes"
        );
        
        resolverRoles[resolver] = ResolverRole.NONE;
        isApprovedResolver[resolver] = false;
        resolverMetadata[resolver].active = false;
        resolverActive[resolver] = false; // Mark as inactive (Phase 1: Task 1.1)
        
        // O(1) removal using index mapping (Phase 1: Task 1.2)
        uint256 index = resolverIndex[resolver];
        uint256 lastIndex = approvedResolvers.length - 1;
        
        if (index != lastIndex) {
            address lastResolver = approvedResolvers[lastIndex];
            approvedResolvers[index] = lastResolver;
            resolverIndex[lastResolver] = index;
        }
        
        approvedResolvers.pop();
        delete resolverIndex[resolver];
        
        emit ResolverRemoved(resolver, _msgSender());
    }
    
    /**
     * @notice Remove a senior resolver (only owner can do this)
     * @param resolver Address of the senior resolver to remove
     */
    function removeSeniorResolver(address resolver) external onlyRole(ROLE_TIMELOCK) {
        require(isApprovedSeniorResolver[resolver], "Not a senior resolver");
        
        // Check if resolver has active disputes (Phase 1: Task 1.6)
        require(
            resolverActiveDisputes[resolver] == 0,
            "Resolver has active disputes"
        );
        
        resolverRoles[resolver] = ResolverRole.NONE;
        isApprovedSeniorResolver[resolver] = false;
        resolverMetadata[resolver].active = false;
        resolverActive[resolver] = false; // Mark as inactive (Phase 1: Task 1.1)
        
        // O(1) removal using index mapping (Phase 1: Task 1.2)
        uint256 index = seniorResolverIndex[resolver];
        uint256 lastIndex = approvedSeniorResolvers.length - 1;
        
        if (index != lastIndex) {
            address lastResolver = approvedSeniorResolvers[lastIndex];
            approvedSeniorResolvers[index] = lastResolver;
            seniorResolverIndex[lastResolver] = index;
        }
        
        approvedSeniorResolvers.pop();
        delete seniorResolverIndex[resolver];
        
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
     * @return success True if escalation was successful
     * @return newResolver Address of new resolver
     * @return newLevel New escalation level
     * @dev Phase 1: Inlined canEscalate logic to save gas (~2100 gas per escalation)
     */
    function executeEscalation(
        uint256 workflowId,
        bytes calldata /* escrowData */
    ) external override nonReentrant returns (
        bool success,
        address newResolver,
        uint8 newLevel
    ) {
        DisputeMetadata storage dm = disputeMetadata[workflowId];
        uint8 currentLevel = dm.escalationLevel;
        uint8 nextLevel = currentLevel + 1;
        
        // Inline escalation check instead of external call (Phase 1: Task 1.3)
        if (nextLevel > MAX_ESCALATION_LEVEL) {
            return (false, address(0), currentLevel);
        }
        
        EscalationConfig memory config = escalationConfig[nextLevel];
        if (!config.enabled) {
            return (false, address(0), 0);
        }
        
        // Determine next resolver (inline logic from canEscalate)
        address nextResolver;
        if (nextLevel == SENIOR_ESCALATION_LEVEL) {
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
        } else if (nextLevel == EXTERNAL_ESCALATION_LEVEL) {
            // Escalate to external resolver
            nextResolver = externalResolver;
            if (nextResolver == address(0)) {
                return (false, address(0), 0);
            }
        } else {
            nextResolver = config.resolver;
        }
        
        // Update metadata
        dm.escalationLevel = nextLevel;
        dm.currentResolver = nextResolver;
        dm.escalatedBy = _msgSender();
        dm.escalationTimestamp = block.timestamp;
        
        // Advance round-robin counter for senior resolvers if escalating to level 1
        if (nextLevel == SENIOR_ESCALATION_LEVEL) {
            bytes32 category = escrowCategory[workflowId];
            advanceRoundRobinCounter(category, true);
        }
        
        emit DisputeEscalated(workflowId, currentLevel, nextLevel, nextResolver);
        
        // Record new resolver in incentive module (if configured) with improved error handling (Phase 1: Task 1.7)
        if (address(incentiveModule) != address(0)) {
            try incentiveModule.recordResolver(workflowId, nextResolver, nextLevel) {
                // Successfully recorded
            } catch Error(string memory reason) {
                emit IncentiveModuleCallFailed(workflowId, "recordResolver", reason);
            } catch (bytes memory) {
                emit IncentiveModuleCallFailed(workflowId, "recordResolver", "Low-level error");
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
        // Use abi.encode instead of abi.encodePacked for better collision resistance (Phase 1: Task 1.9)
        return keccak256(abi.encode(token, amount, categoryType));
    }
    
    /**
     * @notice Auto-categorize escrow based on token and amount
     * @param escrowData Encoded escrow data (token, sender, recipient, amount, etc.)
     * @return category Category key
     * @dev Phase 2: Task 2.3 - Automatic categorization
     *      Returns bytes32(0) if data cannot be decoded
     */
    function autoCategorizeEscrow(bytes calldata escrowData) 
        public pure returns (bytes32) 
    {
        // Try to decode escrow data
        // Expected format: (address token, address sender, address recipient, uint256 amount, ...)
        // Minimum length: 4 * 32 bytes = 128 bytes
        if (escrowData.length < 128) {
            return bytes32(0);
        }
        
        // Attempt to decode - will revert if format is wrong, but that's acceptable
        // since this is a view function and escrow contracts should provide valid data
        (address token, , , uint256 amount, ) = abi.decode(
            escrowData, 
            (address, address, address, uint256, uint256)
        );
        
        // Generate category based on amount tier and token
        string memory tier = getAmountTier(amount);
        return keccak256(abi.encode(token, tier));
    }
    
    /**
     * @notice Get amount tier based on value
     * @param amount Amount in token's smallest unit
     * @return tier Tier name (SMALL, MEDIUM, LARGE, VERY_LARGE)
     * @dev Phase 2: Task 2.3 - Amount-based categorization
     */
    function getAmountTier(uint256 amount) public pure returns (string memory) {
        // Using 1e18 as reference (1 ETH or 1 token with 18 decimals)
        // Adjust thresholds based on actual use case
        if (amount < 1e18) {
            return "SMALL";
        } else if (amount < 10e18) {
            return "MEDIUM";
        } else if (amount < 100e18) {
            return "LARGE";
        } else {
            return "VERY_LARGE";
        }
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
        require(level <= MAX_ESCALATION_LEVEL, "Invalid level");
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
        require(level <= MAX_ESCALATION_LEVEL, "Invalid level");
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
            escalationConfig[EXTERNAL_ESCALATION_LEVEL].enabled = true;
            escalationConfig[EXTERNAL_ESCALATION_LEVEL].resolver = resolver;
        }
        
        emit ExternalResolverUpdated(oldResolver, resolver);
    }
    
    // ============ Internal Helper Functions ============
    
    /**
     * @notice Select resolver using round-robin algorithm with blockhash-based randomness
     * @param category Category key (bytes32(0) for default)
     * @param useSeniorResolvers If true, select from senior resolvers; otherwise from standard resolvers
     * @return selectedResolver Selected resolver address
     * @dev Round-robin selection with blockhash randomness prevents front-running
     *      Skips inactive resolvers automatically
     */
    function selectResolverRoundRobin(bytes32 category, bool useSeniorResolvers)
        internal view returns (address selectedResolver)
    {
        // Phase 3: Task 3.1 - Cache storage reads
        address[] storage resolverList = useSeniorResolvers ? approvedSeniorResolvers : approvedResolvers;
        uint256 listLength = resolverList.length;
        
        if (listLength == 0) {
            return address(0);
        }
        
        // Get current index for this category (single storage read)
        uint256 currentIndex = useSeniorResolvers 
            ? categorySeniorResolverIndex[category] 
            : categoryResolverIndex[category];
        
        // Blockhash-based randomness to prevent front-running (Phase 1: Task 1.4)
        uint256 blockHashValue = 0;
        if (block.number > 0) {
            // Use previous block's hash (available for last 256 blocks)
            blockHashValue = uint256(blockhash(block.number - 1));
        } else {
            // Fallback for block 0 (shouldn't happen in practice)
            blockHashValue = uint256(keccak256(abi.encodePacked(block.timestamp)));
        }
        
        // Combine multiple entropy sources for better randomness
        uint256 randomSeed = uint256(keccak256(abi.encodePacked(
            blockHashValue,        // Previous block hash
            category,              // Category-specific
            block.timestamp,       // Current timestamp
            currentIndex           // Current round-robin index
        )));
        
        // Generate random offset (0 to listLength - 1)
        uint256 randomOffset = randomSeed % listLength;
        
        // Try up to listLength times to find active resolver (Phase 1: Task 1.1)
        for (uint256 i = 0; i < listLength; i++) {
            uint256 index = (currentIndex + randomOffset + i) % listLength;
            address candidate = resolverList[index];
            
            // Check if resolver is active and approved
            if (resolverActive[candidate] && 
                (isApprovedResolver[candidate] || isApprovedSeniorResolver[candidate])) {
                
                // Check capacity (Phase 2: Task 2.1)
                // maxConcurrentDisputes = 0 means unlimited
                // If capacity struct is uninitialized (all zeros), treat as unlimited and accepting
                ResolverCapacity memory capacity = resolverCapacity[candidate];
                bool hasCapacity = (capacity.maxConcurrentDisputes == 0 || 
                                  capacity.currentDisputes < capacity.maxConcurrentDisputes);
                bool acceptsDisputes = capacity.acceptsNewDisputes || 
                                      (capacity.maxConcurrentDisputes == 0 && capacity.currentDisputes == 0);
                
                if (acceptsDisputes && hasCapacity) {
                    selectedResolver = candidate;
                    
                    // Note: Cannot emit event in view function
                    // Event will be emitted in initializeDispute when resolver is actually assigned
                    
                    return selectedResolver;
                }
                // If at capacity, continue to next resolver
            }
        }
        
        // No active resolvers found
        return address(0);
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
        
        uint256 newIndex;
        if (useSeniorResolvers) {
            newIndex = (categorySeniorResolverIndex[category] + 1) % resolverList.length;
            categorySeniorResolverIndex[category] = newIndex;
        } else {
            newIndex = (categoryResolverIndex[category] + 1) % resolverList.length;
            categoryResolverIndex[category] = newIndex;
        }
        
        // Emit event for transparency (Phase 1: Task 1.7)
        emit RoundRobinCounterAdvanced(category, useSeniorResolvers, newIndex);
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
        
        // Set timeout timestamp (Phase 1: Task 1.3)
        dm.timeoutTimestamp = block.timestamp + disputeTimeout;
        
        // Track active disputes (Phase 1: Task 1.6)
        resolverActiveDisputes[resolver]++;
        
        // Update resolver capacity tracking (Phase 2: Task 2.1)
        ResolverCapacity storage capacity = resolverCapacity[resolver];
        capacity.currentDisputes++;
        
        // Advance round-robin counter for this category
        advanceRoundRobinCounter(categoryKey, false);
        
        // Emit resolver selection event with randomness info (Phase 1: Task 1.4)
        // Note: Randomness details would need to be passed or stored if needed
        emit ResolverAssigned(workflowId, resolver, categoryKey);
        
        // Record resolver in incentive module (if configured) with improved error handling (Phase 1: Task 1.7)
        if (address(incentiveModule) != address(0)) {
            try incentiveModule.recordResolver(workflowId, resolver, 0) {
                // Successfully recorded
            } catch Error(string memory reason) {
                emit IncentiveModuleCallFailed(workflowId, "recordResolver", reason);
            } catch (bytes memory) {
                emit IncentiveModuleCallFailed(workflowId, "recordResolver", "Low-level error");
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
        // Allow zero address to disable, but validate if non-zero (Phase 1: Task 1.8)
        if (_incentiveModule != address(0)) {
            require(
                _incentiveModule.code.length > 0,
                "Not a contract"
            );
        }
        
        address oldModule = address(incentiveModule);
        incentiveModule = ResolverIncentiveModule(_incentiveModule);
        emit IncentiveModuleUpdated(oldModule, _incentiveModule);
    }
    
    /**
     * @notice Set resolver active status
     * @param resolver Resolver address
     * @param active True to activate, false to deactivate
     * @dev Only ROLE_TIMELOCK can set active status
     */
    function setResolverActive(address resolver, bool active) 
        external onlyRole(ROLE_TIMELOCK) 
    {
        require(
            isApprovedResolver[resolver] || isApprovedSeniorResolver[resolver],
            "Not a resolver"
        );
        
        resolverActive[resolver] = active;
        if (active) {
            resolverLastActive[resolver] = block.timestamp;
        }
        emit ResolverActiveStatusChanged(resolver, active);
    }
    
    /**
     * @notice Decrement active dispute count for a resolver
     * @param resolver Resolver address
     * @dev Called when dispute is resolved to track resolver workload
     */
    function decrementResolverActiveDisputes(address resolver) 
        external onlyEscrowContract 
    {
        if (resolverActiveDisputes[resolver] > 0) {
            resolverActiveDisputes[resolver]--;
        }
        
        // Update resolver capacity tracking (Phase 2: Task 2.1)
        ResolverCapacity storage capacity = resolverCapacity[resolver];
        if (capacity.currentDisputes > 0) {
            capacity.currentDisputes--;
        }
    }
    
    /**
     * @notice Set resolver capacity configuration
     * @param resolver Resolver address
     * @param maxConcurrentDisputes Maximum number of concurrent disputes (0 = unlimited)
     * @param acceptsNewDisputes Whether resolver accepts new disputes
     * @dev Only ROLE_TIMELOCK can set capacity
     */
    function setResolverCapacity(
        address resolver,
        uint256 maxConcurrentDisputes,
        bool acceptsNewDisputes
    ) external onlyRole(ROLE_TIMELOCK) {
        require(
            isApprovedResolver[resolver] || isApprovedSeniorResolver[resolver],
            "Not a resolver"
        );
        
        ResolverCapacity storage capacity = resolverCapacity[resolver];
        capacity.maxConcurrentDisputes = maxConcurrentDisputes;
        capacity.acceptsNewDisputes = acceptsNewDisputes;
        
        emit ResolverCapacityUpdated(resolver, capacity);
    }
    
    /**
     * @notice Check and auto-escalate dispute if timeout reached
     * @param workflowId The escrow transfer ID
     * @dev Can be called by anyone to trigger auto-escalation
     */
    function checkAndAutoEscalate(uint256 workflowId) external {
        DisputeMetadata storage dm = disputeMetadata[workflowId];
        
        require(dm.currentResolver != address(0), "No dispute");
        require(block.timestamp >= dm.timeoutTimestamp, "Not timed out");
        require(dm.escalationLevel < MAX_ESCALATION_LEVEL, "Max level reached");
        
        // Auto-escalate (use empty bytes for escrowData)
        bytes memory emptyEscrowData = "";
        this.executeEscalation(workflowId, emptyEscrowData);
    }
    
    /**
     * @notice Set dispute timeout duration
     * @param newTimeout New timeout duration in seconds
     * @dev Only ROLE_TIMELOCK can set timeout
     */
    function setDisputeTimeout(uint256 newTimeout) 
        external onlyRole(ROLE_TIMELOCK) 
    {
        require(newTimeout > 0, "Timeout must be > 0");
        require(newTimeout <= MAX_DISPUTE_TIMEOUT, "Timeout too long");
        
        disputeTimeout = newTimeout;
        emit DisputeTimeoutUpdated(newTimeout);
    }
    
    event DisputeTimeoutUpdated(uint256 newTimeout);
    
    /**
     * @notice Get the current incentive module address
     * @return Address of the incentive module (address(0) if not set)
     */
    function getIncentiveModule() external view returns (address) {
        return address(incentiveModule);
    }
    
    // ============ Phase 4: Resolver Reputation System ============
    
    /**
     * @notice Record resolution outcome for a resolver
     * @param resolver Resolver address
     * @param wasEscalated True if dispute was escalated away from this resolver, false if resolved
     * @param resolutionTime Time taken to resolve (in seconds, 0 if escalated)
     * @dev Phase 4: Task 4.1 - Track resolver performance and calculate quality scores
     *      Called by escrow contract when dispute is resolved or escalated
     */
    function recordResolution(
        uint256 /* workflowId */,
        address resolver,
        bool wasEscalated,
        uint256 resolutionTime
    ) external onlyEscrowContract {
        require(resolver != address(0), "Zero resolver");
        require(
            isApprovedResolver[resolver] || isApprovedSeniorResolver[resolver],
            "Not a resolver"
        );
        
        ResolverStats storage stats = resolverStats[resolver];
        
        if (wasEscalated) {
            stats.disputesEscalated++;
        } else {
            stats.disputesResolved++;
            if (resolutionTime > 0) {
                stats.totalResolutionTime += resolutionTime;
            }
            stats.lastResolutionTimestamp = block.timestamp;
        }
        
        stats.totalDisputes = stats.disputesResolved + stats.disputesEscalated;
        
        // Calculate quality score (0-10000 basis points)
        // Quality = (resolved / total) * 10000
        // Higher score = better resolver
        if (stats.totalDisputes > 0) {
            stats.qualityScore = (stats.disputesResolved * BASIS_POINTS_DENOMINATOR) / stats.totalDisputes;
        } else {
            stats.qualityScore = 0;
        }
        
        emit ResolverStatsUpdated(
            resolver,
            stats.disputesResolved,
            stats.disputesEscalated,
            stats.qualityScore
        );
    }
    
    /**
     * @notice Get average resolution time for a resolver
     * @param resolver Resolver address
     * @return averageTime Average resolution time in seconds (0 if no resolutions)
     * @dev Phase 4: Task 4.1 - Helper function for reputation system
     */
    function getAverageResolutionTime(address resolver) 
        external view returns (uint256 averageTime) 
    {
        ResolverStats memory stats = resolverStats[resolver];
        if (stats.disputesResolved > 0) {
            return stats.totalResolutionTime / stats.disputesResolved;
        }
        return 0;
    }
    
    /**
     * @notice Get resolver statistics
     * @param resolver Resolver address
     * @return stats Complete resolver statistics
     * @dev Phase 4: Task 4.1 - Get all stats for a resolver
     */
    function getResolverStats(address resolver) 
        external view returns (ResolverStats memory stats) 
    {
        return resolverStats[resolver];
    }
    
    // ============ Phase 5: Integration & Advanced Features ============
    
    /**
     * @notice Select resolver with quality-based weighting (optional)
     * @param category Category key
     * @param useSeniorResolvers If true, select from senior resolvers
     * @param useQualityWeighting If true, weight selection by quality score
     * @return selectedResolver Selected resolver address
     * @dev Phase 5: Task 5.4 - Quality-based selection using reputation system
     *      Falls back to round-robin if quality weighting disabled or no stats available
     */
    function selectResolverWithQuality(
        bytes32 category,
        bool useSeniorResolvers,
        bool useQualityWeighting
    ) external view returns (address selectedResolver) {
        // If quality weighting disabled, use standard round-robin
        if (!useQualityWeighting) {
            return selectResolverRoundRobin(category, useSeniorResolvers);
        }
        
        address[] memory resolverList = useSeniorResolvers ? approvedSeniorResolvers : approvedResolvers;
        
        if (resolverList.length == 0) {
            return address(0);
        }
        
        // Calculate quality-weighted probabilities
        uint256[] memory weights = new uint256[](resolverList.length);
        uint256 totalWeight = 0;
        
        for (uint256 i = 0; i < resolverList.length; i++) {
            address candidate = resolverList[i];
            
            // Check if resolver is active and approved
            if (resolverActive[candidate] && 
                (isApprovedResolver[candidate] || isApprovedSeniorResolver[candidate])) {
                
                // Check capacity
                ResolverCapacity memory capacity = resolverCapacity[candidate];
                bool hasCapacity = (capacity.maxConcurrentDisputes == 0 || 
                                  capacity.currentDisputes < capacity.maxConcurrentDisputes);
                bool acceptsDisputes = capacity.acceptsNewDisputes || 
                                      (capacity.maxConcurrentDisputes == 0 && capacity.currentDisputes == 0);
                
                if (acceptsDisputes && hasCapacity) {
                    // Weight by quality score (0-10000), minimum weight of 1000 for active resolvers
                    ResolverStats memory stats = resolverStats[candidate];
                    uint256 qualityWeight = stats.qualityScore > 0 ? stats.qualityScore : 5000; // Default to 50% if no stats
                    weights[i] = qualityWeight;
                    totalWeight += qualityWeight;
                }
            }
        }
        
        if (totalWeight == 0) {
            // Fallback to round-robin if no weighted resolvers available
            return selectResolverRoundRobin(category, useSeniorResolvers);
        }
        
        // Use blockhash for randomness
        uint256 blockHashValue = 0;
        if (block.number > 0) {
            blockHashValue = uint256(blockhash(block.number - 1));
        } else {
            blockHashValue = uint256(keccak256(abi.encodePacked(block.timestamp)));
        }
        
        uint256 randomSeed = uint256(keccak256(abi.encodePacked(
            blockHashValue,
            category,
            block.timestamp
        )));
        
        // Select resolver based on weighted probability
        uint256 randomValue = randomSeed % totalWeight;
        uint256 cumulativeWeight = 0;
        
        for (uint256 i = 0; i < resolverList.length; i++) {
            if (weights[i] > 0) {
                cumulativeWeight += weights[i];
                if (randomValue < cumulativeWeight) {
                    return resolverList[i];
                }
            }
        }
        
        // Fallback (shouldn't reach here)
        return selectResolverRoundRobin(category, useSeniorResolvers);
    }
    
    /**
     * @notice Helper function to initialize dispute with auto-categorization
     * @param workflowId The escrow transfer ID
     * @param escrowData Encoded escrow data for auto-categorization
     * @return resolver Selected resolver address
     * @return category Category key used
     * @dev Phase 5: Task 5.2 - Integration helper for escrow contracts
     *      Automatically categorizes and initializes dispute in one call
     */
    function initializeDisputeWithCategory(
        uint256 workflowId,
        bytes calldata escrowData
    ) external onlyEscrowContract returns (address resolver, bytes32 category) {
        // Auto-categorize if data provided
        if (escrowData.length > 0) {
            category = autoCategorizeEscrow(escrowData);
            if (category != bytes32(0)) {
                escrowCategory[workflowId] = category;
            }
        } else {
            category = escrowCategory[workflowId];
        }
        
        // Get resolver for this category
        (resolver, ) = this.getResolver(workflowId, escrowData);
        
        require(resolver != address(0), "No resolver available");
        
        // Initialize dispute
        this.initializeDispute(workflowId, resolver, category);
        
        return (resolver, category);
    }
    
    // ============ Phase 6: Production Readiness & Analytics ============
    
    /**
     * @notice Get system-wide resolver performance metrics
     * @return totalResolvers Total number of active resolvers
     * @return totalSeniorResolvers Total number of senior resolvers
     * @return totalDisputesHandled Total disputes handled across all resolvers
     * @return averageQualityScore Average quality score across all resolvers
     * @dev Phase 6: Task 6.4 - System-wide analytics
     */
    function getSystemMetrics()
        external view returns (
            uint256 totalResolvers,
            uint256 totalSeniorResolvers,
            uint256 totalDisputesHandled,
            uint256 averageQualityScore
        )
    {
        totalResolvers = approvedResolvers.length;
        totalSeniorResolvers = approvedSeniorResolvers.length;
        
        uint256 totalDisputes = 0;
        uint256 totalQuality = 0;
        uint256 resolversWithStats = 0;
        
        // Aggregate stats from all resolvers
        for (uint256 i = 0; i < approvedResolvers.length; i++) {
            ResolverStats memory stats = resolverStats[approvedResolvers[i]];
            if (stats.totalDisputes > 0) {
                totalDisputes += stats.totalDisputes;
                totalQuality += stats.qualityScore;
                resolversWithStats++;
            }
        }
        
        for (uint256 i = 0; i < approvedSeniorResolvers.length; i++) {
            ResolverStats memory stats = resolverStats[approvedSeniorResolvers[i]];
            if (stats.totalDisputes > 0) {
                totalDisputes += stats.totalDisputes;
                totalQuality += stats.qualityScore;
                resolversWithStats++;
            }
        }
        
        totalDisputesHandled = totalDisputes;
        
        if (resolversWithStats > 0) {
            averageQualityScore = totalQuality / resolversWithStats;
        } else {
            averageQualityScore = 0;
        }
    }
    
    /**
     * @notice Get resolver performance ranking
     * @param limit Maximum number of resolvers to return
     * @return resolvers Array of resolver addresses (sorted by quality score)
     * @return scores Array of quality scores corresponding to resolvers
     * @dev Phase 6: Task 6.3 - Performance monitoring
     */
    function getTopResolversByQuality(uint256 limit)
        external view returns (
            address[] memory resolvers,
            uint256[] memory scores
        )
    {
        // Collect all resolvers with stats
        address[] memory allResolvers = new address[](approvedResolvers.length + approvedSeniorResolvers.length);
        uint256[] memory allScores = new uint256[](approvedResolvers.length + approvedSeniorResolvers.length);
        uint256 count = 0;
        
        // Add standard resolvers
        for (uint256 i = 0; i < approvedResolvers.length; i++) {
            address resolver = approvedResolvers[i];
            ResolverStats memory stats = resolverStats[resolver];
            if (stats.totalDisputes > 0) {
                allResolvers[count] = resolver;
                allScores[count] = stats.qualityScore;
                count++;
            }
        }
        
        // Add senior resolvers
        for (uint256 i = 0; i < approvedSeniorResolvers.length; i++) {
            address resolver = approvedSeniorResolvers[i];
            ResolverStats memory stats = resolverStats[resolver];
            if (stats.totalDisputes > 0) {
                allResolvers[count] = resolver;
                allScores[count] = stats.qualityScore;
                count++;
            }
        }
        
        // Simple bubble sort by quality score (descending)
        // For production, consider using a more efficient algorithm or off-chain sorting
        for (uint256 i = 0; i < count - 1; i++) {
            for (uint256 j = 0; j < count - i - 1; j++) {
                if (allScores[j] < allScores[j + 1]) {
                    // Swap scores
                    uint256 tempScore = allScores[j];
                    allScores[j] = allScores[j + 1];
                    allScores[j + 1] = tempScore;
                    
                    // Swap resolvers
                    address tempResolver = allResolvers[j];
                    allResolvers[j] = allResolvers[j + 1];
                    allResolvers[j + 1] = tempResolver;
                }
            }
        }
        
        // Return top N
        uint256 returnCount = count < limit ? count : limit;
        address[] memory topResolvers = new address[](returnCount);
        uint256[] memory topScores = new uint256[](returnCount);
        
        for (uint256 i = 0; i < returnCount; i++) {
            topResolvers[i] = allResolvers[i];
            topScores[i] = allScores[i];
        }
        
        return (topResolvers, topScores);
    }
    
    /**
     * @notice Check if resolver needs attention (low quality score or high escalation rate)
     * @param resolver Resolver address
     * @return needsAttention True if resolver needs review
     * @return reason Reason code (1 = low quality, 2 = high escalation rate, 3 = inactive)
     * @dev Phase 6: Task 6.3 - Performance monitoring and alerts
     */
    function checkResolverNeedsAttention(address resolver)
        external view returns (bool needsAttention, uint8 reason)
    {
        if (!resolverActive[resolver]) {
            return (true, 3); // Inactive
        }
        
        ResolverStats memory stats = resolverStats[resolver];
        
        if (stats.totalDisputes == 0) {
            return (false, 0); // No data yet
        }
        
        // Check for low quality score (< 50%)
        if (stats.qualityScore < 5000) {
            return (true, 1); // Low quality
        }
        
        // Check for high escalation rate (> 50% escalated)
        uint256 escalationRate = (stats.disputesEscalated * BASIS_POINTS_DENOMINATOR) / stats.totalDisputes;
        if (escalationRate > 5000) {
            return (true, 2); // High escalation rate
        }
        
        return (false, 0);
    }
}

