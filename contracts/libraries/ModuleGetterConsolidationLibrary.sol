// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import '../interfaces/IReleaseStrategy.sol';
import '../shared/interfaces/IResolutionModule.sol';
import '../interfaces/IYieldModule.sol';
import '../interfaces/IYieldDistributionModule.sol';

/**
 * @title ModuleGetterConsolidationLibrary
 * @notice Library for optimized module type casting
 * @dev Extracted from EscrowVault to reduce contract size by consolidating type casting logic
 */
library ModuleGetterConsolidationLibrary {
    function getReleaseStrategy(address moduleAddr) internal pure returns (IReleaseStrategy) {
        return IReleaseStrategy(moduleAddr);
    }
    
    function getResolutionModule(address moduleAddr, address fallbackModule) internal pure returns (IResolutionModule) {
        return IResolutionModule(moduleAddr != address(0) ? moduleAddr : fallbackModule);
    }
    
    function getYieldModule(address moduleAddr) internal pure returns (IYieldModule) {
        return IYieldModule(moduleAddr);
    }
    
    function getYieldDistributionModule(address moduleAddr) internal pure returns (IYieldDistributionModule) {
        return IYieldDistributionModule(moduleAddr);
    }
}
