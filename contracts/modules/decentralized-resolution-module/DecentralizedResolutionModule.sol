// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.37;

import '../../../packages/sew-core/contracts/shared/interfaces/IResolutionModule.sol';
import '@openzeppelin/contracts/access/AccessControl.sol';
import '@openzeppelin/contracts/access/IAccessControl.sol';
import '@openzeppelin/contracts/utils/ReentrancyGuard.sol';
import '@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol';
import '../../../packages/sew-core/contracts/governance/SlowLaneQueueActivate.sol';
import '../../../packages/sew-core/contracts/shared/interfaces/IIncentiveModule.sol';
import './DRMStorageBase.sol';
import './interfaces/IStakingModule.sol';
import './interfaces/ISlashingModule.sol';
import './analytics/ResolutionAnalytics.sol';
import './libraries/EscalationCostLibrary.sol';
import '../../../packages/sew-core/contracts/modules/decentralized-resolution-module/interfaces/IKlerosHandoffResolutionModule.sol';
import '../../../packages/sew-core/contracts/shared/interfaces/IResolverAssignmentCallback.sol';
import '../../../packages/sew-core/contracts/shared/interfaces/IResolutionModuleTimeout.sol';

/**
 * @title DecentralizedResolutionModule
 * @notice Hot-path decentralized resolution module. Admin/governance functions live in
 *         DRMAdminFacet and are routed via fallback delegatecall.
 * @dev Staged Rollout Plan (see docs/dispute-resolution/DR_STAGING_PLAN.md):
 *      - DR v1: Decentralise decisions (workload routing, no resolver capital at risk)
 *      - DR v2: Decentralise incentives (user appeal bonds, cost curves, no resolver staking)
 *      - DR v3: Decentralise capital (resolver bonds, slashing, senior backing, fraud lane)
 */
