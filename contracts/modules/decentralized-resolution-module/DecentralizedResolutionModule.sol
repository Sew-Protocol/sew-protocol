// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import '../../shared/interfaces/IResolutionModule.sol';
import '@openzeppelin/contracts/access/AccessControl.sol';
import '@openzeppelin/contracts/utils/ReentrancyGuard.sol';
import '../../governance/SlowLaneQueueActivate.sol';
import '../../shared/interfaces/IIncentiveModule.sol';
import './DRMStorageBase.sol';
import './ResolutionAnalytics.sol';
import './EscalationCostLibrary.sol';
import '../../libraries/ResolutionTableLibrary.sol';

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
    DRMStorageBase
{
    // ============ Errors ============
    error NotRegisteredEscrowContract(address caller);
    error AlreadyInitialized(uint256 workflowId);
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

    // ============ Events ============
    event DecisionSubmitted(uint256 indexed workflowId, uint8 round, address indexed resolver, ResolutionOutcome decision);
    event ResolverAssigned(uint256 indexed workflowId, address indexed resolver, bytes32 category, uint8 round);
    event IncentiveModuleCallFailed(uint256 indexed workflowId, string functionName, string reason);
    event RoundRobinCounterAdvanced(bytes32 indexed category, bool seniorResolvers, uint256 newIndex);
    event AdminFacetUpdated(address indexed oldFacet, address indexed newFacet);
    event DisputeClosedByMutualAgreement(uint256 indexed workflowId, address indexed escrowContract);

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
    }

    // ============ Admin Facet Bootstrap ============

    // Tracks whether setAdminFacet has been called once. After first use, only ROLE_TIMELOCK
    // can rotate the facet, eliminating the DEFAULT_ADMIN_ROLE backdoor.
    bool private _adminFacetSet;

    function setAdminFacet(address newFacet) external {
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
    function pauseNewAssignments(string memory) external { _delegateAdmin(); }
    function resumeNewAssignments() external { _delegateAdmin(); }

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
    function generateCategoryKey(address token, uint256 amount, string memory t) external pure returns (bytes32) { return keccak256(abi.encode(token, amount, t)); }
    function autoCategorizeEscrow(bytes calldata d) external pure returns (bytes32) { return ResolutionTableLibrary.autoCategorize(d); }
    function getAmountTier(uint256 a) external pure returns (string memory) { return ResolutionTableLibrary.getAmountTier(a); }
    function getAmountCategory(uint256 a) external pure returns (bytes32) { return keccak256(abi.encode(ResolutionTableLibrary.getAmountTier(a))); }

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
        bytes32 cat = escrowCategory[escrowContract][workflowId];
        if (cat != bytes32(0) && resolutionTable[cat].enabled) {
            address selected = _selectResolverRoundRobin(cat, false);
            if (selected != address(0)) return (selected, 0);
        }
        return (_selectResolverRoundRobin(bytes32(0), false), 0);
    }

    function canEscalate(
        uint256 workflowId,
        address escrowContract,
        uint8 currentLevel,
        bytes calldata
    ) external view override returns (bool allowed, address nextResolver, uint256 escalationFee) {
        uint8 nextRound = currentLevel + 1;
        if (nextRound > MAX_ROUND || !escalationConfig[nextRound].enabled)
            return (false, address(0), 0);
        if (nextRound == 1)
            nextResolver = _selectResolverRoundRobin(escrowCategory[escrowContract][workflowId], true);
        else if (nextRound == 2) nextResolver = externalResolver;
        if (nextResolver == address(0)) return (false, address(0), 0);

        uint256 bondAmount = 0;
        if (escalationCostConfig.enabled) {
            bondAmount = EscalationCostLibrary.calculateEscalationCost(currentLevel, escalationCostConfig);
        }
        return (true, nextResolver, bondAmount);
    }

    function executeEscalation(
        uint256 workflowId,
        address escrowContract,
        bytes calldata
    ) external override nonReentrant returns (bool success, address newResolver, uint8 newLevel) {
        DisputeMetadata storage dm = disputeMetadata[escrowContract][workflowId];
        uint8 fromRound = dm.currentRound;
        uint8 toRound = fromRound + 1;

        if (toRound > MAX_ROUND || !escalationConfig[toRound].enabled) {
            return (false, address(0), dm.currentRound);
        }

        address nextRes;
        if (toRound == 1) {
            nextRes = _selectResolverRoundRobin(escrowCategory[escrowContract][workflowId], true);
            if (nextRes != address(0)) _advanceRoundRobinCounter(escrowCategory[escrowContract][workflowId], true);
        } else if (toRound == 2) {
            nextRes = externalResolver;
        }

        if (nextRes == address(0)) return (false, address(0), dm.currentRound);

        dm.currentRound = toRound;
        dm.resolverAtRound[toRound] = nextRes;
        dm.assignedAt = block.timestamp;
        dm.resolveBy = block.timestamp + resolveDeadlines[toRound];
        resolverStats[nextRes].casesAssigned++;

        emit ResolverAssigned(workflowId, nextRes, escrowCategory[escrowContract][workflowId], toRound);

        if (address(incentiveModule) != address(0)) {
            try incentiveModule.onResolverAssigned(workflowId, escrowContract, nextRes, toRound) {} catch {
                emit IncentiveModuleCallFailed(workflowId, 'onResolverAssigned', 'FAILED');
            }
        }

        return (true, nextRes, toRound);
    }

    function getRequiredAppealBond(
        uint256, // workflowId
        address, // escrowContract
        uint8 currentLevel,
        bytes calldata escrowData
    ) external view override returns (uint256 amount, address token) {
        uint8 nextRound = currentLevel + 1;
        if (nextRound == 2 && externalResolver != address(0)) return (0, address(0));
        if (!escalationCostConfig.enabled) return (0, address(0));

        uint256 bondAmount = EscalationCostLibrary.calculateEscalationCost(currentLevel, escalationCostConfig);

        (address escrowToken, , , ) = abi.decode(escrowData, (address, address, address, uint256));
        address bondToken = escrowToken;
        if (address(bondTokenRegistry) != address(0) && !bondTokenRegistry.isAccepted(bondToken)) {
            bondToken = bondTokenRegistry.defaultBondToken();
        }
        return (bondAmount, bondToken);
    }

    function moduleName() external pure override returns (string memory) { return 'DecentralizedResolution'; }
    function moduleVersion() external pure override returns (string memory) { return '1.0.0'; }

    function supportsInterface(
        bytes4 interfaceId
    ) public view virtual override(AccessControl, IERC165) returns (bool) {
        return interfaceId == type(IResolutionModule).interfaceId || super.supportsInterface(interfaceId);
    }

    // ============ Escrow Contract Hooks ============

    function setEscrowCategory(
        uint256 workflowId,
        address escrowContract,
        bytes32 categoryKey
    ) external onlyEscrowContract {
        escrowCategory[escrowContract][workflowId] = categoryKey;
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

        capacity.currentDisputes++;
        resolverActiveDisputes[resolver]++;

        dm.currentRound = 0;
        dm.status = DisputeStatus.Open;
        dm.resolverAtRound[0] = resolver;
        dm.assignedAt = block.timestamp;
        dm.resolveBy = block.timestamp + resolveDeadlines[0];
        escrowCategory[escrowContract][workflowId] = categoryKey;

        resolverStats[resolver].casesAssigned++;
        _advanceRoundRobinCounter(categoryKey, false);
        emit ResolverAssigned(workflowId, resolver, categoryKey, 0);

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
        dm.appealDeadline[currentRound] = block.timestamp + appealWindows[currentRound];
        dm.status = DisputeStatus.Decided;

        ResolutionAnalytics.recordSuccessfulResolution(resolverStats[resolver], resolver, resolutionTime, emaAlphaBps);
        emit DecisionSubmitted(workflowId, currentRound, resolver, outcome);

        if (address(incentiveModule) != address(0)) {
            try incentiveModule.onDecisionSubmitted(workflowId, escrowContract, resolver, currentRound, outcome, resolutionTime) {} catch {
                emit IncentiveModuleCallFailed(workflowId, 'onDecisionSubmitted', 'FAILED');
            }
        }
    }

    function recordReversal(
        uint256 workflowId,
        address escrowContract,
        uint8 priorRound
    ) external override onlyEscrowContract {
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

            if (address(incentiveModule) != address(0)) {
                try incentiveModule.distributeAppealBond(workflowId, escrowContract, priorRound, true) {} catch {}
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
        DisputeMetadata storage dm = disputeMetadata[msg.sender][workflowId];

        // No-op if never disputed or already finalized
        if (dm.status == DisputeStatus.Final) return;

        dm.status = DisputeStatus.Final;
        uint8 finalRound = dm.currentRound;

        if (address(incentiveModule) != address(0)) {
            // Pass ResolutionOutcome.NONE — no resolver decision was reached
            try incentiveModule.onDisputeFinalized(workflowId, msg.sender, finalRound, ResolutionOutcome.NONE) {} catch {
                emit IncentiveModuleCallFailed(workflowId, 'onDisputeFinalized', 'MUTUAL_SETTLEMENT');
            }
        }

        emit DisputeClosedByMutualAgreement(workflowId, msg.sender);
    }

    function forceProgress(uint256 workflowId, address escrowContract) external nonReentrant {
        if (!registeredEscrowContracts[_msgSender()] && !hasRole(ROLE_GUARDIAN, _msgSender()))
            revert NotRegisteredEscrowContract(_msgSender());

        DisputeMetadata storage dm = disputeMetadata[escrowContract][workflowId];

        if (block.timestamp < dm.resolveBy) revert DisputeNotTimedOut(workflowId, dm.resolveBy);
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

        bytes32 category = escrowCategory[escrowContract][workflowId];
        address newResolver;

        if (currentRound == 0) {
            newResolver = _selectResolverRoundRobin(category, false);
            if (newResolver != address(0)) _advanceRoundRobinCounter(category, false);
        } else if (currentRound == 1) {
            newResolver = _selectResolverRoundRobin(category, true);
            if (newResolver != address(0)) _advanceRoundRobinCounter(category, true);
        }

        if (newResolver != address(0) && newResolver != timedOutResolver) {
            dm.resolverAtRound[currentRound] = newResolver;
            dm.assignedAt = block.timestamp;
            dm.resolveBy = block.timestamp + resolveDeadlines[currentRound];
            resolverStats[newResolver].casesAssigned++;
            emit ResolverAssigned(workflowId, newResolver, category, currentRound);

            if (address(incentiveModule) != address(0)) {
                try incentiveModule.onResolverAssigned(workflowId, escrowContract, newResolver, currentRound) {} catch {
                    emit IncentiveModuleCallFailed(workflowId, 'onResolverAssigned', 'FAILED');
                }
            }
        } else {
            dm.status = DisputeStatus.Final;
        }
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
