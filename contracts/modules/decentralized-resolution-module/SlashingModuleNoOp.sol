// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import './ISlashingModule.sol';
import '@openzeppelin/contracts/access/AccessControl.sol';

/**
 * @title SlashingModuleNoOp
 * @notice No-op implementation of ISlashingModule for testing and gradual rollout
 * @dev This is a placeholder that implements the interface but performs no actual slashing logic.
 *      Used to test the integration architecture before implementing real slashing.
 *
 *      All functions return success but do nothing.
 *      Events are emitted for observability.
 *
 *      WARNING: DO NOT USE IN PRODUCTION - This provides no actual slashing enforcement!
 */
contract SlashingModuleNoOp is ISlashingModule, AccessControl {
    bytes32 public constant ROLE_TIMELOCK = keccak256('ROLE_TIMELOCK');
    bytes32 public constant ROLE_RESOLUTION_MODULE = keccak256('ROLE_RESOLUTION_MODULE');

    bool public circuitBreakerActive;
    uint256 private _nextSlashId;

    // Dummy storage for testing (not used in logic)
    mapping(uint256 => SlashEvent) private _dummySlashEvents;
    mapping(uint256 => SlashAppeal) private _dummySlashAppeals;

    SlashConfig private _dummyConfig;
    uint256 private _dummyInsurancePoolBalance;

    constructor(address initialOwner) {
        // OpenZeppelin best practice: Grant DEFAULT_ADMIN_ROLE to deployer
        // Deployment scripts will transfer this to TimelockController
        _grantRole(DEFAULT_ADMIN_ROLE, initialOwner);

        circuitBreakerActive = false;
        _nextSlashId = 1;

        // Initialize dummy config with reasonable defaults
        _dummyConfig = SlashConfig({
            timeoutSlashBps: 500, // 5%
            reversalSlashBps: 1000, // 10%
            fraudSlashBps: 5000, // 50%
            maxSlashPerPeriod: 5000 ether,
            slashPeriod: 30 days,
            appealWindow: 3 days,
            appealBond: 100 ether
        });
    }

    // ============ Core Slashing Functions (No-Op) ============

    function proposeSlash(
        uint256 workflowId,
        address /* escrowContract */,
        address resolver,
        SlashReason reason,
        bytes calldata /* evidence */
    ) external override returns (uint256 slashId) {
        slashId = _nextSlashId++;

        emit SlashProposed(
            slashId,
            workflowId,
            resolver,
            reason,
            0, // No actual amount in no-op
            _msgSender()
        );

        return slashId;
    }

    function executeSlash(uint256 slashId) external override {
        emit SlashExecuted(
            slashId,
            address(0),
            0,
            SlashDistribution({
                toProtocol: 0,
                toCounterParty: 0,
                toInsurancePool: 0,
                toSlashProposer: 0
            })
        );
    }

    function appealSlash(
        uint256 slashId,
        string calldata reason,
        bytes calldata /* evidence */
    ) external override {
        emit SlashAppealed(slashId, _msgSender(), _dummyConfig.appealBond, reason);
    }

    function resolveAppeal(uint256 slashId, bool upheld) external override onlyRole(ROLE_TIMELOCK) {
        emit SlashAppealResolved(slashId, upheld, address(0), 0);

        if (upheld) {
            emit SlashReversed(slashId, address(0), 0);
        }
    }

    // ============ Automated Slashing (No-Op) ============

    function slashForTimeout(
        uint256 workflowId,
        address /* escrowContract */,
        address resolver,
        uint8 timeoutType
    ) external override onlyRole(ROLE_RESOLUTION_MODULE) returns (uint256 slashId) {
        slashId = _nextSlashId++;

        SlashReason reason = timeoutType == 0
            ? SlashReason.TIMEOUT_ACCEPT
            : SlashReason.TIMEOUT_RESOLVE;

        emit SlashProposed(
            slashId,
            workflowId,
            resolver,
            reason,
            0, // No actual amount in no-op
            _msgSender()
        );

        return slashId;
    }

    function slashForReversal(
        uint256 workflowId,
        address /* escrowContract */,
        address resolver,
        uint8 /* priorRound */
    ) external override onlyRole(ROLE_RESOLUTION_MODULE) returns (uint256 slashId) {
        slashId = _nextSlashId++;
        emit SlashProposed(slashId, workflowId, resolver, SlashReason.REVERSAL, 0, _msgSender());
        return slashId;
    }

    function restoreReversalSlashOnVindication(
        uint256 /* workflowId */,
        bool /* currentIsRelease */,
        uint8[] calldata /* priorDecisions */
    ) external override onlyRole(ROLE_RESOLUTION_MODULE) returns (uint256 restoredCount) {
        return 0;
    }

    function hasPendingSlash(address /* resolver */) external pure override returns (bool hasPending) {
        return false;
    }

    function slashForFraud(
        uint256 workflowId,
        address /* escrowContract */,
        address resolver,
        bytes calldata /* evidence */
    ) external override returns (uint256 slashId) {
        slashId = _nextSlashId++;

        emit SlashProposed(
            slashId,
            workflowId,
            resolver,
            SlashReason.FRAUD,
            0, // No actual amount in no-op
            _msgSender()
        );

        return slashId;
    }

    // ============ Query Functions (No-Op - return dummy data) ============

    function getSlashEvent(uint256 slashId) external pure override returns (SlashEvent memory) {
        return
            SlashEvent({
                slashId: slashId,
                workflowId: 0,
                escrowContract: address(0),
                resolver: address(0),
                reason: SlashReason.TIMEOUT_RESOLVE,
                amount: 0,
                proposedAt: 0,
                executedAt: 0,
                appealDeadline: 0,
                status: SlashStatus.PENDING,
                proposer: address(0),
                evidence: ''
            });
    }

    function getSlashAppeal(uint256 slashId) external pure override returns (SlashAppeal memory) {
        return
            SlashAppeal({
                slashId: slashId,
                appellant: address(0),
                appealBond: 0,
                appealedAt: 0,
                reason: '',
                evidence: '',
                resolved: false,
                upheld: false
            });
    }

    function calculateSlashAmount(
        address /* resolver */,
        SlashReason /* reason */
    ) external pure override returns (uint256 amount) {
        // Return 0 in no-op mode
        return 0;
    }

    function getSlashableStake(
        address /* resolver */
    ) external pure override returns (uint256 slashable) {
        // Return 0 in no-op mode
        return 0;
    }

    function getSlashedInPeriod(address /* resolver */) external pure override returns (uint256 slashed) {
        return 0;
    }

    function getSlashConfig() external view override returns (SlashConfig memory config) {
        return _dummyConfig;
    }

    function canAppeal(uint256 /* slashId */) external pure override returns (bool) {
        return true; // Always allow appeals in no-op mode
    }

    function canExecute(uint256 /* slashId */) external pure override returns (bool) {
        return true; // Always allow execution in no-op mode
    }

    function getInsurancePoolBalance() external view override returns (uint256 balance) {
        return _dummyInsurancePoolBalance;
    }

    // ============ Distribution Functions (No-Op) ============

    function calculateDistribution(
        uint256 amount,
        SlashReason /* reason */
    ) external pure override returns (SlashDistribution memory distribution) {
        // Return dummy distribution
        return
            SlashDistribution({
                toProtocol: amount / 2,
                toCounterParty: amount / 3,
                toInsurancePool: amount / 6,
                toSlashProposer: 0
            });
    }

    function claimInsurancePayout(
        uint256 workflowId,
        address to,
        uint256 amount
    ) external override {
        emit InsurancePoolPayout(to, amount, workflowId);
    }

    // ============ Admin Functions (No-Op) ============

    function setSlashPercentage(
        SlashReason reason,
        uint256 bps
    ) external override onlyRole(ROLE_TIMELOCK) {
        uint256 oldBps;

        if (reason == SlashReason.TIMEOUT_ACCEPT || reason == SlashReason.TIMEOUT_RESOLVE) {
            oldBps = _dummyConfig.timeoutSlashBps;
            _dummyConfig.timeoutSlashBps = bps;
        } else if (reason == SlashReason.REVERSAL) {
            oldBps = _dummyConfig.reversalSlashBps;
            _dummyConfig.reversalSlashBps = bps;
        } else {
            oldBps = _dummyConfig.fraudSlashBps;
            _dummyConfig.fraudSlashBps = bps;
        }

        emit SlashConfigUpdated(reason, oldBps, bps);
    }

    function setMaxSlashPerPeriod(
        uint256 max,
        uint256 period
    ) external override onlyRole(ROLE_TIMELOCK) {
        _dummyConfig.maxSlashPerPeriod = max;
        _dummyConfig.slashPeriod = period;
    }

    function setAppealWindow(uint256 window) external override onlyRole(ROLE_TIMELOCK) {
        _dummyConfig.appealWindow = window;
    }

    function setAppealBond(uint256 bond) external override onlyRole(ROLE_TIMELOCK) {
        _dummyConfig.appealBond = bond;
    }

    function fundInsurancePool(uint256 amount) external override {
        _dummyInsurancePoolBalance += amount;
        emit InsurancePoolFunded(amount, _dummyInsurancePoolBalance);
    }

    function triggerCircuitBreaker(string memory reason) external override onlyRole(ROLE_TIMELOCK) {
        circuitBreakerActive = true;
        emit CircuitBreakerTriggered(address(0), 0, 0, reason);
    }

    function resetCircuitBreaker() external override onlyRole(ROLE_TIMELOCK) {
        circuitBreakerActive = false;
    }

    // ============ Setup Functions ============

    function setResolutionModule(address module) external onlyRole(ROLE_TIMELOCK) {
        _grantRole(ROLE_RESOLUTION_MODULE, module);
    }
}
