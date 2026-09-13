// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import '@openzeppelin/contracts/utils/introspection/IERC165.sol';

/// @notice Wallet-discoverable settlement and entitlement-delivery actions.
interface IEscrowSettlement is IERC165 {
    function executePendingSettlement(uint256 workflowId) external;
    function withdrawEscrow(uint256 workflowId) external returns (uint256 amount);
}
