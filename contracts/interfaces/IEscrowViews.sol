// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.37;

import '@openzeppelin/contracts/utils/introspection/IERC165.sol';
import '../types/EscrowTypes.sol';

/// @notice Minimal common read surface for wallet escrow rendering.
interface IEscrowViews is IERC165 {
    function getEscrowCount() external view returns (uint256 count);
    function getEscrowState(uint256 workflowId) external view returns (EscrowState state);
    function canRelease(uint256 workflowId, address caller) external view returns (bool allowed);
}
