// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import './IBondTokenRegistry.sol';
import '../../shared/interfaces/IIncentiveModule.sol';
import './DecentralizedResolverStructs.sol';

/**
 * @title DRMStorageBase
 * @notice Shared storage layout for DecentralizedResolutionModule and DRMAdminFacet.
 * @dev CRITICAL: Both DRM and DRMAdminFacet must inherit this contract in the same
 *      linearization position so that all storage slots align perfectly for delegatecall.
 *      Never reorder, insert, or remove variables — append only.
 */
abstract contract DRMStorageBase is DecentralizedResolverStructs {
    // ============ Role Constants ============
    bytes32 public constant ROLE_TIMELOCK = keccak256('ROLE_TIMELOCK');
    bytes32 public constant ROLE_GUARDIAN = keccak256('ROLE_GUARDIAN');

    // ============ Protocol Constants ============
    uint8 public constant MAX_ROUND = 2;
    uint256 public constant BASIS_POINTS_DENOMINATOR = 10000;
    uint256 public constant DEFAULT_DISPUTE_TIMEOUT = 7 days;
    uint256 public constant MAX_DISPUTE_TIMEOUT = 365 days;
    uint256 public constant ACCEPT_DEADLINE = 30 minutes;

    // ============ EMA Parameters ============
    uint256 public emaAlphaBps = 1000;
    uint256 public minEmaScoreThreshold = 500000;
    uint256 public maxTimeoutRateBps = 3000;

    // ============ Timeout Configuration ============
    uint256[3] public resolveDeadlines;
    uint256[3] public appealWindows;

    // ============ DR v2: Escalation Cost Configuration ============
    EscalationCostConfig public escalationCostConfig;
    PendingEscalationCostConfig internal _pendingEscalationCostConfig;
    uint256 public minEscrowValueForEscalation;

    // ============ DR v2: Bond Token Registry ============
    IBondTokenRegistry public bondTokenRegistry;

    // ============ Resolver Registry ============
    mapping(address => ResolverRole) public resolverRoles;
    mapping(address => bool) public isApprovedResolver;
    mapping(address => bool) public isApprovedSeniorResolver;
    address[] public approvedResolvers;
    address[] public approvedSeniorResolvers;

    // ============ Resolver Metadata ============
    mapping(address => ResolverMetadata) public resolverMetadata;
    mapping(address => mapping(uint256 => DisputeMetadata)) public disputeMetadata;
    uint256 public disputeTimeout = DEFAULT_DISPUTE_TIMEOUT;

    // ============ Escalation Configuration ============
    mapping(uint8 => EscalationConfig) public escalationConfig;
    mapping(uint8 => PendingEscalationConfig) internal _pendingEscalationConfig;

    // ============ Resolution Table ============
    mapping(bytes32 => ResolutionTableEntry) public resolutionTable;
    mapping(address => mapping(uint256 => bytes32)) public escrowCategory;
    mapping(bytes32 => uint256) public categoryResolverIndex;
    mapping(bytes32 => uint256) public categorySeniorResolverIndex;

    // ============ Resolver Tracking ============
    mapping(address => bool) public resolverActive;
    mapping(address => uint256) public resolverLastActive;
    mapping(address => uint256) public resolverActiveDisputes;
    mapping(address => ResolverCapacity) public resolverCapacity;
    mapping(address => ResolverStats) public resolverStats;
    mapping(address => uint256) public resolverIndex;
    mapping(address => uint256) public seniorResolverIndex;

    // ============ Protocol ============
    address public externalResolver;
    mapping(address => bool) public registeredEscrowContracts;
    IIncentiveModule public incentiveModule;
    bool public newAssignmentsPaused;

    // ============ Admin Facet Pointer ============
    // Defined here (not in DRM) so layout is identical between DRM and DRMAdminFacet.
    // DRMAdminFacet never reads this slot; DRM uses it for delegatecall routing.
    address public adminFacet;
}
