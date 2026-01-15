// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import "../governance/SlowLaneQueueActivate.sol";
import "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import "../types/EscrowTypes.sol";

/**
 * @title ModuleManagementLibrary
 * @notice Library for validating and managing module operations
 * @dev Extracted from EscrowVault and EscrowableERC20 to reduce contract size
 *      Provides validation functions - actual queue/activate handled by contract
 */
library ModuleManagementLibrary {
    /**
     * @dev Configuration for module validation
     */
    struct ModuleConfig {
        bool requireContract;      // Must be a contract (code.length > 0)
        bool allowZero;            // Allow zero address (for optional modules)
        bytes4 interfaceId;        // ERC-165 interface ID to validate (0 = no validation)
        string moduleName;         // Name for error messages
    }

    /**
     * @notice Validate a module address before queueing
     * @param newModule New module address to validate
     * @param config Module validation configuration
     * @dev Reverts if validation fails
     */
    function validateModule(
        address newModule,
        ModuleConfig memory config
    ) internal view {
        // Check zero address
        if (!config.allowZero && newModule == address(0)) {
            revert InvalidAddress(
                string(abi.encodePacked("Default ", config.moduleName, " cannot be zero")),
                newModule
            );
        }
        
        // Check contract requirement
        if (config.requireContract && newModule.code.length == 0) {
            revert InvalidAddress(
                string(abi.encodePacked("Default ", config.moduleName, " must be a contract")),
                newModule
            );
        }

        // Validate ERC-165 interface if specified
        if (config.interfaceId != bytes4(0) && newModule != address(0)) {
            if (!IERC165(newModule).supportsInterface(config.interfaceId)) {
                revert InvalidAddress(
                    string(abi.encodePacked("Module does not implement required interface")),
                    newModule
                );
            }
        }
    }
}

