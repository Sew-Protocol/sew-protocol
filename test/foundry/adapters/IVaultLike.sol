// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.33;

/**
 * @title IVaultLike
 * @notice Minimal vault interface for testing (ERC-4626 semantics)
 * @dev This interface allows us to test yield modules with standard vault behavior
 *      without committing to full ERC-4626 compliance yet.
 */
interface IVaultLike {
    /**
     * @notice Returns the address of the underlying asset
     * @return assetTokenAddress The underlying ERC20 token
     */
    function asset() external view returns (address assetTokenAddress);

    /**
     * @notice Deposit assets and receive shares
     * @param assets Amount of underlying to deposit
     * @param receiver Address to receive the shares
     * @return shares Amount of shares minted
     */
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);

    /**
     * @notice Redeem shares for assets
     * @param shares Amount of shares to redeem
     * @param receiver Address to receive the assets
     * @param owner Address that owns the shares
     * @return assets Amount of assets returned
     */
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets);

    /**
     * @notice Convert asset amount to share amount
     * @param assets Amount of assets
     * @return shares Equivalent amount of shares
     */
    function convertToShares(uint256 assets) external view returns (uint256 shares);

    /**
     * @notice Convert share amount to asset amount
     * @param shares Amount of shares
     * @return assets Equivalent amount of assets
     */
    function convertToAssets(uint256 shares) external view returns (uint256 assets);

    /**
     * @notice Total assets managed by the vault
     * @return totalManagedAssets Total underlying assets
     */
    function totalAssets() external view returns (uint256 totalManagedAssets);

    /**
     * @notice Share balance of an account
     * @param owner Address to check
     * @return balance Share balance
     */
    function balanceOf(address owner) external view returns (uint256 balance);
}
