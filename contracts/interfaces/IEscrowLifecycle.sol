// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import '@openzeppelin/contracts/utils/introspection/IERC165.sol';

/// @notice Wallet-discoverable pending-escrow lifecycle actions.
interface IEscrowLifecycle is IERC165 {
    function release(uint256 workflowId) external;
    function senderCancel(uint256 workflowId) external returns (bool success);
    function recipientCancel(uint256 workflowId) external returns (bool success);
}
