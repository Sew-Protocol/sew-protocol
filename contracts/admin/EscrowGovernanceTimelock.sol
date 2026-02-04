// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import '@openzeppelin/contracts/access/AccessControl.sol';
import '../governance/SlowLaneQueueActivate.sol';
import '../core/BaseEscrow.sol';
import '../types/EscrowTypes.sol';
import '../libraries/SettingsValidationLibrary.sol';

// Error definitions (matching BaseEscrow for consistency)
error InvalidValue();

/**
 * @title EscrowGovernanceTimelock
 * @notice Time-delayed governance contract for escrow configuration changes.
 * @dev This contract is the "slow lane" state holder for protocol configuration.
 *
 * Design / responsibilities:
 * - Owns all queue/activate pending state (value + eta) per escrow contract.
 * - Enforces the Slow Lane delay via `SlowLaneQueueActivate`.
 * - Applies activated values by calling minimal setter functions on the target escrow contract.
 *
 * Intended integration pattern:
 * - Governance (TimelockController) calls `queueX(escrowContract, ...)`.
 * - After the slow delay elapses, governance calls `activateX(escrowContract)`.
 * - The escrow contract must be compatible with `BaseEscrow` and expose the relevant setters.
 *
 * Important: role wiring prerequisite:
 * - The target escrow contract must authorize this admin contract to call its setter functions.
 * - In this codebase that is typically done via a dedicated role like `ROLE_ADMIN_CONTRACT`.
 * - If the escrow contract has NOT granted the required role(s) to this contract, activate calls will revert.
 */
