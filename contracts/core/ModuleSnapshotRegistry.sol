// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import '@openzeppelin/contracts/access/AccessControl.sol';
import '../governance/SlowLaneQueueActivate.sol';
import '../interfaces/IReleaseStrategy.sol';
import '../interfaces/ICancellationStrategy.sol';
import '../interfaces/IYieldGenerationModule.sol';
import '../interfaces/IYieldDistributionModule.sol';
import '../shared/interfaces/IResolutionModule.sol';
import './BaseEscrow.sol';

/**
 * @title ModuleSnapshotRegistry
 * @notice Central registry for module configurations and slow-lane upgrades
 * @dev Handles queuing and activating default modules with a 7-day delay.
 *      Allows per-escrow contract module management.
 */
contract ModuleSnapshotRegistry is AccessControl, SlowLaneQueueActivate {
    bytes32 public constant ROLE_TIMELOCK = keccak256('ROLE_TIMELOCK');
    bytes32 public constant ROLE_ESCROW_CONTRACT = keccak256('ROLE_ESCROW_CONTRACT');

    struct ModuleState {
        IReleaseStrategy defaultReleaseStrategy;
        ICancellationStrategy defaultCancellationStrategy;
        IYieldGenerationModule defaultYieldGenerationModule;
        IYieldDistributionModule defaultYieldDistributionModule;
        IResolutionModule defaultResolutionModule;
        mapping(BaseEscrow.ModuleType => PendingAddress) pendingModules;
    }

    mapping(address => ModuleState) public escrowModuleStates;

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
    event DefaultCancellationStrategyQueued(
        address indexed escrowContract,
        address indexed oldModule,
        address indexed newModule,
        uint64 eta
    );
    event DefaultCancellationStrategyActivated(
        address indexed escrowContract,
        address indexed oldModule,
        address indexed newModule
    );

    /// @notice Error when escrow contract is not registered
    error EscrowNotRegistered(address escrowContract);
    
    /// @notice Error when yield module is already assigned to another escrow contract
    error YieldModuleAlreadyAssigned(address yieldModule, address assignedEscrow);

    /**
     * @notice Deploy ModuleSnapshotRegistry with initial admin
     * @param initialAdmin Initial admin address (typically timelock)
     */
    constructor(address initialAdmin) {
        if (initialAdmin == address(0)) revert InvalidAddress(ADDR_INITIAL_ADMIN, initialAdmin);
        _grantRole(DEFAULT_ADMIN_ROLE, initialAdmin);
        _grantRole(ROLE_TIMELOCK, initialAdmin);
    }

    /**
     * @notice Register an escrow contract to allow configuration
     * @param escrowContract Address of the escrow contract
     */
    function registerEscrowContract(address escrowContract) external {
        if (!hasRole(DEFAULT_ADMIN_ROLE, msg.sender) && !hasRole(ROLE_TIMELOCK, msg.sender)) {
            revert AccessControlUnauthorizedAccount(msg.sender, ROLE_TIMELOCK);
        }
        if (escrowContract == address(0)) revert InvalidValue();
        _grantRole(ROLE_ESCROW_CONTRACT, escrowContract);
    }

    /**
     * @notice Queue a new default module for an escrow contract
     * @param escrowContract Address of the escrow contract
     * @param moduleType Type of module to queue
     * @param module Address of the new module
     * @dev Only timelock can queue upgrades
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
        if (module.code.length == 0) revert InvalidValue();

        ModuleState storage state = escrowModuleStates[escrowContract];
        _queueAddress(state.pendingModules[moduleType], module);

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
        } else if (moduleType == BaseEscrow.ModuleType.CANCELLATION) {
            emit DefaultCancellationStrategyQueued(
                escrowContract,
                address(state.defaultCancellationStrategy),
                module,
                state.pendingModules[moduleType].eta
            );
        }
    }

    /**
     * @notice Activate the queued module
     * @param escrowContract Address of the escrow contract
     * @param moduleType Type of module to activate
     * @dev Only timelock can activate after delay
     */
    function activateModule(
        address escrowContract,
        BaseEscrow.ModuleType moduleType
    ) external onlyRole(ROLE_TIMELOCK) {
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
        } else if (moduleType == BaseEscrow.ModuleType.CANCELLATION) {
            oldModule = address(state.defaultCancellationStrategy);
            state.defaultCancellationStrategy = ICancellationStrategy(newModule);
            emit DefaultCancellationStrategyActivated(escrowContract, oldModule, newModule);
        }
    }

    /**
     * @notice Get pending module information
     */
    function getPendingModule(
        address escrowContract,
        BaseEscrow.ModuleType moduleType
    ) external view returns (address pendingModule, uint64 eta, bool exists) {
        PendingAddress storage pending = escrowModuleStates[escrowContract].pendingModules[moduleType];
        return (pending.value, pending.eta, pending.exists);
    }

    /**
     * @notice Get current default release strategy for an escrow contract
     */
    function getDefaultReleaseStrategy(address escrowContract) external view returns (IReleaseStrategy) {
        return escrowModuleStates[escrowContract].defaultReleaseStrategy;
    }

    /**
     * @notice Get current default cancellation strategy for an escrow contract
     */
    function getDefaultCancellationStrategy(address escrowContract) external view returns (ICancellationStrategy) {
        return escrowModuleStates[escrowContract].defaultCancellationStrategy;
    }

    /**
     * @notice Get current default yield generation module for an escrow contract
     */
    function getDefaultYieldGenerationModule(address escrowContract) external view returns (IYieldGenerationModule) {
        return escrowModuleStates[escrowContract].defaultYieldGenerationModule;
    }

    /**
     * @notice Get current default yield distribution module for an escrow contract
     */
    function getDefaultYieldDistributionModule(address escrowContract) external view returns (IYieldDistributionModule) {
        return escrowModuleStates[escrowContract].defaultYieldDistributionModule;
    }

    /**
     * @notice Get current default resolution module for an escrow contract
     */
    function getDefaultResolutionModule(address escrowContract) external view returns (IResolutionModule) {
        return escrowModuleStates[escrowContract].defaultResolutionModule;
    }

    /**
     * @notice Get current module address by type
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
        } else if (moduleType == BaseEscrow.ModuleType.CANCELLATION) {
            return address(state.defaultCancellationStrategy);
        }
        return address(0);
    }
}
