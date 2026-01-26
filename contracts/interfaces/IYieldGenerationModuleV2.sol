// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import '@openzeppelin/contracts/interfaces/IERC4626.sol';
import '@openzeppelin/contracts/utils/introspection/IERC165.sol';

/**
 * @title IYieldGenerationModuleV2
 * @notice Extended yield generation module interface that combines ERC-4626 with escrow-specific functionality
 * @dev This interface bridges ERC-4626 vaults with our escrow system's per-workflow tracking
 * 
 * Design Philosophy:
 * - Uses ERC-4626 as the core vault interface (industry standard)
 * - Adds escrow-specific methods for per-workflow accounting
 * - Maintains backward compatibility where possible
 * 
 * Migration Path:
 * 1. Modules implement this interface (adds ERC-4626 + helper methods)
 * 2. BaseEscrow uses ERC-4626 methods for yield operations
 * 3. Per-workflow tracking moves to module (not BaseEscrow)
 * 4. Contract size reduced by removing protocol-specific code from BaseEscrow
 */
interface IYieldGenerationModuleV2 is IERC4626, IERC165 {
    // ============ Escrow-Specific Extensions ============
    
    /**
     * @notice Deposit funds for a specific escrow workflow
     * @param workflowId The escrow transfer ID
     * @param assets Amount of underlying assets to deposit
     * @param receiver Address that will own the shares (typically the escrow vault)
     * @return shares Amount of shares minted
     * @dev Extends ERC-4626 deposit() with workflow tracking
     *      Modules track which shares belong to which workflow
     */
    function depositForWorkflow(
        uint256 workflowId,
        uint256 assets,
        address receiver
    ) external returns (uint256 shares);
    
    /**
     * @notice Redeem shares for a specific escrow workflow
     * @param workflowId The escrow transfer ID
     * @param shares Amount of shares to redeem
     * @param receiver Address to receive the assets
     * @param owner Address that owns the shares
     * @return assets Amount of underlying assets returned
     * @dev Extends ERC-4626 redeem() with workflow tracking
     *      Returns assets which may include accrued yield
     */
    function redeemForWorkflow(
        uint256 workflowId,
        uint256 shares,
        address receiver,
        address owner
    ) external returns (uint256 assets);
    
    /**
     * @notice Get shares balance for a specific workflow
     * @param workflowId The escrow transfer ID
     * @param owner Address that owns the shares
     * @return shares Share balance for this workflow
     * @dev Per-workflow share tracking
     */
    function sharesOfWorkflow(uint256 workflowId, address owner) external view returns (uint256 shares);
    
    /**
     * @notice Calculate yield for a specific workflow
     * @param workflowId The escrow transfer ID
     * @param owner Address that owns the shares
     * @return yieldAmount Current yield (assets - principal)
     * @dev Helper to calculate: convertToAssets(shares) - originalDeposit
     */
    function calculateWorkflowYield(uint256 workflowId, address owner) external view returns (uint256 yieldAmount);
    
    // ============ Module Metadata ============
    
    /**
     * @notice Check if token is supported for yield generation
     * @param token Token address
     * @return supported True if supported
     * @dev Modules may support subset of tokens
     */
    function isTokenSupported(address token) external view returns (bool supported);
    
    /**
     * @notice Get the module name/identifier
     * @return name The module name (e.g., "AaveV3YieldModule")
     */
    function moduleName() external pure returns (string memory name);
    
    /**
     * @notice Get the module version
     * @return version The module version (semantic versioning, e.g., "2.0.0")
     */
    function moduleVersion() external pure returns (string memory version);
    
    // ============ Backward Compatibility (Optional) ============
    
    /**
     * @notice Legacy deposit method (maps to depositForWorkflow)
     * @dev Maintained for backward compatibility during migration
     *      New code should use depositForWorkflow() or standard deposit()
     */
    function depositForYield(
        uint256 workflowId,
        address token,
        uint256 amount
    ) external returns (bool success, uint256 yieldTokenBalance);
    
    /**
     * @notice Legacy withdraw method (maps to redeemForWorkflow)
     * @dev Maintained for backward compatibility during migration
     *      New code should use redeemForWorkflow() or standard redeem()
     */
    function withdrawWithYield(
        uint256 workflowId,
        address token,
        uint256 originalAmount
    ) external returns (bool success, uint256 actualAmount, uint256 yieldAmount);
}