contract DecentralizedResolutionModule is
    SlowLaneQueueActivate,
    AccessControl,
    ReentrancyGuard,
    IResolutionModule,
    IKlerosHandoffResolutionModule,
    IResolutionModuleTimeout,
    DRMStorageBase
{
    // DR v3 permits up to 4x a resolver's effective USD bond per case.
    // Lock one quarter of case exposure, rounded up, as assignment collateral.
    uint256 private constant ASSIGNMENT_STAKE_DIVISOR = 4;
    // ============ Errors ============
    error NotRegisteredEscrowContract(address caller);
    error AlreadyInitialized(uint256 workflowId);
    error InsufficientResolverStake(address resolver, uint256 escrowValue, uint256 maxEscrowValue);
    error ResolverInactive(address resolver);
    error ResolverNotAcceptingDisputes(address resolver);
    error ZeroAddress(string field);
    error InvalidRound(uint8 priorRound, uint8 currentRound);
    error NoPriorDecision(uint8 round);
    error AlreadyFinalized(uint256 workflowId);
    error NoDecision(uint256 workflowId, uint8 round);
    error CannotFinalizeYet(uint256 workflowId, string reason);
    error ResolverCapacityExceeded(address resolver, uint256 currentDisputes, uint256 maxDisputes);
    error AdminFacetNotSet();
    error DisputeNotTimedOut(uint256 workflowId, uint256 resolveBy);
    error DisputeNotOpen(uint256 workflowId);
    // Error declarations mirrored from DRMAdminFacet (ABI-only, no size overhead)
    error InvalidDisputeTimeout(uint256 timeout, uint256 minTimeout, uint256 maxTimeout);
    error NotSeniorResolver(address caller);
    error NotAuthorizedResolver(address caller);
    error InvalidLevel(uint8 level, uint8 maxLevel);
    error WeightExceedsMaximum(uint256 weight, uint256 maxWeight);
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
    error InvalidResolutionConfigVersion(uint256 version);
    error UnsupportedStakeExposureToken(address escrowToken, address requiredToken);
    error UnsupportedStakeExposureDecimals(address token, uint8 decimals);
    error KlerosHandoffInProgress(uint256 workflowId, uint256 disputeId);
    error KlerosTimeoutNotReached(uint256 workflowId, uint256 availableAt, uint256 currentTime);
    error KlerosTimeoutNotAuthorized(address executor);

    // ============ Events ============
    event DecisionSubmitted(uint256 indexed workflowId, uint8 round, address indexed resolver, ResolutionOutcome decision);
    event ResolverAssigned(uint256 indexed workflowId, address indexed resolver, bytes32 category, uint8 round);
    event IncentiveModuleCallFailed(uint256 indexed workflowId, string functionName, string reason);
    event RoundRobinCounterAdvanced(bytes32 indexed category, bool seniorResolvers, uint256 newIndex);
    event AdminFacetUpdated(address indexed oldFacet, address indexed newFacet);
    event DisputeClosedByMutualAgreement(uint256 indexed workflowId, address indexed escrowContract);
    event EscrowCategorySet(uint256 indexed workflowId, address indexed escrowContract, bytes32 category);

    // ============ Modifiers ============
    modifier onlyEscrowContract() {
        if (!registeredEscrowContracts[_msgSender()]) revert NotRegisteredEscrowContract(_msgSender());
        _;
    }

    constructor(address initialOwner) {
        _grantRole(DEFAULT_ADMIN_ROLE, initialOwner);

        escalationConfig[0] = EscalationConfig({resolver: address(0), fee: 0, enabled: true});
        escalationConfig[1] = EscalationConfig({resolver: address(0), fee: 0, enabled: true});
        escalationConfig[2] = EscalationConfig({resolver: address(0), fee: 0, enabled: false});

        resolveDeadlines = [24 hours, 48 hours, 7 days];
        appealWindows = [2 days, 3 days, 0];

        escalationCostConfig = EscalationCostConfig({
            enabled: true,
            curveType: CostCurveType.QUADRATIC,
            baseCost: 0.01 ether,
            stepSize: 0.01 ether,
            multiplier: 0,
            bondToken: address(0)
        });

        ResolutionConfig memory initialConfig;
        initialConfig.resolveDeadlines = resolveDeadlines;
        initialConfig.appealWindows = appealWindows;
        initialConfig.escalationConfigs[0] = escalationConfig[0];
        initialConfig.escalationConfigs[1] = escalationConfig[1];
        initialConfig.escalationConfigs[2] = escalationConfig[2];
        initialConfig.escalationCostConfig = escalationCostConfig;
        initialConfig.externalResolver = externalResolver;
        initialConfig.routingPolicyAlgorithmId = ROUTING_POLICY_ALGORITHM_ID;
        initialConfig.routingPolicyAlgorithmVersion = ROUTING_POLICY_ALGORITHM_VERSION;
        initialConfig.minEmaScoreThreshold = minEmaScoreThreshold;
        initialConfig.maxTimeoutRateBps = maxTimeoutRateBps;
        initialConfig.weightingMode = ResolverWeightingMode.QUALITY_FILTERED;
        initialConfig.categoryRouteBehavior = CategoryRouteBehavior.FALLBACK_TO_GLOBAL;
        resolutionConfigCount = 1;
        activeResolutionConfigVersion = 1;
        _storeResolutionConfig(1, initialConfig);
        resolutionConfigSelectable[1] = true;
    }

    // ============ Admin Facet Bootstrap ============

    // Tracks whether setAdminFacet has been called once. After first use, only ROLE_TIMELOCK
    // can rotate the facet, eliminating the DEFAULT_ADMIN_ROLE backdoor.
    bool private _adminFacetSet;

    function setAdminFacet(address newFacet) external {
        if (newFacet == address(0)) revert ZeroAddress('adminFacet');
        if (_adminFacetSet) {
            if (!hasRole(ROLE_TIMELOCK, _msgSender())) revert Unauthorized(_msgSender());
        } else {
            if (!hasRole(DEFAULT_ADMIN_ROLE, _msgSender()) && !hasRole(ROLE_TIMELOCK, _msgSender()))
                revert Unauthorized(_msgSender());
            _adminFacetSet = true;
        }
        address old = adminFacet;
        adminFacet = newFacet;
        emit AdminFacetUpdated(old, newFacet);
    }

    // ============ Admin Delegation Stubs ============
    // All state-modifying admin/governance functions delegate to DRMAdminFacet.
    // Signatures are kept here for ABI/type compatibility with callers.

    function _delegateAdmin() private {
        address facet = adminFacet;
        if (facet == address(0)) revert AdminFacetNotSet();
        // solhint-disable-next-line no-inline-assembly
        assembly ("memory-safe") {
            calldatacopy(0, 0, calldatasize())
            let result := delegatecall(gas(), facet, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch result
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }

    function appointResolver(address, string memory, string memory) external { _delegateAdmin(); }
    function appointSeniorResolver(address, string memory, string memory) external { _delegateAdmin(); }
    function removeResolver(address) external { _delegateAdmin(); }
    function removeSeniorResolver(address) external { _delegateAdmin(); }
    function updateResolverMetadata(address, string memory, string memory) external { _delegateAdmin(); }
    function setResolverActive(address, bool) external { _delegateAdmin(); }
    function setResolverCapacity(address, uint256, bool) external { _delegateAdmin(); }
    function setResolverAssignmentWeight(address, uint256) external { _delegateAdmin(); }
    function setEMAParameters(uint256, uint256, uint256) external { _delegateAdmin(); }
    function setRoundTimeouts(uint256[3] memory, uint256[3] memory) external { _delegateAdmin(); }
    function setDisputeTimeout(uint256) external { _delegateAdmin(); }
    function queueEscalationConfig(uint8, EscalationConfig memory) external { _delegateAdmin(); }
    function activateEscalationConfig(uint8) external { _delegateAdmin(); }
    function queueEscalationCostConfig(EscalationCostConfig memory) external { _delegateAdmin(); }
    function activateEscalationCostConfig() external { _delegateAdmin(); }
    function setMinEscrowValueForEscalation(uint256) external { _delegateAdmin(); }
    function setExternalResolver(address) external { _delegateAdmin(); }
    function setBondTokenRegistry(address) external { _delegateAdmin(); }
    function setResolutionTableEntry(bytes32, ResolutionTableEntry memory) external { _delegateAdmin(); }
    function registerEscrowContract(address) external { _delegateAdmin(); }
    function unregisterEscrowContract(address) external { _delegateAdmin(); }
    function setIncentiveModule(address) external { _delegateAdmin(); }
    function setStakingModule(address) external { _delegateAdmin(); }
    function pauseNewAssignments(string memory) external { _delegateAdmin(); }
    function resumeNewAssignments() external { _delegateAdmin(); }
    function publishResolutionConfig(ResolutionConfig memory) external { _delegateAdmin(); }
    function activateResolutionConfig(uint256) external { _delegateAdmin(); }
    function setDefaultResolutionConfigVersion(uint256) external { _delegateAdmin(); }
    function deprecateResolutionConfig(uint256) external { _delegateAdmin(); }
    function setResolutionConfigSelectable(uint256, bool) external { _delegateAdmin(); }

    // View/pure helpers — implemented directly (no delegation needed)
    function areNewAssignmentsPaused() external view returns (bool) { return newAssignmentsPaused; }
    function calculateAssignmentWeight(address resolver) external view returns (uint256) { return resolverStats[resolver].assignmentWeight; }
    function getResolutionTableEntry(bytes32 k) external view returns (ResolutionTableEntry memory) { return resolutionTable[k]; }
    function getAverageResolutionTime(address r) external view returns (uint256) {
        return resolverStats[r].casesDecided > 0 ? resolverStats[r].totalResolutionTime / resolverStats[r].casesDecided : 0;
    }
    function getDisputeResolverStats(address r) external view returns (ResolverStats memory) { return resolverStats[r]; }
    function checkResolverNeedsAttention(address r) external view returns (bool, uint8) {
        return ResolutionAnalytics.checkResolverNeedsAttention(resolverStats[r], resolverActive[r]);
    }
    function getPendingEscalationConfig(uint8 level) external view returns (EscalationConfig memory config, uint64 eta, bool exists) {
        PendingEscalationConfig storage p = _pendingEscalationConfig[level];
        return (p.config, p.eta, p.exists);
    }
    function getPendingEscalationCostConfig() external view returns (EscalationCostConfig memory config, uint64 eta, bool exists) {
        PendingEscalationCostConfig storage p = _pendingEscalationCostConfig;
        return (p.config, p.eta, p.exists);
    }
    function getResolutionConfig(uint256 version) external view returns (ResolutionConfig memory) {
        if (version == 0 || version > resolutionConfigCount) revert InvalidResolutionConfigVersion(version);
        return _resolutionConfigs[version];
    }
    function resolutionConfigRoot(uint256 version) external view returns (bytes32) {
        if (version == 0 || version > resolutionConfigCount) revert InvalidResolutionConfigVersion(version);
        return _resolutionConfigs[version].root;
    }
    function isResolutionConfigSelectable(uint256 version) external view returns (bool) {
        return version != 0 && version <= resolutionConfigCount && resolutionConfigSelectable[version]
            && !_resolutionConfigs[version].deprecated;
    }
    function resolutionConfigStatus(uint256 version)
        external
        view
        returns (bool exists, bool selectable, bool deprecated, bytes32 root)
    {
        exists = version != 0 && version <= resolutionConfigCount;
        if (!exists) return (false, false, false, bytes32(0));
        ResolutionConfig storage config = _resolutionConfigs[version];
        return (true, resolutionConfigSelectable[version] && !config.deprecated, config.deprecated, config.root);
    }
    function generateCategoryKey(address token, uint256 amount, string memory t) external pure returns (bytes32) { return keccak256(abi.encode(token, amount, t)); }

    // reversalRate = reversals / casesDecided * 10000 bps (not a true escalation rate)
    function getV1PhaseGateMetrics() external view returns (uint256 reversalRate, uint256 avgResponseTime, uint256 activeResolvers) {
        uint256 totalCases;
        uint256 totalReversals;
        uint256 totalTime;
        uint256 count = approvedResolvers.length + approvedSeniorResolvers.length;
        for (uint256 i = 0; i < count; i++) {
            address r = i < approvedResolvers.length ? approvedResolvers[i] : approvedSeniorResolvers[i - approvedResolvers.length];
            ResolverStats memory s = resolverStats[r];
            totalCases += s.casesDecided;
            totalReversals += s.reversals;
            totalTime += s.totalResolutionTime;
            if (resolverActive[r]) activeResolvers++;
        }
        reversalRate = totalCases > 0 ? (totalReversals * BASIS_POINTS_DENOMINATOR) / totalCases : 0;
        avgResponseTime = totalCases > 0 ? totalTime / totalCases : 0;
    }


    // ============ IResolutionModule Views ============

    function getApprovedResolvers() external view returns (address[] memory) {
        return approvedResolvers;
    }

    function getApprovedSeniorResolvers() external view returns (address[] memory) {
        return approvedSeniorResolvers;
    }

    function getDisputeResolverRole(address disputeResolver) external view returns (ResolverRole) {
        return resolverRoles[disputeResolver];
    }

    function getDisputeMetadata(
        uint256 workflowId,
        address escrowContract
    ) external view returns (DisputeMetadata memory) {
        return disputeMetadata[escrowContract][workflowId];
    }

    function getDecisionAtRound(
        uint256 workflowId,
        address escrowContract,
        uint8 round
    ) external view override returns (uint8 decision) {
        require(round < 3, 'Invalid round');
        return uint8(disputeMetadata[escrowContract][workflowId].decisionAtRound[round]);
    }

    function getAppealDeadlineAndRound(
        uint256 workflowId,
        address escrowContract
    ) external view override returns (uint256 appealDeadline, uint8 currentRound, bool isFinalRound) {
        DisputeMetadata storage dm = disputeMetadata[escrowContract][workflowId];
        currentRound = dm.currentRound;
        isFinalRound = (currentRound >= MAX_ROUND);
        if (isFinalRound) return (0, currentRound, true);
        appealDeadline = dm.appealDeadline[currentRound];
    }

    function isAuthorizedDisputeResolver(
        uint256 workflowId,
        address escrowContract,
        address disputeResolver,
        bytes calldata
    ) external view override returns (bool authorized, uint8 role) {
        DisputeMetadata memory dm = disputeMetadata[escrowContract][workflowId];
        if (dm.status != DisputeStatus.Open) return (false, 0);
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
        address escrowContract,
        bytes calldata
    ) external view override returns (address disputeResolver, uint8 escalationLevel) {
        DisputeMetadata memory dm = disputeMetadata[escrowContract][workflowId];
        address currentResolver = dm.resolverAtRound[dm.currentRound];
        if (currentResolver != address(0)) return (currentResolver, dm.currentRound);
        return (_selectResolverForWorkflow(escrowContract, workflowId, dm.categoryKey, false), 0);
    }

    function canEscalate(
        uint256 workflowId,
        address escrowContract,
        uint8 currentLevel,
        bytes calldata escrowData
    ) external view override returns (bool allowed, address nextResolver, uint256 escalationFee) {
        IResolutionModule.ResolutionAppealQuote memory quote = _quoteAppealTransition(workflowId, escrowContract, escrowData);
        if (quote.predecessorRound != currentLevel) return (false, address(0), 0);
        return (quote.appealable, quote.successorResolver, quote.baseBondAmount);
    }

    function executeEscalation(
        uint256 workflowId,
        address escrowContract,
        bytes calldata escrowData
    ) external override nonReentrant returns (bool success, address newResolver, uint8 newLevel) {
        return _executeEscalation(workflowId, escrowContract, escrowData, bytes32(0));
    }

    function quoteAppealTransition(
        uint256 workflowId,
        address escrowContract,
        bytes calldata escrowData
    ) external view override returns (IResolutionModule.ResolutionAppealQuote memory quote) {
        return _quoteAppealTransition(workflowId, escrowContract, escrowData);
    }

    function executeEscalationWithQuote(
        uint256 workflowId,
        address escrowContract,
        bytes calldata escrowData,
        bytes32 expectedResolutionQuoteRoot
    ) external override nonReentrant returns (bool success, address newResolver, uint8 newLevel) {
        return _executeEscalation(workflowId, escrowContract, escrowData, expectedResolutionQuoteRoot);
    }

    function prepareKlerosHandoff(
        uint256 workflowId,
        address escrowContract,
        bytes calldata escrowData,
        bytes32 resolutionQuoteRoot,
        bytes32 klerosConfigRoot
    ) external override nonReentrant onlyEscrowContract returns (bytes32 handoffRoot) {
        if (escrowContract != _msgSender()) revert NotRegisteredEscrowContract(_msgSender());
        IResolutionModule.ResolutionAppealQuote memory quote = _quoteAppealTransition(workflowId, escrowContract, escrowData);
        if (!quote.appealable || quote.successorRound != 2 || quote.resolutionQuoteRoot != resolutionQuoteRoot) {
            revert('Invalid Kleros handoff quote');
        }
        PreparedKlerosHandoff storage prepared = _preparedKlerosHandoffs[escrowContract][workflowId];
        if (prepared.exists) revert('Kleros handoff already prepared');

        handoffRoot = keccak256(abi.encode(
            'KLEROS_HANDOFF_V1', block.chainid, address(this), escrowContract, workflowId,
            quote.predecessorRound, quote.predecessorResolver, quote.successorRound,
            quote.successorResolver, quote.appealedDecisionRoot, quote.resolutionQuoteRoot, klerosConfigRoot
        ));
        _preparedKlerosHandoffs[escrowContract][workflowId] = PreparedKlerosHandoff({
            handoffRoot: handoffRoot,
            resolutionQuoteRoot: quote.resolutionQuoteRoot,
            klerosConfigRoot: klerosConfigRoot,
            successorResolver: quote.successorResolver,
            predecessorRound: quote.predecessorRound,
            exists: true
        });
    }

    function commitKlerosHandoff(
        uint256 workflowId,
        address escrowContract,
        bytes calldata escrowData,
        bytes32 resolutionQuoteRoot,
        bytes32 handoffRoot,
        bytes32 klerosConfigRoot,
        uint256 klerosDisputeId
    ) external override nonReentrant onlyEscrowContract returns (bool success, address newResolver, uint8 newLevel) {
        if (escrowContract != _msgSender()) revert NotRegisteredEscrowContract(_msgSender());
        PreparedKlerosHandoff memory prepared = _preparedKlerosHandoffs[escrowContract][workflowId];
        if (!prepared.exists || prepared.handoffRoot != handoffRoot || prepared.resolutionQuoteRoot != resolutionQuoteRoot
            || prepared.klerosConfigRoot != klerosConfigRoot) {
            revert('Invalid prepared Kleros handoff');
        }
        IResolutionModule.ResolutionAppealQuote memory quote = _quoteAppealTransition(workflowId, escrowContract, escrowData);
        if (!quote.appealable || quote.successorRound != 2 || quote.resolutionQuoteRoot != prepared.resolutionQuoteRoot
            || quote.successorResolver != prepared.successorResolver || quote.predecessorRound != prepared.predecessorRound) {
            revert('Stale Kleros handoff');
        }
        delete _preparedKlerosHandoffs[escrowContract][workflowId];
        klerosDisputeIdForWorkflow[escrowContract][workflowId] = klerosDisputeId + 1;
        klerosHandoffCommittedAt[escrowContract][workflowId] = uint64(block.timestamp);
        _klerosConfigRootForWorkflow[escrowContract][workflowId] = klerosConfigRoot;
        return _executeEscalation(workflowId, escrowContract, escrowData, resolutionQuoteRoot);
    }

    function getPreparedKlerosHandoff(address escrowContract, uint256 workflowId)
        external view returns (bytes32 handoffRoot, bytes32 resolutionQuoteRoot, address successorResolver, uint8 predecessorRound, bool exists)
    {
        PreparedKlerosHandoff storage prepared = _preparedKlerosHandoffs[escrowContract][workflowId];
        return (prepared.handoffRoot, prepared.resolutionQuoteRoot, prepared.successorResolver, prepared.predecessorRound, prepared.exists);
    }

    function getCommittedKlerosDisputeId(address escrowContract, uint256 workflowId)
        external view override returns (bool committed, uint256 klerosDisputeId)
    {
        uint256 stored = klerosDisputeIdForWorkflow[escrowContract][workflowId];
        if (stored == 0) return (false, 0);
        return (true, stored - 1);
    }

    function getCommittedKlerosConfigRoot(address escrowContract, uint256 workflowId)
        external view override returns (bytes32)
    {
        return _klerosConfigRootForWorkflow[escrowContract][workflowId];
    }

    function _executeEscalation(
        uint256 workflowId,
        address escrowContract,
        bytes calldata escrowData,
        bytes32 expectedResolutionQuoteRoot
    ) internal returns (bool success, address newResolver, uint8 newLevel) {
        IResolutionModule.ResolutionAppealQuote memory quote = _quoteAppealTransition(workflowId, escrowContract, escrowData);
        if (expectedResolutionQuoteRoot != bytes32(0) && quote.resolutionQuoteRoot != expectedResolutionQuoteRoot) {
            revert('Stale appeal quote');
        }
        if (!quote.appealable) return (false, address(0), quote.predecessorRound);
        DisputeMetadata storage dm = disputeMetadata[escrowContract][workflowId];
        uint8 toRound = quote.successorRound;
        address nextRes = quote.successorResolver;
        bool externalArbitrationRound = toRound == MAX_ROUND;
        if (nextRes == address(0)) revert ResolverInactive(nextRes);
        ResolverCapacity storage nextCapacity = resolverCapacity[nextRes];
        if (!externalArbitrationRound) {
            if (!resolverActive[nextRes]) revert ResolverInactive(nextRes);
            if (!nextCapacity.acceptsNewDisputes) revert ResolverNotAcceptingDisputes(nextRes);
            if (nextCapacity.maxConcurrentDisputes > 0 &&
                nextCapacity.currentDisputes >= nextCapacity.maxConcurrentDisputes) {
                revert ResolverCapacityExceeded(
                    nextRes, nextCapacity.currentDisputes, nextCapacity.maxConcurrentDisputes
                );
            }
        }
        if (toRound == 1) _advanceRoundRobinCounterForWorkflow(escrowContract, workflowId, dm.categoryKey, true);

        address priorResolver = dm.resolverAtRound[dm.currentRound];
        if (!externalArbitrationRound && address(stakingModule) != address(0)) {
            IStakingModule(stakingModule).onDisputeEscalated(workflowId, escrowContract, priorResolver);
            IStakingModule(stakingModule).onResolverAssigned(
                workflowId, escrowContract, nextRes, _requiredStakeForWorkflow(escrowContract, workflowId)
            );
        }
        if (!externalArbitrationRound) {
            _decrementActiveAssignment(priorResolver);
            nextCapacity.currentDisputes++;
            resolverActiveDisputes[nextRes]++;
            workflowStakeResolver[escrowContract][workflowId] = nextRes;
        }

        dm.currentRound = toRound;
        dm.resolverAtRound[toRound] = nextRes;
        dm.assignedAt = block.timestamp;
        dm.resolveBy = block.timestamp + _resolutionConfig(escrowContract, workflowId).resolveDeadlines[toRound];
        if (!externalArbitrationRound) resolverStats[nextRes].casesAssigned++;

        emit ResolverAssigned(workflowId, nextRes, dm.categoryKey, toRound);

        if (address(incentiveModule) != address(0)) {
            try incentiveModule.onResolverAssigned(workflowId, escrowContract, nextRes, toRound) {} catch {
                emit IncentiveModuleCallFailed(workflowId, 'onResolverAssigned', 'FAILED');
            }
        }

        return (true, nextRes, toRound);
    }

    function _quoteAppealTransition(
        uint256 workflowId,
        address escrowContract,
        bytes calldata escrowData
    ) internal view returns (IResolutionModule.ResolutionAppealQuote memory quote) {
        DisputeMetadata storage dm = disputeMetadata[escrowContract][workflowId];
        quote.predecessorRound = dm.currentRound;
        quote.successorRound = dm.currentRound + 1;
        quote.predecessorResolver = dm.resolverAtRound[dm.currentRound];
        quote.appealedDecision = dm.decisionAtRound[dm.currentRound];
        quote.appealDeadline = dm.appealDeadline[dm.currentRound];
        quote.finalRound = dm.currentRound >= MAX_ROUND;
        quote.appealedDecisionRoot = keccak256(abi.encode(
            'APPEALED_DECISION_V1', block.chainid, address(this), escrowContract, workflowId,
            quote.predecessorRound, quote.predecessorResolver, quote.appealedDecision,
            dm.decidedAtRound[dm.currentRound], quote.appealDeadline
        ));

        if (!quote.finalRound && dm.status == DisputeStatus.Decided && quote.appealedDecision != ResolutionOutcome.NONE
            && quote.appealDeadline > block.timestamp
            && _resolutionConfig(escrowContract, workflowId).escalationConfigs[quote.successorRound].enabled) {
            ResolutionConfig storage config = _resolutionConfig(escrowContract, workflowId);
            if (quote.successorRound == 1) {
                quote.successorResolver = _selectResolverForWorkflow(escrowContract, workflowId, dm.categoryKey, true);
            } else if (quote.successorRound == 2) {
                quote.successorResolver = config.externalResolver;
            }
            quote.appealable = quote.successorResolver != address(0);
            if (quote.appealable && config.escalationCostConfig.enabled
                && !(quote.successorRound == 2 && config.externalResolver != address(0))) {
                quote.baseBondAmount = EscalationCostLibrary.calculateEscalationCost(quote.predecessorRound, config.escalationCostConfig);
                quote.baseBondAsset = _bondAsset(config, escrowData);
            }
        }
        quote.resolutionQuoteRoot = keccak256(abi.encode(
            'RESOLUTION_APPEAL_QUOTE_V1', block.chainid, address(this), escrowContract, workflowId,
            quote.appealedDecisionRoot, quote.appealable, quote.predecessorRound, quote.successorRound,
            quote.predecessorResolver, quote.successorResolver, quote.appealDeadline, quote.finalRound,
            quote.baseBondAsset, quote.baseBondAmount
        ));
    }

    function getRequiredAppealBond(
        uint256 workflowId,
        address escrowContract,
        uint8 currentLevel,
        bytes calldata escrowData
    ) external view override returns (uint256 amount, address token) {
        uint8 nextRound = currentLevel + 1;
        ResolutionConfig storage config = _resolutionConfig(escrowContract, workflowId);
        if (nextRound == 2 && config.externalResolver != address(0)) return (0, address(0));
        if (!config.escalationCostConfig.enabled) return (0, address(0));

        uint256 bondAmount = EscalationCostLibrary.calculateEscalationCost(currentLevel, config.escalationCostConfig);

        return (bondAmount, _bondAsset(config, escrowData));
    }

    function moduleName() external pure override returns (string memory) { return 'DecentralizedResolution'; }
    function moduleVersion() external pure override returns (string memory) { return '1.0.0'; }

    function supportsInterface(
        bytes4 interfaceId
    ) public view virtual override(AccessControl, IERC165) returns (bool) {
        return interfaceId == type(IResolutionModule).interfaceId
            || interfaceId == type(IResolutionModuleTimeout).interfaceId
            || super.supportsInterface(interfaceId);
    }

    // ============ Escrow Contract Hooks ============

    function setEscrowCategory(
        uint256 workflowId,
        address escrowContract,
        bytes32 categoryKey
    ) external onlyEscrowContract {
        escrowCategory[escrowContract][workflowId] = categoryKey;
        emit EscrowCategorySet(workflowId, escrowContract, categoryKey);
    }

    function initializeDispute(
        uint256 workflowId,
        address escrowContract,
        address resolver,
        bytes32 categoryKey
    ) external onlyEscrowContract {
        DisputeMetadata storage dm = disputeMetadata[escrowContract][workflowId];
        if (dm.resolverAtRound[0] != address(0)) revert AlreadyInitialized(workflowId);

        if (!resolverActive[resolver]) revert ResolverInactive(resolver);
        ResolverCapacity storage capacity = resolverCapacity[resolver];
        if (!capacity.acceptsNewDisputes) revert ResolverNotAcceptingDisputes(resolver);
        if (capacity.maxConcurrentDisputes > 0) {
            if (capacity.currentDisputes >= capacity.maxConcurrentDisputes) {
                revert ResolverCapacityExceeded(resolver, capacity.currentDisputes, capacity.maxConcurrentDisputes);
            }
        }

        workflowStakeResolver[escrowContract][workflowId] = resolver;
        if (address(stakingModule) != address(0)) {
            IStakingModule(stakingModule).onResolverAssigned(workflowId, escrowContract, resolver, 0);
        }

        capacity.currentDisputes++;
        resolverActiveDisputes[resolver]++;

        dm.currentRound = 0;
        dm.status = DisputeStatus.Open;
        dm.resolverAtRound[0] = resolver;
        dm.assignedAt = block.timestamp;
        dm.resolveBy = block.timestamp + _resolutionConfig(escrowContract, workflowId).resolveDeadlines[0];
        dm.categoryKey = categoryKey;
        escrowCategory[escrowContract][workflowId] = categoryKey;

        resolverStats[resolver].casesAssigned++;
        _advanceRoundRobinCounterForWorkflow(escrowContract, workflowId, categoryKey, false);
        emit ResolverAssigned(workflowId, resolver, categoryKey, 0);

        if (address(incentiveModule) != address(0)) {
            try incentiveModule.onResolverAssigned(workflowId, escrowContract, resolver, 0) {} catch {
                emit IncentiveModuleCallFailed(workflowId, 'onResolverAssigned', 'FAILED');
            }
        }
    }

    function initializeDisputeWithCategory(
        uint256 workflowId,
        address escrowContract,
        bytes calldata escrowData
    ) external onlyEscrowContract {
        _initializeDisputeWithCategory(workflowId, escrowContract, escrowData);
    }

    /// @dev Optional extension selected by BaseEscrow without changing IResolutionModule.
    function initializeDisputeWithCategoryAndConfig(
        uint256 workflowId,
        address escrowContract,
        bytes calldata escrowData,
        uint256 configVersion
    ) external onlyEscrowContract {
        // A workflow may open a dispute after its already-bound config is deprecated.
        // Deprecation blocks new selection, not the frozen workflow semantics.
        if (configVersion == 0 || configVersion > resolutionConfigCount) {
            revert InvalidResolutionConfigVersion(configVersion);
        }
        workflowResolutionConfigVersion[escrowContract][workflowId] = configVersion;
        _initializeDisputeWithCategory(workflowId, escrowContract, escrowData);
    }

    function _initializeDisputeWithCategory(
        uint256 workflowId,
        address escrowContract,
        bytes calldata escrowData
    ) internal {
        (address escrowToken, , , uint256 amountAfterFee, ) = abi.decode(
            escrowData, (address, address, address, uint256, address)
        );

        bytes32 cat = escrowCategory[escrowContract][workflowId];
        DisputeMetadata storage dm = disputeMetadata[escrowContract][workflowId];
        if (dm.resolverAtRound[0] != address(0)) revert AlreadyInitialized(workflowId);

        address resolver;
        resolver = _selectResolverForWorkflow(escrowContract, workflowId, cat, false);
        if (resolver == address(0)) return;

        if (!resolverActive[resolver]) revert ResolverInactive(resolver);
        ResolverCapacity storage capacity = resolverCapacity[resolver];
        if (!capacity.acceptsNewDisputes) revert ResolverNotAcceptingDisputes(resolver);
        if (capacity.maxConcurrentDisputes > 0) {
            if (capacity.currentDisputes >= capacity.maxConcurrentDisputes) {
                revert ResolverCapacityExceeded(resolver, capacity.currentDisputes, capacity.maxConcurrentDisputes);
            }
        }

        if (stakingModule != address(0)) {
            uint256 exposureUSD = _normalizeStakeExposure(escrowToken, amountAfterFee);
            uint256 maxEscrow = IStakingModule(stakingModule).getMaxEscrowPerCase(resolver);
            if (exposureUSD > maxEscrow) {
                revert InsufficientResolverStake(resolver, exposureUSD, maxEscrow);
            }
            workflowStakeExposureUSD[escrowContract][workflowId] = exposureUSD;
            IStakingModule(stakingModule).onResolverAssigned(
                workflowId, escrowContract, resolver, _requiredStakeForExposure(exposureUSD)
            );
        }
        workflowStakeResolver[escrowContract][workflowId] = resolver;

        capacity.currentDisputes++;
        resolverActiveDisputes[resolver]++;

        dm.currentRound = 0;
        dm.status = DisputeStatus.Open;
        dm.resolverAtRound[0] = resolver;
        dm.assignedAt = block.timestamp;
        dm.resolveBy = block.timestamp + _resolutionConfig(escrowContract, workflowId).resolveDeadlines[0];
        dm.categoryKey = cat;
        escrowCategory[escrowContract][workflowId] = cat;

        resolverStats[resolver].casesAssigned++;
        _advanceRoundRobinCounterForWorkflow(escrowContract, workflowId, cat, false);
        emit ResolverAssigned(workflowId, resolver, cat, 0);

        if (address(incentiveModule) != address(0)) {
            try incentiveModule.onResolverAssigned(workflowId, escrowContract, resolver, 0) {} catch {
                emit IncentiveModuleCallFailed(workflowId, 'onResolverAssigned', 'FAILED');
            }
        }
    }

    function decrementResolverActiveDisputes(address r) external onlyEscrowContract {
        if (resolverActiveDisputes[r] > 0) resolverActiveDisputes[r]--;
        if (resolverCapacity[r].currentDisputes > 0) resolverCapacity[r].currentDisputes--;
    }

    function recordResolution(
        uint256 workflowId,
        address escrowContract,
        address resolver,
        ResolutionOutcome outcome,
        uint256 resolutionTime
    ) external onlyEscrowContract {
        DisputeMetadata storage dm = disputeMetadata[escrowContract][workflowId];
        uint8 currentRound = dm.currentRound;

        dm.decisionAtRound[currentRound] = outcome;
        dm.decidedAtRound[currentRound] = block.timestamp;
        dm.appealDeadline[currentRound] = block.timestamp + _resolutionConfig(escrowContract, workflowId).appealWindows[currentRound];
        dm.status = DisputeStatus.Decided;

        ResolutionAnalytics.recordSuccessfulResolution(resolverStats[resolver], resolver, resolutionTime, emaAlphaBps);
        emit DecisionSubmitted(workflowId, currentRound, resolver, outcome);

        if (address(incentiveModule) != address(0)) {
            try incentiveModule.onDecisionSubmitted(workflowId, escrowContract, resolver, currentRound, outcome, resolutionTime) {} catch {
                emit IncentiveModuleCallFailed(workflowId, 'onDecisionSubmitted', 'FAILED');
            }
        }

        // Determine appeal bond outcome when this is a higher-round decision.
        // If the new decision differs from the prior round, the appeal succeeded → refund.
        // If it matches, the appeal failed → pay prior resolvers.
        if (currentRound > 0) {
            uint8 priorRound = currentRound - 1;
            ResolutionOutcome priorDecision = dm.decisionAtRound[priorRound];
            if (priorDecision != ResolutionOutcome.NONE) {
                bool outcomeFlipped = priorDecision != outcome;
                // A configured external resolver at round 2 is funded by its
                // arbitration fee, not an appeal bond (see getRequiredAppealBond).
                // Do not ask the incentive ledger to distribute a bond that the
                // protocol transition explicitly did not require or collect.
                bool appealBondRequired = !(
                    currentRound == 2 && _resolutionConfig(escrowContract, workflowId).externalResolver != address(0)
                );
                if (address(incentiveModule) != address(0) && appealBondRequired) {
                    // Atomic: if bond distribution fails, the entire resolution reverts.
                    incentiveModule.distributeAppealBond(
                        workflowId, escrowContract, priorRound, outcomeFlipped
                    );
                }
            }
        }

        // After recording the new resolution, check for reversal-slash vindication.
        // If a prior round was reversed (auto-slashed) and the current outcome agrees
        // with the prior round's decision, restore the prior resolver's slashed stake.
        if (slashingModule != address(0) && currentRound > 0) {
            // Build prior decisions array for the slashing module to evaluate vindication
            uint8[] memory priorDecisions = new uint8[](currentRound + 1); // index by round
            for (uint8 r = 0; r < currentRound + 1; r++) {
                priorDecisions[r] = uint8(dm.decisionAtRound[r]);
            }
            try ISlashingModule(slashingModule).restoreReversalSlashOnVindication(
                workflowId,
                escrowContract,
                outcome == ResolutionOutcome.RELEASE,
                priorDecisions
            ) {} catch {
                emit IncentiveModuleCallFailed(workflowId, 'restoreReversalSlashOnVindication', 'FAILED');
            }
        }
    }

    function recordReversal(
        uint256 workflowId,
        address escrowContract,
        uint8 priorRound
    ) external override onlyEscrowContract {
        // Note: appeal bond distribution is handled by recordResolution when the
        // reversal is detected during a higher-round resolution. If this function
        // is called independently (e.g., retrospective governance action), the
        // caller must ensure distribution has already occurred.
        _recordReversalAnalytics(workflowId, escrowContract, priorRound);
    }

    /// @dev Internal: record reversal analytics and execute automated slash.
    ///      Distribution of the appeal bond is handled by recordResolution.
    function _recordReversalAnalytics(
        uint256 workflowId,
        address escrowContract,
        uint8 priorRound
    ) internal {
        DisputeMetadata storage dm = disputeMetadata[escrowContract][workflowId];

        if (priorRound >= dm.currentRound) revert InvalidRound(priorRound, dm.currentRound);
        if (dm.decisionAtRound[priorRound] == ResolutionOutcome.NONE) revert NoPriorDecision(priorRound);
        if (dm.decisionAtRound[dm.currentRound] == ResolutionOutcome.NONE) {
            revert NoDecision(workflowId, dm.currentRound);
        }

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

            // Execute automated reversal slash via slashing module (Track 1)
            if (slashingModule != address(0)) {
                try ISlashingModule(slashingModule).slashForReversal(
                    workflowId,
                    escrowContract,
                    priorResolver,
                    priorRound
                ) {} catch {
                    emit IncentiveModuleCallFailed(workflowId, 'slashForReversal', 'FAILED');
                }
            }
        }
    }

    function finalizeDispute(uint256 workflowId, address escrowContract) external onlyEscrowContract {
        DisputeMetadata storage dm = disputeMetadata[escrowContract][workflowId];

        if (dm.status == DisputeStatus.Final) revert AlreadyFinalized(workflowId);
        if (dm.decisionAtRound[dm.currentRound] == ResolutionOutcome.NONE) {
            revert NoDecision(workflowId, dm.currentRound);
        }

        bool canFinalize = false;
        if (dm.currentRound == MAX_ROUND) {
            canFinalize = true;
        } else if (dm.appealDeadline[dm.currentRound] > 0) {
            canFinalize = block.timestamp >= dm.appealDeadline[dm.currentRound];
        }

        if (!canFinalize) revert CannotFinalizeYet(workflowId, 'Appeal window not expired or not final round');

        address assignedStakeResolver = workflowStakeResolver[escrowContract][workflowId];
        if (assignedStakeResolver == address(0)) assignedStakeResolver = dm.resolverAtRound[dm.currentRound];
        if (address(stakingModule) != address(0)) {
            IStakingModule(stakingModule).onResolutionFinalized(
                workflowId, escrowContract, assignedStakeResolver, true
            );
        }

        _decrementActiveAssignment(assignedStakeResolver);
        delete workflowStakeResolver[escrowContract][workflowId];
        _clearKlerosHandoff(escrowContract, workflowId);
        dm.status = DisputeStatus.Final;
        ResolutionOutcome finalDecision = dm.decisionAtRound[dm.currentRound];
        uint8 finalRound = dm.currentRound;

        if (address(incentiveModule) != address(0)) {
            try incentiveModule.onDisputeFinalized(workflowId, escrowContract, finalRound, finalDecision) {} catch {
                emit IncentiveModuleCallFailed(workflowId, 'onDisputeFinalized', 'FAILED');
            }
        }
    }

    /**
     * @notice Close a dispute by mutual agreement between escrow participants.
     * @dev Called by the escrow contract when both parties have accepted a split settlement.
     *      Bypasses the appeal-window timing check — mutual agreement is terminal regardless
     *      of where the dispute was in the resolution process.
     *      If no dispute record exists for this escrow (e.g. escrow was PENDING, not DISPUTED),
     *      the call is a no-op.
     * @param workflowId The escrow workflow ID
     */
    function closeByMutualAgreement(uint256 workflowId) external onlyEscrowContract {
        _closeDisputeByMutualAgreement(workflowId, msg.sender);
    }

    function closeDisputeByMutualAgreement(uint256 workflowId, address escrowContract)
        external
        override
        onlyEscrowContract
    {
        if (escrowContract != msg.sender) revert NotRegisteredEscrowContract(msg.sender);
        _closeDisputeByMutualAgreement(workflowId, escrowContract);
    }

    function _closeDisputeByMutualAgreement(uint256 workflowId, address escrowContract) internal {
        DisputeMetadata storage dm = disputeMetadata[escrowContract][workflowId];

        // No-op if never disputed or already finalized
        if (dm.status == DisputeStatus.Final) return;

        address activeResolver = workflowStakeResolver[escrowContract][workflowId];
        if (activeResolver == address(0)) activeResolver = dm.resolverAtRound[dm.currentRound];
        if (address(stakingModule) != address(0) && activeResolver != address(0)) {
            IStakingModule(stakingModule).onResolutionFinalized(
                workflowId, escrowContract, activeResolver, false
            );
        }
        _decrementActiveAssignment(activeResolver);
        delete workflowStakeResolver[escrowContract][workflowId];
        _clearKlerosHandoff(escrowContract, workflowId);

        dm.status = DisputeStatus.Final;
        uint8 finalRound = dm.currentRound;

        if (address(incentiveModule) != address(0)) {
            // Pass ResolutionOutcome.NONE — no resolver decision was reached
            try incentiveModule.onDisputeFinalized(workflowId, msg.sender, finalRound, ResolutionOutcome.NONE) {} catch {
                emit IncentiveModuleCallFailed(workflowId, 'onDisputeFinalized', 'MUTUAL_SETTLEMENT');
            }
        }

        emit DisputeClosedByMutualAgreement(workflowId, escrowContract);
    }

    function closeDisputeByTimeout(
        uint256 workflowId,
        address escrowContract,
        address executor,
        uint256 disputeRaisedAt,
        uint256 maxDisputeDuration
    )
        external
        override
        onlyEscrowContract
    {
        if (escrowContract != msg.sender) revert NotRegisteredEscrowContract(msg.sender);
        DisputeMetadata storage dm = disputeMetadata[escrowContract][workflowId];
        if (dm.status == DisputeStatus.Final) return;
        // A committed Kleros handoff may follow a resolver decision, leaving DRM status
        // Decided while external arbitration is active. Only the escrow's governed timeout
        // recovery can close that state; ordinary timeout closure requires an open dispute.
        bool committedKleros = klerosDisputeIdForWorkflow[escrowContract][workflowId] != 0;
        if (committedKleros) {
            if (!IAccessControl(escrowContract).hasRole(keccak256('ROLE_TIMELOCK'), executor)) {
                revert KlerosTimeoutNotAuthorized(executor);
            }
            uint256 handoffAt = klerosHandoffCommittedAt[escrowContract][workflowId];
            uint256 availableAt = handoffAt + maxDisputeDuration;
            // BaseEscrow admits only ROLE_TIMELOCK for a committed handoff. The escrow
            // is the only caller here, and this branch is reached only through that path.
            if (maxDisputeDuration == 0 || block.timestamp < availableAt) {
                revert KlerosTimeoutNotReached(workflowId, availableAt, block.timestamp);
            }
            if (dm.status != DisputeStatus.Open && dm.status != DisputeStatus.Decided) {
                revert DisputeNotOpen(workflowId);
            }
        } else if (dm.status != DisputeStatus.Open) {
            revert DisputeNotOpen(workflowId);
        } else if (block.timestamp < disputeRaisedAt + maxDisputeDuration) {
            revert DisputeNotTimedOut(workflowId, disputeRaisedAt + maxDisputeDuration);
        }

        address activeResolver = workflowStakeResolver[escrowContract][workflowId];
        if (activeResolver == address(0)) activeResolver = dm.resolverAtRound[dm.currentRound];
        if (address(stakingModule) != address(0) && activeResolver != address(0)) {
            IStakingModule(stakingModule).onResolutionFinalized(
                workflowId, escrowContract, activeResolver, false
            );
        }
        _decrementActiveAssignment(activeResolver);
        delete workflowStakeResolver[escrowContract][workflowId];
        _clearKlerosHandoff(escrowContract, workflowId);
        dm.status = DisputeStatus.Final;

        if (escrowContract.code.length != 0) {
            IResolverAssignmentCallback(escrowContract).updateDisputeResolverFromResolutionModule(
                workflowId, address(0)
            );
        }
    }

    function _decrementActiveAssignment(address resolver) internal {
        if (resolver == address(0)) return;
        if (resolverActiveDisputes[resolver] > 0) resolverActiveDisputes[resolver]--;
        if (resolverCapacity[resolver].currentDisputes > 0) resolverCapacity[resolver].currentDisputes--;
    }

    function _clearKlerosHandoff(address escrowContract, uint256 workflowId) internal {
        delete klerosDisputeIdForWorkflow[escrowContract][workflowId];
        delete klerosHandoffCommittedAt[escrowContract][workflowId];
        delete _klerosConfigRootForWorkflow[escrowContract][workflowId];
    }

    function forceProgress(uint256 workflowId, address escrowContract) external nonReentrant {
        if (!registeredEscrowContracts[_msgSender()] && !hasRole(ROLE_GUARDIAN, _msgSender()))
            revert NotRegisteredEscrowContract(_msgSender());

        DisputeMetadata storage dm = disputeMetadata[escrowContract][workflowId];

        if (block.timestamp < dm.resolveBy) revert DisputeNotTimedOut(workflowId, dm.resolveBy);
        uint256 committedDisputeIdPlusOne = klerosDisputeIdForWorkflow[escrowContract][workflowId];
        if (committedDisputeIdPlusOne != 0) {
            revert KlerosHandoffInProgress(workflowId, committedDisputeIdPlusOne - 1);
        }
        if (dm.status != DisputeStatus.Open) revert DisputeNotOpen(workflowId);

        uint8 currentRound = dm.currentRound;
        address timedOutResolver = dm.resolverAtRound[currentRound];

        ResolutionAnalytics.recordTimeout(
            resolverStats[timedOutResolver],
            timedOutResolver,
            workflowId,
            currentRound,
            1,
            emaAlphaBps
        );

        if (address(incentiveModule) != address(0)) {
            try incentiveModule.onResolverTimeout(workflowId, escrowContract, timedOutResolver, currentRound, 1) {} catch {
                emit IncentiveModuleCallFailed(workflowId, 'onResolverTimeout', 'FAILED');
            }
        }

        bytes32 category = dm.categoryKey;
        address newResolver;

        if (currentRound == 0) {
            newResolver = _selectResolverForWorkflow(escrowContract, workflowId, category, false);
            if (newResolver != address(0)) _advanceRoundRobinCounterForWorkflow(escrowContract, workflowId, category, false);
        } else if (currentRound == 1) {
            newResolver = _selectResolverForWorkflow(escrowContract, workflowId, category, true);
            if (newResolver != address(0)) _advanceRoundRobinCounterForWorkflow(escrowContract, workflowId, category, true);
        }

        if (newResolver != address(0) && newResolver != timedOutResolver) {
            // Decrement old resolver's capacity (they timed out and are being replaced)
            if (resolverActiveDisputes[timedOutResolver] > 0) resolverActiveDisputes[timedOutResolver]--;
            if (resolverCapacity[timedOutResolver].currentDisputes > 0) resolverCapacity[timedOutResolver].currentDisputes--;

            // Increment new resolver's capacity
            resolverCapacity[newResolver].currentDisputes++;
            resolverActiveDisputes[newResolver]++;
            resolverStats[newResolver].casesAssigned++;

            // Transfer the active exposure lock and escrow settlement authority
            // atomically with the module's timeout replacement.
            if (address(stakingModule) != address(0)) {
                IStakingModule(stakingModule).onDisputeEscalated(workflowId, escrowContract, timedOutResolver);
                IStakingModule(stakingModule).onResolverAssigned(
                    workflowId, escrowContract, newResolver, _requiredStakeForWorkflow(escrowContract, workflowId)
                );
            }
            workflowStakeResolver[escrowContract][workflowId] = newResolver;

            if (escrowContract.code.length != 0) {
                IResolverAssignmentCallback(escrowContract).updateDisputeResolverFromResolutionModule(
                    workflowId, newResolver
                );
            }

            dm.resolverAtRound[currentRound] = newResolver;
            dm.assignedAt = block.timestamp;
            dm.resolveBy = block.timestamp + _resolutionConfig(escrowContract, workflowId).resolveDeadlines[currentRound];
            emit ResolverAssigned(workflowId, newResolver, category, currentRound);

            if (address(incentiveModule) != address(0)) {
                try incentiveModule.onResolverAssigned(workflowId, escrowContract, newResolver, currentRound) {} catch {
                    emit IncentiveModuleCallFailed(workflowId, 'onResolverAssigned', 'FAILED');
                }
            }
        } else {
            address assignedStakeResolver = workflowStakeResolver[escrowContract][workflowId];
            if (assignedStakeResolver == address(0)) assignedStakeResolver = timedOutResolver;
            _decrementActiveAssignment(assignedStakeResolver);
            if (address(stakingModule) != address(0) && assignedStakeResolver != address(0)) {
                IStakingModule(stakingModule).onResolutionFinalized(
                    workflowId, escrowContract, assignedStakeResolver, false
                );
            }
            delete workflowStakeResolver[escrowContract][workflowId];
            if (escrowContract.code.length != 0) {
                IResolverAssignmentCallback(escrowContract).updateDisputeResolverFromResolutionModule(
                    workflowId, address(0)
                );
            }
            dm.status = DisputeStatus.Final;
        }
    }

    function _requiredStakeForWorkflow(address escrowContract, uint256 workflowId)
        internal
        view
        returns (uint256)
    {
        return _requiredStakeForExposure(workflowStakeExposureUSD[escrowContract][workflowId]);
    }

    function _requiredStakeForExposure(uint256 exposureUSD) internal pure returns (uint256) {
        if (exposureUSD == 0) return 0; // staking module applies the resolver-tier minimum
        return exposureUSD / ASSIGNMENT_STAKE_DIVISOR
            + (exposureUSD % ASSIGNMENT_STAKE_DIVISOR == 0 ? 0 : 1);
    }

    function _normalizeStakeExposure(address escrowToken, uint256 amount) internal view returns (uint256) {
        address requiredToken = IStakingModule(stakingModule).getStakeToken();
        if (escrowToken != requiredToken) revert UnsupportedStakeExposureToken(escrowToken, requiredToken);
        uint8 tokenDecimals = IERC20Metadata(escrowToken).decimals();
        if (tokenDecimals > 18) revert UnsupportedStakeExposureDecimals(escrowToken, tokenDecimals);
        return amount * (10 ** (18 - tokenDecimals));
    }

    function selectResolverWithQuality(
        bytes32 category,
        bool useSeniorResolvers,
        bool useQualityWeighting
    ) external view returns (address) {
        if (newAssignmentsPaused) return address(0);
        address[] storage list = useSeniorResolvers ? approvedSeniorResolvers : approvedResolvers;
        uint256 len = list.length;
        if (len == 0) return address(0);
        uint256 curIdx = useSeniorResolvers
            ? categorySeniorResolverIndex[category]
            : categoryResolverIndex[category];
        bytes32 blockHash = block.number >= 256 ? blockhash(block.number - 256) : blockhash(0);
        uint256 seed = uint256(keccak256(abi.encodePacked(blockHash, category, curIdx)));
        uint256 offset = seed % len;
        for (uint256 i = 0; i < len; i++) {
            address cand = list[(curIdx + offset + i) % len];
            if (resolverStats[cand].assignmentWeight == 0) continue;
            if (useQualityWeighting) {
                uint256 workloadWeight = ResolutionAnalytics.calculateWorkloadWeight(
                    resolverStats[cand],
                    minEmaScoreThreshold
                );
                if (workloadWeight == 0) continue;
                if (ResolutionAnalytics.getTimeoutRate(resolverStats[cand]) > maxTimeoutRateBps) continue;
            }
            if (
                resolverActive[cand] &&
                resolverCapacity[cand].acceptsNewDisputes &&
                (resolverCapacity[cand].maxConcurrentDisputes == 0 ||
                    resolverCapacity[cand].currentDisputes < resolverCapacity[cand].maxConcurrentDisputes)
            ) return cand;
        }
        return address(0);
    }

    // ============ Internal Helpers ============

    function _categoryEnabled(ResolutionConfig storage config, bytes32 category) internal view returns (bool) {
        uint256 len = config.categoryKeys.length;
        if (len == 0) return resolutionTable[category].enabled;
        for (uint256 i = 0; i < len; i++) {
            if (config.categoryKeys[i] == category) return true;
        }
        return false;
    }

    function _bondAsset(ResolutionConfig storage config, bytes calldata escrowData) internal view returns (address) {
        if (config.bondAssetFixed) return config.escalationCostConfig.bondToken;

        (address escrowToken, , , ) = abi.decode(escrowData, (address, address, address, uint256));
        if (address(bondTokenRegistry) != address(0) && !bondTokenRegistry.isAccepted(escrowToken)) {
            return bondTokenRegistry.defaultBondToken();
        }
        return escrowToken;
    }

    function _selectResolverRoundRobin(bytes32 category, bool useSenior) internal view returns (address) {
        if (newAssignmentsPaused) return address(0);

        address[] storage list = useSenior ? approvedSeniorResolvers : approvedResolvers;
        uint256 len = list.length;
        if (len == 0) return address(0);
        uint256 curIdx = useSenior ? categorySeniorResolverIndex[category] : categoryResolverIndex[category];
        bytes32 blockHash = block.number >= 256 ? blockhash(block.number - 256) : blockhash(0);
        uint256 seed = uint256(keccak256(abi.encodePacked(blockHash, category, curIdx)));
        uint256 offset = seed % len;
        for (uint256 i = 0; i < len; i++) {
            address cand = list[(curIdx + offset + i) % len];
            uint256 workloadWeight = ResolutionAnalytics.calculateWorkloadWeight(resolverStats[cand], minEmaScoreThreshold);
            if (workloadWeight == 0) continue;
            uint256 timeoutRate = ResolutionAnalytics.getTimeoutRate(resolverStats[cand]);
            if (timeoutRate > maxTimeoutRateBps) continue;
            if (
                resolverActive[cand] &&
                resolverCapacity[cand].acceptsNewDisputes &&
                (resolverCapacity[cand].maxConcurrentDisputes == 0 ||
                    resolverCapacity[cand].currentDisputes < resolverCapacity[cand].maxConcurrentDisputes)
            ) return cand;
        }
        return address(0);
    }

    function _selectResolverForWorkflow(address escrowContract, uint256 workflowId, bytes32 category, bool useSenior)
        internal
        view
        returns (address)
    {
        uint256 version = workflowResolutionConfigVersion[escrowContract][workflowId];
        if (version == 0) {
            // Legacy workflows deliberately retain the mutable global routing policy.
            if (category != bytes32(0) && resolutionTable[category].enabled) {
                address selected = _selectResolverRoundRobin(category, useSenior);
                if (selected != address(0)) return selected;
            }
            return _selectResolverRoundRobin(bytes32(0), useSenior);
        }

        ResolutionConfig storage config = _resolutionConfigs[version];
        bool categoryAllowed = category != bytes32(0) && _categoryEnabled(config, category);
        if (categoryAllowed) {
            address selected = _selectResolverWithConfig(config, version, category, useSenior);
            if (selected != address(0)) return selected;
        }
        if (config.categoryRouteBehavior == CategoryRouteBehavior.CATEGORY_ONLY && category != bytes32(0)) return address(0);
        return _selectResolverWithConfig(config, version, bytes32(0), useSenior);
    }

    function _selectResolverWithConfig(ResolutionConfig storage config, uint256, bytes32 category, bool useSenior)
        internal
        view
        returns (address)
    {
        if (newAssignmentsPaused) return address(0);
        address[] storage list = useSenior ? approvedSeniorResolvers : approvedResolvers;
        uint256 len = list.length;
        if (len == 0) return address(0);
        bytes32 cursorCategory = category;
        uint256 curIdx = useSenior ? categorySeniorResolverIndex[cursorCategory] : categoryResolverIndex[cursorCategory];
        bytes32 blockHash = block.number >= 256 ? blockhash(block.number - 256) : blockhash(0);
        uint256 offset = uint256(keccak256(abi.encodePacked(blockHash, cursorCategory, curIdx))) % len;
        for (uint256 i = 0; i < len; i++) {
            address cand = list[(curIdx + offset + i) % len];
            if (resolverStats[cand].assignmentWeight == 0) continue;
            if (config.weightingMode == ResolverWeightingMode.QUALITY_FILTERED) {
                if (ResolutionAnalytics.calculateWorkloadWeight(resolverStats[cand], config.minEmaScoreThreshold) == 0) continue;
                if (ResolutionAnalytics.getTimeoutRate(resolverStats[cand]) > config.maxTimeoutRateBps) continue;
            }
            if (resolverActive[cand] && resolverCapacity[cand].acceptsNewDisputes
                && (resolverCapacity[cand].maxConcurrentDisputes == 0
                    || resolverCapacity[cand].currentDisputes < resolverCapacity[cand].maxConcurrentDisputes)) return cand;
        }
        return address(0);
    }

    function _advanceRoundRobinCounterForWorkflow(address escrowContract, uint256 workflowId, bytes32 category, bool useSenior)
        internal
    {
        uint256 version = workflowResolutionConfigVersion[escrowContract][workflowId];
        if (version != 0) {
            _advanceRoundRobinCounter(category, useSenior);
            return;
        }
        _advanceRoundRobinCounter(category, useSenior);
    }

    function _advanceRoundRobinCounter(bytes32 category, bool useSenior) internal {
        uint256 len = useSenior ? approvedSeniorResolvers.length : approvedResolvers.length;
        if (len == 0) return;
        uint256 newIdx;
        if (useSenior) {
            newIdx = (categorySeniorResolverIndex[category] + 1) % len;
            categorySeniorResolverIndex[category] = newIdx;
        } else {
            newIdx = (categoryResolverIndex[category] + 1) % len;
            categoryResolverIndex[category] = newIdx;
        }
        emit RoundRobinCounterAdvanced(category, useSenior, newIdx);
    }
}
