// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

/**
 * @title IYieldModule
 * @notice Interface for yield generation and distribution modules
 * @dev Handles yield generation during escrow lifespan and distribution at closure
 */
interface IYieldModule {
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
     * @notice Distribute yield to recipients
     * @param workflowId The escrow transfer ID
     * @param token Token address
     * @param yieldAmount Amount of yield to distribute
     * @param distributionData Encoded distribution configuration
     * @return success True if distribution was successful
     * @return distributedAmount Total amount distributed
     */
    function distributeYield(
        uint256 workflowId,
        address token,
        uint256 yieldAmount,
        bytes calldata distributionData
    ) external returns (bool success, uint256 distributedAmount);

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
     */
    function getApprovalTarget(address token) external view returns (address approvalTarget);

    /**
     * @notice Get the module name/identifier
     * @return name The module name
     */
    function moduleName() external pure returns (string memory name);
}
