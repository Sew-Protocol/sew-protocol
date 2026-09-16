// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.37;

/// @notice Narrow, shared protocol policy consumed by escrow creation.
/// @dev Deliberately contains policy state only — no calculation, resolver
///      lookup, fee logic, or creation orchestration.
interface IEscrowCreationPolicy {
    function yieldDepositsPaused() external view returns (bool);
    function resolverMustBeContract() external view returns (bool);
}
