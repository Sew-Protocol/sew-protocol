// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import '@openzeppelin/contracts/utils/introspection/IERC165.sol';

/**
 * @title IYieldGenerationModule
 * @notice Interface for yield generation modules (e.g., Aave, Compound, Yearn)
 * @dev Handles yield generation during escrow lifespan. Distribution is handled separately.
 */
interface IYieldGenerationModule is IERC165 {
    /**
     * @notice Deposit funds to generate yield
     * @param workflowId The escrow transfer ID
     * @param token Token address (or address(this) for native token)
     * @param amount Amount to deposit
     * @return success True if deposit was successful
     * @return yieldTokenBalance Balance of yield token received
     */
    function depositForYield(
        uint256 workflowId,
        address token,
        uint256 amount
    ) external returns (bool success, uint256 yieldTokenBalance);

    /**
     * @notice Withdraw funds and calculate yield
     * @param workflowId The escrow transfer ID
     * @param token Token address
     * @param originalAmount Original deposit amount
     * @return success True if withdrawal was successful
     * @return actualAmount Actual amount withdrawn (including yield)
     * @return yieldAmount Amount of yield generated
     */
    function withdrawWithYield(
        uint256 workflowId,
        address token,
        uint256 originalAmount,
        address escrowContract
    ) external returns (bool success, uint256 actualAmount, uint256 yieldAmount);

    /**
     * @notice Calculate current yield for an escrow
     * @param workflowId The escrow transfer ID
     * @param token Token address
     * @return yieldAmount Current yield amount
     */
    function calculateYield(
        uint256 workflowId,
        address token
    ) external view returns (uint256 yieldAmount);

    /**
     * @notice Check if token is supported for yield generation
     * @param token Token address
     * @return supported True if supported
     */
    function isTokenSupported(address token) external view returns (bool supported);

    /**
     * @notice Get the approval target address for a token (if escrow contract needs to approve before deposit)
     * @param token Token address
     * @return approvalTarget Address that needs approval (address(0) if no approval needed or handled by module)
     * @dev For EscrowableERC20: returns the pool/contract that needs approval to spend tokens
     *      For EscrowVault: typically returns address(0) as module handles approvals
     *      Returns address(0) if approval is not needed or is handled internally by the module
     */
    function getApprovalTarget(address token) external view returns (address approvalTarget);

    /**
     * @notice Get the module name/identifier
     * @return name The module name
     */
    function moduleName() external pure returns (string memory name);

    /**
     * @notice Get the module version
     * @return version The module version (semantic versioning, e.g., "1.0.0")
     */
    function moduleVersion() external pure returns (string memory version);

    /**
     * @notice Get Aave pool address (for library pattern)
     * @return poolAddress Aave V3 Pool address (address(0) if not Aave module or not configured)
     * @dev Optional method - modules can implement if they support Aave
     *      BaseEscrow uses staticcall with try/catch, so modules don't need to implement this
     */
    function getAavePoolAddress() external view returns (address poolAddress);

    /**
     * @notice Get aToken address for a token (for library pattern)
     * @param token Underlying token address
     * @return aTokenAddress aToken address (address(0) if token not supported)
     * @dev Optional method - modules can implement if they support Aave
     *      BaseEscrow uses staticcall with try/catch, so modules don't need to implement this
     */
    function getATokenAddress(address token) external view returns (address aTokenAddress);
}
