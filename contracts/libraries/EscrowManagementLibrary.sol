// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import '../types/EscrowTypes.sol';
import '../core/ModuleSnapshotRegistry.sol';
import '../shared/interfaces/IResolutionModule.sol';

library EscrowManagementLibrary {
    function finalizeDisputeInModule(
        uint256 workflowId,
        function (uint256) internal view returns (IResolutionModule) getResolutionModule
    ) internal {
        IResolutionModule resolutionModule = getResolutionModule(workflowId);
        if (address(resolutionModule) != address(0)) {
            // Low-level call to finalize dispute
            (bool success, ) = address(resolutionModule).call(abi.encodeWithSignature('finalizeDispute(uint256,address)', workflowId, address(this)));
            success; // Ignore success/failure
        }
    }

    function validateWorkflowId(uint256 workflowId, uint256 length) internal pure {
        if (workflowId >= length) {
            revert InvalidWorkflowId(workflowId, length);
        }
    }
}
