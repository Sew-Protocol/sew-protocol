// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

/**
 * @notice Minimal Aave v3 interfaces shared across modules/libraries.
 * @dev Centralized here to avoid duplicate top-level declarations across the codebase.
 */

interface IAavePoolAddressesProvider {
    function getPool() external view returns (address);
}

interface IAavePool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
    // Optional but widely supported in Aave v3 Pool; used for per-escrow yield accounting.
    function getReserveNormalizedIncome(address asset) external view returns (uint256);
}

interface IAaveAToken {
    function balanceOf(address account) external view returns (uint256);
    // Aave V3 canonical method (uppercase)
    function UNDERLYING_ASSET_ADDRESS() external view returns (address);
    // Fallback for some wrappers/forks (lowercase)
    function underlyingAsset() external view returns (address);
}

