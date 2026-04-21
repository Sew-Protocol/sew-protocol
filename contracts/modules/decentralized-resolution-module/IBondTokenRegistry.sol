// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

/**
 * @title IBondTokenRegistry
 * @notice Interface for the external bond token registry used by DecentralizedResolutionModule
 */
interface IBondTokenRegistry {
    function isAccepted(address token) external view returns (bool);
    function defaultBondToken() external view returns (address);
}
