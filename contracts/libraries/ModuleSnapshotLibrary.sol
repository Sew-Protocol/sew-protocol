// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

/**
 * @title ModuleSnapshotLibrary
 * @notice Library for module snapshot operations
 * @dev Extracted from BaseEscrow to reduce contract size
 */
library ModuleSnapshotLibrary {
    bytes4 constant SEL_INCENTIVE_MODULE = bytes4(keccak256("incentiveModule()"));

    /**
     * @notice Get incentive module from resolution module
     * @param resModule Resolution module address
     * @return incentiveMod Incentive module address (0 if not available)
     */
    function getIncentiveModule(address resModule) internal view returns (address incentiveMod) {
        if (resModule == address(0)) {
            return address(0);
        }
        (bool success, bytes memory data) = resModule.staticcall(
            abi.encodeWithSelector(SEL_INCENTIVE_MODULE)
        );
        if (success && data.length >= 32) {
            incentiveMod = abi.decode(data, (address));
        }
    }
}
