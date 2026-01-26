// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import '../interfaces/IYieldGenerationModule.sol';
import '../types/EscrowTypes.sol';
import '../libraries/AaveYieldHandlingLibrary.sol'; // For struct definitions

/**
 * @title IYieldHandlingLibrary
 * @notice Generic interface for yield handling libraries (delegatecall pattern)
 * @dev This interface abstracts yield operations to support multiple yield protocols
 *      Current implementations: AaveYieldHandlingLibrary
 *      Future implementations: CompoundYieldHandlingLibrary, etc.
 * 
 *      Note: Uses AaveYieldHandlingLibrary structs for now. When adding new yield protocols,
 *      extract structs to a shared YieldTypes.sol file.
 */
interface IYieldHandlingLibrary {
    /**
     * @notice Handle yield withdrawal via library pattern
     * @param workflowId The escrow ID
     * @param token Token address
     * @param amount Amount to withdraw
     * @param genModule Yield generation module
     * @param settings Escrow settings
     * @param scaledShares Scaled shares to withdraw
     * @param yieldLibrary Yield library address (for delegatecall)
     * @return result Withdrawal result
     * @dev This is called via delegatecall, so address(this) = BaseEscrow
     *      Returns AaveYieldHandlingLibrary.WithdrawalResult for now
     */
    function handleYieldWithdrawal(
        uint256 workflowId,
        address token,
        uint256 amount,
        IYieldGenerationModule genModule,
        EscrowSettings memory settings,
        uint256 scaledShares,
        address yieldLibrary
    ) external returns (AaveYieldHandlingLibrary.WithdrawalResult memory result);

    /**
     * @notice Handle yield deposit via library pattern
     * @param workflowId The escrow ID
     * @param token Token address
     * @param amount Amount to deposit
     * @param genModule Yield generation module
     * @param settings Escrow settings
     * @param yieldLibrary Yield library address (for delegatecall)
     * @return result Deposit result
     * @dev This is called via delegatecall, so address(this) = BaseEscrow
     *      Returns AaveYieldHandlingLibrary.DepositResult for now
     */
    function handleYieldDeposit(
        uint256 workflowId,
        address token,
        uint256 amount,
        IYieldGenerationModule genModule,
        EscrowSettings memory settings,
        address yieldLibrary
    ) external returns (AaveYieldHandlingLibrary.DepositResult memory result);

    /**
     * @notice Helper to get yield-bearing token address from module
     * @param genModule Yield generation module
     * @param token Underlying token address
     * @return yieldTokenAddress Yield-bearing token address (e.g., aToken for Aave)
     * @dev Implementation-specific: Aave uses aToken, Compound uses cToken, etc.
     */
    function getATokenAddress(IYieldGenerationModule genModule, address token) external view returns (address yieldTokenAddress);
}
