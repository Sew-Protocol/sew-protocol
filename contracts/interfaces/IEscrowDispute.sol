// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import '@openzeppelin/contracts/utils/introspection/IERC165.sol';

/// @notice Wallet-discoverable dispute opening action.
interface IEscrowDispute is IERC165 {
    function raiseDispute(uint256 workflowId) external;
}
