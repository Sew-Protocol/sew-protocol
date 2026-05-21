// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

/**
 * @title IModuleRegistry
 * @notice Interface for module registry - allowlist + metadata for safety and UX
 * @dev Registry is not a marketplace. It's an allowlist + metadata system.
 */
interface IModuleRegistry {
    enum ModuleType {
        YIELD_GENERATION,
        YIELD_DISTRIBUTION,
        RESOLUTION,
        RELEASE_STRATEGY,
        CANCELLATION_STRATEGY
    }

    enum ModuleStatus {
        NONE,
        ACTIVE,
        DEPRECATED
    }

    struct ModuleMetadata {
        string name;
        string version;
        ModuleStatus status;
        uint256 featureFlags; // Bit flags for capabilities
        address[] supportedTokens; // Optional: empty = all tokens supported
    }

    /**
     * @notice Check if a module is approved for a given type
     * @param moduleType Type of module (YIELD_GENERATION, YIELD_DISTRIBUTION, RESOLUTION)
     * @param module Module address to check
     * @return approved True if module is approved and active
     */
    function isApproved(ModuleType moduleType, address module) external view returns (bool approved);

    /**
     * @notice Get metadata for a module
     * @param moduleType Type of module
     * @param module Module address
     * @return metadata Module metadata (empty if not registered)
     */
    function getMetadata(ModuleType moduleType, address module) external view returns (ModuleMetadata memory metadata);

    /**
     * @notice Enumerate all approved modules of a given type
     * @param moduleType Type of module
     * @return modules Array of approved module addresses
     */
    function enumerateModules(ModuleType moduleType) external view returns (address[] memory modules);

    /**
     * @notice Event emitted when a module is added to the registry
     */
    event ModuleAdded(
        ModuleType indexed moduleType,
        address indexed module,
        string name,
        string version
    );

    /**
     * @notice Event emitted when a module is deprecated
     */
    event ModuleDeprecated(ModuleType indexed moduleType, address indexed module);
}
