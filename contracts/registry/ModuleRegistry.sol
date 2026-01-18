// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import '@openzeppelin/contracts/access/AccessControl.sol';
import '@openzeppelin/contracts/utils/introspection/IERC165.sol';
import '../interfaces/IModuleRegistry.sol';
import '../interfaces/IYieldGenerationModule.sol';
import '../interfaces/IYieldDistributionModule.sol';
import '../shared/interfaces/IResolutionModule.sol';

/**
 * @title ModuleRegistry
 * @notice Simple module registry - allowlist + metadata for safety and UX
 * @dev Registry validates and tracks approved modules by type.
 *      Not a marketplace - just an allowlist with metadata for safety.
 */
contract ModuleRegistry is AccessControl, IModuleRegistry {
    bytes32 public constant ROLE_TIMELOCK = keccak256('ROLE_TIMELOCK');

    // Mapping: moduleType => module => metadata
    mapping(ModuleType => mapping(address => ModuleMetadata)) private _modules;

    // Mapping: moduleType => array of active module addresses (for enumeration)
    mapping(ModuleType => address[]) private _moduleList;

    // Errors
    error NotAContract(address module);
    error ModuleAlreadyExists(ModuleType moduleType, address module);
    error InvalidInterface(ModuleType moduleType, address module);
    error ModuleNotFound(ModuleType moduleType, address module);
    error InvalidStatusTransition(ModuleType moduleType, address module, ModuleStatus current, ModuleStatus requested);

    /**
     * @notice Deploy ModuleRegistry with initial admin
     * @param initialAdmin Initial admin address (typically timelock)
     */
    constructor(address initialAdmin) {
        if (initialAdmin == address(0)) revert InvalidAddress('Initial admin cannot be zero', initialAdmin);
        _grantRole(DEFAULT_ADMIN_ROLE, initialAdmin);
        _grantRole(ROLE_TIMELOCK, initialAdmin);
    }

    /**
     * @notice Check if a module is approved and active
     * @param moduleType Type of module
     * @param module Module address
     * @return approved True if module is approved and active
     */
    function isApproved(ModuleType moduleType, address module) external view override returns (bool approved) {
        ModuleMetadata memory meta = _modules[moduleType][module];
        return meta.status == ModuleStatus.ACTIVE;
    }

    /**
     * @notice Get metadata for a module
     * @param moduleType Type of module
     * @param module Module address
     * @return metadata Module metadata (will have empty name if not registered)
     */
    function getMetadata(ModuleType moduleType, address module)
        external
        view
        override
        returns (ModuleMetadata memory metadata)
    {
        return _modules[moduleType][module];
    }

    /**
     * @notice Enumerate all active modules of a given type
     * @param moduleType Type of module
     * @return modules Array of active module addresses
     */
    function enumerateModules(ModuleType moduleType) external view override returns (address[] memory modules) {
        return _moduleList[moduleType];
    }

    /**
     * @notice Add a module to the registry
     * @param moduleType Type of module
     * @param module Module address
     * @param metadata Module metadata
     * @dev Only timelock can add modules. Validates interface and contract status.
     */
    function addModule(
        ModuleType moduleType,
        address module,
        ModuleMetadata calldata metadata
    ) external onlyRole(ROLE_TIMELOCK) {
        if (module.code.length == 0) revert NotAContract(module);

        // Check if module already exists (must be deprecated to re-add)
        ModuleMetadata memory existing = _modules[moduleType][module];
        if (existing.status == ModuleStatus.ACTIVE) {
            revert ModuleAlreadyExists(moduleType, module);
        }

        // Validate interface
        if (moduleType == ModuleType.YIELD_GENERATION) {
            if (!IERC165(module).supportsInterface(type(IYieldGenerationModule).interfaceId)) {
                revert InvalidInterface(moduleType, module);
            }
        } else if (moduleType == ModuleType.YIELD_DISTRIBUTION) {
            if (!IERC165(module).supportsInterface(type(IYieldDistributionModule).interfaceId)) {
                revert InvalidInterface(moduleType, module);
            }
        } else if (moduleType == ModuleType.RESOLUTION) {
            if (!IERC165(module).supportsInterface(type(IResolutionModule).interfaceId)) {
                revert InvalidInterface(moduleType, module);
            }
        }

        // Store metadata
        _modules[moduleType][module] = metadata;

        // Add to list if active
        if (metadata.status == ModuleStatus.ACTIVE) {
            _moduleList[moduleType].push(module);
        }

        emit ModuleAdded(moduleType, module, metadata.name, metadata.version);
    }

    /**
     * @notice Deprecate a module (mark as deprecated, don't remove)
     * @param moduleType Type of module
     * @param module Module address
     * @dev Only timelock can deprecate. Deprecated modules cannot be used as defaults.
     */
    function deprecateModule(ModuleType moduleType, address module) external onlyRole(ROLE_TIMELOCK) {
        ModuleMetadata memory existing = _modules[moduleType][module];
        if (existing.status != ModuleStatus.ACTIVE) {
            revert InvalidStatusTransition(moduleType, module, existing.status, ModuleStatus.DEPRECATED);
        }

        // Update status
        _modules[moduleType][module].status = ModuleStatus.DEPRECATED;

        // Remove from active list (find and remove)
        address[] storage list = _moduleList[moduleType];
        for (uint256 i = 0; i < list.length; i++) {
            if (list[i] == module) {
                // Swap with last and pop
                list[i] = list[list.length - 1];
                list.pop();
                break;
            }
        }

        emit ModuleDeprecated(moduleType, module);
    }

    // Reuse InvalidAddress error from types
    error InvalidAddress(string reason, address addr);
}
