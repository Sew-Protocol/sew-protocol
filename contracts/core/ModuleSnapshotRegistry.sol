// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import '@openzeppelin/contracts/access/AccessControl.sol';
import '../governance/SlowLaneQueueActivate.sol';
import '../interfaces/IReleaseStrategy.sol';
import '../interfaces/IYieldGenerationModule.sol';
import '../interfaces/IYieldDistributionModule.sol';
import '../shared/interfaces/IResolutionModule.sol';
import './BaseEscrow.sol';

/**
 * @title ModuleSnapshotRegistry
 * @notice Registry for module snapshots frozen at escrow creation time.
 * @dev Extracted from EscrowVault/EscrowableERC20 to reduce contract size.
 *      Handles queue/activate pattern for default modules with slow lane activation.
 */
contract ModuleSnapshotRegistry is AccessControl, SlowLaneQueueActivate {
    bytes32 public constant ROLE_ESCROW_CONTRACT = keccak256('ROLE_ESCROW_CONTRACT');
    bytes32 public constant ROLE_TIMELOCK = keccak256('ROLE_TIMELOCK');

    /// @notice Module state for each escrow contract
    struct ModuleState {
        IReleaseStrategy defaultReleaseStrategy;
        IYieldGenerationModule defaultYieldGenerationModule;
        IYieldDistributionModule defaultYieldDistributionModule;
        IResolutionModule defaultResolutionModule;
        mapping(BaseEscrow.ModuleType => PendingAddress) pendingModules;
    }

    /// @notice Mapping from escrow contract to its module state
    mapping(address => ModuleState) public escrowModuleStates;

    /// @notice Events for module management
    event DefaultReleaseStrategyQueued(
        address indexed escrowContract,
        address indexed oldModule,
        address indexed newModule,
        uint64 eta
    );
    event DefaultReleaseStrategyActivated(
        address indexed escrowContract,
        address indexed oldModule,
        address indexed newModule
    );
    event DefaultYieldGenerationModuleQueued(
        address indexed escrowContract,
        address indexed oldModule,
        address indexed newModule,
        uint64 eta
    );
    event DefaultYieldGenerationModuleActivated(
        address indexed escrowContract,
        address indexed oldModule,
        address indexed newModule
    );
    event DefaultYieldDistributionModuleQueued(
        address indexed escrowContract,
        address indexed oldModule,
        address indexed newModule,
        uint64 eta
    );
    event DefaultYieldDistributionModuleActivated(
        address indexed escrowContract,
        address indexed oldModule,
        address indexed newModule
    );
    event DefaultResolutionModuleQueued(
        address indexed escrowContract,
        address indexed oldModule,
        address indexed newModule,
        uint64 eta
    );
    event DefaultResolutionModuleActivated(
        address indexed escrowContract,
        address indexed oldModule,
        address indexed newModule
    );

    /// @notice Error when escrow contract is not registered
    error EscrowNotRegistered(address escrowContract);

    /**
     * @notice Deploy the ModuleSnapshotRegistry.
     * @param initialAdmin Initial admin for bootstrap (expected to be replaced/managed by governance wiring).
     * @dev Grants `DEFAULT_ADMIN_ROLE` and `ROLE_TIMELOCK` to `initialAdmin` for initial setup.
     *      In production, `ROLE_TIMELOCK` should be held by the TimelockController.
     */
    constructor(address initialAdmin) {
        if (initialAdmin == address(0)) revert InvalidValue();
        _grantRole(DEFAULT_ADMIN_ROLE, initialAdmin);
        // ROLE_TIMELOCK gates registerEscrowContract(), so initialAdmin must have it for initial setup.
        _grantRole(ROLE_TIMELOCK, initialAdmin);
    }

    /**
     * @notice Register an escrow contract for module management
     * @param escrowContract Address of the escrow contract
     * @dev Only ROLE_TIMELOCK can register escrow contracts (governance-controlled)
     */
    function registerEscrowContract(address escrowContract) external onlyRole(ROLE_TIMELOCK) {
        if (escrowContract == address(0)) revert InvalidValue();
        _grantRole(ROLE_ESCROW_CONTRACT, escrowContract);
    }

    /**
     * @notice Queue a new module
     * @param escrowContract Address of the escrow contract
     * @param moduleType Type of module to queue
     * @param module Address of the new module to queue
     * @dev Only governance (ROLE_TIMELOCK) can queue modules directly.
     *      Ensures the escrow contract is registered.
     *      Enforces 7-day slow lane delay via SlowLaneQueueActivate.
     */
    function queueModule(
        address escrowContract,
        BaseEscrow.ModuleType moduleType,
        address module
    ) external onlyRole(ROLE_TIMELOCK) {
        if (!hasRole(ROLE_ESCROW_CONTRACT, escrowContract)) {
            revert EscrowNotRegistered(escrowContract);
        }
        if (module == address(0)) revert InvalidValue();

        ModuleState storage state = escrowModuleStates[escrowContract];
        _queueAddress(state.pendingModules[moduleType], module);

        // Emit appropriate event
        if (moduleType == BaseEscrow.ModuleType.RELEASE) {
            emit DefaultReleaseStrategyQueued(
                escrowContract,
                address(state.defaultReleaseStrategy),
                module,
                state.pendingModules[moduleType].eta
            );
        } else if (moduleType == BaseEscrow.ModuleType.YIELD_GEN) {
            emit DefaultYieldGenerationModuleQueued(
                escrowContract,
                address(state.defaultYieldGenerationModule),
                module,
                state.pendingModules[moduleType].eta
            );
        } else if (moduleType == BaseEscrow.ModuleType.YIELD_DIST) {
            emit DefaultYieldDistributionModuleQueued(
                escrowContract,
                address(state.defaultYieldDistributionModule),
                module,
                state.pendingModules[moduleType].eta
            );
        } else if (moduleType == BaseEscrow.ModuleType.RESOLUTION) {
            emit DefaultResolutionModuleQueued(
                escrowContract,
                address(state.defaultResolutionModule),
                module,
                state.pendingModules[moduleType].eta
            );
        }
    }

    /**
     * @notice Activate the queued module
     * @param escrowContract Address of the escrow contract
     * @param moduleType Type of module to activate
     * @dev Only governance (ROLE_TIMELOCK) can activate modules directly.
     *      Ensures the escrow contract is registered.
     *      Reverts if no module is queued for the given type, or if the ETA has not passed yet.
     *      Enforces 7-day slow lane delay - cannot be bypassed.
     */
    function activateModule(
        address escrowContract,
        BaseEscrow.ModuleType moduleType
    ) external onlyRole(ROLE_TIMELOCK) {
        if (!hasRole(ROLE_ESCROW_CONTRACT, escrowContract)) {
            revert EscrowNotRegistered(escrowContract);
        }

        ModuleState storage state = escrowModuleStates[escrowContract];
        address newModule = _activateAddress(state.pendingModules[moduleType]);
        address oldModule;

        if (moduleType == BaseEscrow.ModuleType.RELEASE) {
            oldModule = address(state.defaultReleaseStrategy);
            state.defaultReleaseStrategy = IReleaseStrategy(newModule);
            emit DefaultReleaseStrategyActivated(escrowContract, oldModule, newModule);
        } else if (moduleType == BaseEscrow.ModuleType.YIELD_GEN) {
            oldModule = address(state.defaultYieldGenerationModule);
            state.defaultYieldGenerationModule = IYieldGenerationModule(newModule);
            emit DefaultYieldGenerationModuleActivated(escrowContract, oldModule, newModule);
        } else if (moduleType == BaseEscrow.ModuleType.YIELD_DIST) {
            oldModule = address(state.defaultYieldDistributionModule);
            state.defaultYieldDistributionModule = IYieldDistributionModule(newModule);
            emit DefaultYieldDistributionModuleActivated(escrowContract, oldModule, newModule);
        } else if (moduleType == BaseEscrow.ModuleType.RESOLUTION) {
            oldModule = address(state.defaultResolutionModule);
            state.defaultResolutionModule = IResolutionModule(newModule);
            emit DefaultResolutionModuleActivated(escrowContract, oldModule, newModule);
        }
    }

    /**
     * @notice Get pending module information
     * @param escrowContract Address of the escrow contract
     * @param moduleType Type of module to query
     * @return value Pending module address
     * @return eta Timestamp when activation becomes available
     * @return exists Whether a pending module exists
     */
    function getPendingModule(
        address escrowContract,
        BaseEscrow.ModuleType moduleType
    ) external view returns (address value, uint64 eta, bool exists) {
        ModuleState storage state = escrowModuleStates[escrowContract];
        return getPendingAddress(state.pendingModules[moduleType]);
    }

    /**
     * @notice Get default release strategy for an escrow contract
     * @param escrowContract Address of the escrow contract
     * @return The default release strategy
     */
    function getDefaultReleaseStrategy(
        address escrowContract
    ) external view virtual returns (IReleaseStrategy) {
        return escrowModuleStates[escrowContract].defaultReleaseStrategy;
    }

    /**
     * @notice Get default yield generation module for an escrow contract
     * @param escrowContract Address of the escrow contract
     * @return The default yield generation module
     */
    function getDefaultYieldGenerationModule(
        address escrowContract
    ) external view virtual returns (IYieldGenerationModule) {
        return escrowModuleStates[escrowContract].defaultYieldGenerationModule;
    }

    /**
     * @notice Get default yield distribution module for an escrow contract
     * @param escrowContract Address of the escrow contract
     * @return The default yield distribution module
     */
    function getDefaultYieldDistributionModule(
        address escrowContract
    ) external view virtual returns (IYieldDistributionModule) {
        return escrowModuleStates[escrowContract].defaultYieldDistributionModule;
    }

    /**
     * @notice Get default resolution module for an escrow contract
     * @param escrowContract Address of the escrow contract
     * @return The default resolution module
     */
    function getDefaultResolutionModule(
        address escrowContract
    ) external view virtual returns (IResolutionModule) {
        return escrowModuleStates[escrowContract].defaultResolutionModule;
    }

    /**
     * @notice Get module address for an escrow contract by type
     * @param escrowContract Address of the escrow contract
     * @param moduleType Type of module to retrieve
     * @return The module address (address(0) if not set)
     * @dev PRIORITY: Consolidated getter to reduce bytecode in escrow contracts
     */
    function getModule(
        address escrowContract,
        BaseEscrow.ModuleType moduleType
    ) external view returns (address) {
        ModuleState storage state = escrowModuleStates[escrowContract];
        if (moduleType == BaseEscrow.ModuleType.RELEASE) {
            return address(state.defaultReleaseStrategy);
        } else if (moduleType == BaseEscrow.ModuleType.YIELD_GEN) {
            return address(state.defaultYieldGenerationModule);
        } else if (moduleType == BaseEscrow.ModuleType.YIELD_DIST) {
            return address(state.defaultYieldDistributionModule);
        } else if (moduleType == BaseEscrow.ModuleType.RESOLUTION) {
            return address(state.defaultResolutionModule);
        }
        return address(0);
    }
}
