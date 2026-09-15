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
    error PausedNotSupported();
    error ZeroBondCollector();
    event YieldProtocolFeeBpsUpdated(uint256 oldFeeBps, uint256 newFeeBps);
    event AppealBondProtocolFeeBpsUpdated(uint256 oldFeeBps, uint256 newFeeBps);
    event ResolutionModuleActivated(address indexed oldModule, address indexed newModule);
    event TimeoutConfigUpdated(TimeoutConfig config);
    event MinDisputeEscrowValueUpdated(uint256 newValue);
    event MaxDisputesPerSenderPerDayUpdated(uint32 newMax);
    event EscalationCooldownUpdated(uint64 newCooldown);

    function pause(string calldata) external pure { revert PausedNotSupported(); }
    function unpause() external pure { revert PausedNotSupported(); }
    function paused() external pure returns (bool) { return false; }
    function pauseState() external pure returns (uint256, uint256, uint256, uint256) {
        return (0, 0, 0, 0);
    }
    function pauseCycleCount() external pure returns (uint256) { return 0; }

    function setFeeRecipient(address newAddr) external onlyRole(ROLE_ADMIN_CONTRACT) {
        if (newAddr == address(0)) revert InvalidAddress(ADDR_FEE_RECIPIENT, newAddr);
        escrowFeeAddress = newAddr;
    }

    function setEscrowFeeBps(uint256 feeBps) external onlyRole(ROLE_ADMIN_CONTRACT) {
        if (feeBps > MAX_ESCROW_FEE_BPS) revert InvalidEscrowFee(feeBps, MAX_ESCROW_FEE_BPS);
        escrowFee = feeBps;
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

    function setCreateOps(address ops) external onlyRole(ROLE_TIMELOCK) {
        if (ops == address(0)) revert ZeroCreateOps();
        createOps = CreateOps(ops);
    }

    function setBondCollector(address collector) external onlyRole(ROLE_TIMELOCK) {
        if (collector == address(0)) revert ZeroBondCollector();
        bondCollector = BondCollector(collector);
    }
}