contract EscrowGovernanceTimelock is AccessControl, SlowLaneQueueActivate {
    /// @notice Governance role (intended to be held by TimelockController).
    bytes32 public constant ROLE_TIMELOCK = keccak256('ROLE_TIMELOCK');
    /// @notice Role granted to registered escrow contracts (metadata/allowlisting).
    bytes32 public constant ROLE_ESCROW_CONTRACT = keccak256('ROLE_ESCROW_CONTRACT');
    


    /// @notice Per-escrow-contract pending admin state (slow lane queue/activate).
    struct AdminState {
        // Pending values
        PendingAddress pendingFeeRecipient;
        PendingUint pendingEscrowFee;
        PendingUint pendingYieldProtocolFeeBps;
        PendingUint pendingAppealBondProtocolFeeBps;
        PendingAddress pendingResolutionModule;
    }

    /// @notice Mapping from escrow contract => pending admin state.
    mapping(address => AdminState) public escrowAdminStates;

    /// @notice Emitted when a fee recipient change is queued for an escrow contract.
    event FeeRecipientQueued(address indexed escrowContract, address indexed oldAddr, address indexed newAddr, uint64 eta);
    /// @notice Emitted when a fee recipient change is activated for an escrow contract.
    event FeeRecipientActivated(address indexed escrowContract, address indexed oldAddr, address indexed newAddr);
    /// @notice Emitted when an escrow fee change is queued for an escrow contract.
    event EscrowFeeQueued(address indexed escrowContract, uint256 oldFee, uint256 newFee, uint64 eta);
    /// @notice Emitted when an escrow fee change is activated for an escrow contract.
    event EscrowFeeActivated(address indexed escrowContract, uint256 oldFee, uint256 newFee);
    /// @notice Emitted when a yield protocol fee change is queued for an escrow contract.
    event YieldProtocolFeeQueued(address indexed escrowContract, uint256 oldFee, uint256 newFee, uint64 eta);
    /// @notice Emitted when a yield protocol fee change is activated for an escrow contract.
    event YieldProtocolFeeActivated(address indexed escrowContract, uint256 oldFee, uint256 newFee);
    /// @notice Emitted when an appeal bond protocol fee change is queued for an escrow contract.
    event AppealBondProtocolFeeQueued(address indexed escrowContract, uint256 oldFee, uint256 newFee, uint64 eta);
    /// @notice Emitted when an appeal bond protocol fee change is activated for an escrow contract.
    event AppealBondProtocolFeeActivated(address indexed escrowContract, uint256 oldFee, uint256 newFee);
    /// @notice Emitted when a resolution module change is queued for an escrow contract.
    event ResolutionModuleQueued(address indexed escrowContract, address indexed oldModule, address indexed newModule, uint64 eta);
    /// @notice Emitted when a resolution module change is activated for an escrow contract.
    event ResolutionModuleActivated(address indexed escrowContract, address indexed oldModule, address indexed newModule);

    /**
     * @notice Deploy the EscrowGovernanceTimelock.
     * @param initialOwner Initial admin for bootstrap (expected to be replaced/managed by governance wiring).
     * @dev Grants `DEFAULT_ADMIN_ROLE` and `ROLE_TIMELOCK` to `initialOwner` for initial setup.
     *      In production, `ROLE_TIMELOCK` should be granted to the TimelockController and
     *      `initialOwner` should have its roles revoked as part of deployment hardening.
     */
    constructor(address initialOwner) {
        _grantRole(DEFAULT_ADMIN_ROLE, initialOwner);
        _grantRole(ROLE_TIMELOCK, initialOwner);
        // SlowLaneQueueActivate is abstract - no constructor call needed
    }

    /**
     * @notice Register an escrow contract with this admin contract.
     * @param escrowContract Address of the escrow contract to register.
     * @dev This grants the escrow contract `ROLE_ESCROW_CONTRACT` in this admin contract.
     *      Registration is governance-controlled (`ROLE_TIMELOCK`).
     *
     * Note: registration is informational/allowlisting for offchain consumers;
     * queue/activate functions do not currently check `ROLE_ESCROW_CONTRACT`.
     */
    function registerEscrowContract(address escrowContract) external onlyRole(ROLE_TIMELOCK) {
        if (escrowContract == address(0)) revert InvalidValue();
        _grantRole(ROLE_ESCROW_CONTRACT, escrowContract);
    }

    // ============ Fee Recipient Management ============

    /**
     * @notice Queue a new escrow fee recipient address
     * @param escrowContract Address of the escrow contract
     * @param newAddr New fee recipient address to queue
     * @dev Uses slow lane activation pattern. Requires ROLE_TIMELOCK.
     *      Reverts if `newAddr` is invalid per `SlowLaneQueueActivate` rules.
     */
    function queueFeeRecipient(address escrowContract, address newAddr) external onlyRole(ROLE_TIMELOCK) {
        AdminState storage state = escrowAdminStates[escrowContract];
        address oldAddr = BaseEscrow(escrowContract).escrowFeeAddress();
        _queueAddress(state.pendingFeeRecipient, newAddr);
        emit FeeRecipientQueued(escrowContract, oldAddr, newAddr, state.pendingFeeRecipient.eta);
    }

    /**
     * @notice Activate the queued fee recipient address
     * @param escrowContract Address of the escrow contract
     * @dev Activates after timelock delay. Requires ROLE_TIMELOCK.
     *      Reverts if no value is queued, or if the ETA has not passed yet.
     *
     * Role wiring:
     * - The target escrow contract must grant this admin contract whatever role gates `setFeeRecipient`.
     */
    function activateFeeRecipient(address escrowContract) external onlyRole(ROLE_TIMELOCK) {
        AdminState storage state = escrowAdminStates[escrowContract];
        address oldAddr = BaseEscrow(escrowContract).escrowFeeAddress();
        address newAddr = _activateAddress(state.pendingFeeRecipient);
        BaseEscrow(escrowContract).setFeeRecipient(newAddr);
        emit FeeRecipientActivated(escrowContract, oldAddr, newAddr);
    }

    /**
     * @notice Get pending fee recipient address information
     * @param escrowContract Address of the escrow contract
     * @return value Pending fee recipient address
     * @return eta Timestamp when activation becomes available
     * @return exists Whether a pending address exists
     */
    function getPendingFeeRecipient(address escrowContract) external view returns (address value, uint64 eta, bool exists) {
        return getPendingAddress(escrowAdminStates[escrowContract].pendingFeeRecipient);
    }

    // ============ Escrow Fee Management ============

    /**
     * @notice Queue a new escrow fee percentage
     * @param escrowContract Address of the escrow contract
     * @param feeBps New fee in basis points (e.g., 100 = 1%)
     * @dev Uses slow lane activation pattern. Requires ROLE_TIMELOCK.
     *      For launch, the max fee is capped at 200 bps (2%).
     */
    function queueEscrowFee(address escrowContract, uint256 feeBps) external onlyRole(ROLE_TIMELOCK) {
        uint256 maxFee = 200; // MAX_ESCROW_FEE_BPS = 200 (2%)
        if (feeBps > maxFee) revert InvalidEscrowFee(feeBps, maxFee);
        AdminState storage state = escrowAdminStates[escrowContract];
        uint256 oldFee = BaseEscrow(escrowContract).escrowFee();
        _queueUint(state.pendingEscrowFee, feeBps);
        emit EscrowFeeQueued(escrowContract, oldFee, feeBps, state.pendingEscrowFee.eta);
    }

    /**
     * @notice Activate the queued escrow fee
     * @param escrowContract Address of the escrow contract
     * @dev Activates after timelock delay. Requires ROLE_TIMELOCK.
     *      Reverts if no value is queued, or if the ETA has not passed yet.
     *
     * Role wiring:
     * - The target escrow contract must grant this admin contract whatever role gates `setEscrowFeeBps`.
     */
    function activateEscrowFee(address escrowContract) external onlyRole(ROLE_TIMELOCK) {
        AdminState storage state = escrowAdminStates[escrowContract];
        uint256 oldFee = BaseEscrow(escrowContract).escrowFee();
        uint256 newFee = _activateUint(state.pendingEscrowFee);
        uint256 maxFee = 200; // MAX_ESCROW_FEE_BPS = 200 (2%)
        if (newFee > maxFee) revert InvalidEscrowFee(newFee, maxFee);
        BaseEscrow(escrowContract).setEscrowFeeBps(newFee);
        emit EscrowFeeActivated(escrowContract, oldFee, newFee);
    }

    /**
     * @notice Get pending escrow fee information
     * @param escrowContract Address of the escrow contract
     * @return value Pending fee in basis points
     * @return eta Timestamp when activation becomes available
     * @return exists Whether a pending fee exists
     */
    function getPendingEscrowFee(address escrowContract) external view returns (uint256 value, uint64 eta, bool exists) {
        return getPendingUint(escrowAdminStates[escrowContract].pendingEscrowFee);
    }

    // ============ Protocol Fee Management ============

    /**
     * @notice Queue a new yield protocol fee in basis points
     * @param escrowContract Address of the escrow contract
     * @param feeBps New fee in basis points (0-3000 = 0-30%)
     * @dev Uses slow lane activation pattern. Requires ROLE_TIMELOCK.
     */
    function queueYieldProtocolFeeBps(address escrowContract, uint256 feeBps) external onlyRole(ROLE_TIMELOCK) {
        uint256 maxFee = 3000; // MAX_PROTOCOL_FEE_BPS = 3000 (30%)
        if (feeBps > maxFee) revert FeeExceedsMaximum(feeBps, maxFee);
        AdminState storage state = escrowAdminStates[escrowContract];
        uint256 oldFee = BaseEscrow(escrowContract).yieldProtocolFeeBps();
        _queueUint(state.pendingYieldProtocolFeeBps, feeBps);
        emit YieldProtocolFeeQueued(escrowContract, oldFee, feeBps, state.pendingYieldProtocolFeeBps.eta);
    }

    /**
     * @notice Activate the queued yield protocol fee
     * @param escrowContract Address of the escrow contract
     * @dev Activates after timelock delay. Requires ROLE_TIMELOCK.
     *      Reverts if no value is queued, or if the ETA has not passed yet.
     *
     * Role wiring:
     * - The target escrow contract must grant this admin contract whatever role gates `setYieldProtocolFeeBps`.
     */
    function activateYieldProtocolFeeBps(address escrowContract) external onlyRole(ROLE_TIMELOCK) {
        AdminState storage state = escrowAdminStates[escrowContract];
        uint256 oldFee = BaseEscrow(escrowContract).yieldProtocolFeeBps();
        uint256 newFee = _activateUint(state.pendingYieldProtocolFeeBps);
        BaseEscrow(escrowContract).setYieldProtocolFeeBps(newFee);
        emit YieldProtocolFeeActivated(escrowContract, oldFee, newFee);
    }

    /**
     * @notice Get pending yield protocol fee information
     * @param escrowContract Address of the escrow contract
     * @return value Pending fee in basis points
     * @return eta Timestamp when activation becomes available
     * @return exists Whether a pending fee exists
     */
    function getPendingYieldProtocolFeeBps(address escrowContract) external view returns (uint256 value, uint64 eta, bool exists) {
        return getPendingUint(escrowAdminStates[escrowContract].pendingYieldProtocolFeeBps);
    }

    /**
     * @notice Queue a new appeal bond protocol fee in basis points
     * @param escrowContract Address of the escrow contract
     * @param feeBps New fee in basis points (0-3000 = 0-30%)
     * @dev Uses slow lane activation pattern. Requires ROLE_TIMELOCK.
     */
    function queueAppealBondProtocolFeeBps(address escrowContract, uint256 feeBps) external onlyRole(ROLE_TIMELOCK) {
        uint256 maxFee = 3000; // MAX_PROTOCOL_FEE_BPS = 3000 (30%)
        if (feeBps > maxFee) revert FeeExceedsMaximum(feeBps, maxFee);
        AdminState storage state = escrowAdminStates[escrowContract];
        uint256 oldFee = BaseEscrow(escrowContract).appealBondProtocolFeeBps();
        _queueUint(state.pendingAppealBondProtocolFeeBps, feeBps);
        emit AppealBondProtocolFeeQueued(escrowContract, oldFee, feeBps, state.pendingAppealBondProtocolFeeBps.eta);
    }

    /**
     * @notice Activate the queued appeal bond protocol fee
     * @param escrowContract Address of the escrow contract
     * @dev Activates after timelock delay. Requires ROLE_TIMELOCK.
     *      Reverts if no value is queued, or if the ETA has not passed yet.
     *
     * Role wiring:
     * - The target escrow contract must grant this admin contract whatever role gates `setAppealBondProtocolFeeBps`.
     */
    function activateAppealBondProtocolFeeBps(address escrowContract) external onlyRole(ROLE_TIMELOCK) {
        AdminState storage state = escrowAdminStates[escrowContract];
        uint256 oldFee = BaseEscrow(escrowContract).appealBondProtocolFeeBps();
        uint256 newFee = _activateUint(state.pendingAppealBondProtocolFeeBps);
        BaseEscrow(escrowContract).setAppealBondProtocolFeeBps(newFee);
        emit AppealBondProtocolFeeActivated(escrowContract, oldFee, newFee);
    }

    /**
     * @notice Get pending appeal bond protocol fee information
     * @param escrowContract Address of the escrow contract
     * @return value Pending fee in basis points
     * @return eta Timestamp when activation becomes available
     * @return exists Whether a pending fee exists
     */
    function getPendingAppealBondProtocolFeeBps(address escrowContract) external view returns (uint256 value, uint64 eta, bool exists) {
        return getPendingUint(escrowAdminStates[escrowContract].pendingAppealBondProtocolFeeBps);
    }

    // ============ Resolution Module Management ============

    /**
     * @notice Queue a new resolution module
     * @param escrowContract Address of the escrow contract
     * @param module Address of the new resolution module to queue
     * @dev Uses slow lane activation pattern. Requires ROLE_TIMELOCK.
     */
    function queueResolutionModule(address escrowContract, address module) external onlyRole(ROLE_TIMELOCK) {
        AdminState storage state = escrowAdminStates[escrowContract];
        address oldModule = BaseEscrow(escrowContract).disputeResolutionModule();
        _queueAddress(state.pendingResolutionModule, module);
        emit ResolutionModuleQueued(escrowContract, oldModule, module, state.pendingResolutionModule.eta);
    }

    /**
     * @notice Activate the queued resolution module
     * @param escrowContract Address of the escrow contract
     * @dev Activates after timelock delay. Requires ROLE_TIMELOCK.
     *      Reverts if no value is queued, or if the ETA has not passed yet.
     *
     * Role wiring:
     * - The target escrow contract must grant this admin contract whatever role gates `setResolutionModule`.
     */
    function activateResolutionModule(address escrowContract) external onlyRole(ROLE_TIMELOCK) {
        AdminState storage state = escrowAdminStates[escrowContract];
        address oldModule = BaseEscrow(escrowContract).disputeResolutionModule();
        address newModule = _activateAddress(state.pendingResolutionModule);
        BaseEscrow(escrowContract).setResolutionModule(newModule);
        emit ResolutionModuleActivated(escrowContract, oldModule, newModule);
    }

    /**
     * @notice Get pending resolution module information
     * @param escrowContract Address of the escrow contract
     * @return value Pending resolution module address
     * @return eta Timestamp when activation becomes available
     * @return exists Whether a pending module exists
     */
    function getPendingResolutionModule(address escrowContract) external view returns (address value, uint64 eta, bool exists) {
        return getPendingAddress(escrowAdminStates[escrowContract].pendingResolutionModule);
    }

    // ============ Timeout Configuration ============

    /**
     * @notice Update timeout configuration atomically
     * @param escrowContract Address of the escrow contract
     * @param config New timeout configuration
     * @dev Validates all fields and updates atomically. Requires ROLE_TIMELOCK.
     *
     * Role wiring:
     * - The target escrow contract must grant this admin contract whatever role gates `setTimeoutConfig`.
     */
    function setTimeoutConfig(address escrowContract, TimeoutConfig calldata config) external onlyRole(ROLE_TIMELOCK) {
        // Validate bounds (moved from BaseEscrow)
        if (config.maxDisputeDuration < 7 days || config.maxDisputeDuration > 365 days) {
            revert InvalidConfig(1, config.maxDisputeDuration);
        }
        if (config.appealWindowDuration < 1 days || config.appealWindowDuration > 7 days) {
            revert InvalidConfig(2, config.appealWindowDuration);
        }
        // Validate auto times (if set)
        SettingsValidationLibrary.validateAutoRelease(config.defaultAutoReleaseDelay);
        SettingsValidationLibrary.validateAutoCancel(config.defaultAutoCancelDelay);
        BaseEscrow(escrowContract).setTimeoutConfig(config);
    }
}
