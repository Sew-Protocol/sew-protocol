// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.37;

import '@openzeppelin/contracts/access/AccessControl.sol';
import './EscrowStorage.sol';
import '../types/EscrowTypes.sol';

// Configuration owns governance-controlled escrow policy. It deliberately has
// no state of its own; EscrowStorage remains the sole storage declaration.
abstract contract EscrowConfiguration is AccessControl, EscrowStorage {
    error InvalidEscrowFee(uint256 fee, uint256 maxFee);
    error FeeExceedsMaximum(uint256 feeBps, uint256 maxFeeBps);
    error InvalidConfig(uint8 code, uint256 value);
    error AlreadyPausedCannotRepause();
    error NotPaused();
    error EnforcedPause();
    error UnauthorizedPauseCaller(address caller);
    error ZeroBondCollector();
    event YieldProtocolFeeBpsUpdated(uint256 oldFeeBps, uint256 newFeeBps);
    event AppealBondProtocolFeeBpsUpdated(uint256 oldFeeBps, uint256 newFeeBps);
    event ResolutionModuleActivated(address indexed oldModule, address indexed newModule);
    event TimeoutConfigUpdated(TimeoutConfig config);
    event MinDisputeEscrowValueUpdated(uint256 newValue);
    event MaxDisputesPerSenderPerDayUpdated(uint32 newMax);
    event EscalationCooldownUpdated(uint64 newCooldown);
    event FeeRecipientUpdated(address indexed oldAddr, address indexed newAddr);
    event EscrowFeeBpsUpdated(uint256 oldFeeBps, uint256 newFeeBps);
    event CreationPolicyUpdated(address indexed oldPolicy, address indexed newPolicy);
    event BondCollectorUpdated(address indexed oldCollector, address indexed newCollector);
    event IncidentPauseTriggered(string reason, uint256 timestamp, uint256 pauseCycleCount);
    event SystemResumed(uint256 timestamp);

    /// @notice Stop creation of new escrows during an incident.
    /// @dev Existing escrow dispute, appeal, settlement, claim and withdrawal
    ///      actions remain available. Appeal deadlines continue during a pause.
    ///      The guardian can only pause; governance timelock controls recovery.
    function pause(string calldata reason) external {
        if (!hasRole(ROLE_GUARDIAN, _msgSender()) && !hasRole(ROLE_TIMELOCK, _msgSender())) {
            revert UnauthorizedPauseCaller(_msgSender());
        }
        if (emergencyPaused) revert AlreadyPausedCannotRepause();
        emergencyPaused = true;
        pauseStartedAt = block.timestamp;
        pauseCycles += 1;
        emit IncidentPauseTriggered(reason, block.timestamp, pauseCycles);
    }

    /// @notice Resume new escrow creation after governance reviews the incident.
    function unpause() external onlyRole(ROLE_TIMELOCK) {
        if (!emergencyPaused) revert NotPaused();
        accumulatedPausedDuration += block.timestamp - pauseStartedAt;
        emergencyPaused = false;
        pauseStartedAt = 0;
        lastUnpausedAt = block.timestamp;
        emit SystemResumed(block.timestamp);
    }

    function paused() external view returns (bool) { return emergencyPaused; }

    /// @return pausedAt Current pause start, or zero when not paused.
    /// @return unpausedAt Most recent resume timestamp, or zero before first resume.
    /// @return cycleCount Number of pause cycles since the last cycle reset.
    /// @return lastResetAt Timestamp of the most recent cycle reset (zero until reset).
    function pauseState() external view returns (uint256 pausedAt, uint256 unpausedAt, uint256 cycleCount, uint256 lastResetAt) {
        return (pauseStartedAt, lastUnpausedAt, pauseCycles, 0);
    }

    function pauseCycleCount() external view returns (uint256) { return pauseCycles; }

    function totalPausedDuration() external view returns (uint256) {
        return accumulatedPausedDuration + (emergencyPaused ? block.timestamp - pauseStartedAt : 0);
    }

    function _requireNotPaused() internal view {
        if (emergencyPaused) revert EnforcedPause();
    }

    function setFeeRecipient(address newAddr) external onlyRole(ROLE_ADMIN_CONTRACT) {
        if (newAddr == address(0)) revert InvalidAddress(ADDR_FEE_RECIPIENT, newAddr);
        address oldAddr = escrowFeeAddress;
        escrowFeeAddress = newAddr;
        emit FeeRecipientUpdated(oldAddr, newAddr);
    }

    function setEscrowFeeBps(uint256 feeBps) external onlyRole(ROLE_ADMIN_CONTRACT) {
        if (feeBps > MAX_ESCROW_FEE_BPS) revert InvalidEscrowFee(feeBps, MAX_ESCROW_FEE_BPS);
        uint256 oldFee = escrowFee;
        escrowFee = feeBps;
        emit EscrowFeeBpsUpdated(oldFee, feeBps);
    }

    function setYieldProtocolFeeBps(uint256 feeBps) external onlyRole(ROLE_ADMIN_CONTRACT) {
        if (feeBps > MAX_PROTOCOL_FEE_BPS) revert FeeExceedsMaximum(feeBps, MAX_PROTOCOL_FEE_BPS);
        if (feeBps > 0 && escrowFeeAddress == address(0)) revert InvalidAddress(ADDR_FEE_RECIPIENT, address(0));
        uint256 oldFee = yieldProtocolFeeBps;
        yieldProtocolFeeBps = feeBps;
        emit YieldProtocolFeeBpsUpdated(oldFee, feeBps);
    }

    function setAppealBondProtocolFeeBps(uint256 feeBps) external onlyRole(ROLE_ADMIN_CONTRACT) {
        if (feeBps > MAX_PROTOCOL_FEE_BPS) revert FeeExceedsMaximum(feeBps, MAX_PROTOCOL_FEE_BPS);
        if (feeBps > 0 && escrowFeeAddress == address(0)) revert InvalidAddress(ADDR_FEE_RECIPIENT, address(0));
        uint256 oldFee = appealBondProtocolFeeBps;
        appealBondProtocolFeeBps = feeBps;
        emit AppealBondProtocolFeeBpsUpdated(oldFee, feeBps);
    }

    function setResolutionModule(address module) external onlyRole(ROLE_ADMIN_CONTRACT) {
        if (module == address(0)) revert InvalidAddress(ADDR_GENERIC, module);
        if (module.code.length == 0) revert ModuleNotContract(module);
        address oldModule = disputeResolutionModule;
        disputeResolutionModule = module;
        emit ResolutionModuleActivated(oldModule, module);
    }

    function setTimeoutConfig(TimeoutConfig calldata config) external onlyRole(ROLE_ADMIN_CONTRACT) {
        if (config.defaultAutoReleaseDelay > 0 && config.defaultAutoCancelDelay > 0) revert InvalidConfig(4, config.defaultAutoReleaseDelay);
        timeoutConfig = config;
        emit TimeoutConfigUpdated(config);
    }

    function setMinDisputeEscrowValue(uint256 value) external onlyRole(ROLE_ADMIN_CONTRACT) {
        minDisputeEscrowValue = value;
        emit MinDisputeEscrowValueUpdated(value);
    }

    function setMaxDisputesPerSenderPerDay(uint32 max) external onlyRole(ROLE_ADMIN_CONTRACT) {
        maxDisputesPerSenderPerDay = max;
        emit MaxDisputesPerSenderPerDayUpdated(max);
    }

    function setEscalationCooldown(uint64 cooldown) external onlyRole(ROLE_ADMIN_CONTRACT) {
        escalationCooldown = cooldown;
        emit EscalationCooldownUpdated(cooldown);
    }

    function setCreationPolicy(address policy) external onlyRole(ROLE_TIMELOCK) {
        if (policy == address(0)) revert ZeroCreationPolicy();
        address oldPolicy = address(creationPolicy);
        creationPolicy = EscrowCreationPolicy(policy);
        emit CreationPolicyUpdated(oldPolicy, policy);
    }

    function setBondCollector(address collector) external onlyRole(ROLE_TIMELOCK) {
        if (collector == address(0)) revert ZeroBondCollector();
        address oldCollector = address(bondCollector);
        bondCollector = BondCollector(collector);
        emit BondCollectorUpdated(oldCollector, collector);
    }
}


