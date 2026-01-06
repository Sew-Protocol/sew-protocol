// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/utils/introspection/IERC165.sol";

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
        uint256 originalAmount
    ) external returns (
        bool success,
        uint256 actualAmount,
        uint256 yieldAmount
    );

    /**
     * @notice Withdraw proportional amount (for partial operations)
     * @param workflowId The escrow transfer ID
     * @param token Token address
     * @param amount Amount to withdraw proportionally
     * @param originalDeposit Original total deposit
     * @return success True if withdrawal was successful
     * @return actualAmount Actual amount withdrawn (including proportional yield)
     */
    function withdrawProportional(
        uint256 workflowId,
        address token,
        uint256 amount,
        uint256 originalDeposit
    ) external returns (bool success, uint256 actualAmount);

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
}


