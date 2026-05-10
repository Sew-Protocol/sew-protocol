// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import '@openzeppelin/contracts/access/AccessControl.sol';
import '@openzeppelin/contracts/utils/ReentrancyGuard.sol';
import '../../governance/SlowLaneQueueActivate.sol';
import '../../shared/interfaces/IIncentiveModule.sol';
import './DRMStorageBase.sol';
import './ResolutionAnalytics.sol';
import './EscalationCostLibrary.sol';
import '../../libraries/ResolutionTableLibrary.sol';

/**
 * @title DRMAdminFacet
 * @notice Admin and governance functions for DecentralizedResolutionModule.
 * @dev Deployed separately; called via delegatecall from DRM's fallback.
 *      Storage layout MUST match DRM exactly:
 *        SlowLaneQueueActivate → AccessControl → ReentrancyGuard → DRMStorageBase
 *      Never add state variables here — add to DRMStorageBase only.
 */
contract DRMAdminFacet is SlowLaneQueueActivate, AccessControl, ReentrancyGuard, DRMStorageBase {

    // ============ Errors ============
    error InvalidDisputeTimeout(uint256 timeout, uint256 minTimeout, uint256 maxTimeout);
    error NotSeniorResolver(address caller);
    error NotAuthorizedResolver(address caller);
    error InvalidLevel(uint8 level, uint8 maxLevel);
    error WeightExceedsMaximum(uint256 weight, uint256 maxWeight);
    error ZeroAddress(string field);
    error InvalidAlpha(uint256 alphaBps, uint256 maxAlpha);
    error InvalidThreshold(uint256 threshold, uint256 maxThreshold);
    error InvalidTimeoutRate(uint256 rate, uint256 maxRate);
    error InvalidBaseCost(uint256 baseCost, bool enabled);
    error NotAuthorized(address caller);
    error InvalidResolver(address resolver);
    error InvalidSeniorResolver(address resolver);
    error CannotRemoveResolver(address resolver, uint256 activeDisputes);
    error Unauthorized(address caller);
    error AlreadyPaused();
    error NotPaused();

    // ============ Events ============
    event AdminFacetUpdated(address indexed oldFacet, address indexed newFacet);
    event ResolverAppointed(address indexed resolver, ResolverRole role, address indexed appointedBy);
    event ResolverRemoved(address indexed resolver, address indexed removedBy);
    event ResolverMetadataUpdated(address indexed resolver, ResolverMetadata metadata);
    event DisputeEscalatedToRound(uint256 indexed workflowId, uint8 fromRound, uint8 toRound, address indexed newResolver);
    event ResolutionTableEntrySet(bytes32 indexed categoryKey, ResolutionTableEntry entry);
    event EscalationConfigUpdated(uint8 level, EscalationConfig config);
    event ExternalResolverUpdated(address indexed oldResolver, address indexed newResolver);
    event EscrowContractRegistered(address indexed escrowContract);
    event EscrowContractUnregistered(address indexed escrowContract);
    event EscalationConfigQueued(uint8 level, EscalationConfig config, uint64 eta);
    event EscalationConfigActivated(uint8 level, EscalationConfig oldConfig, EscalationConfig newConfig);
    event IncentiveModuleUpdated(address indexed oldModule, address indexed newModule);
    event ResolverActiveStatusChanged(address indexed resolver, bool active);
    event ResolverCapacityUpdated(address indexed resolver, ResolverCapacity capacity);
    event ResolverAssignmentWeightUpdated(address indexed resolver, uint256 oldWeight, uint256 newWeight);
    event EscalationCostConfigQueued(EscalationCostConfig config, uint64 eta);
    event EscalationCostConfigActivated(EscalationCostConfig oldConfig, EscalationCostConfig newConfig);
    event AppealBondRequired(uint256 indexed workflowId, uint8 round, uint256 amount, address token);
    event MinEscrowValueUpdated(uint256 oldValue, uint256 newValue);
    event BondTokenRegistryUpdated(address indexed oldRegistry, address indexed newRegistry);
    event NewAssignmentsPaused(address indexed pausedBy, string reason);
    event NewAssignmentsResumed(address indexed resumedBy);

    // ============ Modifiers ============
    modifier onlySeniorResolver() {
        if (!isApprovedSeniorResolver[_msgSender()]) revert NotSeniorResolver(_msgSender());
        _;
    }

    // ============ Admin Facet Management ============

    function setAdminFacet(address newFacet) external onlyRole(ROLE_TIMELOCK) {
        address old = adminFacet;
        adminFacet = newFacet;
        emit AdminFacetUpdated(old, newFacet);
    }

    // ============ Resolver Management ============

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
        // Appointer must still be an active senior resolver; demoted seniors lose this right
        if (resolverMetadata[resolver].appointedBy == _msgSender() && !isApprovedSeniorResolver[_msgSender()]) {
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

    function setResolverActive(address r, bool a) external onlyRole(ROLE_TIMELOCK) {
        resolverActive[r] = a;
        emit ResolverActiveStatusChanged(r, a);
    }

    function setResolverCapacity(address r, uint256 m, bool a) external onlyRole(ROLE_TIMELOCK) {
        resolverCapacity[r].maxConcurrentDisputes = m;
        resolverCapacity[r].acceptsNewDisputes = a;
        emit ResolverCapacityUpdated(r, resolverCapacity[r]);
    }

    function setResolverAssignmentWeight(address resolver, uint256 weight) external onlyRole(ROLE_TIMELOCK) {
        if (weight > BASIS_POINTS_DENOMINATOR) revert WeightExceedsMaximum(weight, BASIS_POINTS_DENOMINATOR);
        if (resolver == address(0)) revert ZeroAddress('resolver');
        uint256 oldWeight = resolverStats[resolver].assignmentWeight;
        resolverStats[resolver].assignmentWeight = weight;
        emit ResolverAssignmentWeightUpdated(resolver, oldWeight, weight);
    }

    function calculateAssignmentWeight(address resolver) external view returns (uint256) {
        return resolverStats[resolver].assignmentWeight;
    }

    // ============ EMA / Timeout Governance ============

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

    function setDisputeTimeout(uint256 t) external onlyRole(ROLE_TIMELOCK) {
        if (t == 0 || t > MAX_DISPUTE_TIMEOUT) {
            revert InvalidDisputeTimeout(t, 1, MAX_DISPUTE_TIMEOUT);
        }
        disputeTimeout = t;
    }

    // ============ Escalation Config Governance ============

    function queueEscalationConfig(uint8 level, EscalationConfig memory config) external onlyRole(ROLE_TIMELOCK) {
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
    ) external view returns (EscalationConfig memory config, uint64 eta, bool exists) {
        PendingEscalationConfig storage pending = _pendingEscalationConfig[level];
        return (pending.config, pending.eta, pending.exists);
    }

    // ============ DR v2 Escalation Cost Config ============

    function queueEscalationCostConfig(EscalationCostConfig memory config) external onlyRole(ROLE_TIMELOCK) {
        if (config.baseCost == 0 && config.enabled) revert InvalidBaseCost(config.baseCost, config.enabled);
        _pendingEscalationCostConfig = PendingEscalationCostConfig({
            config: config,
            eta: uint64(block.timestamp + SLOW_DELAY), // forge-lint: disable-line(unsafe-typecast)
            exists: true
        });
        emit EscalationCostConfigQueued(config, _pendingEscalationCostConfig.eta);
    }

    function activateEscalationCostConfig() external onlyRole(ROLE_TIMELOCK) {
        PendingEscalationCostConfig storage pending = _pendingEscalationCostConfig;
        if (!pending.exists || block.timestamp < pending.eta) revert NoPending();
        EscalationCostConfig memory oldConfig = escalationCostConfig;
        escalationCostConfig = pending.config;
        emit EscalationCostConfigActivated(oldConfig, pending.config);
        delete _pendingEscalationCostConfig;
    }

    function getPendingEscalationCostConfig()
        external
        view
        returns (EscalationCostConfig memory config, uint64 eta, bool exists)
    {
        PendingEscalationCostConfig storage pending = _pendingEscalationCostConfig;
        return (pending.config, pending.eta, pending.exists);
    }

    function setMinEscrowValueForEscalation(uint256 minValue) external onlyRole(ROLE_TIMELOCK) {
        uint256 oldValue = minEscrowValueForEscalation;
        minEscrowValueForEscalation = minValue;
        emit MinEscrowValueUpdated(oldValue, minValue);
    }

    // ============ External Resolver & Registry ============

    function setExternalResolver(address resolver) external onlyRole(ROLE_TIMELOCK) {
        if (resolver == address(0)) revert ZeroAddress('resolver');
        address old = externalResolver;
        externalResolver = resolver;
        escalationConfig[2].enabled = true;
        escalationConfig[2].resolver = resolver;
        emit ExternalResolverUpdated(old, resolver);
    }

    function setBondTokenRegistry(address registry) external onlyRole(ROLE_TIMELOCK) {
        address old = address(bondTokenRegistry);
        bondTokenRegistry = IBondTokenRegistry(registry);
        emit BondTokenRegistryUpdated(old, registry);
    }

    function setResolutionTableEntry(
        bytes32 categoryKey,
        ResolutionTableEntry memory entry
    ) external onlyRole(ROLE_TIMELOCK) {
        resolutionTable[categoryKey] = entry;
        emit ResolutionTableEntrySet(categoryKey, entry);
    }

    function getResolutionTableEntry(bytes32 categoryKey) external view returns (ResolutionTableEntry memory) {
        return resolutionTable[categoryKey];
    }

    // ============ Escrow Contract Registry ============

    function registerEscrowContract(address c) external onlyRole(ROLE_TIMELOCK) {
        if (c == address(0)) revert ZeroAddress('escrowContract');
        registeredEscrowContracts[c] = true;
        emit EscrowContractRegistered(c);
    }

    function unregisterEscrowContract(address c) external onlyRole(ROLE_TIMELOCK) {
        if (c == address(0)) revert ZeroAddress('escrowContract');
        registeredEscrowContracts[c] = false;
        emit EscrowContractUnregistered(c);
    }

    function setIncentiveModule(address m) external onlyRole(ROLE_TIMELOCK) {
        address old = address(incentiveModule);
        incentiveModule = IIncentiveModule(m);
        emit IncentiveModuleUpdated(old, m);
    }

    // ============ Emergency Controls ============

    function pauseNewAssignments(string memory reason) external {
        if (!hasRole(ROLE_TIMELOCK, _msgSender()) && !hasRole(ROLE_GUARDIAN, _msgSender())) {
            revert NotAuthorized(_msgSender());
        }
        if (newAssignmentsPaused) revert AlreadyPaused();
        newAssignmentsPaused = true;
        emit NewAssignmentsPaused(_msgSender(), reason);
    }

    function resumeNewAssignments() external onlyRole(ROLE_TIMELOCK) {
        if (!newAssignmentsPaused) revert NotPaused();
        newAssignmentsPaused = false;
        emit NewAssignmentsResumed(_msgSender());
    }

    function areNewAssignmentsPaused() external view returns (bool) {
        return newAssignmentsPaused;
    }

    // ============ View Helpers ============

    function getAverageResolutionTime(address resolver) external view returns (uint256) {
        return resolverStats[resolver].casesDecided > 0
            ? resolverStats[resolver].totalResolutionTime / resolverStats[resolver].casesDecided
            : 0;
    }

    function getDisputeResolverStats(address r) external view returns (ResolverStats memory) {
        return resolverStats[r];
    }

    function checkResolverNeedsAttention(address r) external view returns (bool, uint8) {
        return ResolutionAnalytics.checkResolverNeedsAttention(resolverStats[r], resolverActive[r]);
    }

    function generateCategoryKey(
        address token,
        uint256 amount,
        string memory categoryType
    ) external pure returns (bytes32) {
        return keccak256(abi.encode(token, amount, categoryType));
    }

    function autoCategorizeEscrow(bytes calldata escrowData) external pure returns (bytes32) {
        return ResolutionTableLibrary.autoCategorize(escrowData);
    }

    function getAmountTier(uint256 amount) external pure returns (string memory) {
        return ResolutionTableLibrary.getAmountTier(amount);
    }

    function getAmountCategory(uint256 amount) external pure returns (bytes32) {
        return keccak256(abi.encode(ResolutionTableLibrary.getAmountTier(amount)));
    }
}
