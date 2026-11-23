// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.37;

/// @notice Optional resolution-module extension for terminal escrow timeouts.
/// @dev Modules supporting capital-backed assignments must implement this hook
///      and advertise this interface through ERC-165.
interface IResolutionModuleTimeout {
    function closeDisputeByTimeout(
        uint256 workflowId,
        address escrowContract,
        address executor,
        uint256 disputeRaisedAt,
        uint256 maxDisputeDuration
    ) external;
    function closeDisputeByMutualAgreement(uint256 workflowId, address escrowContract) external;
}
